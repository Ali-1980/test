//
//  BackupTask.m
//  MFCTOOL
//
//  Created by Monterey on 5/5/2025.
//
#import <AppKit/AppKit.h>
#import "BackupTask.h"
#import <libimfccore/libimfccore.h>
#import <libimfccore/lockdown.h>
#import <libimfccore/mobilebackup2.h>
#import <libimfccore/afc.h>
#import <plist/plist.h>
#import "DatalogsSettings.h"
#import <stdatomic.h>

// 错误域定义
NSString *const MFCToolBackupErrorDomain = @"com.MFCTOOL.backup";

// 队列特定标识
static const void *kStateQueueSpecificKey = &kStateQueueSpecificKey;
static void *kStateQueueSpecificValue = (void *)&kStateQueueSpecificValue;

// 协议版本
#define MBACKUP2_VERSION_INT1 2
#define MBACKUP2_VERSION_INT2 1

// 常量定义
#define MAX_RETRY_COUNT 3
#define MAX_TIMEOUT_SECONDS 15.0

#define MAX_SILENCE_DURATION 120.0
#define MAX_PROCESS_DURATION 3600.0

#define HEARTBEAT_INTERVAL 1.0          // 降低心跳间隔为1秒
#define HEARTBEAT_TIMEOUT 2.0           // 心跳超时时间为2秒
#define MAX_HEARTBEAT_RETRIES 3         // 最大心跳重试次数
#define HEARTBEAT_RECOVERY_DELAY 0.5    // 心跳恢复延迟

#define SSL_RETRY_INTERVAL 0.5
#define MAX_SSL_RETRIES 3
#define MIN_HEARTBEAT_INTERVAL 1.0
#define MAX_HEARTBEAT_INTERVAL 5.0

// 日志级别
typedef NS_ENUM(NSInteger, MFCLogLevel) {
    MFCLogLevelError = 0,    // 仅显示错误
    MFCLogLevelWarning = 1,  // 显示警告和错误
    MFCLogLevelInfo = 2,     // 显示信息、警告和错误
    MFCLogLevelDebug = 3,    // 显示调试信息、信息、警告和错误
    MFCLogLevelVerbose = 4   // 显示详细调试信息
};

typedef struct {
    BOOL isValid;
    int64_t lastSuccess;
    int failureCount;
    int nextInterval;
} SSLConnectionState;

#pragma mark - 备份上下文结构

// 备份上下文结构
typedef struct BackupContext {
    idevice_t device;                // 设备句柄
    lockdownd_client_t lockdown;     // Lockdown客户端
    mobilebackup2_client_t backup;   // MobileBackup2客户端
    afc_client_t afc;                // AFC客户端
    BOOL isEncrypted;                // 备份是否加密
    BOOL passwordRequired;           // 是否需要密码
    NSString *password;              // 备份密码
    NSDate *startTime;               // 开始时间
    NSString *deviceUDID;            // 设备UDID
    NSString *backupPath;            // 备份路径
    double protocolVersion;          // 协议版本
} BackupContext;


#pragma mark - 私有接口

@interface BackupTask () {
    BackupContext *_backupContext;   // 备份上下文
    SSLConnectionState _sslState;    // SSL状态作为实例变量
}

// 并发控制
@property (nonatomic, strong) dispatch_queue_t connectionQueue;  // 连接操作队列
@property (nonatomic, strong) dispatch_queue_t stateQueue;       // 状态管理队列
@property (nonatomic, strong) dispatch_queue_t fileQueue;        // 文件操作队列
@property (nonatomic, strong) dispatch_queue_t backupQueue;      // 后台备份队列
@property (nonatomic, strong) NSCondition *pauseCondition;       // 暂停条件变量

// 控制状态
@property (atomic, assign) BackupState internalState;         // 内部状态
@property (atomic, assign) BOOL shouldCancel;                 // 取消标志
@property (atomic, assign) BOOL shouldPause;                  // 暂停标志
@property (nonatomic, assign) NSInteger logLevel;             // 日志级别


// 进度和统计
@property (nonatomic, assign) long long totalBytesReceived;      // 已接收总字节数
@property (nonatomic, assign) int filesProcessed;                // 已处理文件数
@property (nonatomic, assign) int totalFiles;                    // 总文件数
@property (nonatomic, assign) double lastReportedProgress;       // 上次报告的进度
@property (nonatomic, strong) NSDate *lastProgressUpdateTime;    // 上次进度更新时间
@property (nonatomic, assign, readwrite) long long estimatedTotalBytes; // 估计总字节数

// 定时器和回调
@property (nonatomic, strong) dispatch_source_t progressTimer;   // 进度定时器
@property (nonatomic, copy) BackupProgressBlock progressCallback;     // 进度回调
@property (nonatomic, copy) BackupCompletionBlock completionCallback; // 完成回调
@property (nonatomic, copy) BackupPasswordBlock passwordCallback;     // 密码回调

// 日志管理
@property (nonatomic, strong) NSMutableString *logCollector;     // 日志收集器
@property (nonatomic, strong) NSString *logFilePath;             // 日志文件路径

// 重连管理
@property (nonatomic, assign) NSInteger reconnectAttempts;       // 重连尝试次数

// 跟踪信息
@property (nonatomic, strong) NSDate *lastMessageTime;           // 上次消息时间
@property (nonatomic, assign) BOOL isConnected;                  // 是否已连接

// 添加新的SSL相关属性
@property (nonatomic, strong) dispatch_queue_t sslQueue;
@property (nonatomic, strong) NSLock *sslStateLock;

@end

#pragma mark - 实现
@implementation BackupTask

#pragma mark - 单例方法

+ (instancetype)sharedInstance {
    static BackupTask *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

#pragma mark - 初始化和销毁

- (instancetype)init {
    self = [super init];
    if (self) {
        // 创建并发控制队列
        _connectionQueue = dispatch_queue_create("com.MFCTOOL.connection", DISPATCH_QUEUE_SERIAL);
        _stateQueue = dispatch_queue_create("com.MFCTOOL.state", DISPATCH_QUEUE_SERIAL);
        _fileQueue = dispatch_queue_create("com.MFCTOOL.file", DISPATCH_QUEUE_SERIAL);
        _backupQueue = dispatch_queue_create("com.MFCTOOL.backup", DISPATCH_QUEUE_SERIAL);
        
        // 设置队列特定键，用于识别当前线程是否在指定队列上
        dispatch_queue_set_specific(_stateQueue, kStateQueueSpecificKey, kStateQueueSpecificValue, NULL);
        
        // 初始化状态
        _internalState = BackupStateIdle;
        _shouldCancel = NO;
        _shouldPause = NO;
        _pauseCondition = [[NSCondition alloc] init];
        _isConnected = NO;
        
        // 初始化统计信息
        _totalBytesReceived = 0;
        _filesProcessed = 0;
        _totalFiles = 0;
        _lastReportedProgress = 0.0;
        _estimatedTotalBytes = 0;
        _logLevel = MFCLogLevelInfo;
        
        // 初始化日志
        _logCollector = [NSMutableString string];
        
        // 初始化SSL相关
        _sslQueue = dispatch_queue_create("com.MFCTOOL.ssl", DISPATCH_QUEUE_SERIAL);
        _sslStateLock = [[NSLock alloc] init];
        
        // 初始化SSL状态
        _sslState = (SSLConnectionState){
            .isValid = YES,              // 使用YES代替1
            .lastSuccess = 0,
            .failureCount = 0,
            .nextInterval = MIN_HEARTBEAT_INTERVAL
        };
        
        [self logInfo:@"BackupTask初始化完成"];
    }
    return self;
}

// 添加SSL状态安全访问方法
- (BOOL)isSSLValid {
    [self.sslStateLock lock];
    BOOL valid = NO;
    @try {
        valid = _sslState.isValid;
    } @finally {
        [self.sslStateLock unlock];
    }
    return valid;
}

- (void)setSSLValid:(BOOL)valid {
    [self.sslStateLock lock];
    @try {
        _sslState.isValid = valid;
    } @finally {
        [self.sslStateLock unlock];
    }
}

- (void)incrementSSLFailureCount {
    [self.sslStateLock lock];
    @try {
        _sslState.failureCount++;
    } @finally {
        [self.sslStateLock unlock];
    }
}

- (int)sslFailureCount {
    [self.sslStateLock lock];
    int count = 0;
    @try {
        count = _sslState.failureCount;
    } @finally {
        [self.sslStateLock unlock];
    }
    return count;
}

- (void)updateSSLState:(void (^)(SSLConnectionState *state))updateBlock {
    if (!updateBlock) return;
    
    [self.sslStateLock lock];
    @try {
        // 创建临时状态
        SSLConnectionState tempState = _sslState;
        // 在临时状态上执行更新
        updateBlock(&tempState);
        // 原子性地更新真实状态
        _sslState = tempState;
    } @finally {
        [self.sslStateLock unlock];
    }
}


- (void)dealloc {
    [self logInfo:@"BackupTask对象销毁，执行清理"];
    
    // 标记取消
    dispatch_sync(self.stateQueue, ^{
        self.shouldCancel = YES;
    });
    
    // 清理资源
    [self cleanupAll];
    
    [self logInfo:@"BackupTask对象销毁完成"];
}

#pragma mark - 公共方法

- (void)startBackupForDevice:(NSString *)udid
                    progress:(BackupProgressBlock)progressCallback
                  completion:(BackupCompletionBlock)completionCallback {
    
    // 参数验证
    if (!udid || [udid length] == 0) {
        [self logError:@"UDID为空或无效"];
        if (completionCallback) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSError *error = [self createError:MFCToolBackupErrorDeviceConnection
                                       description:@"UDID为空或无效"];
                completionCallback(NO, error);
            });
        }
        return;
    }
    
    [self logInfo:@"启动备份任务，设备UDID: %@", udid];
    
    // 验证当前状态
    __block BOOL canProceed = NO;
    dispatch_sync(self.stateQueue, ^{
        if (self.internalState == BackupStateIdle) {
            self.internalState = BackupStateInitializing;
            self.shouldCancel = NO;
            self.shouldPause = NO;
            canProceed = YES;
        }
    });
    
    if (!canProceed) {
        [self logError:@"备份任务正在进行中，无法启动新任务"];
        if (completionCallback) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSError *error = [self createError:MFCToolBackupErrorInternal
                                       description:@"备份任务正在进行中"];
                completionCallback(NO, error);
            });
        }
        return;
    }
    
    // 保存回调
    self.progressCallback = progressCallback;
    self.completionCallback = completionCallback;
    
    // 创建备份上下文
    _backupContext = calloc(1, sizeof(BackupContext));
    if (!_backupContext) {
        [self logError:@"备份上下文内存分配失败"];
        [self finishWithError:[self createError:MFCToolBackupErrorInternal
                                    description:@"内存分配失败"]];
        return;
    }
    
    // 设置UDID
    _backupContext->deviceUDID = [udid copy];
    [self logInfo:@"备份上下文创建成功，UDID: %@", _backupContext->deviceUDID];
    
    // 启动定时器
    [self startProgressTimer];
    
    // 启动后台备份任务
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @try {
            [self logInfo:@"开始异步备份任务"];
            [self internalStartBackup];
            [self logInfo:@"异步备份任务完成"];
        } @catch (NSException *exception) {
            [self logError:@"备份任务发生异常: %@\n堆栈: %@", exception, [exception callStackSymbols]];
            
            NSError *error = [self createError:MFCToolBackupErrorInternal
                                   description:[NSString stringWithFormat:@"备份异常: %@",
                                              exception.reason]];
            [self finishWithError:error];
        }
    });
    
    [self logInfo:@"备份任务已分派到后台队列"];
}

- (void)pauseBackup {
    dispatch_async(self.stateQueue, ^{
        if (self.internalState == BackupStateBackingUp) {
            self.shouldPause = YES;
            [self logInfo:@"备份已请求暂停"];
        } else {
            [self logWarning:@"备份未在进行中，无法暂停"];
        }
    });
}

- (void)resumeBackup {
    dispatch_async(self.stateQueue, ^{
        if (self.shouldPause) {
            self.shouldPause = NO;
            [self logInfo:@"备份已恢复"];
            [self.pauseCondition signal];
        } else {
            [self logWarning:@"备份未暂停，无需恢复"];
        }
    });
}

- (void)cancelBackup {
    dispatch_async(self.stateQueue, ^{
        if (self.internalState == BackupStateBackingUp ||
            self.internalState == BackupStateRequiringPassword ||
            self.internalState == BackupStateInitializing ||
            self.internalState == BackupStateNegotiating) {
            
            self.shouldCancel = YES;
            [self.pauseCondition signal]; // 唤醒可能等待的线程
            [self logInfo:@"备份已请求取消"];
            [self transitionToState:BackupStateCancelled];
        } else {
            [self logWarning:@"备份未在进行中，无法取消"];
        }
    });
}

- (void)providePassword:(NSString *)password {
    // 创建弱引用避免循环引用
    __weak typeof(self) weakSelf = self;
    
    dispatch_async(self.stateQueue, ^{
        // 强引用确保在block执行期间self不会被释放
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        
        if (strongSelf.passwordCallback) {
            [strongSelf logInfo:@"收到用户提供的密码，长度: %lu", (unsigned long)password.length];
            
            // 保存密码到上下文
            dispatch_sync(strongSelf.connectionQueue, ^{
                // 显式使用self表明这是有意为之的引用
                if (strongSelf->_backupContext) {
                    strongSelf->_backupContext->password = [password copy];
                }
            });
            
            strongSelf.passwordCallback(password);
            strongSelf.passwordCallback = nil;
        } else {
            [strongSelf logWarning:@"没有密码回调处理程序"];
        }
    });
}

- (void)setLogLevel:(NSInteger)level {
    _logLevel = MAX(0, MIN(4, level));
    [self logInfo:@"日志级别设置为: %ld", (long)_logLevel];
}

#pragma mark - 状态管理

- (BackupState)currentState {
    if (dispatch_get_specific(kStateQueueSpecificKey) == kStateQueueSpecificValue) {
        return self.internalState;
    } else {
        __block BackupState state;
        dispatch_sync(self.stateQueue, ^{
            state = self.internalState;
        });
        return state;
    }
}

- (double)currentProgress {
    if (dispatch_get_specific(kStateQueueSpecificKey) == kStateQueueSpecificValue) {
        return self.lastReportedProgress;
    } else {
        __block double progress;
        dispatch_sync(self.stateQueue, ^{
            progress = self.lastReportedProgress;
        });
        return progress;
    }
}

- (long long)getEstimatedTotalBytes {
    __block long long bytes;
    dispatch_sync(self.stateQueue, ^{
        bytes = self.estimatedTotalBytes;
    });
    return bytes;
}

- (NSString *)getEstimatedTotalBytesFormatted {
    long long bytes = [self getEstimatedTotalBytes];
    if (bytes <= 0) {
        return @"未知";
    }
    return [DatalogsSettings humanReadableFileSize:bytes];
}

#pragma mark - 内部实现

- (void)internalStartBackup {
    __block NSError *error = nil;  // 添加__block修饰符
    
    [self logInfo:@"=== 开始内部备份流程 ==="];
    
    @try {
        // 步骤1: 准备备份目录
        [self logInfo:@"步骤1: 准备备份目录 - 开始"];
        if (![self prepareBackupDirectory:&error]) {
            [self logError:@"步骤1: 准备备份目录失败: %@", error.localizedDescription];
            [self finishWithError:error];
            return;
        }
        [self logInfo:@"步骤1: 准备备份目录 - 完成"];
        
        // 步骤2: 连接设备
        [self logInfo:@"步骤2: 连接设备 - 开始"];
        if (![self connectToDevice:&error]) {
            [self logError:@"步骤2: 连接设备失败: %@", error.localizedDescription];
            [self finishWithError:error];
            return;
        }
        [self logInfo:@"步骤2: 连接设备 - 完成"];
        
        // 步骤3: 初始化服务
        [self logInfo:@"步骤3: 初始化服务 - 开始"];
        if (![self initializeServices:&error]) {
            [self logError:@"步骤3: 初始化服务失败: %@", error.localizedDescription];
            [self finishWithError:error];
            return;
        }
        [self logInfo:@"步骤3: 初始化服务 - 完成"];
        
        // 步骤4: 执行备份
        [self logInfo:@"步骤4: 执行备份 - 开始"];
        if (![self performBackup:&error]) {
            [self logError:@"步骤4: 执行备份失败: %@", error.localizedDescription];
            [self finishWithError:error];
            return;
        }
        [self logInfo:@"步骤4: 执行备份 - 完成"];
        
        // 备份成功
        [self logInfo:@"所有步骤完成，备份成功"];
        [self finishWithSuccess];
        
    } @catch (NSException *exception) {
        [self logError:@"备份过程发生异常: %@\n堆栈: %@", exception, [exception callStackSymbols]];
        error = [self createError:MFCToolBackupErrorInternal
                      description:[NSString stringWithFormat:@"异常: %@", exception.reason]];
        [self finishWithError:error];
    } @finally {
        // 确保清理资源
        [self cleanupAll];
        [self logInfo:@"备份任务清理完成"];
        
        // 确保状态重置
        dispatch_sync(self.stateQueue, ^{
            if (self.internalState != BackupStateCompleted &&
                self.internalState != BackupStateError &&
                self.internalState != BackupStateCancelled) {
                self.internalState = BackupStateError;
                if (!error) {
                    error = [self createError:MFCToolBackupErrorInternal
                                  description:@"备份任务异常终止"];
                }
                [self finishWithError:error];
            }
        });
        
        [self logInfo:@"=== 内部备份流程结束 ==="];
    }
}

#pragma mark - 备份流程实现

- (BOOL)prepareBackupDirectory:(NSError **)error {
    [self logInfo:@"准备备份目录"];
    
    // 检查设置类可用性
    if (![DatalogsSettings class]) {
        [self logError:@"DatalogsSettings类不可用"];
        if (error) {
            *error = [self createError:MFCToolBackupErrorInternal
                          description:@"DatalogsSettings类不可用"];
        }
        return NO;
    }
    
    // 获取备份基础路径
    NSString *baseBackupPath = [DatalogsSettings defaultBackupPath];
    [self logDebug:@"基础备份路径: %@", baseBackupPath];
    
    if (!baseBackupPath || [baseBackupPath length] == 0) {
        [self logError:@"无效的备份基础路径"];
        if (error) {
            *error = [self createError:MFCToolBackupErrorFileOperation
                          description:@"无效的备份基础路径"];
        }
        return NO;
    }
    
    // 构建完整备份路径
    if (!_backupContext || !_backupContext->deviceUDID) {
        [self logError:@"备份上下文或UDID为空"];
        if (error) {
            *error = [self createError:MFCToolBackupErrorInternal
                          description:@"备份上下文或UDID为空"];
        }
        return NO;
    }
    
    _backupContext->backupPath = [baseBackupPath stringByAppendingPathComponent:_backupContext->deviceUDID];
    [self logInfo:@"完整备份路径: %@", _backupContext->backupPath];
    
    // 确认或创建目录
    BOOL isDir = NO;
    NSFileManager *fileManager = [NSFileManager defaultManager];
    
    if (![fileManager fileExistsAtPath:_backupContext->backupPath isDirectory:&isDir]) {
        [self logInfo:@"创建备份目录..."];
        NSError *createError = nil;
        
        if (![fileManager createDirectoryAtPath:_backupContext->backupPath
                    withIntermediateDirectories:YES
                                     attributes:nil
                                          error:&createError]) {
            [self logError:@"创建备份目录失败: %@", createError.localizedDescription];
            if (error) {
                *error = [self createError:MFCToolBackupErrorFileOperation
                              description:[NSString stringWithFormat:@"创建备份目录失败: %@",
                                          createError.localizedDescription]];
            }
            return NO;
        }
        
        [self logInfo:@"备份目录创建成功"];
    } else if (!isDir) {
        [self logError:@"备份路径不是目录"];
        if (error) {
            *error = [self createError:MFCToolBackupErrorFileOperation
                          description:@"备份路径不是目录"];
        }
        return NO;
    } else {
        [self logInfo:@"备份目录已存在"];
    }
    
    // 创建日志文件路径
    self.logFilePath = [_backupContext->backupPath stringByAppendingPathComponent:@"backup_log.txt"];
    [self logDebug:@"日志文件路径: %@", self.logFilePath];
    
    // 初始化空日志文件
    NSString *timestamp = [[NSDate date] description];
    NSString *logInitText = [NSString stringWithFormat:@"--- 备份日志开始: %@ ---\n", timestamp];
    NSError *writeError = nil;
    
    if (![logInitText writeToFile:self.logFilePath
                       atomically:YES
                         encoding:NSUTF8StringEncoding
                            error:&writeError]) {
        [self logWarning:@"初始化日志文件失败: %@", writeError.localizedDescription];
        // 继续执行，不阻止备份
    }
    
    // 确保备份结构
    return [self ensureBackupStructure:error];
}

- (BOOL)connectToDevice:(NSError **)error {
    [self logInfo:@"连接设备: %@", _backupContext->deviceUDID];
    [self updateProgress:0.01 message:@"连接设备..."];
    
    // 状态检查
    if (!_backupContext) {
        [self logError:@"备份上下文为空"];
        if (error) {
            *error = [self createError:MFCToolBackupErrorInternal
                          description:@"备份上下文为空"];
        }
        return NO;
    }
    
    // 尝试多次连接设备，使用USBMUX选项
    idevice_error_t ierr = IDEVICE_E_UNKNOWN_ERROR;
    int retries = 0;
    int maxRetries = MAX_RETRY_COUNT;
    
    while (retries < maxRetries) {
        [self logDebug:@"连接设备尝试 %d/%d", retries + 1, maxRetries];
        
        // 使用USBMUX选项，与成功的配对方法保持一致
        ierr = idevice_new_with_options(&_backupContext->device,
                                        [_backupContext->deviceUDID UTF8String],
                                        IDEVICE_LOOKUP_USBMUX);
        
        [self logDebug:@"idevice_new_with_options返回代码: %d", ierr];
        
        if (ierr == IDEVICE_E_SUCCESS) {
            break;
        }
        
        retries++;
        if (retries < maxRetries) {
            [self logWarning:@"连接失败，等待2秒后重试..."];
            [NSThread sleepForTimeInterval:2.0];
            
            // 检查是否已取消
            if ([self shouldCancel]) {
                [self logInfo:@"连接设备过程被取消"];
                if (error) {
                    *error = [self createError:MFCToolBackupErrorCancelled
                                  description:@"用户取消了备份"];
                }
                return NO;
            }
        }
    }
    
    // 检查连接结果
    if (ierr != IDEVICE_E_SUCCESS) {
        [self logError:@"设备连接失败，错误代码: %d", ierr];
        if (error) {
            *error = [self createError:MFCToolBackupErrorDeviceConnection
                          description:[NSString stringWithFormat:@"设备连接失败，错误代码: %d", ierr]];
        }
        return NO;
    }
    
    [self logInfo:@"设备连接成功"];
    
    // 创建Lockdown客户端
    [self logDebug:@"创建Lockdown客户端"];
    lockdownd_error_t lerr = lockdownd_client_new_with_handshake(_backupContext->device,
                                                              &_backupContext->lockdown,
                                                              "MFCTOOL");
    
    if (lerr != LOCKDOWN_E_SUCCESS) {
        [self logError:@"Lockdown客户端创建失败，错误代码: %d", lerr];
        if (error) {
            *error = [self createError:MFCToolBackupErrorLockdown
                          description:[NSString stringWithFormat:@"Lockdown客户端创建失败，错误代码: %d", lerr]];
        }
        return NO;
    }
    
    [self logInfo:@"Lockdown客户端创建成功"];
    
    // 检查设备状态
    return [self checkDeviceState:error];
}


- (BOOL)checkDeviceState:(NSError **)error {
    [self logDebug:@"检查设备状态"];
    
    dispatch_sync(self.connectionQueue, ^{
        _isConnected = (_backupContext && _backupContext->device && _backupContext->lockdown);
    });
    
    if (!_isConnected) {
        [self logError:@"设备连接无效"];
        if (error) {
            *error = [self createError:MFCToolBackupErrorDeviceConnection
                          description:@"设备连接无效"];
        }
        return NO;
    }
    
    // 获取设备名称
    char *deviceName = NULL;
    lockdownd_error_t lerr = lockdownd_get_device_name(_backupContext->lockdown, &deviceName);
    
    if (lerr != LOCKDOWN_E_SUCCESS || !deviceName) {
        [self logError:@"无法获取设备名称，错误代码: %d", lerr];
        
        // 如果是密码保护错误，明确提示需要解锁
        if (lerr == LOCKDOWN_E_PASSWORD_PROTECTED) {
            [self logError:@"设备被密码保护，需要解锁设备"];
            if (error) {
                *error = [self createError:MFCToolBackupErrorDeviceLocked
                              description:@"设备已锁定，请解锁设备后重试"];
            }
            return NO;
        }
        
        if (error) {
            *error = [self createError:MFCToolBackupErrorDeviceConnection
                          description:[NSString stringWithFormat:@"无法获取设备名称，错误代码: %d", lerr]];
        }
        return NO;
    }
    
    [self logInfo:@"设备名称: %s", deviceName];
    
    // 保存配对信息 (借鉴triggerPairForDeviceWithUDID:方法的实现)
    NSData *pairKeyData = [NSData dataWithBytes:deviceName length:strlen(deviceName)];
    [self savePairKey:pairKeyData forDeviceWithUDID:_backupContext->deviceUDID];
    
    free(deviceName);
    
    // 检查设备信任状态
    plist_t trustState = NULL;
    lerr = lockdownd_get_value(_backupContext->lockdown, "com.apple.mobile.lockdown", "HostAttached", &trustState);
    
    if (lerr == LOCKDOWN_E_SUCCESS && trustState && plist_get_node_type(trustState) == PLIST_BOOLEAN) {
        uint8_t isTrusted = 0;
        plist_get_bool_val(trustState, &isTrusted);
        
        if (!isTrusted) {
            [self logError:@"设备未被信任，无法继续备份"];
            
            // 显示Alert提醒用户在设备上确认信任
            dispatch_async(dispatch_get_main_queue(), ^{
                NSAlert *alert = [[NSAlert alloc] init];
                [alert setMessageText:@"设备未信任"];
                [alert setInformativeText:@"请在iOS设备上点击‘信任此电脑’按钮后重试。"];
                [alert addButtonWithTitle:@"好的"];
                [alert runModal];
            });
            
            if (error) {
                *error = [self createError:MFCToolBackupErrorTrustNotEstablished
                                description:@"设备未被信任，请在设备上信任此电脑"];
            }
            plist_free(trustState);
            return NO;
        }
        plist_free(trustState);
    } else {
        // 处理错误码-12 (LOCKDOWN_E_PASSWORD_PROTECTED)
        if (lerr == LOCKDOWN_E_PASSWORD_PROTECTED) {
            [self logError:@"设备需要解锁才能获取信任状态，错误代码: %d", lerr];
            
            // 显示Alert提醒用户解锁设备
            dispatch_async(dispatch_get_main_queue(), ^{
                NSAlert *alert = [[NSAlert alloc] init];
                [alert setMessageText:@"设备已锁定"];
                [alert setInformativeText:@"请解锁iOS设备后重试。"];
                [alert addButtonWithTitle:@"好的"];
                [alert runModal];
            });
            
            if (error) {
                *error = [self createError:MFCToolBackupErrorDeviceLocked
                              description:@"设备已锁定，请解锁后重试"];
            }
            return NO;
        }
        
        [self logWarning:@"无法获取设备信任状态，错误代码: %d，可能需要信任设备", lerr];
        
        // 添加显式配对过程 (借鉴triggerPairForDeviceWithUDID:方法)
        NSString *pairingResult = [self performPairingWithClient:_backupContext->lockdown];
        
        if ([pairingResult containsString:@"配对失败"] || [pairingResult containsString:@"失败"]) {
            [self logError:@"设备配对失败: %@", pairingResult];
            if (error) {
                *error = [self createError:MFCToolBackupErrorTrustNotEstablished
                              description:[NSString stringWithFormat:@"设备配对失败: %@", pairingResult]];
            }
            return NO;
        }
    }
    
    // 检查设备锁定状态
    plist_t lockState = NULL;
    lerr = lockdownd_get_value(_backupContext->lockdown, "com.apple.mobile.lockdown", "DeviceLocked", &lockState);
    
    if (lerr == LOCKDOWN_E_SUCCESS && lockState && plist_get_node_type(lockState) == PLIST_BOOLEAN) {
        uint8_t isLocked = 0;
        plist_get_bool_val(lockState, &isLocked);
        
        if (isLocked) {
            [self logError:@"设备已锁定，无法继续备份"];
            
            // 显示Alert提示用户
            dispatch_async(dispatch_get_main_queue(), ^{
                NSAlert *alert = [[NSAlert alloc] init];
                [alert setMessageText:@"设备已锁定"];
                [alert setInformativeText:@"请解锁设备后重试。"];
                [alert addButtonWithTitle:@"好的"];
                [alert runModal];
            });
            
            if (error) {
                *error = [self createError:MFCToolBackupErrorDeviceLocked
                                description:@"设备已锁定，请解锁后重试"];
            }
            
            plist_free(lockState);
            return NO;
        }
        plist_free(lockState);
    } else if (lerr == LOCKDOWN_E_PASSWORD_PROTECTED) {
        [self logError:@"设备需要解锁，错误代码: %d", lerr];
        if (error) {
            *error = [self createError:MFCToolBackupErrorDeviceLocked
                              description:@"设备需要解锁，请解锁后重试"];
        }
        return NO;
    }
    
    // 检查设备电量
    plist_t batteryState = NULL;
    lerr = lockdownd_get_value(_backupContext->lockdown, "com.apple.mobile.battery", "BatteryCurrentCapacity", &batteryState);
    
    if (lerr == LOCKDOWN_E_SUCCESS && batteryState && plist_get_node_type(batteryState) == PLIST_UINT) {
        uint64_t batteryLevel = 0;
        plist_get_uint_val(batteryState, &batteryLevel);
        
        [self logInfo:@"设备电量: %llu%%", batteryLevel];
        if (batteryLevel < 20) {
            [self logWarning:@"设备电量过低 (%llu%%)，建议充电后继续备份", batteryLevel];
        }
        plist_free(batteryState);
    }
    
    return YES;
}


// 添加 savePairKey 方法，保存配对信息
- (void)savePairKey:(NSData *)pairKeyData forDeviceWithUDID:(NSString *)udid {
    if (!pairKeyData || !udid) {
        [self logWarning:@"无法保存配对信息：无效的参数"];
        return;
    }
    
    NSString *pairingDataPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/MobileDevice/Provisioning Profiles"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:pairingDataPath]) {
        NSError *error = nil;
        [[NSFileManager defaultManager] createDirectoryAtPath:pairingDataPath
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:&error];
        if (error) {
            [self logWarning:@"无法创建配对数据目录: %@", error.localizedDescription];
            return;
        }
    }
    
    NSString *pairingFilePath = [pairingDataPath stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.plist", udid]];
    
    // 创建简单的配对数据
    NSMutableDictionary *pairingDict = [NSMutableDictionary dictionary];
    [pairingDict setObject:pairKeyData forKey:@"DeviceName"];
    [pairingDict setObject:udid forKey:@"DeviceUDID"];
    [pairingDict setObject:[NSDate date] forKey:@"PairingDate"];
    
    NSError *error = nil;
    NSData *plistData = [NSPropertyListSerialization dataWithPropertyList:pairingDict
                                                                   format:NSPropertyListXMLFormat_v1_0
                                                                  options:0
                                                                    error:&error];
    
    if (error || !plistData) {
        [self logWarning:@"无法序列化配对信息: %@", error.localizedDescription];
        return;
    }
    
    if (![plistData writeToFile:pairingFilePath atomically:YES]) {
        [self logWarning:@"无法写入配对信息至: %@", pairingFilePath];
    } else {
        [self logInfo:@"成功保存设备配对信息"];
    }
}

// 添加 performPairingWithClient 方法，执行配对过程
- (NSString *)performPairingWithClient:(lockdownd_client_t)client {
    if (!client) {
        return @"配对失败：无效的Lockdown客户端";
    }
    
    [self logInfo:@"开始执行设备配对流程"];
    
    // 检查配对状态
    uint8_t paired = 0;
    lockdownd_error_t lerr = lockdownd_query_type(client, NULL);
    
    if (lerr == LOCKDOWN_E_SUCCESS) {
        [self logInfo:@"设备已配对"];
        return @"设备已成功配对";
    }
    
    // 开始配对过程
    lerr = lockdownd_pair(client, NULL);
    if (lerr == LOCKDOWN_E_SUCCESS) {
        [self logInfo:@"设备配对成功"];
        return @"设备配对成功";
    } else {
        NSString *errorMsg = [NSString stringWithFormat:@"设备配对失败，错误代码: %d", lerr];
        
        // 如果是用户拒绝，给出更具体的提示
        if (lerr == LOCKDOWN_E_USER_DENIED_PAIRING) {
            [self logError:@"用户拒绝配对"];
            errorMsg = @"用户在设备上拒绝了配对请求，请在设备上点击‘信任’";
        } else if (lerr == LOCKDOWN_E_PASSWORD_PROTECTED) {
            [self logError:@"设备已锁定，无法配对"];
            errorMsg = @"设备已锁定，请解锁后再尝试配对";
        } else if (lerr == LOCKDOWN_E_PAIRING_DIALOG_RESPONSE_PENDING) {
            [self logInfo:@"设备等待用户确认配对请求"];
            errorMsg = @"请在设备上确认信任请求";
        }
        
        [self logError:@"%@", errorMsg];
        return errorMsg;
    }
}


- (BOOL)initializeServices:(NSError **)error {
    [self logInfo:@"初始化服务"];
    [self updateProgress:0.03 message:@"初始化服务..."];
    
    __block BOOL success = NO;
    __block NSError *localError = nil;
    
    dispatch_sync(self.connectionQueue, ^{
        // 启动AFC服务（文件访问）
        [self logDebug:@"启动AFC服务"];
        lockdownd_service_descriptor_t afc_service = NULL;
        lockdownd_error_t lerr = lockdownd_start_service(_backupContext->lockdown,
                                                      "com.apple.afc",
                                                      &afc_service);
        
        if (lerr != LOCKDOWN_E_SUCCESS || !afc_service) {
            [self logError:@"AFC服务启动失败，错误代码: %d", lerr];
            localError = [self createError:MFCToolBackupErrorTrustNotEstablished
                              description:@"无法访问设备文件系统，请确保设备已信任此电脑"];
            success = NO;
            return;
        }
        
        // 创建AFC客户端
        afc_client_new(_backupContext->device, afc_service, &_backupContext->afc);
        lockdownd_service_descriptor_free(afc_service);
        
        [self logDebug:@"AFC服务启动成功"];
        
        // 添加SSL会话预热
        [self logDebug:@"预热SSL会话"];
        if (![self warmupSSLSession]) {
            [self logWarning:@"SSL会话预热失败，继续尝试服务启动"];
        }
        
        // 启动MobileBackup2服务（添加重试机制）
        int retryCount = 0;
        const int maxRetries = 3;
        mobilebackup2_error_t mb2_err = MOBILEBACKUP2_E_SSL_ERROR;
        
        while (retryCount < maxRetries) {
            [self logDebug:@"启动MobileBackup2服务 (尝试 %d/%d)", retryCount + 1, maxRetries];
            
            lockdownd_service_descriptor_t backup_service = NULL;
            lerr = lockdownd_start_service(_backupContext->lockdown,
                                         "com.apple.mobilebackup2",
                                         &backup_service);
            
            if (lerr != LOCKDOWN_E_SUCCESS || !backup_service) {
                [self logError:@"MobileBackup2服务启动失败，错误代码: %d", lerr];
                retryCount++;
                if (retryCount < maxRetries) {
                    [NSThread sleepForTimeInterval:2.0];
                    continue;
                }
                localError = [self createError:MFCToolBackupErrorService
                                  description:@"无法启动备份服务，请重新连接设备"];
                success = NO;
                return;
            }
            
            // 创建MobileBackup2客户端
            mb2_err = mobilebackup2_client_new(_backupContext->device,
                                             backup_service,
                                             &_backupContext->backup);
            
            lockdownd_service_descriptor_free(backup_service);
            
            if (mb2_err == MOBILEBACKUP2_E_SSL_ERROR) {
                [self logError:@"SSL连接失败，尝试重新建立 (%d/%d)", retryCount + 1, maxRetries];
                
                // 记录SSL错误详情
                [self logSSLErrorDetails:mb2_err];
                
                // 清理之前的连接
                if (_backupContext->backup) {
                    mobilebackup2_client_free(_backupContext->backup);
                    _backupContext->backup = NULL;
                }
                
                retryCount++;
                if (retryCount < maxRetries) {
                    // 重置SSL状态
                    [self resetSSLState];
                    [NSThread sleepForTimeInterval:2.0];
                    continue;
                }
                
                NSString *errorDescription = [NSString stringWithFormat:
                    @"无法建立安全连接，请检查：\n"
                    "1. 设备是否已解锁\n"
                    "2. 是否信任此电脑\n"
                    "3. USB连接是否稳定\n"
                    "错误代码: %d", mb2_err];
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSAlert *alert = [[NSAlert alloc] init];
                    [alert setMessageText:@"安全连接失败"];
                    [alert setInformativeText:errorDescription];
                    [alert addButtonWithTitle:@"确定"];
                    [alert setAlertStyle:NSAlertStyleCritical];
                    [alert runModal];
                });
                
                localError = [self createError:MFCToolBackupErrorSSL
                                  description:errorDescription];
                success = NO;
                return;
            } else if (mb2_err != MOBILEBACKUP2_E_SUCCESS) {
                [self logError:@"MobileBackup2客户端创建失败，错误代码: %d", mb2_err];
                retryCount++;
                if (retryCount < maxRetries) {
                    [NSThread sleepForTimeInterval:2.0];
                    continue;
                }
                localError = [self createError:MFCToolBackupErrorService
                                  description:[NSString stringWithFormat:@"MobileBackup2客户端创建失败，错误代码: %d", mb2_err]];
                success = NO;
                return;
            }
            
            // 如果成功，跳出重试循环
            break;
        }
        
        [self logInfo:@"MobileBackup2服务已准备就绪"];
        _backupContext->startTime = [NSDate date];
        success = YES;
    });
    
    if (!success && localError) {
        if (error) {
            *error = localError;
        }
        return NO;
    }
    
    return success;
}

// 新增：SSL会话预热方法
- (BOOL)warmupSSLSession {
    if (!_backupContext || !_backupContext->device) {
        return NO;
    }
    
    // 执行一个简单的设备信息查询来预热SSL会话
    char *deviceName = NULL;
    lockdownd_error_t lerr = lockdownd_get_device_name(_backupContext->lockdown, &deviceName);
    if (deviceName) {
        free(deviceName);
    }
    
    return (lerr == LOCKDOWN_E_SUCCESS);
}

// 新增：重置SSL状态方法
- (void)resetSSLState {
    if (_backupContext && _backupContext->backup) {
        mobilebackup2_client_free(_backupContext->backup);
        _backupContext->backup = NULL;
    }
    
    // 重新初始化lockdown服务
    if (_backupContext && _backupContext->lockdown) {
        lockdownd_client_free(_backupContext->lockdown);
        _backupContext->lockdown = NULL;
        
        lockdownd_error_t lerr = lockdownd_client_new_with_handshake(_backupContext->device,
                                                                    &_backupContext->lockdown,
                                                                    "MFCTOOL");
        if (lerr != LOCKDOWN_E_SUCCESS) {
            [self logError:@"重置SSL状态时重新创建lockdown失败: %d", lerr];
        }
    }
}

// 新增：详细的SSL错误日志方法
- (void)logSSLErrorDetails:(mobilebackup2_error_t)error {
    [self logError:@"SSL错误详细信息:"];
    [self logError:@"- 错误代码: %d", error];
    [self logError:@"- 发生时间: %@", [NSDate date]];
    [self logError:@"- 连接持续时间: %.2f秒",
        [[NSDate date] timeIntervalSinceDate:_backupContext->startTime]];
}

- (mobilebackup2_error_t)retrySSLConnection:(lockdownd_service_descriptor_t)service {
    int retryCount = 0;
    const int maxRetries = 3;
    const int retryDelay = 2; // 秒
    mobilebackup2_error_t lastError = MOBILEBACKUP2_E_SSL_ERROR;
    
    while (retryCount < maxRetries) {
        [self logInfo:@"尝试重新建立SSL连接 (%d/%d)", retryCount + 1, maxRetries];
        
        // 检查是否已取消
        if ([self shouldCancel]) {
            [self logInfo:@"SSL重连过程被取消"];
            return MOBILEBACKUP2_E_SSL_ERROR;
        }
        
        // 先清理之前的连接
        if (_backupContext->backup) {
            mobilebackup2_client_free(_backupContext->backup);
            _backupContext->backup = NULL;
        }
        
        // 等待后重试
        [NSThread sleepForTimeInterval:retryDelay];
        
        // 重新创建客户端
        lastError = mobilebackup2_client_new(_backupContext->device,
                                           service,
                                           &_backupContext->backup);
        
        if (lastError == MOBILEBACKUP2_E_SUCCESS) {
            [self logInfo:@"SSL连接重试成功"];
            return MOBILEBACKUP2_E_SUCCESS;
        }
        
        [self logError:@"SSL连接重试失败 (%d/%d)，错误代码: %d",
         retryCount + 1, maxRetries, lastError];
        
        retryCount++;
    }
    
    [self logError:@"SSL连接重试次数已达上限"];
    return lastError;
}

- (BOOL)performBackup:(NSError **)error {
    [self logInfo:@"执行备份流程"];
    
    // 协议版本协商
    if (![self performProtocolVersionExchange:error]) {
        [self logError:@"协议版本协商失败"];
        return NO;
    }
    
    // 获取设备信息
    if (![self retrieveDeviceInfo:error]) {
        [self logError:@"获取设备信息失败"];
        return NO;
    }
    
    // 处理加密备份（如需要）
    if (_backupContext->isEncrypted && _backupContext->passwordRequired) {
        [self logInfo:@"处理加密备份"];
        if (![self requestBackupPassword:error]) {
            [self logError:@"获取备份密码失败"];
            return NO;
        }
    }
    
    // 发送备份请求
    if (![self sendBackupRequest:error]) {
        [self logError:@"发送备份请求失败"];
        return NO;
    }
    
    // 处理备份消息
    [self transitionToState:BackupStateBackingUp];
    if (![self processBackupMessages:error]) {
        [self logError:@"处理备份消息失败"];
        return NO;
    }
    
    [self logInfo:@"备份流程执行完成"];
    return YES;
}

// 协商方法
- (BOOL)performProtocolVersionExchange:(NSError **)error {
    [self logInfo:@"执行协议版本协商"];
    NSLog(@"[备份调试] 开始协议版本协商过程");
    [self transitionToState:BackupStateNegotiating];
    
    __block BOOL success = NO;
    __block NSError *localError = nil;
    
    // 使用连接队列安全访问连接
    dispatch_sync(self.connectionQueue, ^{
        if (!_backupContext || !_backupContext->backup) {
            [self logError:@"备份上下文或MobileBackup2客户端为空"];
            NSLog(@"[备份调试] 错误: 备份上下文或客户端为空");
            localError = [self createError:MFCToolBackupErrorInternal
                              description:@"备份上下文或MobileBackup2客户端为空"];
            success = NO;
            return;
        }
        
        // 设置正确的版本数组 - 确保与libimobiledevice一致
        NSLog(@"[备份调试] 准备版本数组: {2.1, 2.0, 1.6}");
        double versions[] = {2.1, 2.0, 1.6};
        char count = 3;
        double remote_version = 0.0;
        
        // 执行版本协商
        NSLog(@"[备份调试] 调用mobilebackup2_version_exchange");
        mobilebackup2_error_t mb2_err = mobilebackup2_version_exchange(_backupContext->backup,
                                                                     versions,
                                                                     count,
                                                                     &remote_version);
        
        NSLog(@"[备份调试] 版本交换返回代码: %d", mb2_err);
        
        if (mb2_err != MOBILEBACKUP2_E_SUCCESS) {
            [self logError:@"协议版本协商失败，错误代码: %d", mb2_err];
            NSLog(@"[备份调试] 协议版本协商失败: %d", mb2_err);
            localError = [self createError:MFCToolBackupErrorProtocol
                              description:[NSString stringWithFormat:@"协议版本协商失败，错误代码: %d", mb2_err]];
            success = NO;
            return;
        }
        
        _backupContext->protocolVersion = remote_version;
        [self logInfo:@"协议版本协商成功，远程版本: %.1f", remote_version];
        NSLog(@"[备份调试] 协议版本协商成功，远程版本: %.1f", remote_version);
        success = YES;
    });
    
    [self updateProgress:0.08 message:[NSString stringWithFormat:@"协议协商完成: %.1f", _backupContext->protocolVersion]];
    
    if (!success && localError && error) {
        *error = localError;
    }
    
    return success;
}

- (BOOL)retrieveDeviceInfo:(NSError **)error {
    [self logInfo:@"获取设备信息"];
    [self updateProgress:0.08 message:@"获取设备信息..."];
    
    __block BOOL success = NO;
    __block NSError *localError = nil;
    
    dispatch_sync(self.connectionQueue, ^{
        @try {
            if (!_backupContext || !_backupContext->lockdown) {
                [self logError:@"备份上下文或Lockdown客户端为空"];
                localError = [self createError:MFCToolBackupErrorLockdown
                                  description:@"备份上下文或Lockdown客户端为空"];
                success = NO;
                return;
            }
            
            // 获取设备信息
            plist_t deviceInfo = NULL;
            lockdownd_error_t lerr = lockdownd_get_value(_backupContext->lockdown, NULL, NULL, &deviceInfo);
            
            if (lerr != LOCKDOWN_E_SUCCESS || !deviceInfo) {
                [self logError:@"无法获取设备信息，错误代码: %d", lerr];
                localError = [self createError:MFCToolBackupErrorLockdown
                                  description:[NSString stringWithFormat:@"无法获取设备信息，错误代码: %d", lerr]];
                success = NO;
                return;
            }
            
            // 检查加密状态
            BOOL isEncrypted = NO;
            BOOL passwordRequired = NO;
            plist_t backupSettings = NULL;
            lerr = lockdownd_get_value(_backupContext->lockdown, "com.apple.mobile.backup", NULL, &backupSettings);
            
            if (lerr == LOCKDOWN_E_SUCCESS && backupSettings) {
                plist_t willEncrypt = plist_dict_get_item(backupSettings, "WillEncrypt");
                if (willEncrypt && plist_get_node_type(willEncrypt) == PLIST_BOOLEAN) {
                    uint8_t encryptVal = 0;
                    plist_get_bool_val(willEncrypt, &encryptVal);
                    isEncrypted = encryptVal;
                    passwordRequired = encryptVal;
                }
                plist_free(backupSettings);
            }
            
            // 获取设备容量并估算备份大小
            long long estimatedSize = 0;
            plist_t capacity = plist_dict_get_item(deviceInfo, "TotalDiskCapacity");
            
            if (capacity && plist_get_node_type(capacity) == PLIST_UINT) {
                uint64_t size = 0;
                plist_get_uint_val(capacity, &size);
                
                if (size <= 0) {
                    [self logError:@"设备报告的容量无效: %llu 字节", size];
                    localError = [self createError:MFCToolBackupErrorDeviceConnection
                                      description:@"设备报告了无效的容量，请重新连接设备"];
                    plist_free(deviceInfo);
                    success = NO;
                    return;
                }
                
                // 估算备份大小为设备容量的 20%
                estimatedSize = size * 0.2;
                [self logInfo:@"设备容量: %lld GB, 初始估计备份大小: %lld GB",
                         size / (1024LL * 1024LL * 1024LL),
                         estimatedSize / (1024LL * 1024LL * 1024LL)];
                
                // 检查磁盘空间
                NSError *spaceError = nil;
                if (![DatalogsSettings checkDiskSpaceForPath:_backupContext->backupPath
                                           requiredSpace:estimatedSize
                                                   error:&spaceError]) {
                    localError = [self createError:MFCToolBackupErrorDiskSpace
                                      description:spaceError.localizedDescription];
                    plist_free(deviceInfo);
                    success = NO;
                    return;
                }
            } else {
                // 尝试通过AFC服务获取设备容量
                if (_backupContext && _backupContext->afc) {
                    // 获取设备信息字典
                    char **device_info = NULL;
                    afc_error_t afc_err = afc_get_device_info(_backupContext->afc, &device_info);
                    
                    if (afc_err == AFC_E_SUCCESS && device_info) {
                        // 遍历键值对查找容量信息
                        int i = 0;
                        uint64_t size = 0;
                        
                        while (device_info[i] && device_info[i+1]) {
                            if (strcmp(device_info[i], "FSTotalBytes") == 0) {
                                size = strtoull(device_info[i+1], NULL, 10);
                                break;
                            }
                            i += 2;
                        }
                        
                        // 释放设备信息资源
                        i = 0;
                        while (device_info[i]) {
                            free(device_info[i]);
                            i++;
                        }
                        free(device_info);
                        
                        if (size > 0) {
                            estimatedSize = size * 0.2;
                            [self logInfo:@"通过AFC获取设备容量: %lld GB, 估计备份大小: %lld GB",
                                     size / (1024LL * 1024LL * 1024LL),
                                     estimatedSize / (1024LL * 1024LL * 1024LL)];
                        } else {
                            goto use_default;
                        }
                    } else {
                        goto use_default;
                    }
                } else {
                use_default:
                    // 默认估算值（32GB）
                    estimatedSize = 32LL * 1024LL * 1024LL * 1024LL;
                    [self logWarning:@"无法获取设备容量，使用默认备份大小: %lld 字节 (32GB)", estimatedSize];
                    
                    // 检查默认空间是否足够
                    NSError *spaceError = nil;
                    if (![DatalogsSettings checkDiskSpaceForPath:_backupContext->backupPath
                                           requiredSpace:estimatedSize
                                               error:&spaceError]) {
                        localError = [self createError:MFCToolBackupErrorDiskSpace
                                      description:spaceError.localizedDescription];
                        plist_free(deviceInfo);
                        success = NO;
                        return;
                    }
                }
            }
            
            // 设置初始 estimatedTotalBytes
            self.estimatedTotalBytes = estimatedSize;
            
            // 设置加密状态
            _backupContext->isEncrypted = isEncrypted;
            _backupContext->passwordRequired = passwordRequired;
            [self logInfo:@"备份加密状态: %@", isEncrypted ? @"启用" : @"禁用"];
            
            plist_free(deviceInfo);
            success = YES;
        } @catch (NSException *exception) {
            [self logError:@"获取设备信息异常: %@", exception.reason];
            localError = [self createError:MFCToolBackupErrorInternal
                              description:[NSString stringWithFormat:@"获取设备信息异常: %@", exception.reason]];
            success = NO;
        }
    });
    
    [self updateProgress:0.09 message:@"设备信息获取完成"];
    
    if (!success && localError && error) {
        *error = localError;
    }
    
    return success;
}

- (BOOL)requestBackupPassword:(NSError **)error {
    [self logInfo:@"请求备份密码"];
    [self transitionToState:BackupStateRequiringPassword];
    [self updateProgress:0.08 message:@"等待密码输入..."];
    
    __block BOOL passwordProvided = NO;
    __block NSString *providedPassword = nil;
    __block NSError *localError = nil;
    
    // 最多尝试3次
    int maxAttempts = 3;
    
    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
        if ([self shouldCancel]) {
            [self logInfo:@"密码输入过程被取消"];
            if (error) {
                *error = [self createError:MFCToolBackupErrorCancelled
                                description:@"用户取消了备份"];
            }
            return NO;
        }
        
        // 创建信号量用于同步
        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
        
        // 创建密码回调
        self.passwordCallback = ^(NSString *password) {
            providedPassword = password;
            passwordProvided = (password != nil);
            dispatch_semaphore_signal(semaphore);
        };
        
        // 在主线程显示密码提示 - 修改这部分
        dispatch_async(dispatch_get_main_queue(), ^{
            NSAlert *alert = [[NSAlert alloc] init];
            [alert setMessageText:@"加密备份"];
            [alert setInformativeText:[NSString stringWithFormat:@"此设备启用了加密备份，请输入备份密码（尝试 %d/%d）：",
                                      attempt, maxAttempts]];
            [alert addButtonWithTitle:@"确定"];
            [alert addButtonWithTitle:@"取消"];
            
            // 创建并配置密码输入字段
            NSSecureTextField *passwordField = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(0, 0, 300, 24)];
            [passwordField setPlaceholderString:@"输入密码"];
            
            // 创建容器视图并添加密码字段
            NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 300, 30)];
            [passwordField setTranslatesAutoresizingMaskIntoConstraints:NO];
            [container addSubview:passwordField];
            
            // 设置约束，确保密码字段正确显示
            NSLayoutConstraint *centerY = [NSLayoutConstraint constraintWithItem:passwordField
                                                                     attribute:NSLayoutAttributeCenterY
                                                                     relatedBy:NSLayoutRelationEqual
                                                                        toItem:container
                                                                     attribute:NSLayoutAttributeCenterY
                                                                    multiplier:1.0
                                                                      constant:0];
            
            NSLayoutConstraint *leadingConstraint = [NSLayoutConstraint constraintWithItem:passwordField
                                                                               attribute:NSLayoutAttributeLeading
                                                                               relatedBy:NSLayoutRelationEqual
                                                                                  toItem:container
                                                                               attribute:NSLayoutAttributeLeading
                                                                              multiplier:1.0
                                                                                constant:0];
            
            NSLayoutConstraint *trailingConstraint = [NSLayoutConstraint constraintWithItem:passwordField
                                                                                attribute:NSLayoutAttributeTrailing
                                                                                relatedBy:NSLayoutRelationEqual
                                                                                   toItem:container
                                                                                attribute:NSLayoutAttributeTrailing
                                                                               multiplier:1.0
                                                                                 constant:0];
            
            NSLayoutConstraint *heightConstraint = [NSLayoutConstraint constraintWithItem:passwordField
                                                                              attribute:NSLayoutAttributeHeight
                                                                              relatedBy:NSLayoutRelationEqual
                                                                                 toItem:nil
                                                                              attribute:NSLayoutAttributeNotAnAttribute
                                                                             multiplier:1.0
                                                                               constant:24];
            
            [container addConstraints:@[centerY, leadingConstraint, trailingConstraint]];
            [passwordField addConstraint:heightConstraint];
            
            // 设置容器视图为alert的附件视图
            [alert setAccessoryView:container];
            
            // 为密码字段建立一个引用变量，避免过早释放
            __block NSSecureTextField *secureField = passwordField;
            
            // 运行alert并等待用户响应
            [alert layout]; // 确保窗口布局已更新
            
            // 使用异步执行，确保窗口完全加载后再设置first responder
            dispatch_async(dispatch_get_main_queue(), ^{
                [[alert window] makeFirstResponder:secureField];
            });
            
            NSModalResponse response = [alert runModal];
            
            if (response == NSAlertFirstButtonReturn) {
                self.passwordCallback([secureField stringValue]);
            } else {
                self.passwordCallback(nil);
            }
        });
        
        // 设置2分钟超时
        dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_SEC);
        long result = dispatch_semaphore_wait(semaphore, timeout);
        
        if (result != 0 || !passwordProvided || !providedPassword) {
            [self logWarning:@"密码输入超时或被取消，尝试 %d/%d", attempt, maxAttempts];
            
            if (attempt < maxAttempts) {
                // 提示用户重试
                __block BOOL shouldRetry = NO;
                dispatch_sync(dispatch_get_main_queue(), ^{
                    NSAlert *alert = [[NSAlert alloc] init];
                    [alert setMessageText:@"密码输入失败"];
                    [alert setInformativeText:@"密码输入超时或被取消，是否重试？"];
                    [alert addButtonWithTitle:@"重试"];
                    [alert addButtonWithTitle:@"取消"];
                    shouldRetry = ([alert runModal] == NSAlertFirstButtonReturn);
                });
                
                if (!shouldRetry) {
                    localError = [self createError:MFCToolBackupErrorCancelled
                                      description:[NSString stringWithFormat:@"密码输入取消（尝试 %d/%d）",
                                                  attempt, maxAttempts]];
                    if (error) {
                        *error = localError;
                    }
                    self.passwordCallback = nil;
                    return NO;
                }
            } else {
                localError = [self createError:MFCToolBackupErrorCancelled
                                  description:@"密码输入失败，超出最大尝试次数"];
                if (error) {
                    *error = localError;
                }
                self.passwordCallback = nil;
                return NO;
            }
        } else {
            // 密码提供成功
            dispatch_sync(self.connectionQueue, ^{
                _backupContext->password = [providedPassword copy];
                _backupContext->passwordRequired = NO;
            });
            
            [self logInfo:@"已获取备份密码"];
            self.passwordCallback = nil;
            return YES;
        }
    }
    
    // 理论上不会到这里
    if (error) {
        *error = [self createError:MFCToolBackupErrorCancelled
                       description:@"密码输入失败，超出最大尝试次数"];
    }
    self.passwordCallback = nil;
    return NO;
}

// 备份请求发送方法
- (BOOL)sendBackupRequest:(NSError **)error {
    [self logInfo:@"发送备份请求"];
    NSLog(@"[备份调试] 开始发送备份请求");
    [self updateProgress:0.1 message:@"开始备份..."];
    
    __block BOOL success = NO;
    __block NSError *localError = nil;
    
    dispatch_sync(self.connectionQueue, ^{
        if (!_backupContext || !_backupContext->backup) {
            [self logError:@"备份上下文或客户端为空"];
            NSLog(@"[备份调试] 错误: 备份上下文或客户端为空");
            localError = [self createError:MFCToolBackupErrorInternal
                              description:@"备份上下文或客户端为空"];
            success = NO;
            return;
        }
        
        // 创建备份选项
        NSLog(@"[备份调试] 创建备份选项字典");
        plist_t options = plist_new_dict();
        
        // 获取设备UDID
        NSString *udid = _backupContext->deviceUDID;
        NSLog(@"[备份调试] 设备UDID: %@", udid);
        
        // 基本选项
        plist_dict_set_item(options, "TargetIdentifier", plist_new_string([udid UTF8String]));
        
        // 判断是否应该使用增量备份
        BOOL useIncrementalBackup = [self shouldUseIncrementalBackup];
        NSLog(@"[备份调试] 使用增量备份: %@", useIncrementalBackup ? @"是" : @"否");
        
        plist_dict_set_item(options, "FullBackup", plist_new_bool(useIncrementalBackup ? 0 : 1));
        plist_dict_set_item(options, "IncrementalBackup", plist_new_bool(useIncrementalBackup ? 1 : 0));
        [self logInfo:@"备份类型: %@", useIncrementalBackup ? @"增量备份" : @"完全备份"];
        
        // 设置备份路径
        NSLog(@"[备份调试] 备份路径: %@", _backupContext->backupPath);
        plist_dict_set_item(options, "BackupComputerBase", plist_new_string([_backupContext->backupPath UTF8String]));
        
        // 加密选项
        if (_backupContext->isEncrypted) {
            NSLog(@"[备份调试] 设置加密选项");
            // 明确设置加密标志
            plist_dict_set_item(options, "WillEncrypt", plist_new_bool(1));
            
            // 如果有密码，添加密码
            if (_backupContext->password) {
                plist_dict_set_item(options, "Password", plist_new_string([_backupContext->password UTF8String]));
                NSLog(@"[备份调试] 添加加密密码到备份选项");
            }
        } else {
            NSLog(@"[备份调试] 未使用加密");
            // 明确设置不加密
            plist_dict_set_item(options, "WillEncrypt", plist_new_bool(0));
        }
        
        // 添加备份应用选项
        plist_dict_set_item(options, "BackupApplications", plist_new_bool(1));
        
        // 设置备份协议版本 - 使用正确的版本格式
        char version_str[32];
        sprintf(version_str, "%.1f", _backupContext->protocolVersion);
        NSLog(@"[备份调试] 使用协议版本: %s", version_str);
        plist_dict_set_item(options, "Version", plist_new_string(version_str));
        
        // 输出完整的选项字典以便调试
        char *options_xml = NULL;
        uint32_t options_len = 0;
        plist_to_xml(options, &options_xml, &options_len);
        if (options_xml) {
            NSLog(@"[备份调试] 完整备份选项: %s", options_xml);
            free(options_xml);
        }
        
        // 发送备份请求
        NSLog(@"[备份调试] 调用mobilebackup2_send_request");
        mobilebackup2_error_t mb2_err = mobilebackup2_send_request(_backupContext->backup,
                                                                 "Backup",
                                                                 [udid UTF8String],
                                                                 [udid UTF8String],
                                                                 options);
        
        // 释放选项对象
        plist_free(options);
        
        if (mb2_err != MOBILEBACKUP2_E_SUCCESS) {
            [self logError:@"发送备份请求失败，错误代码: %d", mb2_err];
            NSLog(@"[备份调试] 发送备份请求失败，错误代码: %d", mb2_err);
            localError = [self createError:[self mapProtocolErrorToErrorCode:mb2_err]
                              description:[NSString stringWithFormat:@"发送备份请求失败，错误代码: %d", mb2_err]];
            success = NO;
            return;
        }
        
        [self logInfo:@"备份请求已发送"];
        NSLog(@"[备份调试] 备份请求发送成功");
        success = YES;
    });
    
    if (!success && localError && error) {
        *error = localError;
    }
    
    return success;
}

// 添加增量备份检测方法

- (BOOL)isIncrementalBackupCompleted {
    [self logInfo:@"检查增量备份完成状态"];
    
    // 检查备份目录中的关键文件
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *manifestPath = [_backupContext->backupPath stringByAppendingPathComponent:@"Manifest.plist"];
    NSString *infoPath = [_backupContext->backupPath stringByAppendingPathComponent:@"Info.plist"];
    NSString *statusPath = [_backupContext->backupPath stringByAppendingPathComponent:@"Status.plist"];
    
    // 检查文件是否存在
    BOOL manifestExists = [fileManager fileExistsAtPath:manifestPath];
    BOOL infoExists = [fileManager fileExistsAtPath:infoPath];
    BOOL statusExists = [fileManager fileExistsAtPath:statusPath];
    
    [self logInfo:@"备份文件检查 - Manifest.plist: %@, Info.plist: %@, Status.plist: %@",
             manifestExists ? @"存在" : @"不存在",
             infoExists ? @"存在" : @"不存在",
             statusExists ? @"存在" : @"不存在"];
    
    // 如果基本文件不完整，则不是有效备份
    if (!manifestExists || !infoExists || !statusExists) {
        [self logWarning:@"基本备份文件不完整，增量备份可能无效"];
        return NO;
    }
    
    // 检查Status.plist是否表明备份完成
    NSError *readError = nil;
    NSDictionary *status = nil;
    
    // 正确读取plist文件
    NSData *statusData = [NSData dataWithContentsOfFile:statusPath options:0 error:&readError];
    if (statusData) {
        status = [NSPropertyListSerialization propertyListWithData:statusData
                                                          options:NSPropertyListImmutable
                                                           format:NULL
                                                            error:&readError];
    }
    
    if (readError || !status) {
        [self logWarning:@"无法读取Status.plist: %@", readError.localizedDescription];
        return NO;
    }
    
    // 检查备份状态
    NSNumber *backupState = status[@"BackupState"];
    if (backupState && [backupState intValue] == 0) { // 0表示备份完成
        [self logInfo:@"Status.plist表明备份已完成"];
    } else {
        [self logWarning:@"Status.plist表明备份未完成，状态: %@", backupState ? [backupState stringValue] : @"未知"];
        return NO;
    }
    
    // 检查Manifest.plist中是否包含文件记录
    NSDictionary *manifest = nil;
    
    // 正确读取plist文件
    NSData *manifestData = [NSData dataWithContentsOfFile:manifestPath options:0 error:&readError];
    if (manifestData) {
        manifest = [NSPropertyListSerialization propertyListWithData:manifestData
                                                          options:NSPropertyListImmutable
                                                           format:NULL
                                                            error:&readError];
    }
    
    if (readError || !manifest) {
        [self logWarning:@"无法读取Manifest.plist: %@", readError.localizedDescription];
        return NO;
    }
    
    NSDictionary *files = manifest[@"Files"];
    if (!files || [files count] == 0) {
        [self logWarning:@"Manifest.plist不包含文件记录"];
        return NO;
    }
    
    [self logInfo:@"Manifest.plist包含 %lu 个文件记录", (unsigned long)[files count]];
    
    // 检查Info.plist是否包含设备信息
    NSDictionary *info = nil;
    
    // 正确读取plist文件
    NSData *infoData = [NSData dataWithContentsOfFile:infoPath options:0 error:&readError];
    if (infoData) {
        info = [NSPropertyListSerialization propertyListWithData:infoData
                                                      options:NSPropertyListImmutable
                                                       format:NULL
                                                        error:&readError];
    }
    
    if (readError || !info) {
        [self logWarning:@"无法读取Info.plist: %@", readError.localizedDescription];
        return NO;
    }
    
    // 检查UDID是否匹配
    NSString *backupUDID = info[@"UDID"];
    if (!backupUDID || ![backupUDID isEqualToString:_backupContext->deviceUDID]) {
        [self logWarning:@"备份UDID不匹配: %@ != %@", backupUDID, _backupContext->deviceUDID];
        return NO;
    }
    
    // 检查备份目录中是否有实际文件
    NSError *dirError = nil;
    NSArray *dirContents = [fileManager contentsOfDirectoryAtPath:_backupContext->backupPath error:&dirError];
    
    if (dirError || !dirContents) {
        [self logWarning:@"无法读取备份目录内容: %@", dirError.localizedDescription];
        return NO;
    }
    
    // 排除基本文件后还应该有其他文件
    NSMutableSet *basicFiles = [NSMutableSet setWithArray:@[@"Info.plist", @"Manifest.plist", @"Status.plist", @"backup_log.txt"]];
    NSMutableSet *directoryContents = [NSMutableSet setWithArray:dirContents];
    [directoryContents minusSet:basicFiles];
    
    if ([directoryContents count] == 0) {
        [self logWarning:@"备份目录中只有基本文件，没有实际备份数据"];
        return NO;
    }
    
    [self logInfo:@"备份目录包含 %lu 个非基本文件", (unsigned long)[directoryContents count]];
    
    // 所有检查都通过，认为是有效的增量备份
    [self logInfo:@"增量备份状态检查通过，确认为有效备份"];
    return YES;
}

// 判断是否应该使用增量备份

- (BOOL)shouldUseIncrementalBackup {
    // 检查备份目录中是否已存在备份文件
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *manifestPath = [_backupContext->backupPath stringByAppendingPathComponent:@"Manifest.plist"];
    
    // 如果存在Manifest.plist文件，表示以前已经有备份，可以进行增量备份
    BOOL isDirectory = NO;
    BOOL manifestExists = [fileManager fileExistsAtPath:manifestPath isDirectory:&isDirectory];
    
    [self logInfo:@"备份目录检查 - Manifest.plist %@存在", manifestExists ? @"" : @"不"];
    
    // 如果存在Manifest.plist，读取其内容检查有效性
    if (manifestExists && !isDirectory) {
        NSError *readError = nil;
        NSDictionary *manifest = nil;
        
        // 正确读取plist文件
        NSData *manifestData = [NSData dataWithContentsOfFile:manifestPath options:0 error:&readError];
        if (manifestData) {
            manifest = [NSPropertyListSerialization propertyListWithData:manifestData
                                                                 options:NSPropertyListImmutable
                                                                  format:NULL
                                                                   error:&readError];
        }
        
        if (manifest && !readError) {
            // 检查备份是否包含文件记录
            NSDictionary *files = manifest[@"Files"];
            if (files && [files count] > 0) {
                [self logInfo:@"发现有效的先前备份，包含 %lu 个文件记录，将使用增量备份", (unsigned long)[files count]];
                return YES;
            }
        } else {
            [self logWarning:@"无法读取Manifest.plist或格式错误: %@", readError ? readError.localizedDescription : @"未知错误"];
        }
    }
    
    [self logInfo:@"未找到有效的先前备份或记录为空，将使用完全备份"];
    return NO;
}


#pragma mark - 备份消息处理

- (BOOL)processBackupMessages:(NSError **)error {
    [self logInfo:@"开始处理备份消息..."];
    NSLog(@"[备份调试] ====== 开始备份消息处理循环 ======");
    
    // 验证当前状态
    __block BOOL isValid = NO;
    
    dispatch_sync(self.connectionQueue, ^{
        isValid = (_backupContext && _backupContext->backup);
    });
    
    if (!isValid) {
        [self logError:@"备份上下文或客户端为空"];
        NSLog(@"[备份调试] 错误: 备份上下文或客户端为空");
        if (error) {
            *error = [self createError:MFCToolBackupErrorInternal
                          description:@"备份上下文或客户端为空"];
        }
        return NO;
    }
    
    // 初始化消息处理变量
    __block plist_t message = NULL;
    __block char *dlmessage = NULL;
    int timeoutCount = 0;
    BOOL backupCompleted = NO;
    
    // 超时与心跳机制 - 改进自适应超时策略
    NSDate *processStartTime = [NSDate date];
    self.lastMessageTime = [NSDate date];
    NSDate *lastHeartbeatTime = [NSDate date];
    
    // 自适应超时设置
    NSTimeInterval initialTimeout = 5.0;  // 初始超时5秒
    NSTimeInterval currentTimeout = initialTimeout;
    NSTimeInterval maxTimeout = 20.0;     // 最大超时20秒
    NSTimeInterval minTimeout = 3.0;      // 最小超时3秒
    NSTimeInterval timeoutMultiplier = 1.5;
    
    // 统计数据
    int messageSequence = 0;
    int uploadFileCount = 0;
    int createDirCount = 0;
    
    // 消息类型统计
    NSMutableDictionary *messageStats = [NSMutableDictionary dictionary];
    
    // 确保设备解锁状态 - 在开始消息循环前显示提示
    dispatch_async(dispatch_get_main_queue(), ^{
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:@"保持设备解锁状态"];
        [alert setInformativeText:@"备份过程中请保持iOS设备处于解锁状态，否则可能导致备份失败。"];
        [alert addButtonWithTitle:@"已解锁，继续"];
        [alert runModal];
    });
    
    NSLog(@"[备份调试] 备份消息处理设置完成，开始主循环");
    
    // 处理消息循环
    while (!backupCompleted && [self shouldContinue]) {
        messageSequence++;
        [self logDebug:@"消息循环迭代 #%d，已处理文件数：%d", messageSequence, self.filesProcessed];
        NSLog(@"[备份调试] 消息循环迭代 #%d", messageSequence);
        
        // 检查总体超时
        NSTimeInterval elapsedTotal = [[NSDate date] timeIntervalSinceDate:processStartTime];
        if (elapsedTotal > MAX_PROCESS_DURATION) {
            [self logError:@"备份消息处理超时 (超过%d分钟)", (int)(MAX_PROCESS_DURATION/60)];
            NSLog(@"[备份调试] 错误: 备份总时间超时 %.1f 秒", elapsedTotal);
            if (error) {
                *error = [self createError:MFCToolBackupErrorTimeout
                              description:@"备份消息处理超时，设备可能已断开连接"];
            }
            break;
        }
        
        // 检查自上次通信以来的时间
        NSTimeInterval silenceDuration = [[NSDate date] timeIntervalSinceDate:self.lastMessageTime];
        NSLog(@"[备份调试] 距上次消息时间: %.1f 秒", silenceDuration);
        
        if (silenceDuration > MAX_SILENCE_DURATION) {
            [self logError:@"设备通信中断时间过长 (%.1f秒)，可能已断开连接", silenceDuration];
            NSLog(@"[备份调试] 错误: 通信中断时间过长 %.1f 秒", silenceDuration);
            if (error) {
                *error = [self createError:MFCToolBackupErrorDeviceConnection
                              description:@"设备通信中断时间过长，请检查连接状态"];
            }
            break;
        }
        
        // 发送心跳以维持连接 - 更加智能的心跳策略
        NSTimeInterval timeSinceLastHeartbeat = [[NSDate date] timeIntervalSinceDate:lastHeartbeatTime];
        
        // 根据通信沉默时间自动调整心跳频率
        NSTimeInterval heartbeatInterval = MIN(10.0, MAX(2.0, silenceDuration * 0.2));
        
        NSLog(@"[备份调试] 距上次心跳: %.1f 秒, 心跳间隔: %.1f 秒",
              timeSinceLastHeartbeat, heartbeatInterval);
                                             
       
        if (timeSinceLastHeartbeat >= HEARTBEAT_INTERVAL) {
            NSError *heartbeatError = nil;
            if (![self handleHeartbeat:&heartbeatError]) {
                [self logError:@"心跳检测失败: %@", heartbeatError.localizedDescription];
                
                // 尝试一次性恢复
                [self logInfo:@"尝试恢复备份连接..."];
                if ([self recoverBackupConnection]) {
                    [self logInfo:@"备份连接恢复成功，继续处理"];
                    lastHeartbeatTime = [NSDate date];
                    continue;
                }
                
                if (error) {
                    *error = heartbeatError;
                }
                return NO;
            }
            lastHeartbeatTime = [NSDate date];
        }
        
        // 检查是否暂停
        [self checkPauseState];
        
        // 释放前一条消息的资源
        if (message) {
            plist_free(message);
            message = NULL;
        }
        if (dlmessage) {
            free(dlmessage);
            dlmessage = NULL;
        }
        
        // 接收消息 - 使用更健壮的接收策略
        [self logDebug:@"等待接收消息，迭代 #%d，当前超时: %.1f秒", messageSequence, currentTimeout];
        NSLog(@"[备份调试] 等待接收消息, 超时: %.1f 秒", currentTimeout);
        
        // 使用信号量控制超时
        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
        __block mobilebackup2_error_t mb2_err = MOBILEBACKUP2_E_SUCCESS;
        __block BOOL messageReceived = NO;
        __block BOOL wasWaitingCancelled = NO;
        
        // 在后台线程执行接收操作，以便能够取消
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            @autoreleasepool {
                // 线程安全地访问备份客户端
                mobilebackup2_client_t backup = NULL;
                
                @synchronized(self) {
                    if (_backupContext && _backupContext->backup) {
                        backup = _backupContext->backup;
                    }
                }
                
                if (backup) {
                    NSLog(@"[备份调试] 开始调用mobilebackup2_receive_message");
                    mb2_err = mobilebackup2_receive_message(backup, &message, &dlmessage);
                    NSLog(@"[备份调试] mobilebackup2_receive_message返回: %d", mb2_err);
                    messageReceived = (mb2_err == MOBILEBACKUP2_E_SUCCESS && message != NULL);
                } else {
                    NSLog(@"[备份调试] 错误: 备份客户端无效");
                    mb2_err = MOBILEBACKUP2_E_BAD_VERSION;
                }
                
                // 如果等待已被取消，则不要发送信号
                if (!wasWaitingCancelled) {
                    dispatch_semaphore_signal(semaphore);
                }
            }
        });
        
        // 等待接收完成或超时
        dispatch_time_t timeoutTime = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(currentTimeout * NSEC_PER_SEC));
        long timeoutResult = dispatch_semaphore_wait(semaphore, timeoutTime);
        
        // 处理超时情况
        if (timeoutResult != 0) {
            wasWaitingCancelled = YES; // 标记等待已取消
            
            [self logWarning:@"接收消息超时 (%.1f秒)，超时次数: %d/5", currentTimeout, ++timeoutCount];
            NSLog(@"[备份调试] 接收消息超时, 次数: %d/5", timeoutCount);
            
            // 检查设备是否仍连接
            BOOL deviceStillConnected = [self isDeviceStillConnected];
            NSLog(@"[备份调试] 设备连接状态检查: %@", deviceStillConnected ? @"已连接" : @"已断开");
            
            if (!deviceStillConnected) {
                [self logError:@"设备已断开连接或已锁定，备份中断"];
                NSLog(@"[备份调试] 错误: 设备已断开连接或已锁定");
                if (error) {
                    *error = [self createError:MFCToolBackupErrorDeviceConnection
                                    description:@"设备已断开连接或已锁定，请重连设备并保持解锁状态"];
                }
                break;
            }
            
            if (timeoutCount > 3) {  // 最多允许3次超时
                [self logError:@"多次超时，备份超时终止"];
                NSLog(@"[备份调试] 错误: 超时次数过多，备份终止");
                if (error) {
                    *error = [self createError:MFCToolBackupErrorTimeout
                                    description:@"备份超时，请检查设备连接和USB电缆状态"];
                }
                break;
            }
            
            // 增加超时时间，但不超过最大值
            currentTimeout = MIN(currentTimeout * timeoutMultiplier, maxTimeout);
            [self logInfo:@"增加接收超时时间到 %.1f秒", currentTimeout];
            NSLog(@"[备份调试] 增加超时时间到 %.1f 秒", currentTimeout);
            
            // 如果已超时多次，尝试重建连接
            if (timeoutCount >= 2) {
                [self logInfo:@"多次超时，尝试重置备份连接"];
                NSLog(@"[备份调试] 尝试重建备份连接");
                
                if (![self recreateBackupConnection:error]) {
                    [self logError:@"重建备份连接失败: %@", (*error).localizedDescription];
                    NSLog(@"[备份调试] 错误: 重建连接失败: %@", (*error).localizedDescription);
                    break;
                } else {
                    [self logInfo:@"备份连接重建成功，重新开始备份过程"];
                    NSLog(@"[备份调试] 连接重建成功，重新发送备份请求");
                    
                    // 重置超时计数器
                    timeoutCount = 0;
                    currentTimeout = initialTimeout;
                    
                    // 重建连接后重新执行协议协商和备份请求
                    if (![self performProtocolVersionExchange:error] ||
                        ![self sendBackupRequest:error]) {
                        [self logError:@"重建连接后重新初始化备份失败: %@", (*error).localizedDescription];
                        NSLog(@"[备份调试] 错误: 重新初始化备份失败");
                        break;
                    }
                }
            }
            
            // 等待短暂时间后继续
            NSTimeInterval waitTime = 0.5 * (timeoutCount + 1);
            [self logInfo:@"等待%.1f秒后重试", waitTime];
            NSLog(@"[备份调试] 等待 %.1f 秒后重试", waitTime);
            [NSThread sleepForTimeInterval:waitTime];
            continue;
        }
        
        // 处理接收错误
        if (mb2_err != MOBILEBACKUP2_E_SUCCESS) {
            [self logError:@"接收消息失败，错误代码: %d", mb2_err];
            NSLog(@"[备份调试] 错误: 接收消息失败，代码: %d", mb2_err);
            
            // 特定处理SSL错误（可能是设备断开连接）
            if (mb2_err == MOBILEBACKUP2_E_SSL_ERROR) {
                [self logError:@"SSL错误，可能是设备断开连接或连接重置"];
                NSLog(@"[备份调试] SSL错误，检查设备连接状态");
                
                // 检查设备是否已锁定
                BOOL isConnected = [self isDeviceStillConnected];
                NSLog(@"[备份调试] 设备连接状态: %@", isConnected ? @"已连接" : @"已断开");
                
                if (!isConnected) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        NSAlert *alert = [[NSAlert alloc] init];
                        [alert setMessageText:@"设备连接中断"];
                        [alert setInformativeText:@"设备可能已断开连接或已锁定。请确保设备连接正常且处于解锁状态。"];
                        [alert addButtonWithTitle:@"确定"];
                        [alert runModal];
                    });
                }
                
                if (error) {
                    *error = [self createError:MFCToolBackupErrorDeviceConnection
                                    description:@"SSL连接错误，设备可能已断开或已锁定"];
                }
            } else {
                if (error) {
                    *error = [self createError:[self mapProtocolErrorToErrorCode:mb2_err]
                                    description:[NSString stringWithFormat:@"接收消息失败，错误代码: %d", mb2_err]];
                }
            }
            break;
        }
        
        // 成功接收消息 - 重置超时参数
        if (messageReceived) {
            // 成功收到消息，重置超时计数和降低超时时间
            timeoutCount = 0;
            // 逐渐减少超时时间，但不低于最小值
            currentTimeout = MAX(currentTimeout * 0.9, minTimeout);
            
            self.lastMessageTime = [NSDate date];
            NSLog(@"[备份调试] 成功接收消息，重置超时时间: %.1f 秒", currentTimeout);
            
            // 确认设备仍然连接正常
            BOOL deviceConnected = [self isDeviceStillConnected];
            if (!deviceConnected && !backupCompleted) {
                [self logError:@"设备已断开连接，备份中断"];
                NSLog(@"[备份调试] 错误: 检测到设备已断开连接");
                if (error) {
                    *error = [self createError:MFCToolBackupErrorDeviceConnection
                                  description:@"设备已断开连接，请重新连接并重试备份"];
                }
                break;
            }
            
            // 处理接收到的消息
            if (dlmessage) {
                [self logInfo:@"收到消息类型: %s", dlmessage];
                NSLog(@"[备份调试] 收到消息: %s", dlmessage);
                
                // 统计消息类型
                NSString *msgType = [NSString stringWithUTF8String:dlmessage];
                NSNumber *count = [messageStats objectForKey:msgType] ?: @0;
                [messageStats setObject:@([count intValue] + 1) forKey:msgType];
                
                // 输出消息内容用于调试
                if (self.logLevel >= MFCLogLevelVerbose) {
                    char *message_xml = NULL;
                    uint32_t xml_length = 0;
                    plist_to_xml(message, &message_xml, &xml_length);
                    if (message_xml) {
                        NSLog(@"[备份调试-详细] 消息内容: %s", message_xml);
                        free(message_xml);
                    }
                }
                
                // 根据消息类型处理
                if (!strcmp(dlmessage, "DLContentsOfDirectory")) {
                    [self handleContentsOfDirectory:message];
                } else if (!strcmp(dlmessage, "DLMessageCreateDirectory")) {
                    [self handleCreateDirectory:message];
                    createDirCount++;
                } else if (!strcmp(dlmessage, "DLMessageUploadFiles")) {
                    [self handleUploadFiles:message];
                    uploadFileCount++;
                } else if (!strcmp(dlmessage, "DLMessageProcessMessage")) {
                    [self handleProcessMessage:message];
                } else if (!strcmp(dlmessage, "DLMessageDownloadFiles")) {
                    [self handleDownloadFiles:message];
                } else if (!strcmp(dlmessage, "DLMessageDisconnect")) {
                    NSLog(@"[备份调试] 收到断开连接消息，处理备份完成状态");
                    backupCompleted = [self handleDisconnectMessage:message dlmessage:dlmessage uploadFileCount:uploadFileCount error:error];
                    NSLog(@"[备份调试] 断开消息处理结果: %@", backupCompleted ? @"备份完成" : @"备份未完成");
                } else {
                    [self handleOtherMessage:dlmessage message:message];
                }
            } else {
                [self logWarning:@"接收到空消息名称"];
                NSLog(@"[备份调试] 警告: 接收到空消息名称");
            }
        } else {
            [self logWarning:@"消息接收失败，但无详细错误"];
            NSLog(@"[备份调试] 警告: 消息接收失败，无详细错误");
        }
        
        // 定期提供进度摘要
        if (messageSequence % 20 == 0) {  // 更频繁地报告状态
            NSTimeInterval elapsed = [[NSDate date] timeIntervalSinceDate:processStartTime];
            [self logInfo:@"备份处理状态: 已处理 %d 条消息，耗时 %.1f 秒，文件: %d，目录: %d",
                      messageSequence, elapsed, self.filesProcessed, createDirCount];
            NSLog(@"[备份调试] 处理进度: %d 条消息，%.1f 秒，%d 文件，%d 目录",
                  messageSequence, elapsed, self.filesProcessed, createDirCount);
            
            // 报告消息类型统计
            [self logInfo:@"消息类型统计: %@", messageStats];
            NSLog(@"[备份调试] 消息统计: %@", messageStats);
        }
        
        // 验证备份进度，如果长时间无文件进展，可能表示备份异常
        if (messageSequence > 50 && self.filesProcessed == 0 && uploadFileCount == 0) {
            [self logWarning:@"已处理 %d 条消息但未接收任何文件，备份可能异常", messageSequence];
            NSLog(@"[备份调试] 警告: %d 条消息但未接收文件，检查备份进度", messageSequence);
            
            if (messageSequence > 100) {  // 减少异常检测阈值
                [self logError:@"备份可能卡住，未接收任何文件数据"];
                NSLog(@"[备份调试] 错误: 备份可能卡住，未接收文件数据");
                
                // 提示用户设备状态
                if (messageSequence % 50 == 0 && messageSequence < 200) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        NSAlert *alert = [[NSAlert alloc] init];
                        [alert setMessageText:@"备份进度异常"];
                        [alert setInformativeText:@"备份过程中未收到任何文件数据。请确保设备解锁且信任此电脑。是否继续等待？"];
                        [alert addButtonWithTitle:@"继续等待"];
                        [alert addButtonWithTitle:@"取消备份"];
                        
                        if ([alert runModal] == NSAlertSecondButtonReturn) {
                            self.shouldCancel = YES;
                        }
                    });
                }
                
                // 尝试重新协商
                if (messageSequence > 150 && messageSequence % 50 == 0) {
                    [self logInfo:@"尝试重新协商备份会话以恢复进度"];
                    NSLog(@"[备份调试] 尝试重新协商备份会话");
                    if ([self renegotiateBackupSession:error]) {
                        [self logInfo:@"重新协商成功，继续备份"];
                        NSLog(@"[备份调试] 重新协商成功，继续备份");
                    }
                }
                
                // 超过一定次数后终止
                if (messageSequence > 300) {
                    NSLog(@"[备份调试] 错误: 消息数过多但未收到文件，终止备份");
                    if (error) {
                        *error = [self createError:MFCToolBackupErrorInternal
                                        description:@"备份可能卡住，未接收任何文件数据"];
                    }
                    break;
                }
            }
        }
        
        // 定期检查内存使用
        if (messageSequence % 100 == 0) {
            [self checkMemoryUsage];
        }
    }
    
    // 清理资源
    if (message) plist_free(message);
    if (dlmessage) free(dlmessage);
    
    NSTimeInterval totalTime = [[NSDate date] timeIntervalSinceDate:processStartTime];
    [self logInfo:@"消息处理循环结束，总处理消息数: %d，总耗时: %.1f 秒", messageSequence, totalTime];
    NSLog(@"[备份调试] ====== 备份消息循环结束 ======");
    NSLog(@"[备份调试] 总消息: %d, 耗时: %.1f 秒", messageSequence, totalTime);

    NSLog(@"[备份调试] 最终消息统计: %@", messageStats);
    
    // 检查备份是否有效 - 改进的增量备份检测
    BOOL isValidBackup = backupCompleted && ([self isIncrementalBackupCompleted] || self.filesProcessed > 0);
    NSLog(@"[备份调试] 备份有效性检查: %@", isValidBackup ? @"有效" : @"无效");
    
    if (!isValidBackup && backupCompleted) {
        [self logWarning:@"备份完成但可能无效，检查备份目录"];
        NSLog(@"[备份调试] 警告: 备份标记完成但可能无效");
        if (error && !*error) {
            *error = [self createError:MFCToolBackupErrorInternal
                             description:@"备份过程完成但结果可能无效，请检查"];
        }
    }
    
    return isValidBackup;
}

- (BOOL)recoverBackupConnection {
    [self logInfo:@"开始恢复备份连接"];
    
    // 清理现有连接
    if (_backupContext->backup) {
        mobilebackup2_client_free(_backupContext->backup);
        _backupContext->backup = NULL;
    }
    
    // 重新启动服务
    lockdownd_service_descriptor_t backup_service = NULL;
    lockdownd_error_t lerr = lockdownd_start_service(_backupContext->lockdown,
                                                    "com.apple.mobilebackup2",
                                                    &backup_service);
    
    if (lerr != LOCKDOWN_E_SUCCESS || !backup_service) {
        [self logError:@"无法重新启动备份服务"];
        return NO;
    }
    
    // 创建新的备份客户端
    mobilebackup2_error_t mb2_err = mobilebackup2_client_new(_backupContext->device,
                                                            backup_service,
                                                            &_backupContext->backup);
    
    lockdownd_service_descriptor_free(backup_service);
    
    if (mb2_err != MOBILEBACKUP2_E_SUCCESS) {
        [self logError:@"无法创建新的备份客户端"];
        return NO;
    }
    
    // 重新进行版本协商
    double versions[] = {2.1, 2.0, 1.6};
    double remote_version = 0.0;
    mb2_err = mobilebackup2_version_exchange(_backupContext->backup,
                                           versions,
                                           sizeof(versions)/sizeof(versions[0]),
                                           &remote_version);
    
    if (mb2_err != MOBILEBACKUP2_E_SUCCESS) {
        [self logError:@"版本重新协商失败"];
        return NO;
    }
    
    [self logInfo:@"备份连接恢复完成，协议版本: %.1f", remote_version];
    return YES;
}

//断开连接处理

- (BOOL)handleDisconnectMessage:(plist_t)message dlmessage:(char *)dlmessage uploadFileCount:(int)uploadFileCount error:(NSError **)error {
    [self logInfo:@"接收到断开连接消息，分析备份状态"];
    NSLog(@"[备份调试] 收到断开连接消息");
    
    // 输出完整消息内容用于调试
    char *message_xml = NULL;
    uint32_t xml_length = 0;
    plist_to_xml(message, &message_xml, &xml_length);
    if (message_xml) {
        NSLog(@"[备份调试] 断开消息内容: %s", message_xml);
        free(message_xml);
    }
    
    // 检查备份状态
    BOOL isComplete = YES;
    
    // 从消息中获取状态信息
    plist_t statusNode = plist_dict_get_item(message, "Status");
    if (statusNode && plist_get_node_type(statusNode) == PLIST_STRING) {
        char *statusStr = NULL;
        plist_get_string_val(statusNode, &statusStr);
        
        if (statusStr) {
            [self logInfo:@"备份状态: %s", statusStr];
            NSLog(@"[备份调试] 备份状态: %s", statusStr);
            
            // 检查状态是否为"Complete"
            if (strcmp(statusStr, "Complete") != 0) {
                isComplete = NO;
                [self logWarning:@"备份未完全完成，状态为: %s", statusStr];
                NSLog(@"[备份调试] 警告: 备份未完成，状态: %s", statusStr);
                
                if (error) {
                    NSString *statusDesc = [NSString stringWithUTF8String:statusStr];
                    *error = [self createError:MFCToolBackupErrorIncomplete
                                   description:[NSString stringWithFormat:@"备份未完全完成，状态为: %@", statusDesc]];
                }
            }
            
            free(statusStr);
        }
    }
    
    // 检查错误信息
    plist_t errorNode = plist_dict_get_item(message, "ErrorDescription");
    if (errorNode && plist_get_node_type(errorNode) == PLIST_STRING) {
        char *errorStr = NULL;
        plist_get_string_val(errorNode, &errorStr);
        
        if (errorStr) {
            [self logError:@"备份错误: %s", errorStr];
            NSLog(@"[备份调试] 错误描述: %s", errorStr);
            isComplete = NO;
            
            if (error) {
                NSString *errorDesc = [NSString stringWithUTF8String:errorStr];
                *error = [self createError:MFCToolBackupErrorBackupFailed
                                description:[NSString stringWithFormat:@"备份过程报告错误: %@", errorDesc]];
            }
            
            free(errorStr);
        }
    }
    
    // 检查备份文件信息
    NSLog(@"[备份调试] 备份统计: 处理文件数 %d, 上传文件数 %d", self.filesProcessed, uploadFileCount);
    
    // DLMessageDisconnect消息通常应该在成功传输文件后收到
    // 如果此时没有文件，设置一个标志让调用者知道
    if (self.filesProcessed == 0 && uploadFileCount == 0) {
        [self logWarning:@"收到断开连接消息，但未接收到任何文件数据"];
        NSLog(@"[备份调试] 警告: 未接收到任何文件数据");
        
        // 检查是否是有效的增量备份
        if ([self isIncrementalBackupCompleted]) {
            [self logInfo:@"检测到有效的增量备份，无需传输新文件"];
            NSLog(@"[备份调试] 确认为有效的增量备份");
            isComplete = YES;
        } else {
            [self logWarning:@"可能是无效备份或空备份"];
            NSLog(@"[备份调试] 警告: 可能是无效备份");
            // 不自动将其视为失败，让上层调用者决定
        }
    }
    
    // 发送最终确认响应 - 格式必须符合协议要求
    NSLog(@"[备份调试] 发送断开响应，状态: %@", isComplete ? @"Complete" : @"Incomplete");
    [self sendDisconnectResponse:message isComplete:isComplete];
    
    return isComplete;
}

// 正确方法声明
- (void)sendDisconnectResponse:(plist_t)message isComplete:(BOOL)isComplete {
    dispatch_sync(self.connectionQueue, ^{
        if (_backupContext && _backupContext->backup) {
            // 创建标准断开响应格式
            plist_t response = plist_new_dict();
            
            // 添加状态
            plist_dict_set_item(response, "Status",
                             plist_new_string(isComplete ? "Complete" : "Incomplete"));
            
            // 添加日期
            NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
            [formatter setDateFormat:@"yyyy-MM-dd HH:mm:ss"];
            NSString *dateStr = [formatter stringFromDate:[NSDate date]];
            plist_dict_set_item(response, "Date", plist_new_string([dateStr UTF8String]));
            
            // 添加备份统计信息
            plist_dict_set_item(response, "FilesProcessed", plist_new_uint(self.filesProcessed));
            plist_dict_set_item(response, "TotalBytes", plist_new_uint(self.totalBytesReceived));
            
            NSLog(@"[备份调试] 断开响应详情: 状态=%@, 文件=%d, 字节=%lld",
                  isComplete ? @"Complete" : @"Incomplete",
                  self.filesProcessed,
                  self.totalBytesReceived);
            
            // 输出响应XML用于调试
            char *response_xml = NULL;
            uint32_t xml_length = 0;
            plist_to_xml(response, &response_xml, &xml_length);
            if (response_xml) {
                NSLog(@"[备份调试] 断开响应XML: %s", response_xml);
                free(response_xml);
            }
            
            // 发送响应
            mobilebackup2_send_status_response(_backupContext->backup, 0, NULL, response);
            plist_free(response);
            
            [self logInfo:@"已发送断开响应，状态: %@", isComplete ? @"完成" : @"未完成"];
        }
    });
}



// 设备连接状态检查方法
- (BOOL)isDeviceStillConnected {
    NSLog(@"[备份调试] 检查设备连接状态");
    __block BOOL isConnected = NO;
    __block BOOL isLocked = NO;  // 添加锁定状态跟踪
    
    dispatch_sync(self.connectionQueue, ^{
        if (!_backupContext || !_backupContext->device || !_backupContext->lockdown) {
            isConnected = NO;
            NSLog(@"[备份调试] 设备连接检查: 上下文或句柄为空");
            return;
        }
        
        // 第一步: 尝试获取设备名称以检查基本连接
        char *deviceName = NULL;
        lockdownd_error_t lerr = lockdownd_get_device_name(_backupContext->lockdown, &deviceName);
        
        NSLog(@"[备份调试] 获取设备名称结果: %d", lerr);
        
        if (lerr == LOCKDOWN_E_SUCCESS && deviceName) {
            // 设备基本连接正常
            isConnected = YES;
            NSLog(@"[备份调试] 设备基本连接正常，名称: %s", deviceName);
            free(deviceName);
            deviceName = NULL;
        } else if (lerr == LOCKDOWN_E_PASSWORD_PROTECTED) {
            // 设备已连接但锁定
            isConnected = YES;  // 设备仍然连接
            isLocked = YES;     // 但处于锁定状态
            NSLog(@"[备份调试] 设备已连接但锁定");
            [self logWarning:@"设备已锁定，请解锁后继续"];
        } else {
            // 处理其他错误情况
            isConnected = NO;
            NSString *errorDesc = @"未知错误";
            
            if (lerr == LOCKDOWN_E_MUX_ERROR) {
                errorDesc = @"USB多路复用错误";
            } else if (lerr == LOCKDOWN_E_INVALID_SERVICE) {
                errorDesc = @"无效服务";
            } else if (lerr == LOCKDOWN_E_SSL_ERROR) {
                errorDesc = @"SSL连接错误";
            } else if (lerr == LOCKDOWN_E_RECEIVE_TIMEOUT) {
                errorDesc = @"接收超时";
            } else if (lerr == LOCKDOWN_E_INVALID_CONF) {
                errorDesc = @"无效配置";
            }
            
            NSLog(@"[备份调试] 设备连接错误(%d): %@", lerr, errorDesc);
            [self logWarning:@"设备连接错误: %@ (代码: %d)", errorDesc, lerr];
            return;
        }
        
        // 第二步: 如果基本连接正常但未确定锁定状态，进一步检查设备锁定状态
        if (isConnected && !isLocked) {
            plist_t lockState = NULL;
            lerr = lockdownd_get_value(_backupContext->lockdown, "com.apple.mobile.lockdown", "DeviceLocked", &lockState);
            
            NSLog(@"[备份调试] 获取设备锁定状态结果: %d", lerr);
            
            if (lerr == LOCKDOWN_E_SUCCESS && lockState) {
                if (plist_get_node_type(lockState) == PLIST_BOOLEAN) {
                    uint8_t lockValue = 0;
                    plist_get_bool_val(lockState, &lockValue);
                    
                    isLocked = (lockValue != 0);
                    NSLog(@"[备份调试] 设备锁定状态: %@", isLocked ? @"已锁定" : @"未锁定");
                    
                    if (isLocked) {
                        [self logWarning:@"设备已锁定，请解锁后继续备份"];
                    }
                }
                plist_free(lockState);
            } else if (lerr == LOCKDOWN_E_PASSWORD_PROTECTED) {
                // 🔑核心修复: 再次确认密码保护错误为锁定信号
                isLocked = YES;
                NSLog(@"[备份调试] 检查锁定状态时确认设备已锁定 (LOCKDOWN_E_PASSWORD_PROTECTED)");
                [self logWarning:@"设备已锁定，请解锁后继续"];
            } else {
                NSLog(@"[备份调试] 无法获取设备锁定状态: %d", lerr);
                
                // 🔑核心修复: 如果无法确定锁定状态，使用新方法进行检查
                isLocked = [self isDeviceLocked];
                NSLog(@"[备份调试] 通过辅助方法检测锁定状态: %@", isLocked ? @"已锁定" : @"未锁定");
            }
        }
        
        // 第三步: 尝试获取设备信息以进一步验证连接
        if (isConnected) {
            // 获取一些基本设备信息作为额外验证
            plist_t deviceInfo = NULL;
            lerr = lockdownd_get_value(_backupContext->lockdown, NULL, "ProductVersion", &deviceInfo);
            
            if (lerr == LOCKDOWN_E_SUCCESS && deviceInfo) {
                char *version_str = NULL;
                if (plist_get_node_type(deviceInfo) == PLIST_STRING) {
                    plist_get_string_val(deviceInfo, &version_str);
                    if (version_str) {
                        NSLog(@"[备份调试] 设备iOS版本: %s", version_str);
                        free(version_str);
                    }
                }
                plist_free(deviceInfo);
            } else {
                NSLog(@"[备份调试] 获取设备版本信息失败: %d", lerr);
                // 不改变连接状态，因为这只是额外验证
            }
        }
    });
    
    // 如果设备已锁定，为了备份操作，我们将其视为未连接
    if (isConnected && isLocked) {
        NSLog(@"[备份调试] 设备已连接但已锁定，备份无法继续");
        isConnected = NO;  // 备份需要设备解锁
        
        // 可以在这里添加UI提示代码，提醒用户解锁设备
        dispatch_async(dispatch_get_main_queue(), ^{
            NSAlert *alert = [[NSAlert alloc] init];
            [alert setMessageText:@"设备已锁定"];
            [alert setInformativeText:@"请解锁iOS设备以继续备份操作。"];
            [alert addButtonWithTitle:@"确定"];
            // 修复：移除不兼容的Window参数，改用runModal
            [alert runModal];
        });
    }
    
    NSLog(@"[备份调试] 设备连接最终状态: %@", isConnected ? @"已连接且可用" : @"未连接或已锁定");
    return isConnected;
}

// 新增: 专门用于检测设备是否锁定的方法
- (BOOL)isDeviceLocked {
    if (!_backupContext || !_backupContext->lockdown) {
        [self logInfo:@"无法检查锁定状态：缺少lockdown上下文"];
        return YES;  // 保守假设，无法检查则认为已锁定
    }
    
    // 方法1: 直接获取DeviceLocked状态（最直接的方法）
    plist_t lockState = NULL;
    lockdownd_error_t lerr = lockdownd_get_value(_backupContext->lockdown,
                                              "com.apple.mobile.lockdown",
                                              "DeviceLocked",
                                              &lockState);
    
    // 如果返回LOCKDOWN_E_PASSWORD_PROTECTED错误，则确认设备已锁定
    if (lerr == LOCKDOWN_E_PASSWORD_PROTECTED) {
        [self logInfo:@"设备已锁定 (检测到LOCKDOWN_E_PASSWORD_PROTECTED错误)"];
        return YES;
    }
    
    // 检查锁定状态值
    if (lerr == LOCKDOWN_E_SUCCESS && lockState) {
        uint8_t lockValue = 0;
        plist_get_bool_val(lockState, &lockValue);
        plist_free(lockState);
        if (lockValue) {
            [self logInfo:@"设备已锁定 (DeviceLocked=true)"];
            return YES;
        } else {
            [self logInfo:@"设备未锁定 (DeviceLocked=false)"];
            return NO;  // 如果明确获取到未锁定状态，可以直接返回
        }
    }
    
    // 方法2: 测试启动受限服务 (通常比检查多个保护值更可靠)
    lockdownd_service_descriptor_t service = NULL;
    lerr = lockdownd_start_service(_backupContext->lockdown,
                                 "com.apple.mobile.diagnostics_relay",
                                 &service);
    
    if (lerr == LOCKDOWN_E_PASSWORD_PROTECTED) {
        [self logInfo:@"设备已锁定 (无法启动诊断服务)"];
        return YES;
    }
    
    if (service) {
        lockdownd_service_descriptor_free(service);
        [self logInfo:@"设备未锁定 (成功启动诊断服务)"];
        return NO;  // 成功启动服务意味着设备未锁定
    }
    
    // 方法3: 尝试获取受保护的值来判断锁定状态
    const char* protectedValues[] = {
        "ProductVersion",
        "DeviceClass",
        "UniqueDeviceID",
        "SerialNumber"  // 添加一个额外的保护值
    };
    
    int failedChecks = 0;
    int totalChecks = sizeof(protectedValues) / sizeof(protectedValues[0]);
    
    for (int i = 0; i < totalChecks; i++) {
        plist_t val = NULL;
        lerr = lockdownd_get_value(_backupContext->lockdown, NULL, protectedValues[i], &val);
        
        if (lerr == LOCKDOWN_E_PASSWORD_PROTECTED) {
            failedChecks++;
        }
        
        if (val) plist_free(val);
    }
    
    // 使用比例而非固定数量来判断
    float failureRatio = (float)failedChecks / totalChecks;
    if (failureRatio >= 0.5) {  // 如果50%以上检查失败，判定设备已锁定
        [self logInfo:@"设备已锁定 (%.0f%%受保护值无法访问)", failureRatio * 100];
        return YES;
    }
    
    [self logInfo:@"设备可能未锁定 (所有检查都未确认锁定状态)"];
    return NO;
}

// 内存使用检查方法
- (void)checkMemoryUsage {
    struct mach_task_basic_info info;
    mach_msg_type_number_t size = MACH_TASK_BASIC_INFO_COUNT;
    kern_return_t kerr = task_info(mach_task_self(),
                                 MACH_TASK_BASIC_INFO,
                                 (task_info_t)&info,
                                 &size);
    if (kerr == KERN_SUCCESS) {
        long memUsageMB = info.resident_size / (1024 * 1024);
        [self logDebug:@"当前内存使用: %ld MB", memUsageMB];
        
        // 如果内存使用过高，触发主动清理
        if (memUsageMB > 500) {
            [self logWarning:@"内存使用过高 (%ld MB)，执行主动清理", memUsageMB];
            [self performActiveMemoryCleanup];
        }
    }
}


// 执行主动内存清理
- (void)performActiveMemoryCleanup {
    @autoreleasepool {
        // 清理临时变量
        [self.logCollector setString:[self.logCollector substringFromIndex:MAX(0, self.logCollector.length - 10000)]];
        
        // 清理图像缓存和其他可释放资源
        [[NSURLCache sharedURLCache] removeAllCachedResponses];
        
        // 在后台优先级下执行垃圾回收
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
            @autoreleasepool {
                // 强制一次完整的Autorelease周期
                for (int i = 0; i < 5; i++) {
                    @autoreleasepool {
                        // 创建并立即丢弃一些临时对象以触发清理
                        NSMutableData *tempData = [NSMutableData dataWithLength:1024 * 1024];
                        [tempData setLength:0];
                    }
                }
            }
            
            // 记录清理完成
            [self logInfo:@"内存清理完成"];
        });
        
        // 请求系统执行内存压力清理
        [NSProcessInfo.processInfo performActivityWithOptions:NSActivityBackground
                                                      reason:@"Memory cleanup"
                                                  usingBlock:^{
            // 这里不调用特定函数，而是给系统一个机会回收内存
            [NSThread sleepForTimeInterval:0.1];
        }];
    }
}




#pragma mark - 消息处理方法

- (void)handleContentsOfDirectory:(plist_t)message {
    char *dirpath = NULL;
    plist_t path = plist_dict_get_item(message, "Path");
    
    if (path) {
        plist_get_string_val(path, &dirpath);
    }
    
    [self logInfo:@"请求目录内容: %s", dirpath ? dirpath : "(空)"];
    
    // 发送空响应
    dispatch_sync(self.connectionQueue, ^{
        if (_backupContext && _backupContext->backup) {
            plist_t response = plist_new_dict();
            mobilebackup2_send_status_response(_backupContext->backup, 0, NULL, response);
            plist_free(response);
        }
    });
    
    if (dirpath) free(dirpath);
}

- (void)handleCreateDirectory:(plist_t)message {
    char *dirpath = NULL;
    plist_t path = plist_dict_get_item(message, "Path");
    
    if (path) {
        plist_get_string_val(path, &dirpath);
    }
    
    if (dirpath) {
        NSString *fullPath = [_backupContext->backupPath stringByAppendingPathComponent:
                             [NSString stringWithUTF8String:dirpath]];
        [self logDebug:@"创建目录: %@", fullPath];
        
        dispatch_sync(self.fileQueue, ^{
            NSError *error = nil;
            [[NSFileManager defaultManager] createDirectoryAtPath:fullPath
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:&error];
            if (error) {
                [self logWarning:@"创建目录失败: %@", error.localizedDescription];
            }
        });
        
        free(dirpath);
    } else {
        [self logWarning:@"目录路径为空"];
    }
    
    // 发送成功响应
    dispatch_sync(self.connectionQueue, ^{
        if (_backupContext && _backupContext->backup) {
            plist_t response = plist_new_dict();
            mobilebackup2_send_status_response(_backupContext->backup, 0, NULL, response);
            plist_free(response);
        }
    });
}

//文件上传处理

- (void)handleUploadFiles:(plist_t)message {
    NSDate *operationStart = [NSDate date];
    __block long long bytesReceived = 0;
    uint32_t entryCount = 0; // 不需要__block，因为不在block中修改
    __block int processedCount = 0;  // 添加__block修饰符
    
    NSLog(@"[备份调试] 处理文件上传请求");
    
    // 获取文件条目数组
    plist_t entries = plist_dict_get_item(message, "Entries");
    if (entries && plist_get_node_type(entries) == PLIST_ARRAY) {
        entryCount = plist_array_get_size(entries);
        [self logDebug:@"文件条目数量: %u", entryCount];
        NSLog(@"[备份调试] 文件条目数量: %u", entryCount);
        
        // 如果是第一批文件，更新totalFiles
        dispatch_sync(self.stateQueue, ^{
            if (self.totalFiles == 0) {
                self.totalFiles = entryCount;
                [self logInfo:@"设置总文件数: %d", self.totalFiles];
                NSLog(@"[备份调试] 设置总文件数: %d", self.totalFiles);
            }
        });
        
        // 处理每个文件条目
        for (uint32_t i = 0; i < entryCount && [self shouldContinue]; i++) {
            plist_t entry = plist_array_get_item(entries, i);
            if (!entry) {
                NSLog(@"[备份调试] 警告: 索引 %u 的条目为空", i);
                continue;
            }
            
            plist_t path = plist_dict_get_item(entry, "Path");
            plist_t data = plist_dict_get_item(entry, "Data");
            plist_t size = plist_dict_get_item(entry, "Size"); // 检查大小信息
            
            char *pathStr = NULL;
            uint64_t dataSize = 0;
            char *dataBytes = NULL;
            uint64_t declaredSize = 0;
            
            // 获取文件路径
            if (path) {
                plist_get_string_val(path, &pathStr);
            }
            
            // 获取文件大小声明（如果存在）
            if (size && plist_get_node_type(size) == PLIST_UINT) {
                plist_get_uint_val(size, &declaredSize);
            }
            
            // 获取文件数据
            if (data && plist_get_node_type(data) == PLIST_DATA) {
                plist_get_data_val(data, &dataBytes, &dataSize);
            }
            
            // 记录文件信息
            if (pathStr) {
                NSLog(@"[备份调试] 文件 %d/%u: %s, 大小: %llu 字节",
                      i+1, entryCount, pathStr, dataSize);
            }
            
            // 验证文件路径和数据
            if (pathStr && dataBytes && dataSize > 0) {
                NSString *fullPath = [_backupContext->backupPath stringByAppendingPathComponent:
                                     [NSString stringWithUTF8String:pathStr]];
                NSString *dirPath = [fullPath stringByDeletingLastPathComponent];
                
                // 线程安全的文件操作
                dispatch_sync(self.fileQueue, ^{
                    @autoreleasepool {
                        // 创建目录结构
                        NSError *dirError = nil;
                        [[NSFileManager defaultManager] createDirectoryAtPath:dirPath
                                                  withIntermediateDirectories:YES
                                                                   attributes:nil
                                                                        error:&dirError];
                        
                        if (dirError) {
                            NSLog(@"[备份调试] 创建目录失败: %@", dirError);
                            [self logWarning:@"创建目录失败: %@", dirError.localizedDescription];
                        } else {
                            // 写入文件
                            NSData *fileData = [NSData dataWithBytes:dataBytes length:dataSize];
                            NSError *writeError = nil;
                            BOOL success = [fileData writeToFile:fullPath
                                                        options:NSDataWritingAtomic
                                                          error:&writeError];
                            
                            if (success) {
                                bytesReceived += dataSize;
                                processedCount++;
                                
                                // 更新文件权限（可选）
                                NSDictionary *fileAttrs = @{NSFilePosixPermissions: @(0644)};
                                [[NSFileManager defaultManager] setAttributes:fileAttrs
                                                                 ofItemAtPath:fullPath
                                                                        error:nil];
                                
                                if (i % 10 == 0 || i == entryCount - 1) {
                                    NSLog(@"[备份调试] 成功写入文件 %@, 大小: %llu",
                                          fullPath.lastPathComponent, dataSize);
                                }
                                
                                // 线程安全地更新统计
                                dispatch_sync(self.stateQueue, ^{
                                    self.totalBytesReceived += dataSize;
                                    self.filesProcessed++;
                                    
                                    // 每处理10个文件输出一次日志
                                    if (self.filesProcessed % 10 == 0) {
                                        NSLog(@"[备份调试] 已处理 %d 个文件，共接收 %lld 字节",
                                              self.filesProcessed, self.totalBytesReceived);
                                    }
                                });
                                
                                // 更新估计总大小
                                [self updateEstimatedTotalBytes];
                                
                                // 更新进度
                                [self updateBackupProgress];
                            } else {
                                [self logWarning:@"写入文件失败: %@ - %@", fullPath, writeError.localizedDescription];
                                NSLog(@"[备份调试] 错误: 写入文件失败: %@", writeError);
                            }
                        }
                    }
                });
            } else {
                if (pathStr) {
                    NSLog(@"[备份调试] 警告: 文件数据无效: %s", pathStr);
                    [self logWarning:@"文件数据无效: %s", pathStr];
                } else {
                    NSLog(@"[备份调试] 警告: 文件路径为空");
                    [self logWarning:@"文件路径为空"];
                }
            }
            
            // 释放资源
            if (pathStr) free(pathStr);
            if (dataBytes) free(dataBytes);
        }
        
        NSLog(@"[备份调试] 全部处理完成，成功处理 %d/%u 文件", processedCount, entryCount);
    } else {
        NSLog(@"[备份调试] 错误: Entries不是数组或为空");
        [self logError:@"文件上传请求格式无效或为空"];
    }
    
    // 发送响应 - 使用标准格式
    dispatch_sync(self.connectionQueue, ^{
        if (_backupContext && _backupContext->backup) {
            // 创建标准响应格式
            plist_t response = plist_new_dict();
            
            // 添加处理结果
            plist_dict_set_item(response, "Status", plist_new_string("Complete"));
            
            // 添加处理的文件数量信息
            plist_dict_set_item(response, "FilesProcessed", plist_new_uint(processedCount));
            plist_dict_set_item(response, "TotalFiles", plist_new_uint(entryCount));
            
            // 记录收到的总字节数
            plist_dict_set_item(response, "BytesReceived", plist_new_uint(bytesReceived));
            
            NSLog(@"[备份调试] 发送文件上传响应: 处理 %d/%u 文件, 字节数: %lld",
                  processedCount, entryCount, bytesReceived);
            
            // 发送响应
            mobilebackup2_send_status_response(_backupContext->backup, 0, NULL, response);
            plist_free(response);
        }
    });
    
    // 计算传输速度和输出统计
    NSTimeInterval elapsed = [[NSDate date] timeIntervalSinceDate:operationStart];
    if (elapsed > 0 && bytesReceived > 0) {
        double speedMBps = (bytesReceived / 1024.0 / 1024.0) / elapsed;
        [self logInfo:@"文件传输完成: %d 文件, %@ 数据, 速度: %.2f MB/s",
                     processedCount,
                     [DatalogsSettings humanReadableFileSize:bytesReceived],
                     speedMBps];
        NSLog(@"[备份调试] 文件传输完成: %d 文件, %.2f MB, 速度: %.2f MB/s",
              processedCount,
              bytesReceived / (1024.0 * 1024.0),
              speedMBps);
    } else {
        [self logInfo:@"文件传输完成: %d 文件, %@, 耗时: %.1f 秒",
                     processedCount,
                     [DatalogsSettings humanReadableFileSize:bytesReceived],
                     elapsed];
        NSLog(@"[备份调试] 文件传输完成: %d 文件, %.2f MB, 耗时: %.1f 秒",
              processedCount,
              bytesReceived / (1024.0 * 1024.0),
              elapsed);
    }
}

// 辅助方法 - 格式化字节数为人类可读格式
- (NSString *)formatBytes:(long long)bytes {
    if (bytes < 1024) {
        return [NSString stringWithFormat:@"%lld 字节", bytes];
    } else if (bytes < 1024 * 1024) {
        return [NSString stringWithFormat:@"%.2f KB", bytes / 1024.0];
    } else if (bytes < 1024 * 1024 * 1024) {
        return [NSString stringWithFormat:@"%.2f MB", bytes / (1024.0 * 1024.0)];
    } else {
        return [NSString stringWithFormat:@"%.2f GB", bytes / (1024.0 * 1024.0 * 1024.0)];
    }
}

//消息处理方法

- (void)handleProcessMessage:(plist_t)message {
    char *messageNameStr = NULL;
    plist_t messageName = plist_dict_get_item(message, "MessageName");
    
    if (messageName) {
        plist_get_string_val(messageName, &messageNameStr);
    }
    
    if (messageNameStr) {
        [self logInfo:@"处理消息: %s", messageNameStr];
        NSLog(@"[备份调试] 处理ProcessMessage: %s", messageNameStr);
        
        // 根据消息类型发送响应 - 采用更精确的格式
        dispatch_sync(self.connectionQueue, ^{
            if (_backupContext && _backupContext->backup) {
                plist_t response = plist_new_dict();
                
                if (strcmp(messageNameStr, "BackupMessageBackupReady") == 0) {
                    NSLog(@"[备份调试] 处理BackupMessageBackupReady");
                    plist_dict_set_item(response, "MessageName", plist_new_string(messageNameStr));
                    plist_dict_set_item(response, "Result", plist_new_string("Success"));
                    
                    // BackupReady需要更多参数
                    plist_dict_set_item(response, "Protocol", plist_new_string("com.apple.mobilebackup2"));
                    
                    // 返回设备标识符
                    if (_backupContext->deviceUDID) {
                        plist_dict_set_item(response, "DeviceID",
                            plist_new_string([_backupContext->deviceUDID UTF8String]));
                    }
                    
                    mobilebackup2_send_message(_backupContext->backup, messageNameStr, response);
                }
                else if (strcmp(messageNameStr, "BackupMessageStatus") == 0) {
                    NSLog(@"[备份调试] 处理BackupMessageStatus");
                    plist_dict_set_item(response, "MessageName", plist_new_string(messageNameStr));
                    plist_dict_set_item(response, "Status", plist_new_string("Complete"));
                    
                    // 检查原消息中是否有错误信息和状态
                    plist_t statusNode = plist_dict_get_item(message, "Status");
                    if (statusNode) {
                        char *statusStr = NULL;
                        plist_get_string_val(statusNode, &statusStr);
                        if (statusStr) {
                            NSLog(@"[备份调试] 原始状态: %s", statusStr);
                            free(statusStr);
                        }
                    }
                    
                    mobilebackup2_send_message(_backupContext->backup, messageNameStr, response);
                }
                else {
                    NSLog(@"[备份调试] 处理其他消息类型: %s", messageNameStr);
                    plist_dict_set_item(response, "MessageName", plist_new_string(messageNameStr));
                    plist_dict_set_item(response, "Status", plist_new_string("Complete"));
                    mobilebackup2_send_message(_backupContext->backup, messageNameStr, response);
                }
                
                plist_free(response);
            }
        });
        
        free(messageNameStr);
    } else {
        [self logWarning:@"过程消息名称为空"];
        NSLog(@"[备份调试] 警告: 过程消息名称为空");
    }
}

//下载文件处理

- (void)handleDownloadFiles:(plist_t)message {
    [self logInfo:@"处理文件下载请求"];
    NSLog(@"[备份调试] 开始处理文件下载请求");
    
    // 添加完整消息结构日志
    char *xml_message = NULL;
    uint32_t xml_length = 0;
    plist_to_xml(message, &xml_message, &xml_length);
    if (xml_message) {
        NSLog(@"[备份调试] 下载请求消息: %s", xml_message);
        free(xml_message);
    }
    
    // 解析请求的文件
    plist_t files = plist_dict_get_item(message, "Files");
    plist_t response = plist_new_dict();
    plist_t responseFiles = plist_new_dict();
    
    int requestedCount = 0;
    int foundCount = 0;
    
    // 检查是否是字典格式
    if (files && plist_get_node_type(files) == PLIST_DICT) {
        // 创建字典迭代器
        plist_dict_iter iter = NULL;
        plist_dict_new_iter(files, &iter);
        
        if (iter) {
            char *key = NULL;
            plist_t val = NULL;
            
            do {
                // 获取下一个键值对
                plist_dict_next_item(files, iter, &key, &val);
                
                // 如果已到字典结尾，退出循环
                if (!key || !val) break;
                
                requestedCount++;
                NSString *filePath = [NSString stringWithUTF8String:key];
                NSString *fullPath = [_backupContext->backupPath stringByAppendingPathComponent:filePath];
                
                NSLog(@"[备份调试] 请求下载文件: %@", filePath);
                
                // 检查文件是否存在
                __block BOOL fileExists = NO;
                
                dispatch_sync(self.fileQueue, ^{
                    fileExists = [[NSFileManager defaultManager] fileExistsAtPath:fullPath];
                });
                
                if (fileExists) {
                    foundCount++;
                    // 安全读取文件
                    __block NSData *fileData = nil;
                    __block NSError *readError = nil;
                    
                    dispatch_sync(self.fileQueue, ^{
                        fileData = [NSData dataWithContentsOfFile:fullPath options:NSDataReadingMappedIfSafe error:&readError];
                    });
                    
                    if (fileData && !readError) {
                        NSLog(@"[备份调试] 文件读取成功: %@, 大小: %lu", filePath, (unsigned long)fileData.length);
                        plist_t fileData_node = plist_new_data([fileData bytes], [fileData length]);
                        plist_dict_set_item(responseFiles, key, fileData_node);
                    } else {
                        [self logWarning:@"读取文件失败: %@", readError];
                        NSLog(@"[备份调试] 读取文件失败: %@", readError);
                        plist_t empty_data = plist_new_data(NULL, 0);
                        plist_dict_set_item(responseFiles, key, empty_data);
                    }
                } else {
                    NSLog(@"[备份调试] 文件不存在: %@", filePath);
                    
                    // 对于关键文件，只有在确认需要时才创建，避免创建无效的备份文件
                    if ([filePath isEqualToString:@"Info.plist"] ||
                        [filePath isEqualToString:@"Manifest.plist"] ||
                        [filePath isEqualToString:@"Status.plist"]) {
                        
                        NSLog(@"[备份调试] 尝试处理关键文件请求: %@", filePath);
                        
                        if ([filePath isEqualToString:@"Info.plist"]) {
                            [self createDefaultInfoPlist:filePath fullPath:fullPath responseDict:responseFiles key:key];
                            foundCount++;
                        } else if ([filePath isEqualToString:@"Manifest.plist"]) {
                            [self createDefaultManifestPlist:filePath fullPath:fullPath responseDict:responseFiles key:key];
                            foundCount++;
                        } else if ([filePath isEqualToString:@"Status.plist"]) {
                            [self createDefaultStatusPlist:filePath fullPath:fullPath responseDict:responseFiles key:key];
                            foundCount++;
                        }
                    } else {
                        // 对于其他文件，返回空数据
                        NSLog(@"[备份调试] 返回空数据，文件不存在: %@", filePath);
                        plist_t empty_data = plist_new_data(NULL, 0);
                        plist_dict_set_item(responseFiles, key, empty_data);
                    }
                }
                
                // 释放key内存
                free(key);
                key = NULL;
                
            } while (1);
            
            // 释放迭代器
            free(iter);
        }
    } else {
        NSLog(@"[备份调试] 下载请求使用非标准格式");
        // 非标准格式的处理，尝试作为数组处理
        // 检查是否是数组格式的请求
        plist_t paths_array = NULL;
        
        if (plist_get_node_type(message) == PLIST_ARRAY && plist_array_get_size(message) >= 2) {
            paths_array = plist_array_get_item(message, 1);
        }
        
        if (paths_array && plist_get_node_type(paths_array) == PLIST_ARRAY) {
            uint32_t paths_count = plist_array_get_size(paths_array);
            [self logDebug:@"从数组格式中发现 %d 个文件路径", paths_count];
            
            for (uint32_t i = 0; i < paths_count; i++) {
                plist_t path_node = plist_array_get_item(paths_array, i);
                char *path_str = NULL;
                
                if (path_node && plist_get_node_type(path_node) == PLIST_STRING) {
                    plist_get_string_val(path_node, &path_str);
                    
                    if (path_str) {
                        NSString *filePath = [NSString stringWithUTF8String:path_str];
                        NSString *fullPath = [_backupContext->backupPath stringByAppendingPathComponent:filePath];
                        
                        // 处理请求的文件
                        [self processRequestedFile:filePath fullPath:fullPath responseDict:responseFiles key:path_str];
                        free(path_str);
                    }
                }
            }
        } else {
            [self logWarning:@"无法识别的文件下载请求格式"];
        }
    }
    
    // 添加文件字典到响应
    plist_dict_set_item(response, "Files", responseFiles);
    
    // 添加响应统计信息
    plist_dict_set_item(response, "RequestedCount", plist_new_uint(requestedCount));
    plist_dict_set_item(response, "FoundCount", plist_new_uint(foundCount));
    
    NSLog(@"[备份调试] 下载响应: 请求文件数: %d, 找到文件数: %d", requestedCount, foundCount);
    
    // 发送响应
    dispatch_sync(self.connectionQueue, ^{
        if (_backupContext && _backupContext->backup) {
            mobilebackup2_send_status_response(_backupContext->backup, 0, NULL, response);
        }
    });
    
    // 释放资源
    plist_free(response);
    [self logInfo:@"文件下载请求处理完成"];
    NSLog(@"[备份调试] 文件下载请求处理完成");
}


- (void)handleOtherMessage:(char *)dlmessage message:(plist_t)message {
    [self logInfo:@"处理其他消息: %s", dlmessage];
    
    // 处理文件操作类消息
    if (!strcmp(dlmessage, "DLMessageMoveFile") ||
        !strcmp(dlmessage, "DLMessageMoveItem") ||
        !strcmp(dlmessage, "DLMessageRemoveFile") ||
        !strcmp(dlmessage, "DLMessageRemoveItem") ||
        !strcmp(dlmessage, "DLMessageCopyItem")) {
        
        // 获取源和目标路径
        plist_t src = plist_dict_get_item(message, "Source");
        plist_t dst = plist_dict_get_item(message, "Destination");
        char *srcPath = NULL;
        char *dstPath = NULL;
        
        if (src) plist_get_string_val(src, &srcPath);
        if (dst) plist_get_string_val(dst, &dstPath);
        
        NSString *operation = [NSString stringWithFormat:@"%s", dlmessage];
        [self logDebug:@"文件操作: %@, 源: %s, 目标: %s",
                    operation, srcPath ? srcPath : "(空)", dstPath ? dstPath : "(空)"];
        
        // 执行文件操作
        if (srcPath) {
            NSString *srcFullPath = [_backupContext->backupPath stringByAppendingPathComponent:[NSString stringWithUTF8String:srcPath]];
            
            dispatch_sync(self.fileQueue, ^{
                NSError *error = nil;
                NSFileManager *fileManager = [NSFileManager defaultManager];
                
                if ([operation hasSuffix:@"RemoveFile"] || [operation hasSuffix:@"RemoveItem"]) {
                    [fileManager removeItemAtPath:srcFullPath error:&error];
                } else if (dstPath) {
                    NSString *dstFullPath = [_backupContext->backupPath stringByAppendingPathComponent:
                                            [NSString stringWithUTF8String:dstPath]];
                    
                    if ([operation hasSuffix:@"CopyItem"]) {
                        [fileManager copyItemAtPath:srcFullPath toPath:dstFullPath error:&error];
                    } else if ([operation hasSuffix:@"MoveFile"] || [operation hasSuffix:@"MoveItem"]) {
                        [fileManager moveItemAtPath:srcFullPath toPath:dstFullPath error:&error];
                    }
                }
                
                if (error) {
                    [self logWarning:@"文件操作失败: %@", error.localizedDescription];
                }
            });
        }
        
        if (srcPath) free(srcPath);
        if (dstPath) free(dstPath);
    }
    
    // 发送通用响应
    dispatch_sync(self.connectionQueue, ^{
        if (_backupContext && _backupContext->backup) {
            plist_t response = plist_new_dict();
            mobilebackup2_send_status_response(_backupContext->backup, 0, NULL, response);
            plist_free(response);
        }
    });
}

#pragma mark - 辅助方法

- (BOOL)processRequestedFile:(NSString *)filePath fullPath:(NSString *)fullPath responseDict:(plist_t)responseDict key:(const char *)key {
    __block BOOL fileExists = NO;
    
    dispatch_sync(self.fileQueue, ^{
        fileExists = [[NSFileManager defaultManager] fileExistsAtPath:fullPath];
    });
    
    // 文件存在，读取内容
    if (fileExists) {
        __block NSData *fileData = nil;
        __block NSError *readError = nil;
        
        dispatch_sync(self.fileQueue, ^{
            fileData = [NSData dataWithContentsOfFile:fullPath options:NSDataReadingMappedIfSafe error:&readError];
        });
        
        if (fileData && !readError) {
            [self logDebug:@"成功读取文件，大小: %lu 字节", (unsigned long)fileData.length];
            plist_t fileData_node = plist_new_data([fileData bytes], [fileData length]);
            plist_dict_set_item(responseDict, key, fileData_node);
            return YES;
        } else {
            [self logWarning:@"读取文件失败: %@", readError];
        }
    } else {
        // 文件不存在，可能需要创建默认内容
        [self logDebug:@"文件不存在: %@", filePath];
        
        if ([filePath hasSuffix:@"Info.plist"]) {
            return [self createDefaultInfoPlist:filePath fullPath:fullPath responseDict:responseDict key:key];
        } else if ([filePath hasSuffix:@"Manifest.plist"]) {
            return [self createDefaultManifestPlist:filePath fullPath:fullPath responseDict:responseDict key:key];
        } else if ([filePath hasSuffix:@"Status.plist"]) {
            return [self createDefaultStatusPlist:filePath fullPath:fullPath responseDict:responseDict key:key];
        }
    }
    
    // 默认返回空数据
    plist_t empty_data = plist_new_data(NULL, 0);
    plist_dict_set_item(responseDict, key, empty_data);
    return NO;
}

- (BOOL)createDefaultInfoPlist:(NSString *)filePath fullPath:(NSString *)fullPath responseDict:(plist_t)responseDict key:(const char *)key {
    [self logInfo:@"创建默认Info.plist内容"];
    
    NSMutableDictionary *infoDict = [NSMutableDictionary dictionary];
    [infoDict setObject:_backupContext->deviceUDID forKey:@"UDID"];
    [infoDict setObject:@"MFCTOOL" forKey:@"BackupComputerName"];
    [infoDict setObject:[NSDate date] forKey:@"Date"];
    [infoDict setObject:@(0) forKey:@"iTunesVersion"];
    [infoDict setObject:@"2.4" forKey:@"Version"];
    
    return [self createPlistFile:infoDict filePath:filePath fullPath:fullPath responseDict:responseDict key:key];
}

- (BOOL)createDefaultManifestPlist:(NSString *)filePath fullPath:(NSString *)fullPath responseDict:(plist_t)responseDict key:(const char *)key {
    [self logInfo:@"创建默认Manifest.plist内容"];
    
    NSMutableDictionary *manifestDict = [NSMutableDictionary dictionary];
    [manifestDict setObject:@{} forKey:@"Files"];
    [manifestDict setObject:@"2.4" forKey:@"Version"];
    [manifestDict setObject:@NO forKey:@"IsEncrypted"];
    
    return [self createPlistFile:manifestDict filePath:filePath fullPath:fullPath responseDict:responseDict key:key];
}

- (BOOL)createDefaultStatusPlist:(NSString *)filePath fullPath:(NSString *)fullPath responseDict:(plist_t)responseDict key:(const char *)key {
    [self logInfo:@"创建默认Status.plist内容"];
    
    NSMutableDictionary *statusDict = [NSMutableDictionary dictionary];
    [statusDict setObject:[[NSUUID UUID] UUIDString] forKey:@"UUID"];
    [statusDict setObject:@(0) forKey:@"BackupState"];
    [statusDict setObject:@([[NSDate date] timeIntervalSince1970]) forKey:@"Date"];
    [statusDict setObject:@(0) forKey:@"SnapshotState"];
    
    return [self createPlistFile:statusDict filePath:filePath fullPath:fullPath responseDict:responseDict key:key];
}

- (BOOL)createPlistFile:(NSDictionary *)dict filePath:(NSString *)filePath fullPath:(NSString *)fullPath responseDict:(plist_t)responseDict key:(const char *)key {
    NSError *error = nil;
    NSData *plistData = [NSPropertyListSerialization dataWithPropertyList:dict
                                                                  format:NSPropertyListXMLFormat_v1_0
                                                                 options:0
                                                                   error:&error];
    
    if (!plistData || error) {
        [self logWarning:@"创建plist数据失败: %@", error];
        plist_t empty_data = plist_new_data(NULL, 0);
        plist_dict_set_item(responseDict, key, empty_data);
        return NO;
    }
    
    // 创建目录
    dispatch_sync(self.fileQueue, ^{
        NSString *dirPath = [fullPath stringByDeletingLastPathComponent];
        [[NSFileManager defaultManager] createDirectoryAtPath:dirPath
                                 withIntermediateDirectories:YES
                                                  attributes:nil
                                                       error:nil];
        
        // 写入文件
        [plistData writeToFile:fullPath atomically:YES];
    });
    
    // 添加到响应
    plist_t fileData_node = plist_new_data([plistData bytes], [plistData length]);
    plist_dict_set_item(responseDict, key, fileData_node);
    return YES;
}

- (BOOL)ensureBackupStructure:(NSError **)error {
    [self logInfo:@"确保备份目录结构完整"];
    
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *infoPath = [_backupContext->backupPath stringByAppendingPathComponent:@"Info.plist"];
    NSString *manifestPath = [_backupContext->backupPath stringByAppendingPathComponent:@"Manifest.plist"];
    NSString *statusPath = [_backupContext->backupPath stringByAppendingPathComponent:@"Status.plist"];
    
    __block BOOL infoExists = NO;
    __block BOOL manifestExists = NO;
    __block BOOL statusExists = NO;
    
    dispatch_sync(self.fileQueue, ^{
        infoExists = [fileManager fileExistsAtPath:infoPath];
        manifestExists = [fileManager fileExistsAtPath:manifestPath];
        statusExists = [fileManager fileExistsAtPath:statusPath];
    });
    
    [self logDebug:@"检查基本文件 - Info.plist: %@, Manifest.plist: %@, Status.plist: %@",
               infoExists ? @"已存在" : @"不存在",
               manifestExists ? @"已存在" : @"不存在",
               statusExists ? @"已存在" : @"不存在"];
    
    // 创建缺失的文件
    if (!infoExists) {
        NSMutableDictionary *infoDict = [NSMutableDictionary dictionary];
        [infoDict setObject:_backupContext->deviceUDID forKey:@"UDID"];
        [infoDict setObject:@"MFCTOOL" forKey:@"BackupComputerName"];
        [infoDict setObject:[NSDate date] forKey:@"Date"];
        [infoDict setObject:@(0) forKey:@"iTunesVersion"];
        [infoDict setObject:@"2.4" forKey:@"Version"];
        
        [self savePlistToDisk:infoDict path:infoPath];
    }
    
    if (!manifestExists) {
        NSMutableDictionary *manifestDict = [NSMutableDictionary dictionary];
        [manifestDict setObject:@{} forKey:@"Files"];
        [manifestDict setObject:@"2.4" forKey:@"Version"];
        [manifestDict setObject:@NO forKey:@"IsEncrypted"];
        
        [self savePlistToDisk:manifestDict path:manifestPath];
    }
    
    if (!statusExists) {
        NSMutableDictionary *statusDict = [NSMutableDictionary dictionary];
        [statusDict setObject:[[NSUUID UUID] UUIDString] forKey:@"UUID"];
        [statusDict setObject:@(0) forKey:@"BackupState"];
        [statusDict setObject:@([[NSDate date] timeIntervalSince1970]) forKey:@"Date"];
        [statusDict setObject:@(0) forKey:@"SnapshotState"];
        
        [self savePlistToDisk:statusDict path:statusPath];
    }
    
    return YES;
}

- (void)savePlistToDisk:(NSDictionary *)dict path:(NSString *)path {
    dispatch_sync(self.fileQueue, ^{
        NSError *error = nil;
        NSData *plistData = [NSPropertyListSerialization dataWithPropertyList:dict
                                                                      format:NSPropertyListXMLFormat_v1_0
                                                                     options:0
                                                                       error:&error];
        
        if (plistData && !error) {
            [plistData writeToFile:path atomically:YES];
            [self logInfo:@"%@ 创建成功", [path lastPathComponent]];
        } else {
            [self logWarning:@"创建 %@ 失败: %@", [path lastPathComponent], error];
        }
    });
}

#pragma mark - 连接管理

- (BOOL)recreateBackupConnection:(NSError **)error {
    [self logInfo:@"开始重建备份连接"];
    
    __block BOOL success = NO;
    __block NSError *localError = nil;
    
    dispatch_sync(self.connectionQueue, ^{
        @try {
            // 先释放所有现有资源
            if (_backupContext->backup) {
                [self logDebug:@"释放旧的备份客户端"];
                mobilebackup2_client_free(_backupContext->backup);
                _backupContext->backup = NULL;
            }
            
            if (_backupContext->afc) {
                [self logDebug:@"释放旧的AFC客户端"];
                afc_client_free(_backupContext->afc);
                _backupContext->afc = NULL;
            }
            
            if (_backupContext->lockdown) {
                [self logDebug:@"释放旧的Lockdown客户端"];
                lockdownd_client_free(_backupContext->lockdown);
                _backupContext->lockdown = NULL;
            }
            
            if (_backupContext->device) {
                [self logDebug:@"释放旧的设备句柄"];
                idevice_free(_backupContext->device);
                _backupContext->device = NULL;
            }
            
            // 重新连接设备
            [self logDebug:@"尝试重新连接设备"];
            idevice_error_t ierr = idevice_new_with_options(&_backupContext->device,
                                                          [_backupContext->deviceUDID UTF8String],
                                                          IDEVICE_LOOKUP_USBMUX);
            
            if (ierr != IDEVICE_E_SUCCESS) {
                [self logError:@"重新连接设备失败，错误代码: %d", ierr];
                localError = [self createError:MFCToolBackupErrorDeviceConnection
                                   description:[NSString stringWithFormat:@"重新连接设备失败，错误代码: %d", ierr]];
                success = NO;
                return;
            }
            
            // 重新创建Lockdown客户端
            [self logDebug:@"创建新的Lockdown客户端"];
            lockdownd_error_t lerr = lockdownd_client_new_with_handshake(_backupContext->device,
                                                                      &_backupContext->lockdown,
                                                                      "MFCTOOL");
            
            if (lerr != LOCKDOWN_E_SUCCESS) {
                [self logError:@"重新创建Lockdown客户端失败，错误代码: %d", lerr];
                localError = [self createError:MFCToolBackupErrorLockdown
                                   description:[NSString stringWithFormat:@"重新创建Lockdown客户端失败，错误代码: %d", lerr]];
                success = NO;
                return;
            }
            
            // 检查设备是否已解锁和信任
            char *deviceName = NULL;
            lerr = lockdownd_get_device_name(_backupContext->lockdown, &deviceName);
            
            if (lerr != LOCKDOWN_E_SUCCESS || !deviceName) {
                [self logError:@"设备可能已锁定或未信任，错误代码: %d", lerr];
                
                if (lerr == LOCKDOWN_E_PASSWORD_PROTECTED) {
                    [self logError:@"设备已锁定，请解锁后重试"];
                    localError = [self createError:MFCToolBackupErrorDeviceLocked
                                       description:@"设备已锁定，请解锁后重试"];
                } else {
                    localError = [self createError:MFCToolBackupErrorTrustNotEstablished
                                       description:@"设备可能未信任此电脑，请在设备上确认信任"];
                }
                
                success = NO;
                return;
            }
            
            if (deviceName) {
                free(deviceName);
            }
            
            // 启动AFC服务
            [self logDebug:@"启动新的AFC服务"];
            lockdownd_service_descriptor_t afc_service = NULL;
            lerr = lockdownd_start_service(_backupContext->lockdown,
                                        "com.apple.afc",
                                        &afc_service);
            
            if (lerr != LOCKDOWN_E_SUCCESS || !afc_service) {
                [self logError:@"重新启动AFC服务失败，错误代码: %d", lerr];
                localError = [self createError:MFCToolBackupErrorService
                                   description:@"重新启动AFC服务失败，请确保设备已信任此电脑"];
                success = NO;
                return;
            }
            
            // 创建新的AFC客户端
            afc_client_new(_backupContext->device, afc_service, &_backupContext->afc);
            lockdownd_service_descriptor_free(afc_service);
            
            // 启动备份服务
            [self logDebug:@"启动新的备份服务"];
            lockdownd_service_descriptor_t backup_service = NULL;
            lerr = lockdownd_start_service(_backupContext->lockdown,
                                        "com.apple.mobilebackup2",
                                        &backup_service);
            
            if (lerr != LOCKDOWN_E_SUCCESS || !backup_service) {
                [self logError:@"重新启动备份服务失败，错误代码: %d", lerr];
                localError = [self createError:MFCToolBackupErrorService
                                   description:[NSString stringWithFormat:@"重新启动备份服务失败，错误代码: %d", lerr]];
                success = NO;
                return;
            }
            
            // 创建新的备份客户端
            mobilebackup2_error_t mb2_err = mobilebackup2_client_new(_backupContext->device,
                                                                  backup_service,
                                                                  &_backupContext->backup);
            
            lockdownd_service_descriptor_free(backup_service);
            
            if (mb2_err != MOBILEBACKUP2_E_SUCCESS) {
                [self logError:@"创建新的备份客户端失败，错误代码: %d", mb2_err];
                localError = [self createError:MFCToolBackupErrorService
                                   description:[NSString stringWithFormat:@"创建新的备份客户端失败，错误代码: %d", mb2_err]];
                success = NO;
                return;
            }
            
            [self logInfo:@"成功创建新的备份客户端"];
            
            // 协议版本协商
            [self logDebug:@"重新进行协议版本协商"];
            double versions[] = {2.1, 2.0, 1.6};
            char count = 3;
            double remote_version = 0.0;
            
            mb2_err = mobilebackup2_version_exchange(_backupContext->backup,
                                                  versions,
                                                  count,
                                                  &remote_version);
            
            if (mb2_err != MOBILEBACKUP2_E_SUCCESS) {
                [self logError:@"协议版本协商失败，错误代码: %d", mb2_err];
                localError = [self createError:MFCToolBackupErrorProtocol
                                   description:[NSString stringWithFormat:@"协议版本协商失败，错误代码: %d", mb2_err]];
                success = NO;
                return;
            }
            
            [self logInfo:@"协议版本协商成功，远程版本: %.1f", remote_version];
            _backupContext->protocolVersion = remote_version;
            
            [self logInfo:@"备份连接重建成功"];
            success = YES;
            
        } @catch (NSException *exception) {
            [self logError:@"重建连接过程发生异常: %@", exception];
            [self logDebug:@"异常堆栈: %@", [exception callStackSymbols]];
            
            localError = [self createError:MFCToolBackupErrorInternal
                              description:[NSString stringWithFormat:@"重建连接过程发生异常: %@", exception.reason]];
            success = NO;
        }
    });
    
    if (!success && localError && error) {
        *error = localError;
    }
    
    return success;
}

//心跳机制
- (BOOL)sendHeartbeat {
    NSLog(@"[备份调试] 尝试发送心跳");
    [self logDebug:@"发送心跳信号以保持连接活跃"];
    
    __block BOOL success = NO;
    
    dispatch_sync(self.connectionQueue, ^{
        @try {
            // 检查连接状态
            if (!_backupContext || !_backupContext->backup) {
                [self logWarning:@"心跳检测 - 备份客户端已无效，需重建连接"];
                NSLog(@"[备份调试] 心跳错误: 备份客户端无效");
                success = NO;
                return;
            }
            
            // 首先检查设备是否仍然已连接并解锁
            char *deviceName = NULL;
            lockdownd_error_t lerr = LOCKDOWN_E_UNKNOWN_ERROR;
            
            if (_backupContext->lockdown) {
                lerr = lockdownd_get_device_name(_backupContext->lockdown, &deviceName);
                
                if (lerr != LOCKDOWN_E_SUCCESS) {
                    [self logWarning:@"心跳过程中设备可能已断开或锁定，错误: %d", lerr];
                    NSLog(@"[备份调试] 心跳检查设备连接状态失败: %d", lerr);
                    success = NO;
                    return;
                }
                
                if (deviceName) {
                    free(deviceName);
                }
            }
            
            // 创建正确的DLMessagePing心跳消息 - 参考device_link_service.c中的实现
            NSLog(@"[备份调试] 创建标准DLMessagePing心跳消息");
            plist_t dict = plist_new_dict();
            plist_dict_set_item(dict, "MessageName", plist_new_string("DLMessagePing"));
            
            // 添加结果字典，与标准实现保持一致
            plist_t result = plist_new_dict();
            plist_dict_set_item(result, "Status", plist_new_string("Acknowledged"));
            plist_dict_set_item(dict, "Result", result);
            
            // 发送心跳消息 - 使用正确的API
            NSLog(@"[备份调试] 发送DLMessagePing心跳");
            mobilebackup2_error_t mb2_err = mobilebackup2_send_message(_backupContext->backup, "DLMessagePing", dict);
            plist_free(dict);
            
            if (mb2_err != MOBILEBACKUP2_E_SUCCESS) {
                [self logWarning:@"心跳信号发送失败，错误代码: %d", mb2_err];
                NSLog(@"[备份调试] 心跳发送失败，错误代码: %d", mb2_err);
                success = NO;
                return;
            }
            
            // 尝试接收心跳响应
            NSLog(@"[备份调试] 尝试接收心跳响应");
            plist_t ping_response = NULL;
            char *dlmessage = NULL;
            mb2_err = mobilebackup2_receive_message(_backupContext->backup, &ping_response, &dlmessage);
            
            if (mb2_err == MOBILEBACKUP2_E_SUCCESS && ping_response && dlmessage) {
                NSLog(@"[备份调试] 收到心跳响应: %s", dlmessage);
                if (dlmessage) free(dlmessage);
                if (ping_response) plist_free(ping_response);
            } else {
                NSLog(@"[备份调试] 未收到心跳响应或超时，继续执行");
                // 即使未收到响应也不中断操作
            }
            
            success = YES;
            NSLog(@"[备份调试] 心跳发送成功");
            
        } @catch (NSException *exception) {
            [self logWarning:@"心跳操作异常: %@", exception];
            NSLog(@"[备份调试] 心跳异常: %@", exception);
            success = NO;
        }
    });
    
    return success;
}


// 修改心跳处理方法
- (BOOL)handleHeartbeat:(NSError **)error {
    __block BOOL success = NO;
    __block NSError *localError = nil;
    
    dispatch_sync(self.sslQueue, ^{
        if (![self isSSLValid]) {
            [self incrementSSLFailureCount];
            if ([self sslFailureCount] > MAX_SSL_RETRIES) {
                localError = [self createError:MFCToolBackupErrorSSL
                                 description:@"SSL连接状态无效，需要重新建立连接"];
                return;
            }
        }
        
        plist_t ping = plist_new_dict();
        if (!ping) {
            localError = [self createError:MFCToolBackupErrorInternal
                             description:@"无法创建心跳消息"];
            return;
        }
        
        @try {
            plist_dict_set_item(ping, "MessageName", plist_new_string("DLMessagePing"));
            plist_dict_set_item(ping, "Timestamp",
                              plist_new_string([[@(time(NULL)) stringValue] UTF8String]));
            
            if (![self verifyDeviceConnection]) {
                localError = [self createError:MFCToolBackupErrorDeviceConnection
                                 description:@"设备连接已断开"];
                return;
            }
            
            __block BOOL timeoutOccurred = NO;
            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,
                                                          0, 0, self.sslQueue);
            
            if (timer) {
                dispatch_source_set_timer(timer,
                                        dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                                        DISPATCH_TIME_FOREVER, 0);
                
                dispatch_source_set_event_handler(timer, ^{
                    timeoutOccurred = YES;
                    dispatch_semaphore_signal(sem);
                });
                
                dispatch_resume(timer);
            }
            
            mobilebackup2_error_t mb2_err = mobilebackup2_send_message(_backupContext->backup,
                                                                    "DLMessagePing",
                                                                    ping);
            
            if (mb2_err == MOBILEBACKUP2_E_SUCCESS) {
                char *dlmessage = NULL;
                plist_t response = NULL;
                
                mb2_err = mobilebackup2_receive_message(_backupContext->backup,
                                                      &response,
                                                      &dlmessage);
                
                if (mb2_err == MOBILEBACKUP2_E_SUCCESS && dlmessage) {
                    if (strcmp(dlmessage, "DLMessageProcessMessage") == 0) {
                        success = YES;
                        [self updateSSLState:^(SSLConnectionState *state) {
                            state->isValid = 1;
                            state->lastSuccess = time(NULL);
                            state->failureCount = 0;
                        }];
                    }
                    free(dlmessage);
                }
                
                if (response) {
                    plist_free(response);
                }
            }
            
            if (timer) {
                dispatch_source_cancel(timer);
            }
            
            if (!success) {
                if (timeoutOccurred) {
                    localError = [self createError:MFCToolBackupErrorTimeout
                                     description:@"心跳请求超时"];
                } else if (mb2_err == MOBILEBACKUP2_E_SSL_ERROR) {
                    [self setSSLValid:NO];
                    [self logError:@"SSL心跳失败，错误码: %d", mb2_err];
                    
                    if ([self recoverSSLSession]) {
                        success = YES;
                    } else {
                        localError = [self createError:MFCToolBackupErrorSSL
                                         description:@"无法恢复SSL会话"];
                    }
                } else {
                    localError = [self createError:MFCToolBackupErrorCommunication
                                     description:[NSString stringWithFormat:@"心跳失败，错误码: %d", mb2_err]];
                }
            }
        } @catch (NSException *exception) {
            [self logError:@"心跳处理异常: %@", exception];
            localError = [self createError:MFCToolBackupErrorInternal
                             description:[NSString stringWithFormat:@"心跳处理异常: %@", exception.reason]];
        } @finally {
            if (ping) {
                plist_free(ping);
            }
        }
    });
    
    if (error && localError) {
        *error = localError;
    }
    
    return success;
}

- (BOOL)verifyDeviceConnection {
    if (!_backupContext || !_backupContext->device || !_backupContext->lockdown) {
        return NO;
    }
    
    char *deviceName = NULL;
    lockdownd_error_t lerr = lockdownd_get_device_name(_backupContext->lockdown, &deviceName);
    
    if (deviceName) {
        free(deviceName);
    }
    
    return (lerr == LOCKDOWN_E_SUCCESS);
}


// 6. 添加心跳超时保护
- (void)handleHeartbeatWithTimeout:(NSTimeInterval)timeout completion:(void (^)(BOOL success, NSError *error))completion {
    dispatch_async(self.sslQueue, ^{
        __block BOOL success = NO;
        __block NSError *error = nil;
        
        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.sslQueue);
        
        dispatch_source_set_timer(timer,
                                dispatch_time(DISPATCH_TIME_NOW, timeout * NSEC_PER_SEC),
                                DISPATCH_TIME_FOREVER, 0);
        
        dispatch_source_set_event_handler(timer, ^{
            dispatch_semaphore_signal(semaphore);
        });
        
        dispatch_resume(timer);
        
        // 执行心跳检查
        @try {
            if (![self performHeartbeatCheck:&error]) {
                success = NO;
            } else {
                success = YES;
                [self updateSSLState:^(SSLConnectionState *state) {
                    state->isValid = YES;
                    state->lastSuccess = time(NULL);
                    state->failureCount = 0;
                }];
            }
        } @catch (NSException *exception) {
            error = [self createError:MFCToolBackupErrorSSL
                         description:[NSString stringWithFormat:@"心跳处理异常: %@", exception.reason]];
            success = NO;
        }
        
        // 取消定时器
        dispatch_source_cancel(timer);
        dispatch_release(timer);
        
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(success, error);
            });
        }
    });
}

// 7. 添加心跳检查的核心方法
- (BOOL)performHeartbeatCheck:(NSError **)error {
    if (![self isSSLValid]) {
        [self incrementSSLFailureCount];
        if ([self sslFailureCount] > MAX_SSL_RETRIES) {
            if (error) {
                *error = [self createError:MFCToolBackupErrorSSL
                             description:@"SSL连接状态无效，需要重新建立连接"];
            }
            return NO;
        }
    }
    
    __block BOOL success = NO;
    __block NSError *localError = nil;
    
    @try {
        // 创建心跳消息
        plist_t ping = plist_new_dict();
        if (!ping) {
            if (error) {
                *error = [self createError:MFCToolBackupErrorInternal
                             description:@"无法创建心跳消息"];
            }
            return NO;
        }
        
        @try {
            // 添加心跳消息内容
            plist_dict_set_item(ping, "MessageName", plist_new_string("DLMessagePing"));
            plist_dict_set_item(ping, "Timestamp",
                              plist_new_string([[@(time(NULL)) stringValue] UTF8String]));
            
            // 发送心跳消息
            mobilebackup2_error_t mb2_err = mobilebackup2_send_message(_backupContext->backup,
                                                                    "DLMessagePing",
                                                                    ping);
            
            if (mb2_err == MOBILEBACKUP2_E_SUCCESS) {
                success = YES;
            } else {
                if (error) {
                    *error = [self createError:MFCToolBackupErrorCommunication
                                 description:[NSString stringWithFormat:@"心跳发送失败，错误码: %d", mb2_err]];
                }
            }
        } @finally {
            if (ping) {
                plist_free(ping);
            }
        }
    } @catch (NSException *exception) {
        if (error) {
            *error = [self createError:MFCToolBackupErrorInternal
                         description:[NSString stringWithFormat:@"心跳检查异常: %@", exception.reason]];
        }
        success = NO;
    }
    
    return success;
}

// 添加SSL会话恢复方法
- (BOOL)recoverSSLSession {
    [self logInfo:@"开始恢复SSL会话"];
    
    // 清理现有连接
    if (_backupContext->backup) {
        mobilebackup2_client_free(_backupContext->backup);
        _backupContext->backup = NULL;
    }
    
    // 重新启动服务
    lockdownd_service_descriptor_t backup_service = NULL;
    lockdownd_error_t lerr = lockdownd_start_service(_backupContext->lockdown,
                                                    "com.apple.mobilebackup2",
                                                    &backup_service);
    
    if (lerr != LOCKDOWN_E_SUCCESS || !backup_service) {
        [self logError:@"重新启动备份服务失败"];
        return NO;
    }
    
    // 创建新的客户端
    mobilebackup2_error_t mb2_err = mobilebackup2_client_new(_backupContext->device,
                                                            backup_service,
                                                            &_backupContext->backup);
    
    lockdownd_service_descriptor_free(backup_service);
    
    if (mb2_err != MOBILEBACKUP2_E_SUCCESS) {
        [self logError:@"创建新的备份客户端失败"];
        return NO;
    }
    
    // 执行版本协商
    double versions[] = {2.1, 2.0, 1.6};
    double remote_version = 0.0;
    mb2_err = mobilebackup2_version_exchange(_backupContext->backup,
                                           versions,
                                           sizeof(versions)/sizeof(versions[0]),
                                           &remote_version);
    
    if (mb2_err != MOBILEBACKUP2_E_SUCCESS) {
        [self logError:@"版本协商失败"];
        return NO;
    }
    
    [self logInfo:@"SSL会话恢复成功，远程版本: %.1f", remote_version];
    return YES;
}

#pragma mark - 状态和进度管理

- (void)transitionToState:(BackupState)newState {
    // 使用barrier确保状态转换的线程安全
    dispatch_barrier_async(self.stateQueue, ^{
        BackupState oldState = self.internalState;
        if (oldState != newState) {
            [self logInfo:@"状态转换: %@ -> %@",
                       [self stateToString:oldState],
                       [self stateToString:newState]];
            
            self.internalState = newState;
            
            // 状态变更通知
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter] postNotificationName:@"BackupTaskStateChanged"
                                                                    object:self
                                                                  userInfo:@{@"oldState": @(oldState),
                                                                             @"newState": @(newState)}];
            });
        }
    });
}

- (NSString *)stateToString:(BackupState)state {
    switch (state) {
        case BackupStateIdle: return @"空闲";
        case BackupStateInitializing: return @"初始化中";
        case BackupStateNegotiating: return @"协议协商中";
        case BackupStateRequiringPassword: return @"等待密码";
        case BackupStateBackingUp: return @"备份中";
        case BackupStateCompleted: return @"已完成";
        case BackupStateError: return @"错误";
        case BackupStateCancelled: return @"已取消";
        default: return [NSString stringWithFormat:@"未知(%ld)", (long)state];
    }
}

- (void)updateProgress:(double)progress message:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.progressCallback) {
            self.progressCallback(progress, message);
        }
    });
}

- (void)updateBackupProgress {
    // 检查当前是否已在 stateQueue 上
    if (dispatch_get_specific(kStateQueueSpecificKey) == kStateQueueSpecificValue) {
        // 已在队列上，直接执行内部方法
        [self _updateBackupProgressInternal];
    } else {
        // 不在队列上，使用异步调用
        dispatch_async(self.stateQueue, ^{
            [self _updateBackupProgressInternal];
        });
    }
}

- (void)_updateBackupProgressInternal {
    // 已经在 stateQueue 上，无需再使用 dispatch_sync
    
    // 改进进度计算逻辑
    double byteProgress = 0.0;
    double fileProgress = 0.0;
    
    // 如果有估计的总大小，计算字节进度
    if (self.estimatedTotalBytes > 0) {
        byteProgress = (double)self.totalBytesReceived / self.estimatedTotalBytes;
    }
    
    // 如果有估计的总文件数，计算文件进度
    if (self.totalFiles > 0) {
        fileProgress = (double)self.filesProcessed / self.totalFiles;
    } else if (self.filesProcessed > 0) {
        // 如果有处理文件但无总数估计，使用动态缩放
        fileProgress = MIN(0.8, (double)self.filesProcessed / 1000.0);
    }
    
    // 综合进度，根据备份阶段动态调整权重
    double combinedProgress;
    BackupState currentState = self.internalState;
    
    if (currentState == BackupStateInitializing ||
        currentState == BackupStateNegotiating) {
        // 初始阶段，进度限制在0-10%
        combinedProgress = 0.1 * (byteProgress + fileProgress) / 2;
    } else if (currentState == BackupStateRequiringPassword) {
        // 等待密码阶段，固定进度
        combinedProgress = 0.1;
    } else if (currentState == BackupStateBackingUp) {
        // 备份阶段，进度范围为10%-95%
        double weightedProgress = byteProgress * 0.6 + fileProgress * 0.4;
        combinedProgress = 0.1 + weightedProgress * 0.85;
    } else if (currentState == BackupStateCompleted) {
        // 完成阶段
        combinedProgress = 1.0;
    } else {
        // 其他状态
        combinedProgress = MAX(byteProgress, fileProgress);
    }
    
    // 限制进度范围
    combinedProgress = MAX(0.0, MIN(combinedProgress, 1.0));
    
    // 平滑进度变化，避免进度回退
    if (combinedProgress < self.lastReportedProgress) {
        // 只允许微小的进度回退（可能由于估计值更新）
        if (self.lastReportedProgress - combinedProgress > 0.05) {
            combinedProgress = self.lastReportedProgress;
        }
    }
    
    // 如果是第一次更新，初始化lastProgressUpdateTime
    if (!self.lastProgressUpdateTime) {
        self.lastProgressUpdateTime = [NSDate date];
    }
    
    // 如果进度变化超过1%或者时间超过3秒，更新显示
    NSTimeInterval timeSinceLastUpdate = [[NSDate date] timeIntervalSinceDate:self.lastProgressUpdateTime];
    
    if (fabs(combinedProgress - self.lastReportedProgress) >= 0.01 || timeSinceLastUpdate >= 3.0) {
        self.lastReportedProgress = combinedProgress;
        self.lastProgressUpdateTime = [NSDate date];
        
        // 生成更详细的进度信息
        NSString *message;
        NSString *stateStr = [self stateToString:currentState];
        
        if (self.estimatedTotalBytes > 0) {
            message = [NSString stringWithFormat:@"%@ - 已处理 %d/%d 文件，传输: %@/%@ (%.1f%%)",
                      stateStr,
                      self.filesProcessed,
                      self.totalFiles > 0 ? self.totalFiles : 0,
                      [DatalogsSettings humanReadableFileSize:self.totalBytesReceived],
                      [DatalogsSettings humanReadableFileSize:self.estimatedTotalBytes],
                      combinedProgress * 100];
        } else {
            message = [NSString stringWithFormat:@"%@ - 已处理 %d 文件，传输: %@",
                      stateStr,
                      self.filesProcessed,
                      [DatalogsSettings humanReadableFileSize:self.totalBytesReceived]];
        }
        
        // 添加额外的性能信息，如果需要
        if (self.logLevel >= MFCLogLevelDebug) {
            NSTimeInterval duration = [[NSDate date] timeIntervalSinceDate:_backupContext->startTime];
            if (duration > 0 && self.totalBytesReceived > 0) {
                double speedMBps = (self.totalBytesReceived / 1024.0 / 1024.0) / duration;
                message = [message stringByAppendingFormat:@" (%.2f MB/s)", speedMBps];
            }
        }
        
        // 在主线程更新UI
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.progressCallback) {
                self.progressCallback(combinedProgress, message);
            }
        });
        
        // 记录进度到日志
        if (timeSinceLastUpdate >= 10.0) { // 每10秒记录一次
            [self logInfo:@"备份进度: %.1f%%, 已处理 %d 文件，传输: %@",
                     combinedProgress * 100,
                     self.filesProcessed,
                     [DatalogsSettings humanReadableFileSize:self.totalBytesReceived]];
        }
    }
}

- (void)updateEstimatedTotalBytes {
    // 检查当前是否已在 stateQueue 上
    if (dispatch_get_specific(kStateQueueSpecificKey) == kStateQueueSpecificValue) {
        [self _updateEstimatedTotalBytesInternal];
    } else {
        dispatch_async(self.stateQueue, ^{
            [self _updateEstimatedTotalBytesInternal];
        });
    }
}

- (void)_updateEstimatedTotalBytesInternal {
    if (self.filesProcessed > 0 && self.totalFiles > 0) {
        // 基于已处理文件的平均大小重新估算
        double avgSize = (double)self.totalBytesReceived / self.filesProcessed;
        long long newEstimate = (long long)(avgSize * self.totalFiles);
        
        // 如果新估算与当前估算差异较大（>20%），更新
        if (self.estimatedTotalBytes == 0 ||
            fabs(1.0 - (double)newEstimate / self.estimatedTotalBytes) > 0.2) {
            self.estimatedTotalBytes = newEstimate;
            [self logInfo:@"更新估算总大小: %lld 字节 (%.2f MB), 基于 %d/%d 文件",
                     self.estimatedTotalBytes,
                     self.estimatedTotalBytes / (1024.0 * 1024.0),
                     self.filesProcessed,
                     self.totalFiles];
        }
    }
}

- (void)startProgressTimer {
    [self logDebug:@"启动进度定时器"];
    
    // 停止已有定时器
    if (self.progressTimer) {
        dispatch_source_cancel(self.progressTimer);
        self.progressTimer = nil;
    }
    
    // 创建新定时器
    self.progressTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(self.progressTimer, DISPATCH_TIME_NOW, 1.0 * NSEC_PER_SEC, 0.5 * NSEC_PER_SEC);
    
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(self.progressTimer, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        
        // 直接调用公共方法，它会自动处理队列问题
        [strongSelf updateBackupProgress];
    });
    
    dispatch_resume(self.progressTimer);
    [self logDebug:@"进度定时器启动成功"];
}

- (BOOL)shouldContinue {
    __block BOOL shouldContinue = YES;
    
    dispatch_sync(self.stateQueue, ^{
        shouldContinue = !self.shouldCancel;
    });
    
    return shouldContinue;
}

// 使用条件变量时确保释放锁，避免死锁
- (void)checkPauseState {
    [self.pauseCondition lock];
    
    __block BOOL isPaused = NO;
    
    // 避免在持有锁时调用dispatch_sync
    @try {
        isPaused = self.shouldPause;
        
        if (isPaused) {
            [self logInfo:@"备份已暂停，等待恢复"];
            
            // 设置超时，避免永久等待
            NSDate *timeoutDate = [NSDate dateWithTimeIntervalSinceNow:300.0]; // 5分钟超时
            while (self.shouldPause && !self.shouldCancel &&
                   [self.pauseCondition waitUntilDate:timeoutDate]) {
                // 周期性检查
            }
            
            if (self.shouldPause && !self.shouldCancel) {
                [self logWarning:@"暂停等待超时，自动恢复备份"];
                self.shouldPause = NO;
            }
            
            [self logInfo:@"备份已恢复"];
        }
    }
    @finally {
        [self.pauseCondition unlock];
    }
}

#pragma mark - 完成和清理

// 在 finishWithSuccess 方法中添加增量备份处理
- (void)finishWithSuccess {
    // 验证备份是否包含数据
    if (self.filesProcessed == 0 || self.totalBytesReceived == 0) {
        [self logWarning:@"备份完成但未传输新文件或数据，检查是否为有效的增量备份"];
        
        if ([self isIncrementalBackupCompleted]) {
            [self logInfo:@"确认为有效的增量备份，无需传输新文件"];
            // 继续执行成功流程
        } else {
            // 否则尝试备份目录检查
            NSFileManager *fileManager = [NSFileManager defaultManager];
            NSError *dirError = nil;
            NSArray *existingFiles = [fileManager contentsOfDirectoryAtPath:_backupContext->backupPath error:&dirError];
            
            NSMutableSet *basicFiles = [NSMutableSet setWithArray:@[@"Info.plist", @"Manifest.plist", @"Status.plist", @"backup_log.txt"]];
            NSMutableSet *directoryContents = [NSMutableSet setWithArray:existingFiles];
            [directoryContents minusSet:basicFiles];
            
            // 如果目录中有超过基本文件的文件，认为是有效的增量备份
            if (!dirError && [directoryContents count] > 0) {
                [self logInfo:@"目录中存在 %lu 个非基本文件，判断为有效的增量备份", (unsigned long)[directoryContents count]];
                // 继续执行成功流程
            } else {
                // 如果目录中文件很少，并且本次备份未传输任何文件，则视为失败
                [self logError:@"备份目录内容不足且未传输新文件，备份可能失败"];
                NSError *emptyBackupError = [self createError:MFCToolBackupErrorIncomplete
                                           description:@"备份过程完成但未包含任何文件，请重试"];
                [self finishWithError:emptyBackupError];
                return;
            }
        }
    }
    
    [self transitionToState:BackupStateCompleted];
    
    NSTimeInterval duration = [[NSDate date] timeIntervalSinceDate:_backupContext->startTime];
    
    [self logInfo:@"备份成功完成"];
    [self updateProgress:1.0 message:@"备份完成！"];
    
    // 统计信息
    NSString *backupType = (self.filesProcessed == 0 && self.totalBytesReceived == 0) ? @"增量备份(无新文件)" : @"备份";
    NSString *stats = [NSString stringWithFormat:@"%@统计:\n总文件数: %d\n总数据量: %@\n总用时: %.1f 秒\n平均速度: %.2f MB/s",
                       backupType,
                       self.filesProcessed,
                       [DatalogsSettings humanReadableFileSize:self.totalBytesReceived],
                       duration,
                       self.totalBytesReceived / 1024.0 / 1024.0 / (duration > 0 ? duration : 1)];
    [self logInfo:@"%@", stats];
    
    // 更新备份信息
    [self updateBackupInfo];
    
    // 保存完成回调
    BackupCompletionBlock completionHandler = self.completionCallback;
    
    // 保存日志
    [self saveLogsToDisk];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        if (completionHandler) {
            completionHandler(YES, nil);
        }
    });
}

// 添加备份信息更新方法
- (void)updateBackupInfo {
    // 更新Info.plist的备份时间
    NSString *infoPath = [_backupContext->backupPath stringByAppendingPathComponent:@"Info.plist"];
    NSError *readError = nil;
    NSMutableDictionary *info = nil;
    
    // 正确读取plist文件
    NSData *infoData = [NSData dataWithContentsOfFile:infoPath options:0 error:&readError];
    if (infoData) {
        id plistObject = [NSPropertyListSerialization propertyListWithData:infoData
                                                                options:NSPropertyListMutableContainersAndLeaves
                                                                 format:NULL
                                                                  error:&readError];
        if ([plistObject isKindOfClass:[NSMutableDictionary class]]) {
            info = (NSMutableDictionary *)plistObject;
        } else if ([plistObject isKindOfClass:[NSDictionary class]]) {
            info = [NSMutableDictionary dictionaryWithDictionary:(NSDictionary *)plistObject];
        }
    }
    
    if (!readError && info) {
        // 更新备份时间
        [info setObject:[NSDate date] forKey:@"Date"];
        
        // 更新计算机名称
        NSString *computerName = [[NSHost currentHost] localizedName];
        if (computerName) {
            [info setObject:computerName forKey:@"BackupComputerName"];
        } else {
            [info setObject:@"MFCTOOL" forKey:@"BackupComputerName"];
        }
        
        // 保存更新后的Info.plist
        NSError *writeError = nil;
        NSData *plistData = [NSPropertyListSerialization dataWithPropertyList:info
                                                                      format:NSPropertyListXMLFormat_v1_0
                                                                     options:0
                                                                       error:&writeError];
        
        if (plistData && !writeError) {
            BOOL success = [plistData writeToFile:infoPath atomically:YES];
            if (success) {
                [self logInfo:@"已更新备份信息"];
            } else {
                [self logWarning:@"写入备份信息文件失败"];
            }
        } else {
            [self logWarning:@"序列化备份信息失败: %@", writeError.localizedDescription];
        }
    } else {
        [self logWarning:@"无法读取备份信息: %@", readError.localizedDescription];
    }
}

// 添加重协商备份会话方法

- (BOOL)renegotiateBackupSession:(NSError **)error {
    [self logInfo:@"尝试重新协商备份会话"];
    
    __block BOOL success = NO;
    __block NSError *localError = nil;
    
    dispatch_sync(self.connectionQueue, ^{
        // 确保备份客户端有效
        if (!_backupContext || !_backupContext->backup) {
            [self logError:@"备份客户端无效，无法重新协商"];
            localError = [self createError:MFCToolBackupErrorInternal
                              description:@"备份客户端无效，无法重新协商"];
            success = NO;
            return;
        }
        
        // 尝试重新执行版本协商
        [self logDebug:@"重新执行协议版本协商"];
        double versions[] = {2.1, 2.0, 1.6};
        char count = 3;
        double remote_version = 0.0;
        
        mobilebackup2_error_t mb2_err = mobilebackup2_version_exchange(_backupContext->backup,
                                                                   versions,
                                                                   count,
                                                                   &remote_version);
        
        if (mb2_err != MOBILEBACKUP2_E_SUCCESS) {
            [self logError:@"协议版本协商失败，错误代码: %d", mb2_err];
            localError = [self createError:[self mapProtocolErrorToErrorCode:mb2_err]
                              description:[NSString stringWithFormat:@"协议版本协商失败，错误代码: %d", mb2_err]];
            success = NO;
            return;
        }
        
        [self logInfo:@"协议版本协商成功，远程版本: %.1f", remote_version];
        _backupContext->protocolVersion = remote_version;
        
        // 重新发送备份请求
        if (![self sendBackupRequest:&localError]) {
            [self logError:@"重新发送备份请求失败: %@", localError.localizedDescription];
            success = NO;
            return;
        }
        
        [self logInfo:@"重新发送备份请求成功"];
        success = YES;
    });
    
    if (!success && localError && error) {
        *error = localError;
    }
    
    return success;
}




- (void)finishWithError:(NSError *)error {
    [self transitionToState:BackupStateError];
    
    // 确保有效的错误对象
    if (!error) {
        error = [self createError:MFCToolBackupErrorInternal
                     description:@"未知错误"];
    }
    
    [self logError:@"备份失败: %@", error.localizedDescription];
    
    // 保存完成回调
    BackupCompletionBlock completionHandler = self.completionCallback;
    
    // 保存日志
    [self saveLogsToDisk];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        if (completionHandler) {
            completionHandler(NO, error);
        }
    });
}

- (void)cleanupAll {
    [self logInfo:@"执行资源清理"];
    
    // 停止定时器
    if (self.progressTimer) {
        dispatch_source_cancel(self.progressTimer);
        self.progressTimer = nil;
        [self logDebug:@"进度定时器已取消"];
    }
    
    // 清理上下文资源
    dispatch_sync(self.connectionQueue, ^{
        if (_backupContext) {
            if (_backupContext->backup) {
                [self logDebug:@"释放backup客户端"];
                mobilebackup2_client_free(_backupContext->backup);
                _backupContext->backup = NULL;
            }
            
            if (_backupContext->afc) {
                [self logDebug:@"释放afc客户端"];
                afc_client_free(_backupContext->afc);
                _backupContext->afc = NULL;
            }
            
            if (_backupContext->lockdown) {
                [self logDebug:@"释放lockdown客户端"];
                lockdownd_client_free(_backupContext->lockdown);
                _backupContext->lockdown = NULL;
            }
            
            if (_backupContext->device) {
                [self logDebug:@"释放设备句柄"];
                idevice_free(_backupContext->device);
                _backupContext->device = NULL;
            }
            
            // 清理NSString字段
            _backupContext->deviceUDID = nil;
            _backupContext->backupPath = nil;
            _backupContext->password = nil;
            
            // 释放上下文结构体
            free(_backupContext);
            _backupContext = NULL;
        }
    });
    
    // 清除回调
    self.progressCallback = nil;
    self.passwordCallback = nil;
    
    [self logInfo:@"资源清理完成"];
}

#pragma mark - 日志和错误处理

- (void)logError:(NSString *)format, ... {
    if (self.logLevel < MFCLogLevelError) return;
    
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    
    [self logWithLevel:@"[ERR]" message:message];
}

- (void)logWarning:(NSString *)format, ... {
    if (self.logLevel < MFCLogLevelWarning) return;
    
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    
    [self logWithLevel:@"[WAR]" message:message];
}

- (void)logInfo:(NSString *)format, ... {
    if (self.logLevel < MFCLogLevelInfo) return;
    
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    
    [self logWithLevel:@"[INFO]" message:message];
}

- (void)logDebug:(NSString *)format, ... {
    if (self.logLevel < MFCLogLevelDebug) return;
    
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    
    [self logWithLevel:@"[DEBUG]" message:message];
}

- (void)logVerbose:(NSString *)format, ... {
    if (self.logLevel < MFCLogLevelVerbose) return;
    
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    
    [self logWithLevel:@"[VERBOSE]" message:message];
}

- (void)logWithLevel:(NSString *)level message:(NSString *)message {
    NSString *timestamp = [[NSDate date] description];
    NSString *logEntry = [NSString stringWithFormat:@"[%@] %@ %@\n", timestamp, level, message];
    
    // 在控制台输出
    NSLog(@"%@ %@", level, message);
    
    // 添加到日志收集器
    @synchronized(self.logCollector) {
        [self.logCollector appendString:logEntry];
    }
    
    // 当日志超过1MB时，写入文件
    if (self.logCollector.length > 1024 * 1024) {
        [self saveLogsToDisk];
    }
}

- (void)saveLogsToDisk {
    @synchronized(self.logCollector) {
        if (!self.logFilePath || self.logCollector.length == 0) return;
        
        // 创建一个副本
        NSString *logContent = [self.logCollector copy];
        
        // 清空收集器
        [self.logCollector setString:@""];
        
        // 异步写入文件
        dispatch_async(self.fileQueue, ^{
            NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:self.logFilePath];
            
            if (fileHandle) {
                [fileHandle seekToEndOfFile];
                [fileHandle writeData:[logContent dataUsingEncoding:NSUTF8StringEncoding]];
                [fileHandle closeFile];
            } else {
                // 文件不存在，创建新文件
                [logContent writeToFile:self.logFilePath
                             atomically:YES
                               encoding:NSUTF8StringEncoding
                                  error:nil];
            }
        });
    }
}

// 增强错误创建方法
- (NSError *)createError:(MFCToolBackupError)code description:(NSString *)description {
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionaryWithObject:description forKey:NSLocalizedDescriptionKey];
    
    // 添加恢复建议
    NSString *recoverySuggestion = nil;
    switch (code) {
        case MFCToolBackupErrorDeviceConnection:
            recoverySuggestion = @"请检查设备是否连接正常，尝试重新连接USB线缆或重启设备。";
            break;
        case MFCToolBackupErrorLockdown:
            recoverySuggestion = @"请确保设备已解锁，并在设备上确认信任此计算机。";
            break;
        case MFCToolBackupErrorTrustNotEstablished:
            recoverySuggestion = @"请在设备上点击 ‘信任’ 按钮以信任此计算机。";
            break;
        case MFCToolBackupErrorDiskSpace:
            recoverySuggestion = @"请清理计算机磁盘空间后再尝试备份。";
            break;
        case MFCToolBackupErrorTimeout:
            recoverySuggestion = @"备份过程超时，请检查设备状态并重试。若问题持续，请尝试重启设备。";
            break;
        case MFCToolBackupErrorInvalidPassword:
            recoverySuggestion = @"请输入正确的备份密码。如果忘记密码，可能无法恢复备份。";
            break;
        case MFCToolBackupErrorEncryptionFailed:
            recoverySuggestion = @"加密备份失败，请检查密码并重试。";
            break;
        case MFCToolBackupErrorDeviceLocked:
            recoverySuggestion = @"请解锁设备后重试备份操作。";
            break;
        case MFCToolBackupErrorNetworkError:
            recoverySuggestion = @"网络连接异常，请检查USB连接并重试。";
            break;
        case MFCToolBackupErrorIncomplete:
            recoverySuggestion = @"备份未完成，请检查设备状态后重新尝试备份。";
            break;
        case MFCToolBackupErrorDeviceDetached:
            recoverySuggestion = @"设备已断开连接，请重新连接设备并重试。";
            break;
        case MFCToolBackupErrorDeviceBusy:
            recoverySuggestion = @"设备当前正忙，请稍后重试。";
            break;
        default:
            recoverySuggestion = @"请重试备份操作，如果问题持续，请重启设备和计算机。";
            break;
    }
    
    [userInfo setObject:recoverySuggestion forKey:NSLocalizedRecoverySuggestionErrorKey];
    
    // 错误恢复选项
    NSArray *recoveryOptions = @[@"重试", @"取消"];
    [userInfo setObject:recoveryOptions forKey:NSLocalizedRecoveryOptionsErrorKey];
    
    return [NSError errorWithDomain:MFCToolBackupErrorDomain code:code userInfo:userInfo];
}


// 添加错误映射方法
- (MFCToolBackupError)mapProtocolErrorToErrorCode:(mobilebackup2_error_t)protocolError {
    switch (protocolError) {
        case MOBILEBACKUP2_E_SUCCESS:
            return MFCToolBackupErrorInternal; // 不应该发生
        case MOBILEBACKUP2_E_INVALID_ARG:
            return MFCToolBackupErrorInternal;
        case MOBILEBACKUP2_E_PLIST_ERROR:
            return MFCToolBackupErrorProtocol;
        case MOBILEBACKUP2_E_MUX_ERROR:
            return MFCToolBackupErrorDeviceConnection;
        case MOBILEBACKUP2_E_SSL_ERROR:
            return MFCToolBackupErrorDeviceConnection;
        case MOBILEBACKUP2_E_RECEIVE_TIMEOUT:
            return MFCToolBackupErrorTimeout;
        case MOBILEBACKUP2_E_BAD_VERSION:
            return MFCToolBackupErrorProtocolMismatch;
        case MOBILEBACKUP2_E_REPLY_NOT_OK:
            return MFCToolBackupErrorBackupFailed;
        case MOBILEBACKUP2_E_NO_COMMON_VERSION:
            return MFCToolBackupErrorProtocolMismatch;
        default:
            return MFCToolBackupErrorInternal;
    }
}

@end
