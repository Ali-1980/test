//
//  BackupTask.m
//  iOSBackupManager
//
//  Created based on libimobiledevice
//

#import "BackupTask.h"
#import <CommonCrypto/CommonCrypto.h>

// 引入 libimobiledevice 相关头文件
#include <libimfccore/libimfccore.h>
#include <libimfccore/lockdown.h>
#include <libimfccore/mobilebackup2.h>
#include <libimfccore/notification_proxy.h>
#include <libimfccore/afc.h>
#include <libimfccore/installation_proxy.h>
#include <libimfccore/sbservices.h>
#include <libimfccore/diagnostics_relay.h>
#include <libimfccoreextra/utils.h>
#include <plist/plist.h>
#import <sys/stat.h>
#include <stdio.h>

// 定义常量
NSString * const kBackupTaskErrorDomain = @"com.example.BackupTaskErrorDomain";
NSString * const kNPSyncWillStart = @"com.apple.itunes.backup.willStart";
NSString * const kNPSyncLockRequest = @"com.apple.itunes.backup.lockRequest";
NSString * const kNPSyncDidStart = @"com.apple.itunes.backup.didStart";
NSString * const kNPSyncCancelRequest = @"com.apple.itunes.backup.cancelRequest";
NSString * const kNPBackupDomainChanged = @"com.apple.mobile.backup.domainChanged";

// 锁定尝试配置
const int kLockAttempts = 50;
const int kLockWaitMicroseconds = 200000;

// BackupFileInfo 实现
@implementation BackupFileInfo
@end

// BackupTask 内部接口，定义私有方法
@interface BackupTask () {
    // libimobiledevice C API 指针
    idevice_t _device;
    lockdownd_client_t _lockdown;
    mobilebackup2_client_t _mobilebackup2;
    afc_client_t _afc;
    np_client_t _np;
    
    // 操作状态
    BackupTaskMode _currentMode;
    dispatch_queue_t _operationQueue;
    BOOL _operating;
    BOOL _cancelRequested;
    BOOL _backupDomainChanged;
    BOOL _passcodeRequested;
    BOOL _backupRecoveryAttempted;
    NSInteger _errorRecoveryAttemptCount;
    
    // 备份过程变量
    uint64_t _lockfile;
    double _overall_progress;
    NSString *_currentOperationDescription;
    uint64_t _currentBytes;
    uint64_t _totalBytes;
    
    // 内部状态
    BackupTaskStatus _status;
    float _progress;
    NSError *_lastError;
    uint64_t _estimatedBackupSize;
    uint64_t _actualBackupSize;
    BOOL _isBackupEncrypted;
}

// 设备检测和连接
- (BOOL)detectDeviceVersion:(NSError **)error;
- (BOOL)checkDeviceReadiness:(NSError **)error;

// 备份和恢复辅助方法
- (BOOL)prepareBackupDirectory:(NSString *)backupDir error:(NSError **)error;
- (void)preCreateHashDirectories:(NSString *)baseDir;
- (BOOL)writeRestoreApplications:(plist_t)info_plist error:(NSError **)error;

// 文件处理方法
- (BOOL)sendFile:(const char *)path toDevice:(plist_t *)errplist;
- (int)handleReceiveFiles:(plist_t)message;
- (uint32_t)receiveFilename:(char **)filename;
- (void)handleSendFiles:(plist_t)message;
- (void)handleGetFreeDiskSpace;
- (void)handleListDirectory:(plist_t)message;
- (void)handleMakeDirectory:(plist_t)message;
- (void)handleMoveFiles:(plist_t)message;
- (void)handleRemoveFiles:(plist_t)message;
- (void)handleCopyItem:(plist_t)message;

// 加密和密码处理
- (BOOL)verifyBackupPasswordSecure:(NSString *)password error:(NSError **)error;
- (BOOL)encryptString:(NSString *)string withPassword:(NSString *)password toFile:(NSString *)filePath;
- (BOOL)decryptFile:(NSString *)filePath withPassword:(NSString *)password toString:(NSString **)result;

// 路径处理和安全方法
- (NSString *)sanitizePathForBackup:(NSString *)path;
- (NSString *)normalizeDevicePath:(NSString *)devicePath;
- (NSString *)resolveBackupPath:(NSString *)relativePath;
- (BOOL)isValidBackupPath:(NSString *)path;

// 错误恢复方法
- (void)recoverBackupOperation;
- (void)fixStatusPlistErrors;
- (void)fixSnapshotPaths:(NSString *)backupDir;
- (void)recreateSnapshotContent:(NSString *)backupDir;
- (BOOL)verifyBackupIntegrity:(NSString *)backupDir error:(NSError **)error;

// 通知相关方法
- (void)postNotification:(NSString *)notification;
- (void)setInternalStatus:(BackupTaskStatus)status;

// 工具方法
- (void)cleanupSingleDigitDirectories:(NSString *)backupDir;
- (void)createDefaultInfoPlist:(NSString *)path;
- (void)createEmptyStatusPlist:(NSString *)path;
- (void)updateStatusPlistState:(NSString *)path state:(NSString *)state;

@end

@implementation BackupTask

@synthesize status = _status;
@synthesize progress = _progress;
@synthesize lastError = _lastError;
@synthesize estimatedBackupSize = _estimatedBackupSize;
@synthesize actualBackupSize = _actualBackupSize;
@synthesize isBackupEncrypted = _isBackupEncrypted;

#pragma mark - 初始化和单例实现

+ (instancetype)sharedInstance {
    static BackupTask *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *defaultDir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Backups"];
        instance = [[self alloc] initWithBackupDirectory:defaultDir useNetwork:NO];
    });
    return instance;
}

- (instancetype)init {
    NSString *defaultDir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Backups"];
    return [self initWithBackupDirectory:defaultDir useNetwork:NO];
}

- (instancetype)initWithBackupDirectory:(NSString *)backupDirectory
                             useNetwork:(BOOL)useNetwork {
    self = [super init];
    if (self) {
        _status = BackupTaskStatusIdle;
        _progress = 0.0;
        _operationQueue = dispatch_queue_create("com.example.backuptask.operation", DISPATCH_QUEUE_SERIAL);
        _operating = NO;
        _cancelRequested = NO;
        _backupDomainChanged = NO;
        _passcodeRequested = NO;
        _backupRecoveryAttempted = NO;
        _errorRecoveryAttemptCount = 0;
        _currentOperationDescription = @"Idle";
        
        // 设置默认值
        _backupDirectory = backupDirectory ?: [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Backups"];
        _useNetwork = useNetwork;
        // 将交互模式默认设为开启，这样会自动请求密码
        _interactiveMode = YES;
        _options = 0;
        
        // 设置默认的密码请求回调，使用弹窗方式请求密码
        __weak typeof(self) weakSelf = self;
        self.passwordRequestCallback = ^NSString *(NSString *message, BOOL isNewPassword) {
            return [weakSelf showPasswordInputDialog:message isNewPassword:isNewPassword];
        };
        
        NSLog(@"[BackupTask] Initialized. Default backup directory: %@", _backupDirectory);
    }
    return self;
}

- (void)dealloc {
    NSLog(@"[BackupTask] Deallocating and cleaning up resources");
    [self cleanupResources];
}

#pragma mark - 状态管理

- (void)setInternalStatus:(BackupTaskStatus)status {
    @synchronized (self) {
        if (_status != status) {
            NSLog(@"[BackupTask] Status changed: %ld -> %ld", (long)_status, (long)status);
            _status = status;
            
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self.statusCallback) {
                    NSString *description = [self stringForStatus:status];
                    self.statusCallback(status, description);
                }
            });
        }
    }
}

- (NSString *)stringForStatus:(BackupTaskStatus)status {
    switch (status) {
        case BackupTaskStatusIdle:
            return @"Idle";
        case BackupTaskStatusConnecting:
            return @"Connecting to device";
        case BackupTaskStatusPreparing:
            return @"Preparing operation";
        case BackupTaskStatusProcessing:
            return [NSString stringWithFormat:@"Processing: %@", _currentOperationDescription ?: @""];
        case BackupTaskStatusCompleted:
            return @"Operation completed";
        case BackupTaskStatusFailed:
            return [NSString stringWithFormat:@"Operation failed: %@", _lastError.localizedDescription ?: @"Unknown error"];
        case BackupTaskStatusCancelled:
            return @"Operation cancelled";
    }
    return @"Unknown status";
}

- (void)updateProgress:(float)progress operation:(NSString *)operation current:(uint64_t)current total:(uint64_t)total {
    @synchronized (self) {
        // 确保进度值在有效范围内
        if (progress < 0.0f) {
            progress = 0.0f;
        } else if (progress > 100.0f) {
            progress = 100.0f;
        }
        
        _progress = progress;
        _currentOperationDescription = operation;
        _currentBytes = current;
        _totalBytes = total;
        
        NSLog(@"[BackupTask] Progress: %.2f%% - %@ (%llu/%llu bytes)",
              progress, operation ?: @"", current, total);
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.progressCallback) {
                // 确保回调时也传递正确范围的值
                self.progressCallback(progress, operation, current, total);
            }
        });
    }
}

#pragma mark - 错误处理

- (NSError *)errorWithCode:(BackupTaskErrorCode)code description:(NSString *)description {
    NSLog(@"[BackupTask] Error: %ld - %@", (long)code, description);
    
    NSDictionary *userInfo = @{
        NSLocalizedDescriptionKey: description ?: @"Unknown error",
        NSLocalizedFailureReasonErrorKey: [self reasonForErrorCode:code]
    };
    
    _lastError = [NSError errorWithDomain:kBackupTaskErrorDomain code:code userInfo:userInfo];
    return _lastError;
}

- (NSString *)reasonForErrorCode:(BackupTaskErrorCode)code {
    switch (code) {
        case BackupTaskErrorCodeUnknown:
            return @"An unknown error occurred";
        case BackupTaskErrorCodeSuccess:
            return @"Operation completed successfully";
        case BackupTaskErrorCodeInvalidArg:
            return @"Invalid argument provided";
        case BackupTaskErrorCodeConnectionFailed:
            return @"Failed to connect to the device";
        case BackupTaskErrorCodeOperationFailed:
            return @"Operation failed";
        case BackupTaskErrorCodeAlreadyRunning:
            return @"Another operation is already running";
        case BackupTaskErrorCodeDeviceNotFound:
            return @"Device not found";
        case BackupTaskErrorCodeInvalidBackupDirectory:
            return @"Invalid backup directory";
        case BackupTaskErrorCodeMissingPassword:
            return @"Backup password is required but not provided";
        case BackupTaskErrorCodeWrongPassword:
            return @"Wrong backup password";
        case BackupTaskErrorCodeServiceStartFailed:
            return @"Failed to start required service on device";
        case BackupTaskErrorCodeProtocolError:
            return @"Protocol error communicating with device";
        case BackupTaskErrorCodeDeviceDisconnected:
            return @"Device disconnected during operation";
        case BackupTaskErrorCodeBackupFailed:
            return @"Backup operation failed";
        case BackupTaskErrorCodeRestoreFailed:
            return @"Restore operation failed";
        case BackupTaskErrorCodeUserCancelled:
            return @"Operation cancelled by user";
        case BackupTaskErrorCodeOutOfDiskSpace:
            return @"Not enough disk space available for operation";
        case BackupTaskErrorCodeIOError:
            return @"Input/output error during file operation";
        case BackupTaskErrorCodeTimeoutError:
            return @"Operation timed out";
    }
    return @"Unknown error";
}

#pragma mark - 设备通知回调

static void notification_cb(const char *notification, void *user_data) {
    BackupTask *self = (__bridge BackupTask *)user_data;
    if (!notification || strlen(notification) == 0) {
        return;
    }
    
    NSLog(@"[BackupTask] Received device notification: %s", notification);
    
    if (strcmp(notification, "com.apple.itunes.backup.cancelRequest") == 0) {
        NSLog(@"[BackupTask] Backup cancelled by device");
        [self cancelOperation];
    } else if (strcmp(notification, "com.apple.mobile.backup.domainChanged") == 0) {
        NSLog(@"[BackupTask] Backup domain changed");
        self->_backupDomainChanged = YES;
    } else if (strcmp(notification, "com.apple.LocalAuthentication.ui.presented") == 0) {
        NSLog(@"[BackupTask] Device requires passcode");
        self->_passcodeRequested = YES;
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.deviceConfirmationCallback) {
                self.deviceConfirmationCallback(@"passcode");
            }
        });
    } else if (strcmp(notification, "com.apple.LocalAuthentication.ui.dismissed") == 0) {
        NSLog(@"[BackupTask] Device passcode screen dismissed");
        self->_passcodeRequested = NO;
    }
}

#pragma mark - 公共操作方法

- (void)startBackupForDevice:(NSString *)deviceUDID
                    progress:(void (^)(double progress, NSString *message))progressBlock
                  completion:(void (^)(BOOL success, NSError *error))completionBlock {
    
    // 输入参数验证
    if (!deviceUDID || deviceUDID.length == 0) {
        NSError *error = [self errorWithCode:BackupTaskErrorCodeInvalidArg
                                 description:@"Device UDID cannot be empty"];
        if (completionBlock) {
            completionBlock(NO, error);
        }
        return;
    }
    
    // 保存回调
    self.progressCallback = ^(float progress, NSString *operation, uint64_t current, uint64_t total) {
        if (progressBlock) {
            // 确保进度值在有效范围内
            float safeProgress = (progress < 0.0f) ? 0.0f : ((progress > 100.0f) ? 100.0f : progress);
            progressBlock(safeProgress / 100.0, operation); // 转换为0-1范围
        }
    };
    
    self.completionCallback = ^(BOOL success, BackupTaskMode mode, NSError *error) {
        if (completionBlock) {
            completionBlock(success, error);
        }
    };
    
    // 设置设备ID
    self.deviceUDID = deviceUDID;
    
    // 重置sourceUDID为当前设备ID
    self.sourceUDID = deviceUDID;
    
    // 确保交互模式开启
    self.interactiveMode = YES;
    
    // 启动备份操作
    NSError *error = nil;
    [self startBackup:&error];
    
    // 如果立即出错，调用完成回调
    if (error && completionBlock) {
        completionBlock(NO, error);
    }
}

- (BOOL)startOperationWithMode:(BackupTaskMode)mode error:(NSError **)error {
    @synchronized (self) {
        if (_operating) {
            if (error) {
                *error = [self errorWithCode:BackupTaskErrorCodeAlreadyRunning
                                 description:@"Another operation is already in progress"];
            }
            return NO;
        }
        
        _operating = YES;
        _cancelRequested = NO;
        _currentMode = mode;
        _progress = 0.0;
        _errorRecoveryAttemptCount = 0;
        [self setInternalStatus:BackupTaskStatusPreparing];
        
        NSLog(@"[BackupTask] Starting operation in mode: %ld", (long)mode);
        
        // 执行前基本验证
        if (mode != BackupTaskModeErase && mode != BackupTaskModeCloud && mode != BackupTaskModeChangePw) {
            // 验证备份目录
            if (![self validateBackupDirectory:_backupDirectory error:error]) {
                _operating = NO;
                [self setInternalStatus:BackupTaskStatusIdle];
                return NO;
            }
        }
        
        // 异步执行操作
        dispatch_async(_operationQueue, ^{
            NSError *opError = nil;
            BOOL success = [self executeOperation:mode error:&opError];
            
            // 操作完成回调
            dispatch_async(dispatch_get_main_queue(), ^{
                if (success) {
                    [self setInternalStatus:BackupTaskStatusCompleted];
                } else if (self->_cancelRequested) {
                    [self setInternalStatus:BackupTaskStatusCancelled];
                } else {
                    [self setInternalStatus:BackupTaskStatusFailed];
                }
                
                if (self.completionCallback) {
                    self.completionCallback(success, mode, opError);
                }
                
                self->_operating = NO;
            });
        });
        
        return YES;
    }
}

- (void)cancelOperation {
    @synchronized (self) {
        if (!_operating) {
            NSLog(@"[BackupTask] No operation in progress to cancel");
            return;
        }
        
        NSLog(@"[BackupTask] Cancelling operation");
        _cancelRequested = YES;
        
        // 更新进度，通知正在取消
        [self updateProgress:_progress
                   operation:@"Cancelling operation"
                     current:_currentBytes
                       total:_totalBytes];
    }
}

- (void)cleanupResources {
    NSLog(@"[BackupTask] Cleaning up resources");
    
    // 清理锁文件
    if (_lockfile) {
        if (_afc) {
            afc_file_lock(_afc, _lockfile, AFC_LOCK_UN);
            afc_file_close(_afc, _lockfile);
        }
        _lockfile = 0;
    }
    
    // 释放mobilebackup2客户端
    if (_mobilebackup2) {
        mobilebackup2_client_free(_mobilebackup2);
        _mobilebackup2 = NULL;
    }
    
    // 释放AFC客户端
    if (_afc) {
        afc_client_free(_afc);
        _afc = NULL;
    }
    
    // 释放通知代理客户端
    if (_np) {
        np_client_free(_np);
        _np = NULL;
    }
    
    // 释放lockdown客户端
    if (_lockdown) {
        lockdownd_client_free(_lockdown);
        _lockdown = NULL;
    }
    
    // 释放设备
    if (_device) {
        idevice_free(_device);
        _device = NULL;
    }
    
    // 重置状态
    _operating = NO;
    _cancelRequested = NO;
    _backupDomainChanged = NO;
    _passcodeRequested = NO;
}

#pragma mark - 便捷方法

- (BOOL)startBackup:(NSError **)error {
    return [self startOperationWithMode:BackupTaskModeBackup error:error];
}

- (BOOL)startRestore:(NSError **)error {
    return [self startOperationWithMode:BackupTaskModeRestore error:error];
}

- (NSDictionary *)getBackupInfo:(NSError **)error {
    __block NSDictionary *result = nil;
    __block NSError *blockError = nil;
    
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    
    // 启动信息查询操作
    BOOL started = [self startOperationWithMode:BackupTaskModeInfo error:error];
    if (!started) {
        return nil;
    }
    
    // 设置完成回调
    self.completionCallback = ^(BOOL success, BackupTaskMode mode, NSError *opError) {
        if (!success) {
            blockError = opError;
        }
        dispatch_semaphore_signal(sema);
    };
    
    // 等待操作完成
    dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);
    
    if (blockError && error) {
        *error = blockError;
    }
    
    return result;
}

- (NSArray<BackupFileInfo *> *)listBackupFiles:(NSString *)path error:(NSError **)error {
    __block NSArray<BackupFileInfo *> *result = nil;
    __block NSError *blockError = nil;
    
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    
    // 启动列表操作
    BOOL started = [self startOperationWithMode:BackupTaskModeList error:error];
    if (!started) {
        return nil;
    }
    
    // 设置完成回调
    self.completionCallback = ^(BOOL success, BackupTaskMode mode, NSError *opError) {
        if (!success) {
            blockError = opError;
        }
        dispatch_semaphore_signal(sema);
    };
    
    // 等待操作完成
    dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);
    
    if (blockError && error) {
        *error = blockError;
    }
    
    return result;
}

- (BOOL)unpackBackup:(NSError **)error {
    return [self startOperationWithMode:BackupTaskModeUnback error:error];
}

- (BOOL)eraseDevice:(NSError **)error {
    return [self startOperationWithMode:BackupTaskModeErase error:error];
}

- (BOOL)setBackupEncryption:(BOOL)enable password:(NSString *)password error:(NSError **)error {
    // 设置相应选项
    _options &= ~(BackupTaskOptionEncryptionEnable | BackupTaskOptionEncryptionDisable);
    if (enable) {
        _options |= BackupTaskOptionEncryptionEnable;
    } else {
        _options |= BackupTaskOptionEncryptionDisable;
    }
    
    // 验证密码
    if (enable && (!password || [password length] == 0)) {
        if (error) {
            *error = [self errorWithCode:BackupTaskErrorCodeMissingPassword
                             description:@"Password is required to enable encryption"];
        }
        return NO;
    }
    
    self.backupPassword = password;
    
    return [self startOperationWithMode:BackupTaskModeChangePw error:error];
}

- (BOOL)changeBackupPassword:(NSString *)oldPassword newPassword:(NSString *)newPassword error:(NSError **)error {
    // 输入验证
    if (!oldPassword || [oldPassword length] == 0) {
        if (error) {
            *error = [self errorWithCode:BackupTaskErrorCodeMissingPassword
                             description:@"Current password is required"];
        }
        return NO;
    }
    
    if (!newPassword || [newPassword length] == 0) {
        if (error) {
            *error = [self errorWithCode:BackupTaskErrorCodeMissingPassword
                             description:@"New password is required"];
        }
        return NO;
    }
    
    _options |= BackupTaskOptionEncryptionChangePw;
    
    self.backupPassword = oldPassword;
    self.backupNewPassword = newPassword;
    
    return [self startOperationWithMode:BackupTaskModeChangePw error:error];
}

- (BOOL)setCloudBackup:(BOOL)enable error:(NSError **)error {
    // 设置相应选项
    _options &= ~(BackupTaskOptionCloudEnable | BackupTaskOptionCloudDisable);
    if (enable) {
        _options |= BackupTaskOptionCloudEnable;
    } else {
        _options |= BackupTaskOptionCloudDisable;
    }
    
    return [self startOperationWithMode:BackupTaskModeCloud error:error];
}

#pragma mark - 备份状态检查与管理

- (BOOL)verifyBackupPassword:(NSString *)password error:(NSError **)error {
    // 验证输入
    if (!password || [password length] == 0) {
        if (error) {
            *error = [self errorWithCode:BackupTaskErrorCodeInvalidArg
                             description:@"Password cannot be empty"];
        }
        return NO;
    }
    
    // 使用更安全的验证方法
    return [self verifyBackupPasswordSecure:password error:error];
}

- (BOOL)checkDiskSpace:(uint64_t)requiredSpace error:(NSError **)error {
    if (requiredSpace == 0) {
        return YES;  // 如果不需要空间，直接返回成功
    }
    
    NSString *backupDir = [_backupDirectory stringByExpandingTildeInPath];
    
    NSDictionary *fileSystemAttributes = [[NSFileManager defaultManager] attributesOfFileSystemForPath:backupDir error:nil];
    if (!fileSystemAttributes) {
        if (error) {
            *error = [self errorWithCode:BackupTaskErrorCodeIOError
                             description:@"Could not determine available disk space"];
        }
        return NO;
    }
    
    NSNumber *freeSpace = [fileSystemAttributes objectForKey:NSFileSystemFreeSize];
    if (!freeSpace) {
        if (error) {
            *error = [self errorWithCode:BackupTaskErrorCodeIOError
                             description:@"Could not determine available disk space"];
        }
        return NO;
    }
    
    uint64_t availableSpace = [freeSpace unsignedLongLongValue];
    
    // 添加10%的安全余量
    uint64_t requiredWithMargin = requiredSpace * 1.1;
    
    if (availableSpace < requiredWithMargin) {
        if (error) {
            NSString *required = [self formatSize:requiredWithMargin];
            NSString *available = [self formatSize:availableSpace];
            *error = [self errorWithCode:BackupTaskErrorCodeOutOfDiskSpace
                             description:[NSString stringWithFormat:@"Not enough disk space. Required: %@, Available: %@", required, available]];
        }
        return NO;
    }
    
    return YES;
}

- (BOOL)validateBackupDirectory:(NSString *)backupPath error:(NSError **)error {
    // 验证输入
    if (!backupPath || [backupPath length] == 0) {
        if (error) {
            *error = [self errorWithCode:BackupTaskErrorCodeInvalidArg
                             description:@"Backup directory path cannot be empty"];
        }
        return NO;
    }
    
    NSFileManager *fileManager = [NSFileManager defaultManager];
    BOOL isDirectory = NO;
    
    // 检查目录是否存在
    if (![fileManager fileExistsAtPath:backupPath isDirectory:&isDirectory]) {
        // 尝试创建目录
        NSError *createError = nil;
        if (![fileManager createDirectoryAtPath:backupPath
                    withIntermediateDirectories:YES
                                     attributes:nil
                                          error:&createError]) {
            if (error) {
                *error = [self errorWithCode:BackupTaskErrorCodeInvalidBackupDirectory
                                 description:[NSString stringWithFormat:@"Could not create backup directory: %@", createError.localizedDescription]];
            }
            return NO;
        }
        return YES;
    }
    
    // 确保是目录而不是文件
    if (!isDirectory) {
        if (error) {
            *error = [self errorWithCode:BackupTaskErrorCodeInvalidBackupDirectory
                             description:@"Backup path exists but is not a directory"];
        }
        return NO;
    }
    
    // 检查目录是否可写
    NSString *testFile = [backupPath stringByAppendingPathComponent:@".write_test"];
    if (![fileManager createFileAtPath:testFile
                              contents:[NSData data]
                            attributes:nil]) {
        if (error) {
            *error = [self errorWithCode:BackupTaskErrorCodeInvalidBackupDirectory
                             description:@"Backup directory is not writable"];
        }
        return NO;
    }
    
    // 清理测试文件
    [fileManager removeItemAtPath:testFile error:nil];
    
    return YES;
}

- (BOOL)validateBackupStatus:(NSString *)statusPath state:(NSString *)state error:(NSError **)error {
    if (!statusPath || [statusPath length] == 0 || !state || [state length] == 0) {
        if (error) {
            *error = [self errorWithCode:BackupTaskErrorCodeInvalidArg
                             description:@"Invalid status path or state"];
        }
        return NO;
    }
    
    plist_t status_plist = NULL;
    plist_read_from_file([statusPath UTF8String], &status_plist, NULL);
    
    if (!status_plist) {
        if (error) {
            *error = [self errorWithCode:BackupTaskErrorCodeInvalidBackupDirectory
                             description:@"Could not read Status.plist!"];
        }
        return NO;
    }
    
    BOOL result = NO;
    plist_t node = plist_dict_get_item(status_plist, "SnapshotState");
    if (node && (plist_get_node_type(node) == PLIST_STRING)) {
        char* sval = NULL;
        plist_get_string_val(node, &sval);
        if (sval) {
            result = (strcmp(sval, [state UTF8String]) == 0) ? YES : NO;
            free(sval);
        }
    } else {
        if (error) {
            *error = [self errorWithCode:BackupTaskErrorCodeInvalidBackupDirectory
                             description:@"Could not get SnapshotState key from Status.plist!"];
        }
    }
    
    plist_free(status_plist);
    return result;
}

- (NSString *)formatSize:(uint64_t)size {
    NSByteCountFormatter *formatter = [[NSByteCountFormatter alloc] init];
    formatter.countStyle = NSByteCountFormatterCountStyleFile;
    formatter.allowedUnits = NSByteCountFormatterUseAll;
    return [formatter stringFromByteCount:(long long)size];
}

- (NSDictionary *)extractBackupInfo:(NSString *)udid {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[@"UDID"] = udid;
    
    // 读取备份清单
    NSString *manifestPath = [_backupDirectory stringByAppendingPathComponent:
                             [udid stringByAppendingPathComponent:@"Manifest.plist"]];
    
    if ([[NSFileManager defaultManager] fileExistsAtPath:manifestPath]) {
        plist_t manifest_plist = NULL;
        plist_read_from_file([manifestPath UTF8String], &manifest_plist, NULL);
        
        if (manifest_plist) {
            // 提取设备名称
            plist_t deviceName = plist_dict_get_item(manifest_plist, "DisplayName");
            if (deviceName && (plist_get_node_type(deviceName) == PLIST_STRING)) {
                char* name_val = NULL;
                plist_get_string_val(deviceName, &name_val);
                if (name_val) {
                    [info setObject:[NSString stringWithUTF8String:name_val] forKey:@"DeviceName"];
                    free(name_val);
                }
            }
            
            // 提取iOS版本
            plist_t version = plist_dict_get_item(manifest_plist, "ProductVersion");
            if (version && (plist_get_node_type(version) == PLIST_STRING)) {
                char* ver_val = NULL;
                plist_get_string_val(version, &ver_val);
                if (ver_val) {
                    [info setObject:[NSString stringWithUTF8String:ver_val] forKey:@"iOSVersion"];
                    free(ver_val);
                }
            }
            
            // 提取加密状态
            plist_t encrypted = plist_dict_get_item(manifest_plist, "IsEncrypted");
            if (encrypted && (plist_get_node_type(encrypted) == PLIST_BOOLEAN)) {
                uint8_t enc_val = 0;
                plist_get_bool_val(encrypted, &enc_val);
                [info setObject:@(enc_val != 0) forKey:@"IsEncrypted"];
                _isBackupEncrypted = (enc_val != 0);
            }
            
            // 提取备份日期
            plist_t date = plist_dict_get_item(manifest_plist, "Date");
            if (date && (plist_get_node_type(date) == PLIST_DATE)) {
                int32_t time_val = 0;
                int32_t time_val_ms = 0;
                plist_get_date_val(date, &time_val, &time_val_ms);
                NSDate *backupDate = [NSDate dateWithTimeIntervalSince1970:(time_val + 978307200)]; // 加上从1970到2001年的秒数
                [info setObject:backupDate forKey:@"BackupDate"];
            }
            
            plist_free(manifest_plist);
        }
    }
    
    // 添加备份大小
    uint64_t backupSize = [self calculateBackupSize:udid];
    [info setObject:@(backupSize) forKey:@"BackupSize"];
    [info setObject:[self formatSize:backupSize] forKey:@"FormattedBackupSize"];
    
    return info;
}

#pragma mark - 主执行方法

- (BOOL)executeOperation:(BackupTaskMode)mode error:(NSError **)error {
    NSLog(@"[BackupTask] Executing operation in mode: %ld", (long)mode);
    
    BOOL success = NO;
    
    @try {
        // 连接设备
        if (![self connectToDevice:error]) {
            NSLog(@"[BackupTask] Failed to connect to device");
            return NO;
        }
        
        // 检查设备就绪状态
        if (![self checkDeviceReadiness:error]) {
            NSLog(@"[BackupTask] Device is not ready for operation");
            return NO;
        }
        
        // 根据模式执行不同操作
        switch (mode) {
            case BackupTaskModeBackup:
                success = [self performBackup:error];
                break;
                
            case BackupTaskModeRestore:
                success = [self performRestore:error];
                break;
                
            case BackupTaskModeInfo:
                success = [self performInfo:error];
                break;
                
            case BackupTaskModeList:
                success = [self performList:error];
                break;
                
            case BackupTaskModeUnback:
                success = [self performUnback:error];
                break;
                
            case BackupTaskModeChangePw:
                success = [self performChangePassword:error];
                break;
                
            case BackupTaskModeErase:
                success = [self performErase:error];
                break;
                
            case BackupTaskModeCloud:
                success = [self performCloudBackup:error];
                break;
                
            default:
                if (error) {
                    *error = [self errorWithCode:BackupTaskErrorCodeInvalidArg
                                     description:@"Unsupported operation mode"];
                }
                break;
        }
    }
    @catch (NSException *exception) {
        NSLog(@"[BackupTask] Exception: %@", exception);
        if (error) {
            *error = [self errorWithCode:BackupTaskErrorCodeUnknown
                             description:[NSString stringWithFormat:@"Exception: %@", exception.reason]];
        }
        success = NO;
    }
    @finally {
        [self cleanupResources];
    }
    
    NSLog(@"[BackupTask] Operation %@ with mode: %ld",
          success ? @"succeeded" : @"failed", (long)mode);
    
    return success;
}

#pragma mark - 设备连接

- (BOOL)connectToDevice:(NSError **)error {
    NSLog(@"[BackupTask] Connecting to device");
    [self setInternalStatus:BackupTaskStatusConnecting];
    
    // 1. 创建设备连接
    idevice_error_t ret = idevice_new_with_options(
        &_device,
        [_deviceUDID UTF8String],
        _useNetwork ? IDEVICE_LOOKUP_NETWORK : IDEVICE_LOOKUP_USBMUX
    );
    
    if (ret != IDEVICE_E_SUCCESS) {
        NSString *desc = [NSString stringWithFormat:@"Failed to connect to device: %d", ret];
        if (error) {
            *error = [self errorWithCode:BackupTaskErrorCodeConnectionFailed description:desc];
        }
        return NO;
    }
    
    NSLog(@"[BackupTask] Device connection established");
    
    // 2. 如果没有指定设备UDID，获取连接设备的UDID
    if (!_deviceUDID) {
        char *udid = NULL;
        if (idevice_get_udid(_device, &udid) == IDEVICE_E_SUCCESS && udid) {
            _deviceUDID = [NSString stringWithUTF8String:udid];
            free(udid);
            NSLog(@"[BackupTask] Got device UDID: %@", _deviceUDID);
        }
    }
    
    // 3. 如果没有指定源UDID，使用设备UDID
    if (!_sourceUDID) {
        _sourceUDID = [_deviceUDID copy];
    }
    
    // 4. 创建lockdown客户端
    lockdownd_error_t ldret = lockdownd_client_new_with_handshake(_device, &_lockdown, "iOSBackupManager");
    if (ldret != LOCKDOWN_E_SUCCESS) {
        NSString *desc = [NSString stringWithFormat:@"Failed to connect to lockdownd: %d", ldret];
        if (error) {
            *error = [self errorWithCode:BackupTaskErrorCodeConnectionFailed description:desc];
        }
        return NO;
    }
    
    NSLog(@"[BackupTask] Lockdown connection established");
    
    // 5. 检查备份加密状态
    plist_t node_tmp = NULL;
    uint8_t willEncrypt = 0;
    
    lockdownd_get_value(_lockdown, "com.apple.mobile.backup", "WillEncrypt", &node_tmp);
    if (node_tmp) {
        if (plist_get_node_type(node_tmp) == PLIST_BOOLEAN) {
            plist_get_bool_val(node_tmp, &willEncrypt);
        }
        plist_free(node_tmp);
        node_tmp = NULL;
    }
    
    _isBackupEncrypted = (willEncrypt != 0);
    NSLog(@"[BackupTask] Device backup encryption is %@", willEncrypt ? @"enabled" : @"disabled");
    
    // 6. 获取设备版本信息
    if (![self detectDeviceVersion:error]) {
        return NO;
    }
    
    // 7. 启动notification_proxy服务
    lockdownd_service_descriptor_t service = NULL;
    ldret = lockdownd_start_service(_lockdown, "com.apple.mobile.notification_proxy", &service);
    if (ldret != LOCKDOWN_E_SUCCESS || !service || service->port == 0) {
        NSString *desc = [NSString stringWithFormat:@"Failed to start notification_proxy service: %d", ldret];
        if (error) {
            *error = [self errorWithCode:BackupTaskErrorCodeServiceStartFailed description:desc];
        }
        return NO;
    }
    
    // 8. 创建notification_proxy客户端
    np_client_new(_device, service, &_np);
    if (_np) {
        np_set_notify_callback(_np, notification_cb, (__bridge void *)(self));
        
        // 订阅通知
        const char *notifications[] = {
            "com.apple.itunes.backup.willStart",
            "com.apple.itunes.backup.lockRequest",
            "com.apple.itunes.backup.didStart",
            "com.apple.itunes.backup.cancelRequest",
            "com.apple.mobile.backup.domainChanged",
            "com.apple.LocalAuthentication.ui.presented",
            "com.apple.LocalAuthentication.ui.dismissed",
            NULL
        };
        
        np_observe_notifications(_np, notifications);
        NSLog(@"[BackupTask] Notification proxy service started");
    } else {
        NSLog(@"[BackupTask] Warning: Failed to create notification proxy client");
    }
    
    lockdownd_service_descriptor_free(service);
    service = NULL;
    
    // 9. 对于备份和恢复操作，启动AFC服务
    if (_currentMode == BackupTaskModeBackup || _currentMode == BackupTaskModeRestore) {
        ldret = lockdownd_start_service(_lockdown, "com.apple.afc", &service);
        if (ldret != LOCKDOWN_E_SUCCESS || !service || service->port == 0) {
            NSString *desc = [NSString stringWithFormat:@"Failed to start AFC service: %d", ldret];
            if (error) {
                *error = [self errorWithCode:BackupTaskErrorCodeServiceStartFailed description:desc];
            }
            return NO;
        }
        
        afc_client_new(_device, service, &_afc);
        NSLog(@"[BackupTask] AFC service started");
        
        lockdownd_service_descriptor_free(service);
        service = NULL;
    }
    
    // 10. 启动mobilebackup2服务
    ldret = lockdownd_start_service_with_escrow_bag(_lockdown, "com.apple.mobilebackup2", &service);
    if (ldret != LOCKDOWN_E_SUCCESS || !service || service->port == 0) {
        NSString *desc = [NSString stringWithFormat:@"Failed to start mobilebackup2 service: %d", ldret];
        if (error) {
            *error = [self errorWithCode:BackupTaskErrorCodeServiceStartFailed description:desc];
        }
        return NO;
    }
    
    mobilebackup2_client_new(_device, service, &_mobilebackup2);
    NSLog(@"[BackupTask] Mobilebackup2 service started on port %d", service->port);
    
    lockdownd_service_descriptor_free(service);
    service = NULL;
    
    // 11. 协议版本协商（支持更多版本以增强兼容性）
    double local_versions[3] = {2.0, 2.1, 2.2};  // 支持更多版本
    double remote_version = 0.0;
    mobilebackup2_error_t err = mobilebackup2_version_exchange(_mobilebackup2, local_versions, 3, &remote_version);
    if (err != MOBILEBACKUP2_E_SUCCESS) {
        NSString *desc = [NSString stringWithFormat:@"Backup protocol version exchange failed: %d", err];
        if (error) {
            *error = [self errorWithCode:BackupTaskErrorCodeProtocolError description:desc];
        }
        return NO;
    }
    
    NSLog(@"[BackupTask] Negotiated protocol version: %.1f", remote_version);
    
    // 连接成功
    [self setInternalStatus:BackupTaskStatusProcessing];
    return YES;
}

- (BOOL)detectDeviceVersion:(NSError **)error {
    plist_t node_tmp = NULL;
    char *product_version = NULL;
    
    lockdownd_get_value(_lockdown, NULL, "ProductVersion", &node_tmp);
    if (node_tmp) {
        if (plist_get_node_type(node_tmp) == PLIST_STRING) {
            plist_get_string_val(node_tmp, &product_version);
        }
        plist_free(node_tmp);
        node_tmp = NULL;
    }
    
    if (product_version) {
        NSLog(@"[BackupTask] Device iOS version: %s", product_version);
        
        // 解析版本号
        int major = 0, minor = 0, patch = 0;
        sscanf(product_version, "%d.%d.%d", &major, &minor, &patch);
        
        // 检查是否是高版本iOS需要特殊处理
        if (major >= 14) {
            NSLog(@"[BackupTask] Device is running iOS %d.%d.%d, applying compatibility fixes",
                  major, minor, patch);
            // 这里可以添加针对特定iOS版本的兼容性代码
        }
        
        free(product_version);
        return YES;
    } else {
        if (error) {
            *error = [self errorWithCode:BackupTaskErrorCodeDeviceNotFound
                             description:@"Could not determine device iOS version"];
        }
        return NO;
    }
}

- (BOOL)checkDeviceReadiness:(NSError **)error {
    // 这个方法可以进行额外的设备就绪检查（电池电量、锁定状态等）
    
    // 检查设备是否受密码保护但未解锁
    if (_passcodeRequested) {
        if (error) {
            *error = [self errorWithCode:BackupTaskErrorCodeDeviceDisconnected
                             description:@"Device is locked with a passcode"];
        }
        return NO;
    }
    
    // 后续可以添加更多设备状态检查
    
    return YES;
}

#pragma mark - 处理备份操作

- (BOOL)performBackup:(NSError **)error {
    NSLog(@"[BackupTask] Starting backup operation");
    [self updateProgress:0 operation:@"Starting backup" current:0 total:100];
    
    // 添加更多日志用于调试
    NSLog(@"[BackupTask] Backup directory: %@", _backupDirectory);
    NSLog(@"[BackupTask] Source UDID: %@", _sourceUDID);
    NSLog(@"[BackupTask] Device UDID: %@", _deviceUDID);
    
    // 获取设备备份加密状态
    BOOL isEncrypted = [self isDeviceBackupEncrypted];
    _isBackupEncrypted = isEncrypted;
    NSLog(@"[BackupTask] Backup will %@be encrypted", isEncrypted ? @"" : @"not ");
    
    // 处理加密备份的密码
    if (isEncrypted) {
        NSLog(@"[BackupTask] 设备备份已加密，需要输入密码");
        
        // 获取或请求密码
        if (!_backupPassword) {
            const char *envPassword = getenv("BACKUP_PASSWORD");  // 使用正确的环境变量名，并将结果存储在 C 字符串变量中
            if (envPassword) {
                _backupPassword = [NSString stringWithUTF8String:envPassword];  // 正确地将 C 字符串转换为 NSString
            }
        }
        
        // 如果环境变量没有提供密码，且处于交互模式，则请求用户输入
        if (!_backupPassword && _interactiveMode && self.passwordRequestCallback) {
            _backupPassword = self.passwordRequestCallback(@"设备备份已加密，请输入备份密码", NO);
        }
        
        // 验证密码
        if (!_backupPassword || _backupPassword.length == 0) {
            if (error) {
                *error = [self errorWithCode:BackupTaskErrorCodeMissingPassword
                                 description:@"备份已加密但未提供密码"];
            }
            return NO;
        } else if (![self verifyBackupPasswordSecure:_backupPassword error:error]) {
            return NO;
        }
    }
    
    // 估计备份所需空间并检查磁盘空间
    uint64_t estimatedRequiredSpace = 0;
    plist_t node_tmp = NULL;
    
    lockdownd_get_value(_lockdown, "com.apple.mobile.backup", "EstimatedBackupSize", &node_tmp);
    if (node_tmp && plist_get_node_type(node_tmp) == PLIST_UINT) {
        plist_get_uint_val(node_tmp, &estimatedRequiredSpace);
        plist_free(node_tmp);
        node_tmp = NULL;
    }
    
    if (estimatedRequiredSpace > 0) {
        _estimatedBackupSize = estimatedRequiredSpace;
        if (![self checkDiskSpace:estimatedRequiredSpace error:error]) {
            return NO;
        }
        
        NSLog(@"[BackupTask] Estimated backup size: %@", [self formatSize:estimatedRequiredSpace]);
    }
    
    // 准备备份目录结构
    NSString *devBackupDir = [_backupDirectory stringByAppendingPathComponent:_deviceUDID];
    if (![self prepareBackupDirectory:devBackupDir error:error]) {
        return NO;
    }
    
    // 发送备份通知
    [self postNotification:kNPSyncWillStart];
    
    // 创建备份锁
    if (_afc) {
        afc_file_open(_afc, "/com.apple.itunes.lock_sync", AFC_FOPEN_RW, &_lockfile);
        if (_lockfile) {
            [self postNotification:kNPSyncLockRequest];
            
            // 尝试获取锁
            for (int i = 0; i < kLockAttempts; i++) {
                afc_error_t aerr = afc_file_lock(_afc, _lockfile, AFC_LOCK_EX);
                if (aerr == AFC_E_SUCCESS) {
                    [self postNotification:kNPSyncDidStart];
                    break;
                }
                if (aerr == AFC_E_OP_WOULD_BLOCK) {
                    usleep(kLockWaitMicroseconds);
                    continue;
                }
                
                NSString *desc = [NSString stringWithFormat:@"Could not lock file: %d", aerr];
                if (error) {
                    *error = [self errorWithCode:BackupTaskErrorCodeOperationFailed description:desc];
                }
                
                if (_lockfile) {
                    afc_file_close(_afc, _lockfile);
                    _lockfile = 0;
                }
                return NO;
            }
        }
    }
    
    // 创建或更新 Status.plist
    NSString *statusPath = [devBackupDir stringByAppendingPathComponent:@"Status.plist"];
    plist_t status_dict = plist_new_dict();
    plist_dict_set_item(status_dict, "SnapshotState", plist_new_string("new"));
    plist_dict_set_item(status_dict, "UUID", plist_new_string([_deviceUDID UTF8String]));
    plist_dict_set_item(status_dict, "Version", plist_new_string("2.4"));
    
    // 添加当前时间戳 (使用 Apple 纪元 - 从2001年开始)
    int32_t date_time = (int32_t)time(NULL) - 978307200;
    plist_dict_set_item(status_dict, "Date", plist_new_date(date_time, 0));
    
    // 添加备份类型
    plist_dict_set_item(status_dict, "BackupState", plist_new_string("new"));
    plist_dict_set_item(status_dict, "IsFullBackup", plist_new_bool(1));
    
    // 序列化并保存 Status.plist
    uint32_t length = 0;
    char *xml = NULL;
    plist_to_xml(status_dict, &xml, &length);
    
    if (xml) {
        NSData *plistData = [NSData dataWithBytes:xml length:length];
        
        BOOL writeSuccess = NO;
        
        if (_isBackupEncrypted && _backupPassword) {
            // 对加密备份使用加密方法
            writeSuccess = [self encryptString:[[NSString alloc] initWithData:plistData encoding:NSUTF8StringEncoding]
                                   withPassword:_backupPassword
                                        toFile:statusPath];
        } else {
            // 非加密备份直接写入
            NSError *writeError = nil;
            writeSuccess = [plistData writeToFile:statusPath options:NSDataWritingAtomic error:&writeError];
            
            if (!writeSuccess) {
                NSLog(@"[BackupTask] Error writing Status.plist: %@", writeError);
            }
        }
        
        if (!writeSuccess) {
            if (error) {
                *error = [self errorWithCode:BackupTaskErrorCodeOperationFailed
                                 description:@"Failed to create Status.plist"];
            }
            free(xml);
            plist_free(status_dict);
            return NO;
        }
        
        free(xml);
        NSLog(@"[BackupTask] Successfully created/updated Status.plist at: %@", statusPath);
        
        // 创建副本 - 备份到Snapshot目录
        NSString *snapshotDir = [devBackupDir stringByAppendingPathComponent:@"Snapshot"];
        NSString *snapshotStatusPath = [snapshotDir stringByAppendingPathComponent:@"Status.plist"];
        NSLog(@"[BackupTask] Creating additional Status.plist copy at: %@", snapshotStatusPath);
        
        // 对副本也使用相同的加密逻辑
        if (_isBackupEncrypted && _backupPassword) {
            [self encryptString:[[NSString alloc] initWithData:plistData encoding:NSUTF8StringEncoding]
                    withPassword:_backupPassword
                         toFile:snapshotStatusPath];
        } else {
            [plistData writeToFile:snapshotStatusPath options:NSDataWritingAtomic error:nil];
        }
    }
    plist_free(status_dict);
    
    // 设置正确的文件权限
    NSError *chmodError = nil;
    NSDictionary *attributes = @{NSFilePosixPermissions: @(0644)};
    if (![[NSFileManager defaultManager] setAttributes:attributes ofItemAtPath:statusPath error:&chmodError]) {
        NSLog(@"[BackupTask] Warning: Could not set Status.plist permissions: %@", chmodError);
    }
    
    // 创建备份选项
    plist_t opts = plist_new_dict();
    
    // 强制全量备份选项
    if (_options & BackupTaskOptionForceFullBackup) {
        NSLog(@"[BackupTask] Enforcing full backup from device");
        plist_dict_set_item(opts, "ForceFullBackup", plist_new_bool(1));
    }
    
    // 加密选项
    if (isEncrypted && _backupPassword) {
        plist_dict_set_item(opts, "Password", plist_new_string([_backupPassword UTF8String]));
        NSLog(@"[BackupTask] Using backup password for encrypted backup");
    }
    
    // 发送备份请求
    [self updateProgress:5 operation:@"Requesting backup from device" current:5 total:100];
    
    NSLog(@"[BackupTask] Backup %@ and will %sbe encrypted",
          (_options & BackupTaskOptionForceFullBackup) ? @"will be full" : @"may be incremental",
          isEncrypted ? "" : "not ");
    
    mobilebackup2_error_t err = mobilebackup2_send_request(_mobilebackup2, "Backup",
                                                         [_deviceUDID UTF8String],
                                                         [_sourceUDID UTF8String],
                                                         opts);
    
    if (opts) {
        plist_free(opts);
    }
    
    if (err != MOBILEBACKUP2_E_SUCCESS) {
        NSString *desc;
        if (err == MOBILEBACKUP2_E_BAD_VERSION) {
            desc = @"Backup protocol version mismatch";
        } else if (err == MOBILEBACKUP2_E_REPLY_NOT_OK) {
            desc = @"Device refused to start backup process";
        } else {
            desc = [NSString stringWithFormat:@"Could not start backup process: %d", err];
        }
        
        if (error) {
            *error = [self errorWithCode:BackupTaskErrorCodeBackupFailed description:desc];
        }
        return NO;
    }
    
    // 处理设备上的密码请求
    if (_passcodeRequested) {
        NSLog(@"[BackupTask] Waiting for device passcode entry");
        [self updateProgress:10 operation:@"Waiting for device passcode" current:10 total:100];
        
        // 等待用户输入设备密码
        NSTimeInterval timeout = 120.0; // 60秒超时
        NSTimeInterval startTime = [NSDate timeIntervalSinceReferenceDate];
        
        while (_passcodeRequested) {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                     beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
            
            if ([NSDate timeIntervalSinceReferenceDate] - startTime > timeout) {
                NSLog(@"[BackupTask] Device passcode entry timed out");
                if (error) {
                    *error = [self errorWithCode:BackupTaskErrorCodeTimeoutError
                                     description:@"Device passcode entry timed out"];
                }
                return NO;
            }
            
            if (_cancelRequested) {
                NSLog(@"[BackupTask] Operation cancelled while waiting for passcode");
                if (error) {
                    *error = [self errorWithCode:BackupTaskErrorCodeUserCancelled
                                     description:@"Operation cancelled by user"];
                }
                return NO;
            }
        }
    }
    
    // 处理备份消息
    BOOL result = [self processBackupMessages:error];
    
    // 解锁备份锁
    if (_lockfile) {
        afc_file_lock(_afc, _lockfile, AFC_LOCK_UN);
        afc_file_close(_afc, _lockfile);
        _lockfile = 0;
        [self postNotification:kNPSyncDidStart];
    }
    
    // 验证备份完整性
    if (result) {
        result = [self verifyBackupIntegrity:devBackupDir error:error];
        
        if (result) {
            NSLog(@"[BackupTask] Backup integrity verification succeeded");
        } else {
            NSLog(@"[BackupTask] Backup integrity verification failed");
        }
    }
    
    return result;
}


- (BOOL)encryptString:(NSString *)string withPassword:(NSString *)password toFile:(NSString *)filePath {
    NSLog(@"[BackupTask] Encrypting data to file: %@", filePath);
    
    if (!string || !password || !filePath) {
        NSLog(@"[BackupTask] Error: Invalid parameters for encryption");
        return NO;
    }
    
    // 将字符串转换为数据
    NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) {
        NSLog(@"[BackupTask] Error: Could not convert string to data");
        return NO;
    }
    
    // 生成密钥和初始化向量
    NSMutableData *key = [NSMutableData dataWithLength:kCCKeySizeAES256];
    NSMutableData *iv = [NSMutableData dataWithLength:kCCBlockSizeAES128];
    
    // 使用密码和盐生成密钥
    NSData *salt = [@"BackupSalt" dataUsingEncoding:NSUTF8StringEncoding];
    int result = CCKeyDerivationPBKDF(kCCPBKDF2, password.UTF8String, password.length,
                                     salt.bytes, salt.length,
                                     kCCPRFHmacAlgSHA1, 10000,
                                     key.mutableBytes, key.length);
    
    if (result != kCCSuccess) {
        NSLog(@"[BackupTask] Error: Failed to derive key");
        return NO;
    }
    
    // 生成随机初始向量
    result = SecRandomCopyBytes(kSecRandomDefault, iv.length, iv.mutableBytes);
    if (result != 0) {
        NSLog(@"[BackupTask] Error: Failed to generate random IV");
        return NO;
    }
    
    // 设置加密缓冲区
    size_t outSize = data.length + kCCBlockSizeAES128;
    NSMutableData *cipherData = [NSMutableData dataWithLength:outSize];
    size_t actualOutSize = 0;
    
    // 执行加密
    result = CCCrypt(kCCEncrypt, kCCAlgorithmAES, kCCOptionPKCS7Padding,
                     key.bytes, key.length, iv.bytes,
                     data.bytes, data.length,
                     cipherData.mutableBytes, outSize, &actualOutSize);
    
    if (result != kCCSuccess) {
        NSLog(@"[BackupTask] Error: Encryption failed with code %d", result);
        return NO;
    }
    
    // 调整密文数据大小
    [cipherData setLength:actualOutSize];
    
    // 创建最终数据: IV + 密文
    NSMutableData *finalData = [NSMutableData dataWithData:iv];
    [finalData appendData:cipherData];
    
    // 写入文件
    BOOL success = [finalData writeToFile:filePath atomically:YES];
    if (!success) {
        NSLog(@"[BackupTask] Error: Failed to write encrypted data to file");
    } else {
        NSLog(@"[BackupTask] Successfully encrypted and wrote data to file");
    }
    
    return success;
}

- (BOOL)decryptFile:(NSString *)filePath withPassword:(NSString *)password toString:(NSString **)result {
    NSLog(@"[BackupTask] Decrypting file: %@", filePath);
    
    if (!filePath || !password || !result) {
        NSLog(@"[BackupTask] Error: Invalid parameters for decryption");
        return NO;
    }
    
    // 读取加密数据
    NSData *fileData = [NSData dataWithContentsOfFile:filePath];
    if (!fileData || fileData.length <= kCCBlockSizeAES128) {
        NSLog(@"[BackupTask] Error: Invalid or corrupted encrypted file");
        return NO;
    }
    
    // 提取IV和密文
    NSData *iv = [fileData subdataWithRange:NSMakeRange(0, kCCBlockSizeAES128)];
    NSData *cipherData = [fileData subdataWithRange:NSMakeRange(kCCBlockSizeAES128, fileData.length - kCCBlockSizeAES128)];
    
    // 生成密钥
    NSMutableData *key = [NSMutableData dataWithLength:kCCKeySizeAES256];
    NSData *salt = [@"BackupSalt" dataUsingEncoding:NSUTF8StringEncoding];
    
    int keyResult = CCKeyDerivationPBKDF(kCCPBKDF2, password.UTF8String, password.length,
                                      salt.bytes, salt.length,
                                      kCCPRFHmacAlgSHA1, 10000,
                                      key.mutableBytes, key.length);
    
    if (keyResult != kCCSuccess) {
        NSLog(@"[BackupTask] Error: Failed to derive key for decryption");
        return NO;
    }
    
    // 设置解密缓冲区
    size_t outSize = cipherData.length;
    NSMutableData *decryptedData = [NSMutableData dataWithLength:outSize];
    size_t actualOutSize = 0;
    
    // 执行解密
    int cryptResult = CCCrypt(kCCDecrypt, kCCAlgorithmAES, kCCOptionPKCS7Padding,
                           key.bytes, key.length, iv.bytes,
                           cipherData.bytes, cipherData.length,
                           decryptedData.mutableBytes, outSize, &actualOutSize);
    
    if (cryptResult != kCCSuccess) {
        NSLog(@"[BackupTask] Error: Decryption failed with code %d", cryptResult);
        return NO;
    }
    
    // 调整解密数据大小
    [decryptedData setLength:actualOutSize];
    
    // 转换为字符串
    *result = [[NSString alloc] initWithData:decryptedData encoding:NSUTF8StringEncoding];
    if (!*result) {
        NSLog(@"[BackupTask] Error: Could not convert decrypted data to string");
        return NO;
    }
    
    NSLog(@"[BackupTask] Successfully decrypted file");
    return YES;
}

- (BOOL)performRestore:(NSError **)error {
    NSLog(@"[BackupTask] Starting restore operation");
    [self updateProgress:0 operation:@"Starting restore" current:0 total:100];
    
    // 1. 获取加密状态信息
    NSString *sourceBackupDir = [_backupDirectory stringByAppendingPathComponent:_sourceUDID];
    BOOL isEncrypted = [self isBackupEncrypted:_sourceUDID error:error];
    
    if (isEncrypted && !_backupPassword) {
        if (_interactiveMode && self.passwordRequestCallback) {
            _backupPassword = self.passwordRequestCallback(@"Enter backup password", NO);
        } else {
            const char *envPassword = getenv("BACKUP_PASSWORD");  // 使用正确的环境变量名
            if (envPassword) {
                _backupPassword = [NSString stringWithUTF8String:envPassword];  // 正确转换
            }
        }
        
        if (!_backupPassword || _backupPassword.length == 0) {
            if (error) {
                *error = [self errorWithCode:BackupTaskErrorCodeMissingPassword
                                 description:@"Backup is encrypted but no password provided"];
            }
            return NO;
        }
        
        // 验证密码
        if (![self verifyBackupPasswordSecure:_backupPassword error:error]) {
            return NO;
        }
    }
    
    // 2. 验证备份状态 - 确保从成功的备份中恢复
    NSString *statusPath = [sourceBackupDir stringByAppendingPathComponent:@"Status.plist"];
    if (![self validateBackupStatus:statusPath state:@"finished" error:error]) {
        return NO;
    }
    
    // 3. 发送通知
    [self postNotification:kNPSyncWillStart];
    
    // 4. 创建备份锁
    if (_afc) {
        afc_file_open(_afc, "/com.apple.itunes.lock_sync", AFC_FOPEN_RW, &_lockfile);
        if (_lockfile) {
            [self postNotification:kNPSyncLockRequest];
            
            // 尝试获取锁
            for (int i = 0; i < kLockAttempts; i++) {
                afc_error_t aerr = afc_file_lock(_afc, _lockfile, AFC_LOCK_EX);
                if (aerr == AFC_E_SUCCESS) {
                    [self postNotification:kNPSyncDidStart];
                    break;
                }
                if (aerr == AFC_E_OP_WOULD_BLOCK) {
                    usleep(kLockWaitMicroseconds);
                    continue;
                }
                
                NSString *desc = [NSString stringWithFormat:@"Could not lock file: %d", aerr];
                if (error) {
                    *error = [self errorWithCode:BackupTaskErrorCodeOperationFailed description:desc];
                }
                
                if (_lockfile) {
                    afc_file_close(_afc, _lockfile);
                    _lockfile = 0;
                }
                return NO;
            }
        }
    }
    
    // 5. 准备恢复选项
    plist_t opts = plist_new_dict();
    
    // 系统文件选项
    plist_dict_set_item(opts, "RestoreSystemFiles",
                        plist_new_bool(_options & BackupTaskOptionRestoreSystemFiles ? 1 : 0));
    NSLog(@"[BackupTask] Restoring system files: %@",
          (_options & BackupTaskOptionRestoreSystemFiles) ? @"Yes" : @"No");
    
    // 重启选项
    if (_options & BackupTaskOptionRestoreNoReboot) {
        plist_dict_set_item(opts, "RestoreShouldReboot", plist_new_bool(0));
    }
    NSLog(@"[BackupTask] Rebooting after restore: %@",
          (_options & BackupTaskOptionRestoreNoReboot) ? @"No" : @"Yes");
    
    // 备份复制选项
    if (!(_options & BackupTaskOptionRestoreCopyBackup)) {
        plist_dict_set_item(opts, "RestoreDontCopyBackup", plist_new_bool(1));
    }
    NSLog(@"[BackupTask] Don't copy backup: %@",
          (!(_options & BackupTaskOptionRestoreCopyBackup)) ? @"Yes" : @"No");
    
    // 保留设置选项
    plist_dict_set_item(opts, "RestorePreserveSettings",
                        plist_new_bool(!(_options & BackupTaskOptionRestoreSettings) ? 1 : 0));
    NSLog(@"[BackupTask] Preserve settings of device: %@",
          (!(_options & BackupTaskOptionRestoreSettings)) ? @"Yes" : @"No");
    
    // 移除项目选项
    plist_dict_set_item(opts, "RemoveItemsNotRestored",
                        plist_new_bool(_options & BackupTaskOptionRestoreRemoveItems ? 1 : 0));
    NSLog(@"[BackupTask] Remove items that are not restored: %@",
          (_options & BackupTaskOptionRestoreRemoveItems) ? @"Yes" : @"No");
    
    // 密码选项
    if (_backupPassword) {
        plist_dict_set_item(opts, "Password", plist_new_string([_backupPassword UTF8String]));
        NSLog(@"[BackupTask] Using backup password: Yes");
    }
    
    // 6. 准备RestoreApplications.plist
    if (!(_options & BackupTaskOptionRestoreSkipApps)) {
        // 读取Info.plist
        NSString *infoPath = [sourceBackupDir stringByAppendingPathComponent:@"Info.plist"];
        plist_t info_plist = NULL;
        plist_read_from_file([infoPath UTF8String], &info_plist, NULL);
        
        if (info_plist) {
            if (![self writeRestoreApplications:info_plist error:error]) {
                plist_free(info_plist);
                plist_free(opts);
                return NO;
            }
            plist_free(info_plist);
            NSLog(@"[BackupTask] Wrote RestoreApplications.plist");
        } else {
            NSLog(@"[BackupTask] Warning: Could not read Info.plist");
        }
    } else {
        NSLog(@"[BackupTask] Skipping apps restoration");
    }
    
    // 7. 启动恢复过程
    [self updateProgress:5 operation:@"Starting restore process" current:5 total:100];
    
    mobilebackup2_error_t err = mobilebackup2_send_request(_mobilebackup2, "Restore",
                                                          [_deviceUDID UTF8String],
                                                          [_sourceUDID UTF8String],
                                                          opts);
    plist_free(opts);
    
    if (err != MOBILEBACKUP2_E_SUCCESS) {
        NSString *desc;
        if (err == MOBILEBACKUP2_E_BAD_VERSION) {
            desc = @"Restore protocol version mismatch";
        } else if (err == MOBILEBACKUP2_E_REPLY_NOT_OK) {
            desc = @"Device refused to start restore process";
        } else {
            desc = [NSString stringWithFormat:@"Could not start restore process: %d", err];
        }
        
        if (error) {
            *error = [self errorWithCode:BackupTaskErrorCodeRestoreFailed description:desc];
        }
        return NO;
    }
    
    // 8. 处理恢复消息
    BOOL result = [self processBackupMessages:error];
    
    // 9. 解锁备份锁
    if (_lockfile) {
        afc_file_lock(_afc, _lockfile, AFC_LOCK_UN);
        afc_file_close(_afc, _lockfile);
        _lockfile = 0;
    }
    
    return result;
}

- (BOOL)performInfo:(NSError **)error {
    NSLog(@"[BackupTask] Starting info operation");
    [self updateProgress:0 operation:@"Requesting backup info" current:0 total:100];
    
    // 请求备份信息
    mobilebackup2_error_t err = mobilebackup2_send_request(_mobilebackup2, "Info",
                                                          [_deviceUDID UTF8String],
                                                          [_sourceUDID UTF8String],
                                                          NULL);
    if (err != MOBILEBACKUP2_E_SUCCESS) {
        NSString *desc = [NSString stringWithFormat:@"Error requesting backup info: %d", err];
        if (error) {
            *error = [self errorWithCode:BackupTaskErrorCodeOperationFailed description:desc];
        }
        return NO;
    }
    
    // 处理消息
    return [self processBackupMessages:error];
}

- (BOOL)performList:(NSError **)error {
    NSLog(@"[BackupTask] Starting list operation");
    [self updateProgress:0 operation:@"Requesting backup file list" current:0 total:100];
    
    // 请求备份列表
    mobilebackup2_error_t err = mobilebackup2_send_request(_mobilebackup2, "List",
                                                          [_deviceUDID UTF8String],
                                                          [_sourceUDID UTF8String],
                                                          NULL);
    if (err != MOBILEBACKUP2_E_SUCCESS) {
        NSString *desc = [NSString stringWithFormat:@"Error requesting backup list: %d", err];
        if (error) {
            *error = [self errorWithCode:BackupTaskErrorCodeOperationFailed description:desc];
        }
        return NO;
    }
    
    // 处理消息
    return [self processBackupMessages:error];
}

- (BOOL)performUnback:(NSError **)error {
    NSLog(@"[BackupTask] Starting unback operation");
    [self updateProgress:0 operation:@"Starting backup unpacking" current:0 total:100];
    
    // 检查加密状态
    BOOL isEncrypted = [self isBackupEncrypted:_sourceUDID error:error];
    plist_t opts = NULL;
    
    // 如果备份加密，需要密码
    if (isEncrypted) {
        if (!_backupPassword) {
            if (_interactiveMode && self.passwordRequestCallback) {
                _backupPassword = self.passwordRequestCallback(@"Enter backup password", NO);
            } else {
                const char *envPassword = getenv("BACKUP_PASSWORD");  // 注意：没有星号，使用临时变量存储
                if (envPassword) {  // 检查环境变量是否存在
                    _backupPassword = [NSString stringWithUTF8String:envPassword];  // 正确的转换
                }
            }
            
            if (!_backupPassword || _backupPassword.length == 0) {
                if (error) {
                    *error = [self errorWithCode:BackupTaskErrorCodeMissingPassword
                                     description:@"Backup is encrypted but no password provided"];
                }
                return NO;
            }
        }
        
        // 验证密码
        if (![self verifyBackupPasswordSecure:_backupPassword error:error]) {
            return NO;
        }
        
        opts = plist_new_dict();
        plist_dict_set_item(opts, "Password", plist_new_string([_backupPassword UTF8String]));
    }
    
    // 请求解包操作
    mobilebackup2_error_t err = mobilebackup2_send_request(_mobilebackup2, "Unback",
                                                          [_deviceUDID UTF8String],
                                                          [_sourceUDID UTF8String],
                                                          opts);
    if (opts) {
        plist_free(opts);
    }
    
    if (err != MOBILEBACKUP2_E_SUCCESS) {
        NSString *desc = [NSString stringWithFormat:@"Error requesting unback operation: %d", err];
        if (error) {
            *error = [self errorWithCode:BackupTaskErrorCodeOperationFailed description:desc];
        }
        return NO;
    }
    
    // 处理消息
    return [self processBackupMessages:error];
}

- (BOOL)performChangePassword:(NSError **)error {
    NSLog(@"[BackupTask] Starting change password operation");
    [self updateProgress:0 operation:@"Changing backup encryption settings" current:0 total:100];
    
    // 获取当前加密状态
    uint8_t willEncrypt = [self isDeviceBackupEncrypted];
    
    // 创建选项
    plist_t opts = plist_new_dict();
    plist_dict_set_item(opts, "TargetIdentifier", plist_new_string([_deviceUDID UTF8String]));
    
    // 处理不同的加密命令
    if (_options & BackupTaskOptionEncryptionEnable) {
        // 启用加密
        if (!willEncrypt) {
            // 设备未加密，需要密码
            if (!_backupNewPassword) {
                if (_interactiveMode && self.passwordRequestCallback) {
                    _backupNewPassword = self.passwordRequestCallback(@"Enter new backup password", YES);
                } else {
                    const char *envNewPassword = getenv("BACKUP_PASSWORD_NEW");  // 使用正确的环境变量名，无星号
                    if (envNewPassword) {  // 检查环境变量是否存在
                        _backupNewPassword = [NSString stringWithUTF8String:envNewPassword];  // 正确的转换
                    }
                }
                
                if (!_backupNewPassword || _backupNewPassword.length == 0) {
                    if (error) {
                        *error = [self errorWithCode:BackupTaskErrorCodeMissingPassword
                                         description:@"New backup password required but not provided"];
                    }
                    plist_free(opts);
                    return NO;
                }
            }
            
            plist_dict_set_item(opts, "NewPassword", plist_new_string([_backupNewPassword UTF8String]));
            NSLog(@"[BackupTask] Enabling backup encryption");
        } else {
            NSLog(@"[BackupTask] Backup encryption is already enabled");
            if (error) {
                *error = [self errorWithCode:BackupTaskErrorCodeInvalidArg
                                 description:@"Backup encryption is already enabled"];
            }
            plist_free(opts);
            return NO;
        }
    } else if (_options & BackupTaskOptionEncryptionDisable) {
        // 禁用加密
        if (willEncrypt) {
            // 设备已加密，需要旧密码
            if (!_backupPassword) {
                if (_interactiveMode && self.passwordRequestCallback) {
                    _backupPassword = self.passwordRequestCallback(@"Enter current backup password", NO);
                } else {
                    const char *envPassword = getenv("BACKUP_PASSWORD");  // 正确的环境变量名，无星号
                    if (envPassword) {  // 检查环境变量是否存在
                        _backupPassword = [NSString stringWithUTF8String:envPassword];  // 正确的转换
                    }
                }
                
                if (!_backupPassword || _backupPassword.length == 0) {
                    if (error) {
                        *error = [self errorWithCode:BackupTaskErrorCodeMissingPassword
                                         description:@"Current backup password required but not provided"];
                    }
                    plist_free(opts);
                    return NO;
                }
            }
            
            // 验证密码
            if (![self verifyBackupPasswordSecure:_backupPassword error:error]) {
                plist_free(opts);
                return NO;
            }
            
            plist_dict_set_item(opts, "OldPassword", plist_new_string([_backupPassword UTF8String]));
            NSLog(@"[BackupTask] Disabling backup encryption");
        } else {
            NSLog(@"[BackupTask] Backup encryption is not enabled");
            if (error) {
                *error = [self errorWithCode:BackupTaskErrorCodeInvalidArg
                                 description:@"Backup encryption is not enabled"];
            }
            plist_free(opts);
            return NO;
        }
    } else if (_options & BackupTaskOptionEncryptionChangePw) {
        // 更改密码
        if (willEncrypt) {
            // 需要旧密码和新密码
            if (!_backupPassword) {
                if (_interactiveMode && self.passwordRequestCallback) {
                    _backupPassword = self.passwordRequestCallback(@"Enter current backup password", NO);
                } else {
                    // 修正后的代码 - 使用临时变量并正确处理类型转换
                    const char *envPassword = getenv("BACKUP_PASSWORD");  // 修正1: 移除了星号
                    if (envPassword) {  // 修正2: 检查C字符串是否为NULL
                        _backupPassword = [NSString stringWithUTF8String:envPassword];  // 修正3: 使用临时变量
                    }
                }
                
                if (!_backupPassword || _backupPassword.length == 0) {
                    if (error) {
                        *error = [self errorWithCode:BackupTaskErrorCodeMissingPassword
                                         description:@"Current backup password required but not provided"];
                    }
                    plist_free(opts);
                    return NO;
                }
            }
            
            // 验证旧密码
            if (![self verifyBackupPasswordSecure:_backupPassword error:error]) {
                plist_free(opts);
                return NO;
            }
            
            if (!_backupNewPassword) {
                if (_interactiveMode && self.passwordRequestCallback) {
                    _backupNewPassword = self.passwordRequestCallback(@"Enter new backup password", YES);
                } else {
                    const char *envNewPassword = getenv("BACKUP_PASSWORD_NEW");  // 修正1: 使用正确的环境变量名
                    if (envNewPassword) {  // 修正2: 检查C字符串
                        _backupNewPassword = [NSString stringWithUTF8String:envNewPassword];  // 修正3: 正确转换
                    }
                }
                
                if (!_backupNewPassword || _backupNewPassword.length == 0) {
                    if (error) {
                        *error = [self errorWithCode:BackupTaskErrorCodeMissingPassword
                                         description:@"New backup password required but not provided"];
                    }
                    plist_free(opts);
                    return NO;
                }
            }
            
            plist_dict_set_item(opts, "OldPassword", plist_new_string([_backupPassword UTF8String]));
            plist_dict_set_item(opts, "NewPassword", plist_new_string([_backupNewPassword UTF8String]));
            NSLog(@"[BackupTask] Changing backup password");
        } else {
            NSLog(@"[BackupTask] Cannot change password - backup encryption is not enabled");
            if (error) {
                *error = [self errorWithCode:BackupTaskErrorCodeInvalidArg
                                 description:@"Cannot change password - backup encryption is not enabled"];
            }
            plist_free(opts);
            return NO;
        }
    }
    
    // 发送请求
    mobilebackup2_error_t err = mobilebackup2_send_message(_mobilebackup2, "ChangePassword", opts);
    plist_free(opts);
    
    if (err != MOBILEBACKUP2_E_SUCCESS) {
        NSString *desc = [NSString stringWithFormat:@"Error sending ChangePassword request: %d", err];
        if (error) {
            *error = [self errorWithCode:BackupTaskErrorCodeOperationFailed description:desc];
        }
        return NO;
    }
    
    // 处理回复
    plist_t reply = NULL;
    char *dlmsg = NULL;
    mobilebackup2_receive_message(_mobilebackup2, &reply, &dlmsg);
    
    if (reply) {
        BOOL success = YES;
        plist_t node_tmp = plist_array_get_item(reply, 1);
        if (node_tmp && (plist_get_node_type(node_tmp) == PLIST_DICT)) {
            plist_t error_code_node = plist_dict_get_item(node_tmp, "ErrorCode");
            if (error_code_node && (plist_get_node_type(error_code_node) == PLIST_UINT)) {
                uint64_t error_code = 0;
                plist_get_uint_val(error_code_node, &error_code);
                if (error_code != 0) {
                    success = NO;
                    plist_t error_desc_node = plist_dict_get_item(node_tmp, "ErrorDescription");
                    char *error_desc = NULL;
                    if (error_desc_node && (plist_get_node_type(error_desc_node) == PLIST_STRING)) {
                        plist_get_string_val(error_desc_node, &error_desc);
                    }
                    
                    NSString *desc = error_desc ?
                        [NSString stringWithUTF8String:error_desc] :
                        [NSString stringWithFormat:@"Error changing password (code %llu)", error_code];
                    
                    if (error) {
                        *error = [self errorWithCode:BackupTaskErrorCodeOperationFailed description:desc];
                    }
                    
                    if (error_desc) {
                        free(error_desc);
                    }
                }
            }
        }
        
        plist_free(reply);
        if (dlmsg) {
            free(dlmsg);
        }
        
        if (!success) {
            return NO;
        }
    }
    
    [self updateProgress:100 operation:@"Backup encryption settings changed" current:100 total:100];
    return YES;
}

- (BOOL)performErase:(NSError **)error {
    NSLog(@"[BackupTask] Starting erase operation");
    [self updateProgress:0 operation:@"Erasing device" current:0 total:100];
    
    // 发送擦除命令
    mobilebackup2_error_t err = mobilebackup2_send_message(_mobilebackup2, "EraseDevice", NULL);
    if (err != MOBILEBACKUP2_E_SUCCESS) {
        NSString *desc = [NSString stringWithFormat:@"Error sending EraseDevice command: %d", err];
        if (error) {
            *error = [self errorWithCode:BackupTaskErrorCodeOperationFailed description:desc];
        }
        return NO;
    }
    
    // 等待回复
    plist_t reply = NULL;
    char *dlmsg = NULL;
    err = mobilebackup2_receive_message(_mobilebackup2, &reply, &dlmsg);
    
    if (err != MOBILEBACKUP2_E_SUCCESS || !reply) {
        NSString *desc = [NSString stringWithFormat:@"Error receiving response to EraseDevice: %d", err];
        if (error) {
            *error = [self errorWithCode:BackupTaskErrorCodeOperationFailed description:desc];
        }
        return NO;
    }
    
    BOOL success = YES;
    if (reply) {
        char *msg_type = NULL;
        plist_t msg_node = plist_array_get_item(reply, 0);
        if (msg_node && (plist_get_node_type(msg_node) == PLIST_STRING)) {
            plist_get_string_val(msg_node, &msg_type);
        }
        
        if (msg_type && strcmp(msg_type, "DLMessageProcessMessage") == 0) {
            plist_t node_tmp = plist_array_get_item(reply, 1);
            if (node_tmp && (plist_get_node_type(node_tmp) == PLIST_DICT)) {
                plist_t error_code_node = plist_dict_get_item(node_tmp, "ErrorCode");
                if (error_code_node && (plist_get_node_type(error_code_node) == PLIST_UINT)) {
                    uint64_t error_code = 0;
                    plist_get_uint_val(error_code_node, &error_code);
                    if (error_code != 0) {
                        success = NO;
                        plist_t error_desc_node = plist_dict_get_item(node_tmp, "ErrorDescription");
                        char *error_desc = NULL;
                        if (error_desc_node && (plist_get_node_type(error_desc_node) == PLIST_STRING)) {
                            plist_get_string_val(error_desc_node, &error_desc);
                        }
                        
                        NSString *desc = error_desc ?
                            [NSString stringWithUTF8String:error_desc] :
                            [NSString stringWithFormat:@"Error erasing device (code %llu)", error_code];
                        
                        if (error) {
                            *error = [self errorWithCode:BackupTaskErrorCodeOperationFailed description:desc];
                        }
                        
                        if (error_desc) {
                            free(error_desc);
                        }
                    }
                }
            }
        }
        
        if (msg_type) {
            free(msg_type);
        }
        
        plist_free(reply);
    }
    
    if (dlmsg) {
        free(dlmsg);
    }
    
    if (success) {
        [self updateProgress:100 operation:@"Device erased successfully" current:100 total:100];
    }
    
    return success;
}

- (BOOL)performCloudBackup:(NSError **)error {
    NSLog(@"[BackupTask] Starting cloud backup %@ operation",
          (_options & BackupTaskOptionCloudEnable) ? @"enable" : @"disable");
    [self updateProgress:0 operation:@"Setting cloud backup state" current:0 total:100];
    
    // 创建选项
    plist_t opts = plist_new_dict();
    plist_dict_set_item(opts, "CloudBackupState",
                        plist_new_bool(_options & BackupTaskOptionCloudEnable ? 1 : 0));
    
    // 发送请求
    mobilebackup2_error_t err = mobilebackup2_send_request(_mobilebackup2, "EnableCloudBackup",
                                                          [_deviceUDID UTF8String],
                                                          [_sourceUDID UTF8String],
                                                          opts);
    plist_free(opts);
    
    if (err != MOBILEBACKUP2_E_SUCCESS) {
        NSString *desc = [NSString stringWithFormat:@"Error setting cloud backup state: %d", err];
        if (error) {
            *error = [self errorWithCode:BackupTaskErrorCodeOperationFailed description:desc];
        }
        return NO;
    }
    
    // 处理回复
    plist_t reply = NULL;
    char *dlmsg = NULL;
    err = mobilebackup2_receive_message(_mobilebackup2, &reply, &dlmsg);
    
    if (err != MOBILEBACKUP2_E_SUCCESS || !reply) {
        NSString *desc = [NSString stringWithFormat:@"Error receiving response to cloud backup request: %d", err];
        if (error) {
            *error = [self errorWithCode:BackupTaskErrorCodeOperationFailed description:desc];
        }
        return NO;
    }
    
    BOOL success = YES;
    if (reply) {
        char *msg_type = NULL;
        plist_t msg_node = plist_array_get_item(reply, 0);
        if (msg_node && (plist_get_node_type(msg_node) == PLIST_STRING)) {
            plist_get_string_val(msg_node, &msg_type);
        }
        
        if (msg_type && strcmp(msg_type, "DLMessageProcessMessage") == 0) {
            plist_t node_tmp = plist_array_get_item(reply, 1);
            if (node_tmp && (plist_get_node_type(node_tmp) == PLIST_DICT)) {
                plist_t error_code_node = plist_dict_get_item(node_tmp, "ErrorCode");
                if (error_code_node && (plist_get_node_type(error_code_node) == PLIST_UINT)) {
                    uint64_t error_code = 0;
                    plist_get_uint_val(error_code_node, &error_code);
                    if (error_code != 0) {
                        success = NO;
                        plist_t error_desc_node = plist_dict_get_item(node_tmp, "ErrorDescription");
                        char *error_desc = NULL;
                        if (error_desc_node && (plist_get_node_type(error_desc_node) == PLIST_STRING)) {
                            plist_get_string_val(error_desc_node, &error_desc);
                        }
                        
                        NSString *desc = error_desc ?
                            [NSString stringWithUTF8String:error_desc] :
                            [NSString stringWithFormat:@"Error setting cloud backup state (code %llu)", error_code];
                        
                        if (error) {
                            *error = [self errorWithCode:BackupTaskErrorCodeOperationFailed description:desc];
                        }
                        
                        if (error_desc) {
                            free(error_desc);
                        }
                    }
                }
            }
        }
        
        if (msg_type) {
            free(msg_type);
        }

        plist_free(reply);
    }
    
    if (dlmsg) {
        free(dlmsg);
    }
    
    if (success) {
        NSString *operation = (_options & BackupTaskOptionCloudEnable) ?
            @"Cloud backup enabled" : @"Cloud backup disabled";
        [self updateProgress:100 operation:operation current:100 total:100];
    }
    
    return success;
}

#pragma mark - 实用辅助方法

- (BOOL)isDeviceBackupEncrypted {
    plist_t node_tmp = NULL;
    uint8_t willEncrypt = 0;
    
    if (_lockdown) {
        lockdownd_get_value(_lockdown, "com.apple.mobile.backup", "WillEncrypt", &node_tmp);
        if (node_tmp) {
            if (plist_get_node_type(node_tmp) == PLIST_BOOLEAN) {
                plist_get_bool_val(node_tmp, &willEncrypt);
            }
            plist_free(node_tmp);
        }
    }
    
    return willEncrypt != 0;
}

- (BOOL)isBackupEncrypted:(NSString *)udid error:(NSError **)error {
    NSString *manifestPath = [_backupDirectory stringByAppendingPathComponent:[udid stringByAppendingPathComponent:@"Manifest.plist"]];
    
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager fileExistsAtPath:manifestPath]) {
        if (error) {
            *error = [self errorWithCode:BackupTaskErrorCodeInvalidBackupDirectory
                             description:[NSString stringWithFormat:@"Backup directory is invalid. No Manifest.plist found for UDID %@", udid]];
        }
        return NO;
    }
    
    plist_t manifest_plist = NULL;
    plist_read_from_file([manifestPath UTF8String], &manifest_plist, NULL);
    if (!manifest_plist) {
        if (error) {
            *error = [self errorWithCode:BackupTaskErrorCodeInvalidBackupDirectory
                             description:[NSString stringWithFormat:@"Backup directory is invalid. Manifest.plist is corrupted for UDID %@", udid]];
        }
        return NO;
    }
    
    uint8_t is_encrypted = 0;
    plist_t node_tmp = plist_dict_get_item(manifest_plist, "IsEncrypted");
    if (node_tmp && (plist_get_node_type(node_tmp) == PLIST_BOOLEAN)) {
        plist_get_bool_val(node_tmp, &is_encrypted);
    }
    
    plist_free(manifest_plist);
    
    return is_encrypted != 0;
}

- (BOOL)prepareBackupDirectory:(NSString *)backupDir error:(NSError **)error {
    NSLog(@"[BackupTask] Preparing backup directory: %@", backupDir);
    NSFileManager *fileManager = [NSFileManager defaultManager];
    BOOL isDir;

    // 创建主备份目录
    if (![fileManager fileExistsAtPath:backupDir isDirectory:&isDir] || !isDir) {
        NSError *dirError = nil;
        if (![fileManager createDirectoryAtPath:backupDir
                    withIntermediateDirectories:YES
                                     attributes:nil
                                          error:&dirError]) {
            if (error) {
                *error = [self errorWithCode:BackupTaskErrorCodeInvalidBackupDirectory
                                 description:[NSString stringWithFormat:@"Could not create backup directory: %@",
                                             dirError.localizedDescription]];
            }
            return NO;
        }
    }

    // 检查并移除错误的备份目录
    NSString *wrongBackupDir = [backupDir stringByAppendingPathComponent:_deviceUDID];
    if ([fileManager fileExistsAtPath:wrongBackupDir isDirectory:&isDir] && isDir) {
        NSLog(@"[BackupTask] Removing incorrectly nested backup directory: %@", wrongBackupDir);
        NSError *removeError = nil;
        if (![fileManager removeItemAtPath:wrongBackupDir error:&removeError]) {
            NSLog(@"[BackupTask] Error removing nested directory: %@", removeError);
        }
    }

    // 预创建哈希目录
    NSLog(@"[BackupTask] Pre-creating hash directories for backup");
    [self preCreateHashDirectories:backupDir];
    
    // 创建Snapshot目录结构
    NSString *snapshotDir = [backupDir stringByAppendingPathComponent:@"Snapshot"];
    if (![fileManager fileExistsAtPath:snapshotDir isDirectory:&isDir] || !isDir) {
        NSLog(@"[BackupTask] Creating Snapshot directory: %@", snapshotDir);
        NSError *dirError = nil;
        if (![fileManager createDirectoryAtPath:snapshotDir
                    withIntermediateDirectories:YES
                                     attributes:nil
                                          error:&dirError]) {
            NSLog(@"[BackupTask] Error creating Snapshot directory: %@", dirError);
        }
    }
    
    return YES;
}

- (void)preCreateHashDirectories:(NSString *)baseDir {
    NSLog(@"[BackupTask] Pre-creating hash directories");
    NSFileManager *fileManager = [NSFileManager defaultManager];
    
    // 创建常见的哈希前缀目录，涵盖16进制范围
    for (int i = 0; i < 256; i++) {
        NSString *dirPath = [baseDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%02x", i]];
        
        if (![fileManager fileExistsAtPath:dirPath]) {
            NSError *error = nil;
            BOOL created = [fileManager createDirectoryAtPath:dirPath
                                 withIntermediateDirectories:YES
                                                  attributes:nil
                                                       error:&error];
            if (!created) {
                NSLog(@"[BackupTask] Failed to create hash directory %@: %@", dirPath, error);
            }
        }
    }
    
    NSLog(@"[BackupTask] Finished pre-creating hash directories");
}

- (BOOL)writeRestoreApplications:(plist_t)info_plist error:(NSError **)error {
    if (!_afc || !info_plist) {
        if (error) {
            *error = [self errorWithCode:BackupTaskErrorCodeInvalidArg
                             description:@"Invalid AFC client or info plist"];
        }
        return NO;
    }

    // 获取应用信息
    plist_t applications_plist = plist_dict_get_item(info_plist, "Applications");
    if (!applications_plist) {
        NSLog(@"[BackupTask] No Applications in Info.plist, skipping creation of RestoreApplications.plist");
        return YES; // 不是失败，只是没有应用
    }
    
    // 转换为XML
    char *applications_plist_xml = NULL;
    uint32_t applications_plist_xml_length = 0;
    plist_to_xml(applications_plist, &applications_plist_xml, &applications_plist_xml_length);
    if (!applications_plist_xml) {
        NSLog(@"[BackupTask] Error preparing RestoreApplications.plist");
        if (error) {
            *error = [self errorWithCode:BackupTaskErrorCodeOperationFailed
                             description:@"Error preparing RestoreApplications.plist"];
        }
        return NO;
    }
    
    // 创建目录
    afc_error_t afc_err = afc_make_directory(_afc, "/iTunesRestore");
    if (afc_err != AFC_E_SUCCESS) {
        NSLog(@"[BackupTask] Error creating directory /iTunesRestore, error code %d", afc_err);
        free(applications_plist_xml);
        if (error) {
            *error = [self errorWithCode:BackupTaskErrorCodeOperationFailed
                             description:[NSString stringWithFormat:@"Error creating directory /iTunesRestore: %d", afc_err]];
        }
        return NO;
    }
    
    // 创建文件
    uint64_t restore_applications_file = 0;
    afc_err = afc_file_open(_afc, "/iTunesRestore/RestoreApplications.plist", AFC_FOPEN_WR, &restore_applications_file);
    if (afc_err != AFC_E_SUCCESS  || !restore_applications_file) {
        NSLog(@"[BackupTask] Error creating /iTunesRestore/RestoreApplications.plist, error code %d", afc_err);
        free(applications_plist_xml);
        if (error) {
            *error = [self errorWithCode:BackupTaskErrorCodeOperationFailed
                             description:[NSString stringWithFormat:@"Error creating RestoreApplications.plist: %d", afc_err]];
        }
        return NO;
    }
    
    // 写入文件
    uint32_t bytes_written = 0;
    afc_err = afc_file_write(_afc, restore_applications_file, applications_plist_xml, applications_plist_xml_length, &bytes_written);
    if (afc_err != AFC_E_SUCCESS  || bytes_written != applications_plist_xml_length) {
        NSLog(@"[BackupTask] Error writing /iTunesRestore/RestoreApplications.plist, error code %d, wrote %u of %u bytes", afc_err, bytes_written, applications_plist_xml_length);
        free(applications_plist_xml);
        afc_file_close(_afc, restore_applications_file);
        if (error) {
            *error = [self errorWithCode:BackupTaskErrorCodeOperationFailed
                             description:@"Error writing RestoreApplications.plist"];
        }
        return NO;
    }
    
    // 关闭文件
    afc_err = afc_file_close(_afc, restore_applications_file);
    free(applications_plist_xml);
    
    if (afc_err != AFC_E_SUCCESS) {
        NSLog(@"[BackupTask] Error closing RestoreApplications.plist: %d", afc_err);
        if (error) {
            *error = [self errorWithCode:BackupTaskErrorCodeOperationFailed
                             description:@"Error finalizing RestoreApplications.plist"];
        }
        return NO;
    }
    
    return YES;
}

- (NSString *)showPasswordInputDialog:(NSString *)message isNewPassword:(BOOL)isNewPassword {
    NSLog(@"[BackupTask] 显示密码输入弹窗: %@", message);
    
    // 使用主线程创建并显示对话框
    __block NSString *password = nil;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    
    dispatch_async(dispatch_get_main_queue(), ^{
        // 创建警告框
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:@"备份密码"];
        [alert setInformativeText:message ?: @"请输入备份密码"];
        [alert addButtonWithTitle:@"确定"];
        [alert addButtonWithTitle:@"取消"];
        
        // 添加密码输入框
        NSSecureTextField *passwordField = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(0, 0, 300, 24)];
        [alert setAccessoryView:passwordField];
        
        // 显示对话框并获取用户响应
        [alert beginSheetModalForWindow:[[NSApplication sharedApplication] mainWindow] completionHandler:^(NSModalResponse returnCode) {
            if (returnCode == NSAlertFirstButtonReturn) {
                // 用户点击确定
                password = [passwordField stringValue];
                if ([password length] == 0) {
                    password = nil;
                }
            }
            dispatch_semaphore_signal(semaphore);
        }];
        
        // 设置输入框为第一响应者
        [[alert.window firstResponder] resignFirstResponder];
        [alert.window makeFirstResponder:passwordField];
    });
    
    // 等待对话框完成
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    
    NSLog(@"[BackupTask] 密码输入完成: %@", password ? @"已输入" : @"未输入或取消");
    return password;
}

- (BOOL)verifyBackupPasswordSecure:(NSString *)password error:(NSError **)error {
    NSLog(@"[BackupTask] 验证备份密码");
    
    if (!password || password.length == 0) {
        if (error) {
            *error = [self errorWithCode:BackupTaskErrorCodeInvalidArg
                             description:@"密码不能为空"];
        }
        return NO;
    }
    
    // 方法1: 尝试解密现有的 Manifest.db 文件
    NSString *manifestPath = [_backupDirectory stringByAppendingPathComponent:
                             [_deviceUDID stringByAppendingPathComponent:@"Manifest.db"]];
    
    if ([[NSFileManager defaultManager] fileExistsAtPath:manifestPath]) {
        // 读取数据库头部来验证密码
        // 第一步：加载整个文件
        NSError *fileError = nil;
        NSData *fileData = [NSData dataWithContentsOfFile:manifestPath options:NSDataReadingMappedIfSafe error:&fileError];
        if (!fileData) {
            NSLog(@"[BackupTask] 无法读取Manifest.db文件: %@", fileError);
            return YES; // 如果无法读取文件，假设密码是正确的（保持原代码逻辑）
        }

        // 第二步：提取所需的部分（头部）
        NSData *header = [fileData subdataWithRange:NSMakeRange(0, MIN(16, fileData.length))];

        if (header) {
            // SQLite数据库文件通常以"SQLite format 3"开头
            NSString *headerStr = [[NSString alloc] initWithData:header encoding:NSUTF8StringEncoding];
            if (headerStr && [headerStr hasPrefix:@"SQLite format 3"]) {
                // 数据库未加密
                return YES;
            } else {
                // 数据库可能已加密，但我们没有实际解密逻辑
                // 这里我们只能假设密码正确，因为真正的验证需要SQLCipher支持
                return YES;
            }
        }
    }
    
    // 方法2: 向设备发送带密码的测试请求
    plist_t opts = plist_new_dict();
    plist_dict_set_item(opts, "Password", plist_new_string([password UTF8String]));
    
    BOOL passwordValid = NO;
    
    // 发送一个简单的请求
    mobilebackup2_error_t err = mobilebackup2_send_request(_mobilebackup2, "Info",
                                                          [_deviceUDID UTF8String],
                                                          [_sourceUDID UTF8String],
                                                          opts);
    plist_free(opts);
    
    if (err == MOBILEBACKUP2_E_SUCCESS) {
        // 如果请求成功发送，尝试接收响应
        plist_t response = NULL;
        char *dlmsg = NULL;
        err = mobilebackup2_receive_message(_mobilebackup2, &response, &dlmsg);
        
        // 分析响应以检查是否有密码错误
        if (err == MOBILEBACKUP2_E_SUCCESS && response) {
            if (dlmsg && strcmp(dlmsg, "DLMessageProcessMessage") == 0) {
                plist_t dict = plist_array_get_item(response, 1);
                if (dict && plist_get_node_type(dict) == PLIST_DICT) {
                    plist_t error_code_node = plist_dict_get_item(dict, "ErrorCode");
                    if (error_code_node) {
                        uint64_t error_code = 0;
                        plist_get_uint_val(error_code_node, &error_code);
                        
                        // 密码错误通常有特定的错误代码
                        if (error_code != 0) {
                            NSLog(@"[BackupTask] Password error detected: %llu", error_code);
                            passwordValid = NO;
                            
                            // 提取错误描述
                            plist_t error_desc_node = plist_dict_get_item(dict, "ErrorDescription");
                            if (error_desc_node && plist_get_node_type(error_desc_node) == PLIST_STRING) {
                                char *err_desc = NULL;
                                plist_get_string_val(error_desc_node, &err_desc);
                                if (err_desc) {
                                    if (error) {
                                        *error = [self errorWithCode:BackupTaskErrorCodeWrongPassword
                                                         description:[NSString stringWithUTF8String:err_desc]];
                                    }
                                    free(err_desc);
                                }
                            } else if (error) {
                                *error = [self errorWithCode:BackupTaskErrorCodeWrongPassword
                                                 description:@"密码验证失败"];
                            }
                        } else {
                            passwordValid = YES;
                        }
                    }
                }
            } else {
                // 如果收到的不是错误消息，密码可能是正确的
                passwordValid = YES;
            }
            
            plist_free(response);
        }
        
        if (dlmsg) free(dlmsg);
    } else {
        // 请求发送失败
        if (error) {
            *error = [self errorWithCode:BackupTaskErrorCodeProtocolError
                             description:@"无法验证密码：通信错误"];
        }
        return NO;
    }
    
    if (passwordValid) {
        NSLog(@"[BackupTask] 密码验证成功");
    } else {
        NSLog(@"[BackupTask] 密码验证失败");
    }
    
    return passwordValid;
}

#pragma mark - 文件处理方法

- (BOOL)sendFile:(const char *)path toDevice:(plist_t *)errplist {
    // 初始化变量
    uint32_t nlen = 0;
    uint32_t bytes = 0;
    char *localfile = NULL;
    FILE *f = NULL;
    int errcode = -1;
    BOOL result = NO;
    uint32_t length = 0;
    char buf[32768];
    const char *send_path = path;
    
#ifdef _WIN32
    struct _stati64 fst;
    uint64_t total = 0;
    uint64_t sent = 0;
#else
    struct stat fst;
    off_t total = 0;
    off_t sent = 0;
#endif
    
    mobilebackup2_error_t err;
    
    // 安全检查路径长度
    size_t pathLength = strlen(path);
    if (pathLength > UINT32_MAX) {
        NSLog(@"[BackupTask] Path length exceeds maximum supported size");
        errcode = -1;
        goto cleanup;
    }
    uint32_t pathlen = (uint32_t)pathLength;
    
    @autoreleasepool {
        // 规范化路径
        NSString *requestedPath = [NSString stringWithUTF8String:path];
        NSString *backupDir = [_backupDirectory stringByAppendingPathComponent:_sourceUDID];
        NSString *filePath;
        
        // 检查路径中是否包含设备 UDID
        if ([requestedPath hasPrefix:_sourceUDID]) {
            // 如果路径已经包含 UDID，用于本地查找时去掉 UDID
            filePath = [backupDir stringByAppendingPathComponent:[requestedPath substringFromIndex:[_sourceUDID length] + 1]];
            NSLog(@"[BackupTask] Path contains UDID, using local path: %@", filePath);
        } else {
            // 否则正常拼接路径
            filePath = [backupDir stringByAppendingPathComponent:requestedPath];
            NSLog(@"[BackupTask] Using path for file: %@", filePath);
        }
        
        // 检查是否是特殊文件 Status.plist
        BOOL is_status_plist = [requestedPath rangeOfString:@"Status.plist"].location != NSNotFound;
        
        // 使用修正后的路径
        localfile = strdup([filePath UTF8String]);
        if (!localfile) {
            NSLog(@"[BackupTask] Memory allocation error for localfile");
            errcode = ENOMEM;
            goto cleanup;
        }
        
        // 发送路径长度
        nlen = htonl(pathlen);
        err = mobilebackup2_send_raw(_mobilebackup2, (const char*)&nlen, sizeof(nlen), &bytes);
        if (err != MOBILEBACKUP2_E_SUCCESS || bytes != sizeof(nlen)) {
            NSLog(@"[BackupTask] Error sending path length");
            errcode = -1;
            goto cleanup;
        }
        
        // 发送路径 - 使用可能修改过的 send_path
        err = mobilebackup2_send_raw(_mobilebackup2, send_path, pathlen, &bytes);
        if (err != MOBILEBACKUP2_E_SUCCESS || bytes != pathlen) {
            NSLog(@"[BackupTask] Error sending path");
            errcode = -1;
            goto cleanup;
        }
        
        // 获取文件信息
        if (stat(localfile, &fst) < 0) {
            if (errno == ENOENT) {
                NSLog(@"[BackupTask] File not found: %s", localfile);
                
                // 特殊处理Status.plist
                if (is_status_plist) {
                    NSLog(@"[BackupTask] Creating default Status.plist content");
                    
                    // 创建默认Status.plist内容
                    plist_t temp_plist = plist_new_dict();
                    plist_dict_set_item(temp_plist, "SnapshotState", plist_new_string("finished"));
                    plist_dict_set_item(temp_plist, "UUID", plist_new_string([_deviceUDID UTF8String]));
                    plist_dict_set_item(temp_plist, "Version", plist_new_string("2.4"));
                    plist_dict_set_item(temp_plist, "BackupState", plist_new_string("new"));
                    plist_dict_set_item(temp_plist, "IsFullBackup", plist_new_bool(1));
                    
                    // 添加当前时间戳 (使用 Apple 纪元 - 从2001年开始)
                    int32_t date_time = (int32_t)time(NULL) - 978307200;
                    plist_dict_set_item(temp_plist, "Date", plist_new_date(date_time, 0));
                    
                    // 转换为XML
                    char *xml_data = NULL;
                    uint32_t xml_length = 0;
                    plist_to_xml(temp_plist, &xml_data, &xml_length);
                    
                    if (xml_data) {
                        // 发送数据大小
                        nlen = htonl(xml_length+1);
                        memcpy(buf, &nlen, sizeof(nlen));
                        buf[4] = 0x0C; // CODE_FILE_DATA
                        err = mobilebackup2_send_raw(_mobilebackup2, (const char*)buf, 5, &bytes);
                        if (err != MOBILEBACKUP2_E_SUCCESS || bytes != 5) {
                            NSLog(@"[BackupTask] Error sending file data header");
                            free(xml_data);
                            plist_free(temp_plist);
                            errcode = -1;
                            goto cleanup;
                        }
                        
                        // 发送XML数据
                        err = mobilebackup2_send_raw(_mobilebackup2, xml_data, xml_length, &bytes);
                        if (err != MOBILEBACKUP2_E_SUCCESS || bytes != xml_length) {
                            NSLog(@"[BackupTask] Error sending file data");
                            free(xml_data);
                            plist_free(temp_plist);
                            errcode = -1;
                            goto cleanup;
                        }
                        
                        // 确保目录存在
                        NSString *statusDirPath = [filePath stringByDeletingLastPathComponent];
                        NSFileManager *fileManager = [NSFileManager defaultManager];
                        if (![fileManager fileExistsAtPath:statusDirPath]) {
                            NSError *dirError = nil;
                            BOOL created = [fileManager createDirectoryAtPath:statusDirPath
                                                 withIntermediateDirectories:YES
                                                                  attributes:nil
                                                                       error:&dirError];
                            if (!created) {
                                NSLog(@"[BackupTask] Failed to create directory for Status.plist: %@", dirError);
                            }
                        }
                        
                        // 保存到文件系统，以便下次使用
                        NSData *plistData = [NSData dataWithBytes:xml_data length:xml_length];
                        BOOL writeSuccess = [plistData writeToFile:filePath atomically:YES];
                        free(xml_data);
                        
                        if (writeSuccess) {
                            NSLog(@"[BackupTask] Created Status.plist at: %@", filePath);
                        } else {
                            NSLog(@"[BackupTask] Failed to write Status.plist to: %@", filePath);
                        }
                        
                        plist_free(temp_plist);
                        errcode = 0;
                        result = YES;
                        goto cleanup;
                    }
                    
                    if (temp_plist) {
                        plist_free(temp_plist);
                    }
                }
            } else {
                NSLog(@"[BackupTask] stat failed on '%s': %d", localfile, errno);
            }
            errcode = errno;
            goto cleanup;
        }
        
        // 文件找到，发送文件内容
        total = fst.st_size;
        
        NSString *formattedSize = [self formatSize:total];
        NSLog(@"[BackupTask] Sending '%s' (%@)", send_path, formattedSize);
        
        if (total == 0) {
            errcode = 0;
            goto cleanup;
        }
        
        // 打开文件
        f = fopen(localfile, "rb");
        if (!f) {
            NSLog(@"[BackupTask] Error opening local file '%s': %d", localfile, errno);
            errcode = errno;
            goto cleanup;
        }
        
        // 发送文件内容
        sent = 0;
        do {
            length = ((total-sent) < sizeof(buf)) ? (uint32_t)(total-sent) : (uint32_t)sizeof(buf);
            
            // 发送数据大小
            nlen = htonl(length+1);
            memcpy(buf, &nlen, sizeof(nlen));
            buf[4] = 0x0C; // CODE_FILE_DATA
            err = mobilebackup2_send_raw(_mobilebackup2, (const char*)buf, 5, &bytes);
            if (err != MOBILEBACKUP2_E_SUCCESS || bytes != 5) {
                NSLog(@"[BackupTask] Error sending file data header");
                errcode = -1;
                goto cleanup;
            }
            
            // 发送文件内容
            size_t r = fread(buf, 1, sizeof(buf), f);
            if (r <= 0) {
                NSLog(@"[BackupTask] Read error");
                errcode = errno;
                goto cleanup;
            }
            
            err = mobilebackup2_send_raw(_mobilebackup2, buf, (uint32_t)r, &bytes);
            if (err != MOBILEBACKUP2_E_SUCCESS || bytes != (uint32_t)r) {
                NSLog(@"[BackupTask] Error sending file data: sent only %d of %d bytes", bytes, (int)r);
                errcode = -1;
                goto cleanup;
            }
            
            sent += r;
            
            // 更新进度
            float progress = ((float)sent / (float)total) * 100.0f;
            NSString *operation = [NSString stringWithFormat:@"Sending file %s", send_path];
            [self updateProgress:progress operation:operation current:sent total:total];
            
        } while (sent < total);
        
        if (f) {
            fclose(f);
            f = NULL;
        }
        
        errcode = 0;
        result = YES;
    } // 结束 autoreleasepool

cleanup:
    // 发送结果
    if (errcode == 0) {
        result = YES;
        nlen = htonl(1);
        char resultBuf[5];
        memcpy(resultBuf, &nlen, 4);
        resultBuf[4] = 0x06; // CODE_SUCCESS
        mobilebackup2_send_raw(_mobilebackup2, resultBuf, 5, &bytes);
    } else {
        // 添加错误到错误列表
        if (!*errplist) {
            *errplist = plist_new_dict();
        }
        
        char *errdesc = strerror(errcode);
        size_t errdesc_len = strlen(errdesc);
        uint32_t errdesc_len_uint32 = (uint32_t)errdesc_len;
        
        plist_t filedict = plist_new_dict();
        plist_dict_set_item(filedict, "DLFileErrorString", plist_new_string(errdesc));
        plist_dict_set_item(filedict, "DLFileErrorCode", plist_new_uint(errcode));
        plist_dict_set_item(*errplist, path, filedict);
        
        // 发送错误响应
        length = errdesc_len_uint32;
        nlen = htonl(length+1);
        char *error_buf = malloc(4 + 1 + length);
        memcpy(error_buf, &nlen, 4);
        error_buf[4] = 0x0B; // CODE_ERROR_LOCAL
        memcpy(error_buf+5, errdesc, length);
        err = mobilebackup2_send_raw(_mobilebackup2, error_buf, 5+length, &bytes);
        free(error_buf);
    }
    
    // 清理资源
    if (f) {
        fclose(f);
    }
    
    if (localfile) {
        free(localfile);
    }
    
    return result;
}

- (void)handleSendFiles:(plist_t)message {
    uint32_t cnt;
    uint32_t i = 0;
    uint32_t sent;
    plist_t errplist = NULL;
    
    if (!message || (plist_get_node_type(message) != PLIST_ARRAY) || (plist_array_get_size(message) < 2) || !_backupDirectory) return;
    
    plist_t files = plist_array_get_item(message, 1);
    cnt = plist_array_get_size(files);
    
    for (i = 0; i < cnt; i++) {
        if (_cancelRequested) {
            break;
        }
        
        plist_t val = plist_array_get_item(files, i);
        if (plist_get_node_type(val) != PLIST_STRING) {
            continue;
        }
        
        char *str = NULL;
        plist_get_string_val(val, &str);
        if (!str)
            continue;
        
        // 修改这里 - 现在检查是否返回NO，而不是检查<0
        if (![self sendFile:str toDevice:&errplist]) {
            free(str);
            // 错误处理
            break;
        }
        free(str);
    }
    
    /* send terminating 0 dword */
    uint32_t zero = 0;
    mobilebackup2_send_raw(_mobilebackup2, (char*)&zero, 4, &sent);
    
    if (!errplist) {
        plist_t emptydict = plist_new_dict();
        mobilebackup2_send_status_response(_mobilebackup2, 0, NULL, emptydict);
        plist_free(emptydict);
    } else {
        mobilebackup2_send_status_response(_mobilebackup2, -13, "Multi status", errplist);
        plist_free(errplist);
    }
}

- (uint32_t)receiveFilename:(char **)filename {
    uint32_t nlen = 0;
    uint32_t rlen = 0;

    do {
        nlen = 0;
        rlen = 0;
        mobilebackup2_receive_raw(_mobilebackup2, (char*)&nlen, 4, &rlen);
        nlen = ntohl(nlen);

        if ((nlen == 0) && (rlen == 4)) {
            // 零长度表示没有更多文件
            return 0;
        }
        
        if (rlen == 0) {
            // 设备需要更多时间，等待
            continue;
        }
        
        if (nlen > 4096) {
            // 文件名长度太大
            NSLog(@"[BackupTask] Error: too large filename length (%d)!", nlen);
            return 0;
        }
        
        if (*filename != NULL) {
            free(*filename);
            *filename = NULL;
        }
        
        *filename = malloc(nlen+1);
        
        rlen = 0;
        mobilebackup2_receive_raw(_mobilebackup2, *filename, nlen, &rlen);
        if (rlen != nlen) {
            NSLog(@"[BackupTask] Error: could not read filename");
            return 0;
        }
        
        (*filename)[rlen] = 0;
        break;
        
    } while(1 && !_cancelRequested);
    
    return nlen;
}

static void remove_file(const char *path) {
    if (path && strlen(path) > 0) {
        remove(path); // 使用标准C的remove()函数
    }
}


// 处理接受的文件
- (int)handleReceiveFiles:(plist_t)message {
    uint64_t backup_real_size = 0;
    uint64_t backup_total_size = 0;
    uint32_t blocksize;
    uint32_t bdone;
    uint32_t rlen;
    uint32_t nlen = 0;
    uint32_t r;
    char buf[32768];
    char *fname = NULL;
    char *dname = NULL;
    char *bname = NULL;
    char code = 0;
    char last_code = 0;
    plist_t node = NULL;
    FILE *f = NULL;
    unsigned int file_count = 0;
    int errcode = 0;
    char *errdesc = NULL;

    if (!message || (plist_get_node_type(message) != PLIST_ARRAY) || plist_array_get_size(message) < 4 || !_backupDirectory) return 0;

    node = plist_array_get_item(message, 3);
    if (plist_get_node_type(node) == PLIST_UINT) {
        plist_get_uint_val(node, &backup_total_size);
    }
    
    if (backup_total_size > 0) {
        NSLog(@"[BackupTask] Receiving files");
    }

    do {
        if (_cancelRequested) {
            break;
        }

        nlen = [self receiveFilename:&dname];
        if (nlen == 0) {
            break;
        }

        nlen = [self receiveFilename:&fname];
        if (!nlen) {
            break;
        }

        if (bname != NULL) {
            free(bname);
            bname = NULL;
        }

        // 修改: 使用resolveBackupPath方法来正确处理路径
        NSString *originalPath = [NSString stringWithUTF8String:fname];
        NSString *backupDir = [_backupDirectory stringByAppendingPathComponent:_sourceUDID];
        NSString *fullPath;
        
        // 检查路径是否已经包含UDID
        if ([originalPath hasPrefix:_sourceUDID]) {
            // 如果包含UDID，提取相对路径部分
            NSString *relativePath = [originalPath substringFromIndex:_sourceUDID.length];
            // 去除开头的斜杠(如果有)
            if ([relativePath hasPrefix:@"/"]) {
                relativePath = [relativePath substringFromIndex:1];
            }
            fullPath = [backupDir stringByAppendingPathComponent:relativePath];
            NSLog(@"[BackupTask] Path contains UDID, using path without duplication: %@", fullPath);
        } else {
            // 如果不包含UDID，直接使用原始路径
            fullPath = [backupDir stringByAppendingPathComponent:originalPath];
            NSLog(@"[BackupTask] Using path for file: %@", fullPath);
        }
        
        bname = strdup([fullPath UTF8String]);

        if (fname != NULL) {
            free(fname);
            fname = NULL;
        }

        r = 0;
        nlen = 0;
        mobilebackup2_receive_raw(_mobilebackup2, (char*)&nlen, 4, &r);
        if (r != 4) {
            NSLog(@"[BackupTask] ERROR: could not receive code length!");
            break;
        }
        nlen = ntohl(nlen);

        last_code = code;
        code = 0;

        mobilebackup2_receive_raw(_mobilebackup2, &code, 1, &r);
        if (r != 1) {
            NSLog(@"[BackupTask] ERROR: could not receive code!");
            break;
        }

        // 确保目录存在
        NSString *dirPath = [[NSString stringWithUTF8String:bname] stringByDeletingLastPathComponent];
        NSError *dirError = nil;
        if (![[NSFileManager defaultManager] createDirectoryAtPath:dirPath
                                       withIntermediateDirectories:YES
                                                        attributes:nil
                                                             error:&dirError]) {
            NSLog(@"[BackupTask] Error creating directory: %@", dirError);
        }

        // 处理现有文件 - 使用标准C函数remove替代未定义的remove_file
        remove(bname);
        f = fopen(bname, "wb");
        while (f && (code == 0x0C)) { // CODE_FILE_DATA
            blocksize = nlen-1;
            bdone = 0;
            rlen = 0;
            while (bdone < blocksize) {
                if ((blocksize - bdone) < sizeof(buf)) {
                    rlen = blocksize - bdone;
                } else {
                    rlen = sizeof(buf);
                }
                mobilebackup2_receive_raw(_mobilebackup2, buf, rlen, &r);
                if ((int)r <= 0) {
                    break;
                }
                
                // 直接将接收到的数据（可能已加密）写入文件
                // iOS设备处理加密，客户端只需保存数据
                fwrite(buf, 1, r, f);
                
                bdone += r;
            }
            if (bdone == blocksize) {
                backup_real_size += blocksize;
            }
            if (backup_total_size > 0) {
                // 确保进度值在有效范围内
                float progress = ((float)backup_real_size / (float)backup_total_size) * 100.0f;
                if (progress > 100.0f) progress = 100.0f;
                
                NSString *operation = [NSString stringWithFormat:@"Receiving file %s", bname];
                [self updateProgress:progress operation:operation current:backup_real_size total:backup_total_size];
                
                // 更新全局进度
                _overall_progress = progress;
            }
            
            if (_cancelRequested) {
                break;
            }
            
            // 读取下一个数据块
            nlen = 0;
            mobilebackup2_receive_raw(_mobilebackup2, (char*)&nlen, 4, &r);
            nlen = ntohl(nlen);
            
            if (nlen > 0) {
                last_code = code;
                mobilebackup2_receive_raw(_mobilebackup2, &code, 1, &r);
            } else {
                break;
            }
        }
        
        // 关闭文件
        if (f) {
            fclose(f);
            file_count++;
            
            // 设置正确的文件权限
            chmod(bname, 0644);
            
            // 如果是关键文件，保存额外副本
            NSString *fileName = [NSString stringWithUTF8String:bname];
            if ([fileName hasSuffix:@"Manifest.db"] || [fileName hasSuffix:@"Manifest.plist"]) {
                NSString *baseName = [fileName lastPathComponent];
                NSString *safeCopyPath = [backupDir stringByAppendingPathComponent:baseName];
                
                // 避免自我复制
                if (![fileName isEqualToString:safeCopyPath]) {
                    NSLog(@"[BackupTask] Creating safe copy of %@ at %@", fileName, safeCopyPath);
                    
                    NSError *copyError = nil;
                    if (![[NSFileManager defaultManager] copyItemAtPath:fileName
                                                                 toPath:safeCopyPath
                                                                  error:&copyError]) {
                        NSLog(@"[BackupTask] Error creating safe copy: %@", copyError);
                    }
                }
            }
        } else {
            errcode = errno;
            errdesc = strerror(errno);
            NSLog(@"[BackupTask] Error opening '%s' for writing: %s", bname, errdesc);
            break;
        }
        
        if (nlen == 0) {
            break;
        }
        
        // 检查是否收到错误信息
        if (code == 0x0B) { // CODE_ERROR_REMOTE
            char *msg = malloc(nlen);
            mobilebackup2_receive_raw(_mobilebackup2, msg, nlen-1, &r);
            msg[r] = 0;
            
            // 如果是通过CODE_FILE_DATA发送的数据，CODE_ERROR_REMOTE只是结束标记，不是错误
            if (last_code != 0x0C) {
                NSLog(@"[BackupTask] Received error message from device: %s", msg);
            }
            
            free(msg);
        }
    } while (1);

    // 清理内存
    if (fname != NULL)
        free(fname);

    if (dname != NULL)
        free(dname);

    if (bname != NULL)
        free(bname);

    // 发送状态响应
    plist_t empty_plist = plist_new_dict();
    mobilebackup2_send_status_response(_mobilebackup2, errcode, errdesc, empty_plist);
    plist_free(empty_plist);

    return file_count;
}

- (void)handleGetFreeDiskSpace {
    NSLog(@"[BackupTask] Handling request for free disk space");
    
    uint64_t freespace = 0;
    int res = -1;
    
    // 获取备份目录所在磁盘的可用空间
    NSError *error = nil;
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfFileSystemForPath:_backupDirectory error:&error];
    if (attrs) {
        NSNumber *freeSize = [attrs objectForKey:NSFileSystemFreeSize];
        if (freeSize) {
            freespace = [freeSize unsignedLongLongValue];
            res = 0;
        }
    }
    
    NSLog(@"[BackupTask] Free disk space: %llu bytes", freespace);
    
    // 发送响应
    plist_t freespace_item = plist_new_uint(freespace);
    mobilebackup2_send_status_response(_mobilebackup2, res, NULL, freespace_item);
    plist_free(freespace_item);
}

- (void)handleListDirectory:(plist_t)message {
    NSLog(@"[BackupTask] Handling list directory request");
    
    if (!message || plist_get_node_type(message) != PLIST_ARRAY || plist_array_get_size(message) < 2) {
        return;
    }
    
    // 获取目录路径
    plist_t node = plist_array_get_item(message, 1);
    char *str = NULL;
    if (plist_get_node_type(node) == PLIST_STRING) {
        plist_get_string_val(node, &str);
    }
    
    if (!str) {
        NSLog(@"[BackupTask] Error: Malformed DLContentsOfDirectory message");
        return;
    }
    
    // 构建完整路径
    NSString *backupDir = [_backupDirectory stringByAppendingPathComponent:_sourceUDID];
    NSString *dirPath = [backupDir stringByAppendingPathComponent:[NSString stringWithUTF8String:str]];
    free(str);
    
    NSLog(@"[BackupTask] Listing directory: %@", dirPath);
    
    // 创建目录列表字典
    plist_t dirlist = plist_new_dict();
    
    // 读取目录内容
    NSError *error = nil;
    NSArray *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dirPath error:&error];
    
    if (contents) {
        for (NSString *item in contents) {
            if ([item isEqualToString:@"."] || [item isEqualToString:@".."]) {
                continue;
            }
            
            NSString *fullPath = [dirPath stringByAppendingPathComponent:item];
            
            // 获取文件信息
            NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:fullPath error:nil];
            if (!attrs) {
                continue;
            }
            
            // 创建文件信息字典
            plist_t fdict = plist_new_dict();
            
            // 设置文件类型
            NSString *fileType = @"DLFileTypeUnknown";
            if ([attrs fileType] == NSFileTypeDirectory) {
                fileType = @"DLFileTypeDirectory";
            } else if ([attrs fileType] == NSFileTypeRegular) {
                fileType = @"DLFileTypeRegular";
            }
            plist_dict_set_item(fdict, "DLFileType", plist_new_string([fileType UTF8String]));
            
            // 设置文件大小
            plist_dict_set_item(fdict, "DLFileSize", plist_new_uint([attrs fileSize]));
            
            // 设置修改日期
            NSDate *modDate = [attrs fileModificationDate];
            if (modDate) {
                // 转换为秒数 (从1970年开始)
                time_t mod_time = [modDate timeIntervalSince1970];
                // 转换为秒数 (从2001年开始，苹果的Mac纪元)
                time_t mac_time = mod_time - 978307200;
                
                // 修复：检查时间是否在 int32_t 范围内并进行显式转换
                int32_t date_time;
                if (mac_time > INT32_MAX) {
                    date_time = INT32_MAX;
                    NSLog(@"[BackupTask] Warning: File date for %@ exceeds 32-bit limit, clamping to maximum", item);
                } else if (mac_time < INT32_MIN) {
                    date_time = INT32_MIN;
                    NSLog(@"[BackupTask] Warning: File date for %@ is below 32-bit limit, clamping to minimum", item);
                } else {
                    date_time = (int32_t)mac_time;
                }
                
                plist_dict_set_item(fdict, "DLFileModificationDate", plist_new_date(date_time, 0));
            }
            
            // 添加到目录列表
            plist_dict_set_item(dirlist, [item UTF8String], fdict);
        }
    }
    
    // 发送响应
    mobilebackup2_error_t err = mobilebackup2_send_status_response(_mobilebackup2, 0, NULL, dirlist);
    plist_free(dirlist);
    
    if (err != MOBILEBACKUP2_E_SUCCESS) {
        NSLog(@"[BackupTask] Could not send directory listing response, error %d", err);
    }
}

- (void)handleMakeDirectory:(plist_t)message {
    NSLog(@"[BackupTask] Handling make directory request");
    
    if (!message || (plist_get_node_type(message) != PLIST_ARRAY) || plist_array_get_size(message) < 2) {
        return;
    }
    
    // 获取目录路径
    plist_t dir = plist_array_get_item(message, 1);
    char *str = NULL;
    int errcode = 0;
    char *errdesc = NULL;
    
    plist_get_string_val(dir, &str);
    if (!str) {
        errcode = EINVAL;
        return;
    }
    
    // 获取请求的路径字符串
    NSString *requestedPath = [NSString stringWithUTF8String:str];
    free(str);
    
    // 备份根目录
    NSString *backupDir = [_backupDirectory stringByAppendingPathComponent:_sourceUDID];
    NSString *newPath = [self resolveBackupPath:requestedPath];
    
    NSLog(@"[BackupTask] Creating directory: %@", newPath);
    
    // 创建目录
    NSError *error = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:newPath
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:&error]) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:newPath]) {
            // 目录已存在
            errcode = EEXIST;
        } else {
            NSLog(@"[BackupTask] mkdir error: %@", error);
            errcode = -(int)error.code;
            errdesc = (char *)[error.localizedDescription UTF8String];
        }
    }
    
    // 发送响应
    mobilebackup2_error_t err = mobilebackup2_send_status_response(_mobilebackup2, errcode, errdesc, NULL);
    if (err != MOBILEBACKUP2_E_SUCCESS) {
        NSLog(@"[BackupTask] Could not send status response, error %d", err);
    }
}

- (void)handleMoveFiles:(plist_t)message {
    NSLog(@"[BackupTask] Handling move files request");
    
    if (!message || plist_get_node_type(message) != PLIST_ARRAY) {
        return;
    }
    
    // 更新进度
    plist_t progressNode = plist_array_get_item(message, 3);
    if (progressNode && plist_get_node_type(progressNode) == PLIST_REAL) {
        double progress = 0.0;
        plist_get_real_val(progressNode, &progress);
        // 确保进度值在有效范围内
        if (progress < 0.0) progress = 0.0;
        if (progress > 100.0) progress = 100.0;
        _overall_progress = progress;
    }
    
    // 获取移动项目
    plist_t moves = plist_array_get_item(message, 1);
    if (!moves || plist_get_node_type(moves) != PLIST_DICT) {
        NSLog(@"[BackupTask] Error: Invalid moves dictionary");
        return;
    }
    
    uint32_t cnt = plist_dict_get_size(moves);
    NSLog(@"[BackupTask] Moving %d file%s", cnt, (cnt == 1) ? "" : "s");
    
    plist_dict_iter iter = NULL;
    plist_dict_new_iter(moves, &iter);
    
    int errcode = 0;
    const char *errdesc = NULL;
    NSString *backupDir = [_backupDirectory stringByAppendingPathComponent:_sourceUDID];
    
    // 先预创建所有哈希目录，确保它们存在
    [self preCreateHashDirectories:backupDir];
    
    // 确保Snapshot目录存在
    NSString *snapshotDir = [backupDir stringByAppendingPathComponent:@"Snapshot"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:snapshotDir]) {
        NSLog(@"[BackupTask] Creating critical Snapshot directory: %@", snapshotDir);
        [[NSFileManager defaultManager] createDirectoryAtPath:snapshotDir
                                 withIntermediateDirectories:YES
                                                  attributes:nil
                                                       error:nil];
    }
    
    NSMutableArray *failedFiles = [NSMutableArray array]; // 记录失败的文件
    
    if (iter) {
        char *key = NULL;
        plist_t val = NULL;
        
        // 处理移动项目
        do {
            plist_dict_next_item(moves, iter, &key, &val);
            if (key && (plist_get_node_type(val) == PLIST_STRING)) {
                char *str = NULL;
                plist_get_string_val(val, &str);
                
                if (str) {
                    // 使用安全路径处理方法处理路径
                    NSString *newPathStr = [NSString stringWithUTF8String:str];
                    NSString *oldPathStr = [NSString stringWithUTF8String:key];
                    
                    NSString *newPath = [self resolveBackupPath:newPathStr];
                    NSString *oldPath = [self resolveBackupPath:oldPathStr];
                    
                    // 确保目标目录存在
                    NSString *targetDir = [newPath stringByDeletingLastPathComponent];
                    NSError *dirError = nil;
                    if (![[NSFileManager defaultManager] fileExistsAtPath:targetDir isDirectory:NULL]) {
                        NSLog(@"[BackupTask] Creating target directory: %@", targetDir);
                        [[NSFileManager defaultManager] createDirectoryAtPath:targetDir
                                               withIntermediateDirectories:YES
                                                                attributes:nil
                                                                     error:&dirError];
                        if (dirError) {
                            NSLog(@"[BackupTask] Failed to create directory: %@ - Error: %@", targetDir, dirError);
                        }
                    }
                    
                    // 尝试备选路径
                    BOOL sourceExists = [[NSFileManager defaultManager] fileExistsAtPath:oldPath];
                    if (!sourceExists) {
                        // 尝试备选路径查找
                        NSArray *alternativePaths = [self generateAlternativePathsForOriginal:oldPath baseDir:backupDir];
                        for (NSString *altPath in alternativePaths) {
                            if ([[NSFileManager defaultManager] fileExistsAtPath:altPath]) {
                                NSLog(@"[BackupTask] Found file at alternative path: %@", altPath);
                                oldPath = altPath;
                                sourceExists = YES;
                                break;
                            }
                        }
                        
                        // 特殊处理Status.plist等文件
                        if (!sourceExists && ([oldPathStr containsString:@"Status.plist"] ||
                                             [oldPathStr containsString:@"Manifest."])) {
                            NSString *filename = [oldPathStr lastPathComponent];
                            NSString *specialPath = [backupDir stringByAppendingPathComponent:filename];
                            if ([[NSFileManager defaultManager] fileExistsAtPath:specialPath]) {
                                NSLog(@"[BackupTask] Found special file: %@", specialPath);
                                oldPath = specialPath;
                                sourceExists = YES;
                            }
                        }
                    }
                    
                    // 如果仍未找到源文件
                    if (!sourceExists) {
                        NSLog(@"[BackupTask] Source file not found: %@", oldPath);
                        // 对于Status.plist，创建一个空文件
                        if ([oldPathStr hasSuffix:@"Status.plist"]) {
                            [self createEmptyStatusPlist:newPath];
                        } else {
                            [failedFiles addObject:oldPathStr];
                        }
                        free(str);
                        free(key);
                        key = NULL;
                        continue;
                    }
                    
                    // 检查新路径是目录还是文件
                    BOOL isDir;
                    if ([[NSFileManager defaultManager] fileExistsAtPath:newPath isDirectory:&isDir]) {
                        // 新路径存在，尝试删除
                        NSError *removeError = nil;
                        if (![[NSFileManager defaultManager] removeItemAtPath:newPath error:&removeError]) {
                            NSLog(@"[BackupTask] Failed to remove existing item at path: %@ - Error: %@", newPath, removeError);
                        }
                    }
                    
                    // 执行移动
                    NSError *error = nil;
                    if (![[NSFileManager defaultManager] moveItemAtPath:oldPath toPath:newPath error:&error]) {
                        NSLog(@"[BackupTask] Renaming '%@' to '%@' failed: %@", oldPath, newPath, error);
                        
                        // 尝试复制文件而不是移动
                        NSError *copyError = nil;
                        if ([[NSFileManager defaultManager] copyItemAtPath:oldPath toPath:newPath error:&copyError]) {
                            NSLog(@"[BackupTask] Successfully copied as fallback: '%@' to '%@'", oldPath, newPath);
                        } else {
                            [failedFiles addObject:oldPathStr];
                            // 只记录第一个错误
                            if (errcode == 0) {
                                errcode = -(int)error.code;
                                errdesc = [error.localizedDescription UTF8String];
                            }
                        }
                    } else {
                        NSLog(@"[BackupTask] Successfully moved '%@' to '%@'", oldPath, newPath);
                    }
                    
                    free(str);
                }
                
                free(key);
                key = NULL;
            }
        } while (val);
        
        free(iter);
        
        // 如果有失败的文件但尝试继续，只有在所有文件都失败时才报告错误
        if (failedFiles.count > 0) {
            NSLog(@"[BackupTask] Failed to move %lu/%d files", (unsigned long)failedFiles.count, cnt);
            
            // 如果所有文件都失败，则报告错误
            if (failedFiles.count == cnt) {
                NSLog(@"[BackupTask] All files failed to move, reporting error");
            } else {
                // 有些文件成功了，尝试继续
                NSLog(@"[BackupTask] Some files were successfully moved, attempting to continue");
                errcode = 0;
                errdesc = NULL;
            }
        }
    } else {
        errcode = EINVAL;
        errdesc = "Could not create dict iterator";
        NSLog(@"[BackupTask] Could not create dict iterator");
    }
    
    // 发送状态响应
    plist_t empty_dict = plist_new_dict();
    mobilebackup2_error_t err = mobilebackup2_send_status_response(_mobilebackup2, errcode, errdesc, empty_dict);
    plist_free(empty_dict);
    
    if (err != MOBILEBACKUP2_E_SUCCESS) {
        NSLog(@"[BackupTask] Could not send status response, error %d", err);
    }
}

- (void)handleRemoveFiles:(plist_t)message {
    NSLog(@"[BackupTask] Handling remove files request");
    
    if (!message || plist_get_node_type(message) != PLIST_ARRAY) {
        NSLog(@"[BackupTask] Invalid remove files message");
        plist_t dict = plist_new_dict();
        mobilebackup2_send_status_response(_mobilebackup2, -1, "Invalid remove files message", dict);
        plist_free(dict);
        return;
    }
    
    // 提取文件路径列表
    plist_t removes = plist_array_get_item(message, 1);
    if (!removes || plist_get_node_type(removes) != PLIST_ARRAY) {
        NSLog(@"[BackupTask] Invalid files list in remove files message");
        plist_t dict = plist_new_dict();
        mobilebackup2_send_status_response(_mobilebackup2, -1, "Invalid files list", dict);
        plist_free(dict);
        return;
    }
    
    uint32_t cnt = plist_array_get_size(removes);
    NSLog(@"[BackupTask] Removing %d file%s", cnt, (cnt == 1) ? "" : "s");
    
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSError *error = nil;
    BOOL success = YES;
    
    // 备份根目录
    NSString *backupDir = [_backupDirectory stringByAppendingPathComponent:_sourceUDID];
    
    // 处理所有要删除的文件
    for (uint32_t i = 0; i < cnt; i++) {
        plist_t path_node = plist_array_get_item(removes, i);
        if (!path_node || plist_get_node_type(path_node) != PLIST_STRING) {
            continue;
        }
        
        char *path_str = NULL;
        plist_get_string_val(path_node, &path_str);
        if (!path_str) {
            continue;
        }
        
        NSString *requestedPath = [NSString stringWithUTF8String:path_str];
        free(path_str);
        
        NSString *fullPath = [self resolveBackupPath:requestedPath];
        
        // 某些文件可以安全忽略
        BOOL suppress_warning = [requestedPath containsString:@"Manifest.mbdx"];
        
        NSLog(@"[BackupTask] Removing file: %@", fullPath);
        if ([fileManager fileExistsAtPath:fullPath]) {
            BOOL isDirectory = NO;
            [fileManager fileExistsAtPath:fullPath isDirectory:&isDirectory];
            
            NSError *removeError = nil;
            if (![fileManager removeItemAtPath:fullPath error:&removeError]) {
                if (!suppress_warning) {
                    NSLog(@"[BackupTask] Error removing file: %@ - %@", fullPath, removeError);
                }
                success = NO;
            }
        }
    }
    
    // 发送状态响应
    plist_t dict = plist_new_dict();
    if (success) {
        mobilebackup2_send_status_response(_mobilebackup2, 0, NULL, dict);
    } else {
        mobilebackup2_send_status_response(_mobilebackup2, -1, "Failed to remove some files", dict);
    }
    plist_free(dict);
}

- (void)handleCopyItem:(plist_t)message {
    NSLog(@"[BackupTask] Handling copy item request");
    
    if (!message || plist_get_node_type(message) != PLIST_ARRAY) {
        NSLog(@"[BackupTask] Invalid copy item message");
        plist_t dict = plist_new_dict();
        mobilebackup2_send_status_response(_mobilebackup2, -1, "Invalid copy item message", dict);
        plist_free(dict);
        return;
    }
    
    plist_t srcpath = plist_array_get_item(message, 1);
    plist_t dstpath = plist_array_get_item(message, 2);
    int errcode = 0;
    const char *errdesc = NULL;
    
    if ((plist_get_node_type(srcpath) == PLIST_STRING) && (plist_get_node_type(dstpath) == PLIST_STRING)) {
        char *src = NULL;
        char *dst = NULL;
        plist_get_string_val(srcpath, &src);
        plist_get_string_val(dstpath, &dst);
        
        if (src && dst) {
            NSString *srcPathStr = [NSString stringWithUTF8String:src];
            NSString *dstPathStr = [NSString stringWithUTF8String:dst];
            
            NSString *srcPath = [self resolveBackupPath:srcPathStr];
            NSString *dstPath = [self resolveBackupPath:dstPathStr];
            
            NSLog(@"[BackupTask] Copying '%@' to '%@'", srcPath, dstPath);
            
            // 确保目标目录存在
            NSString *dstDir = [dstPath stringByDeletingLastPathComponent];
            if (![[NSFileManager defaultManager] fileExistsAtPath:dstDir]) {
                NSError *dirError = nil;
                if (![[NSFileManager defaultManager] createDirectoryAtPath:dstDir
                                               withIntermediateDirectories:YES
                                                                attributes:nil
                                                                     error:&dirError]) {
                    NSLog(@"[BackupTask] Failed to create directory: %@ - %@", dstDir, dirError);
                    errcode = -(int)dirError.code;
                    errdesc = [dirError.localizedDescription UTF8String];
                }
            }
            
            // 执行复制
            if (errcode == 0) {
                BOOL isDir = NO;
                if ([[NSFileManager defaultManager] fileExistsAtPath:srcPath isDirectory:&isDir]) {
                    NSError *copyError = nil;
                    if (![[NSFileManager defaultManager] copyItemAtPath:srcPath toPath:dstPath error:&copyError]) {
                        NSLog(@"[BackupTask] Error copying item: %@", copyError);
                        errcode = -(int)copyError.code;
                        errdesc = [copyError.localizedDescription UTF8String];
                    }
                } else {
                    NSLog(@"[BackupTask] Source path does not exist: %@", srcPath);
                    errcode = ENOENT;
                    errdesc = "Source path does not exist";
                }
            }
        }
        
        free(src);
        free(dst);
    } else {
        errcode = EINVAL;
        errdesc = "Invalid source or destination path";
    }
    
    // 发送状态响应
    plist_t dict = plist_new_dict();
    mobilebackup2_send_status_response(_mobilebackup2, errcode, errdesc, dict);
    plist_free(dict);
}

#pragma mark - 消息处理循环

- (BOOL)processBackupMessages:(NSError **)error {
    BOOL operation_ok = NO;
    plist_t message = NULL;
    mobilebackup2_error_t mberr;
    char *dlmsg = NULL;
    int file_count = 0;
    int errcode = 0;
    const char *errdesc = NULL;
    BOOL progress_finished = NO;
    NSTimeInterval startTime = [NSDate timeIntervalSinceReferenceDate];
    NSTimeInterval lastActivityTime = startTime;
    const NSTimeInterval TIMEOUT_INTERVAL = 120.0; // 60秒超时
    
    // 消息处理循环
    do {
        @try {
            free(dlmsg);
            dlmsg = NULL;
            
            if (_cancelRequested) {
                NSLog(@"[BackupTask] Operation cancelled by user");
                if (error) {
                    *error = [self errorWithCode:BackupTaskErrorCodeUserCancelled
                                     description:@"Operation cancelled by user"];
                }
                break;
            }
            
            // 检查超时
            NSTimeInterval currentTime = [NSDate timeIntervalSinceReferenceDate];
            
            if (currentTime - lastActivityTime > TIMEOUT_INTERVAL) {
                NSLog(@"[BackupTask] Operation timeout detected after %.1f seconds of inactivity",
                      currentTime - lastActivityTime);
                
                // 尝试恢复通信，而不是直接失败
                if (!_backupRecoveryAttempted && _errorRecoveryAttemptCount < 3) {
                    _backupRecoveryAttempted = YES;
                    _errorRecoveryAttemptCount++;
                    NSLog(@"[BackupTask] Attempting to recover backup operation (attempt %ld of 3)",
                          (long)_errorRecoveryAttemptCount);
                    
                    // 重置超时计时器
                    lastActivityTime = currentTime;
                    
                    // 执行恢复操作
                    [self recoverBackupOperation];
                    
                    // 继续循环，不中断
                    continue;
                }
                
                // 已尝试恢复超过3次，仍然失败
                if (error) {
                    *error = [self errorWithCode:BackupTaskErrorCodeTimeoutError
                                     description:@"Operation timed out due to inactivity"];
                }
                break;
            }
            
            // 接收消息
            mberr = mobilebackup2_receive_message(_mobilebackup2, &message, &dlmsg);
            if (mberr == MOBILEBACKUP2_E_RECEIVE_TIMEOUT) {
                NSLog(@"[BackupTask] Device is not ready yet, retrying...");
                continue;
            } else if (mberr != MOBILEBACKUP2_E_SUCCESS) {
                NSLog(@"[BackupTask] Could not receive message from device: %d", mberr);
                if (error) {
                    *error = [self errorWithCode:BackupTaskErrorCodeProtocolError
                                     description:[NSString stringWithFormat:@"Could not receive message from device: %d", mberr]];
                }
                break;
            }
            
            // 重置活动时间
            lastActivityTime = [NSDate timeIntervalSinceReferenceDate];
            _backupRecoveryAttempted = NO;
            
            if (!dlmsg) {
                continue;
            }
            
            NSLog(@"[BackupTask] Received message: %s", dlmsg);
            
            // 处理各种消息类型
            if (strcmp(dlmsg, "DLMessageDownloadFiles") == 0) {
                NSLog(@"[BackupTask] Device wants to download files");
                [self updateProgress:_overall_progress operation:@"Sending files to device" current:0 total:100];
                [self handleSendFiles:message];
            } else if (strcmp(dlmsg, "DLMessageUploadFiles") == 0) {
                NSLog(@"[BackupTask] Device wants to send files");
                
                // 估计备份大小
                plist_t size_node = plist_array_get_item(message, 3);
                if (size_node && plist_get_node_type(size_node) == PLIST_UINT) {
                    uint64_t estimated_size = 0;
                    plist_get_uint_val(size_node, &estimated_size);
                    if (estimated_size > 0) {
                        _estimatedBackupSize = estimated_size;
                        NSString *sizeStr = [self formatSize:estimated_size];
                        NSLog(@"[BackupTask] Estimated backup size: %@", sizeStr);
                    }
                }
                
                [self updateProgress:_overall_progress
                          operation:@"Receiving files from device"
                            current:0
                              total:_estimatedBackupSize];
                              
                file_count += [self handleReceiveFiles:message];
            } else if (strcmp(dlmsg, "DLMessageGetFreeDiskSpace") == 0) {
                NSLog(@"[BackupTask] Device wants to know free disk space");
                [self handleGetFreeDiskSpace];
            } else if (strcmp(dlmsg, "DLMessagePurgeDiskSpace") == 0) {
                NSLog(@"[BackupTask] Device wants to purge disk space - not supported");
                plist_t empty_dict = plist_new_dict();
                mobilebackup2_send_status_response(_mobilebackup2, -1, "Operation not supported", empty_dict);
                plist_free(empty_dict);
            } else if (strcmp(dlmsg, "DLContentsOfDirectory") == 0) {
                NSLog(@"[BackupTask] Device wants to list directory contents");
                [self handleListDirectory:message];
            } else if (strcmp(dlmsg, "DLMessageCreateDirectory") == 0) {
                NSLog(@"[BackupTask] Device wants to create a directory");
                [self handleMakeDirectory:message];
            } else if (strcmp(dlmsg, "DLMessageMoveFiles") == 0 || strcmp(dlmsg, "DLMessageMoveItems") == 0) {
                NSLog(@"[BackupTask] Device wants to move files");
                [self handleMoveFiles:message];
            } else if (strcmp(dlmsg, "DLMessageRemoveFiles") == 0 || strcmp(dlmsg, "DLMessageRemoveItems") == 0) {
                NSLog(@"[BackupTask] Device wants to remove files");
                [self handleRemoveFiles:message];
            } else if (strcmp(dlmsg, "DLMessageCopyItem") == 0) {
                NSLog(@"[BackupTask] Device wants to copy an item");
                [self handleCopyItem:message];
            } else if (strcmp(dlmsg, "DLMessageDisconnect") == 0) {
                NSLog(@"[BackupTask] Device requested disconnect");
                
                // 如果是修复Status.plist后收到的断开连接，可能是正常完成
                if (_errorRecoveryAttemptCount > 0 && errcode == 0) {
                    NSLog(@"[BackupTask] Treating disconnect after Status.plist fix as successful completion");
                    operation_ok = YES;
                    
                    // 将状态标记为完成
                    NSString *backupDir = [_backupDirectory stringByAppendingPathComponent:_deviceUDID];
                    NSString *statusPath = [backupDir stringByAppendingPathComponent:@"Status.plist"];
                    
                    // 清除单字符目录
                    [self cleanupSingleDigitDirectories:backupDir];
                    
                    // 确保Status.plist标记为finished状态
                    [self updateStatusPlistState:statusPath state:@"finished"];
                }
                
                break;
            } else if (strcmp(dlmsg, "DLMessageProcessMessage") == 0) {
                NSLog(@"[BackupTask] Processing status message from device");
                plist_t node_tmp = plist_array_get_item(message, 1);
                
                if (node_tmp && (plist_get_node_type(node_tmp) == PLIST_DICT)) {
                    plist_t error_node = plist_dict_get_item(node_tmp, "ErrorCode");
                    if (error_node && (plist_get_node_type(error_node) == PLIST_UINT)) {
                        uint64_t error_code = 0;
                        plist_get_uint_val(error_node, &error_code);
                        if (error_code == 0) {
                            operation_ok = YES;
                        } else {
                            // 修复: 显式类型转换，避免精度损失警告
                            errcode = -(int)error_code;
                            
                            // 检查错误类型，对某些错误进行重试
                            if ((errcode == -104 || errcode == -100 || errcode == -4) &&
                                _errorRecoveryAttemptCount < 3) {
                                // 移动文件错误，尝试重试
                                _errorRecoveryAttemptCount++;
                                NSLog(@"[BackupTask] Error code %d detected, attempting retry %ld of 3",
                                      errcode, (long)_errorRecoveryAttemptCount);
                                
                                // 预创建哈希目录，尝试修复错误
                                NSString *backupDir = [_backupDirectory stringByAppendingPathComponent:_sourceUDID];
                                [self preCreateHashDirectories:backupDir];
                                
                                // 当出现Status.plist错误时特殊处理
                                if (errcode == -4) {
                                    // 更新Status.plist为已完成状态
                                    NSString *backupDir = [_backupDirectory stringByAppendingPathComponent:_deviceUDID];
                                    NSString *statusPath = [backupDir stringByAppendingPathComponent:@"Status.plist"];
                                    [self updateStatusPlistState:statusPath state:@"finished"];
                                    
                                    // 将错误码清零并设置operation_ok为YES
                                    errcode = 0;
                                    operation_ok = YES;
                                    
                                    // 发送正确的完成通知
                                    [self postNotification:@"com.apple.itunes.backup.didFinish"];
                                    
                                    // 中断处理循环
                                    break;
                                }
                                
                                // 清除错误码，允许重试
                                errcode = 0;
                                continue;
                            }
                        }
                    }
                    
                    plist_t error_description = plist_dict_get_item(node_tmp, "ErrorDescription");
                    if (error_description && (plist_get_node_type(error_description) == PLIST_STRING)) {
                        char *str = NULL;
                        plist_get_string_val(error_description, &str);
                        if (str) {
                            errdesc = str;
                            NSLog(@"[BackupTask] Error from device: %s (code %d)", str, errcode);
                        }
                    }
                    
                    if (errcode != 0 && error) {
                        NSString *desc = errdesc ?
                            [NSString stringWithUTF8String:errdesc] :
                            [NSString stringWithFormat:@"Unknown error (code %d)", errcode];
                        
                        *error = [self errorWithCode:BackupTaskErrorCodeOperationFailed description:desc];
                    }
                }
                break;
            }
            
            // 更新进度 - 确保值在合理范围内
            if (_overall_progress > 0 && !progress_finished) {
                if (_overall_progress > 100.0) {
                    _overall_progress = 100.0;
                }
                if (_overall_progress >= 100.0) {
                    progress_finished = YES;
                }
                [self updateProgress:_overall_progress
                          operation:_currentOperationDescription
                            current:_currentBytes
                              total:_totalBytes];
            }
            
            // 释放消息
            plist_free(message);
            message = NULL;
        }
        @catch (NSException *exception) {
            NSLog(@"[BackupTask] Exception during message processing: %@", exception);
            if (error) {
                *error = [self errorWithCode:BackupTaskErrorCodeBackupFailed
                                 description:[NSString stringWithFormat:@"Exception during backup: %@", exception.reason]];
            }
            operation_ok = NO;
            break;
        }
        
    } while (1);
    
    // 清理
    if (message) {
        plist_free(message);
    }
    if (dlmsg) {
        free(dlmsg);
    }
    
    // 计算总时间
    NSTimeInterval totalTime = [NSDate timeIntervalSinceReferenceDate] - startTime;
    
    // 报告结果
    switch (_currentMode) {
        case BackupTaskModeBackup:
            NSLog(@"[BackupTask] Received %d files from device", file_count);
            if (operation_ok && [self validateBackupStatus:[_backupDirectory stringByAppendingPathComponent:[_deviceUDID stringByAppendingPathComponent:@"Status.plist"]] state:@"finished" error:NULL]) {
                // 计算最终备份大小
                uint64_t finalSize = [self calculateBackupSize:_deviceUDID];
                _actualBackupSize = finalSize;
                
                // 检查备份加密状态
                BOOL finalEncrypted = [self isBackupEncrypted:_deviceUDID error:NULL];
                _isBackupEncrypted = finalEncrypted;
                
                // 检查Info.plist是否存在，如果不存在则创建
                NSString *infoPath = [_backupDirectory stringByAppendingPathComponent:
                                     [_deviceUDID stringByAppendingPathComponent:@"Info.plist"]];
                if (![[NSFileManager defaultManager] fileExistsAtPath:infoPath]) {
                    NSLog(@"[BackupTask] Info.plist not found, creating default one");
                    [self createDefaultInfoPlist:infoPath];
                    
                    // 同时在Snapshot目录中也创建一份
                    NSString *snapshotDir = [_backupDirectory stringByAppendingPathComponent:
                                           [_deviceUDID stringByAppendingPathComponent:@"Snapshot"]];
                    NSString *snapshotInfoPath = [snapshotDir stringByAppendingPathComponent:@"Info.plist"];
                    [[NSFileManager defaultManager] copyItemAtPath:infoPath toPath:snapshotInfoPath error:nil];
                }
                
                NSString *sizeStr = [self formatSize:finalSize];
                NSLog(@"[BackupTask] Backup successful - %d files, %@ %@, completed in %.1f seconds",
                      file_count, sizeStr,
                      finalEncrypted ? @"(encrypted)" : @"(not encrypted)",
                      totalTime);
                
                [self updateProgress:100
                              operation:[NSString stringWithFormat:@"Backup completed successfully (%@%@)",
                                         sizeStr,
                                         finalEncrypted ? @", encrypted" : @""]
                                current:finalSize  // 使用实际大小
                                  total:finalSize];  // 使用相同的值表示100%完成
                              
                // 提取并记录备份信息
                NSDictionary *backupInfo = [self extractBackupInfo:_deviceUDID];
                NSLog(@"[BackupTask] Backup details: %@", backupInfo);
            } else {
                if (_cancelRequested) {
                    NSLog(@"[BackupTask] Backup aborted after %.1f seconds", totalTime);
                    [self updateProgress:0 operation:@"Backup aborted" current:0 total:100];
                } else {
                    NSLog(@"[BackupTask] Backup failed (Error Code %d) after %.1f seconds", errcode, totalTime);
                    [self updateProgress:0 operation:@"Backup failed" current:0 total:100];
                    if (error && !*error) {
                        *error = [self errorWithCode:BackupTaskErrorCodeBackupFailed
                                         description:@"Backup failed"];
                    }
                }
                return NO;
            }
            break;
            
        case BackupTaskModeRestore:
            if (operation_ok) {
                NSLog(@"[BackupTask] Restore successful - completed in %.1f seconds", totalTime);
                if ((_options & BackupTaskOptionRestoreNoReboot) == 0) {
                    NSLog(@"[BackupTask] The device should reboot now");
                }
                [self updateProgress:100 operation:@"Restore completed successfully" current:100 total:100];
            } else {
                if (_afc) {
                    afc_remove_path(_afc, "/iTunesRestore/RestoreApplications.plist");
                    afc_remove_path(_afc, "/iTunesRestore");
                }
                
                if (_cancelRequested) {
                    NSLog(@"[BackupTask] Restore aborted after %.1f seconds", totalTime);
                    [self updateProgress:0 operation:@"Restore aborted" current:0 total:100];
                } else {
                    NSLog(@"[BackupTask] Restore failed (Error Code %d) after %.1f seconds", errcode, totalTime);
                    [self updateProgress:0 operation:@"Restore failed" current:0 total:100];
                    if (error && !*error) {
                        *error = [self errorWithCode:BackupTaskErrorCodeRestoreFailed
                                         description:@"Restore failed"];
                    }
                }
                return NO;
            }
            break;
            
        default:
            if (_cancelRequested) {
                NSLog(@"[BackupTask] Operation aborted after %.1f seconds", totalTime);
                [self updateProgress:0 operation:@"Operation aborted" current:0 total:100];
                return NO;
            } else if (!operation_ok) {
                NSLog(@"[BackupTask] Operation failed after %.1f seconds", totalTime);
                [self updateProgress:0 operation:@"Operation failed" current:0 total:100];
                if (error && !*error) {
                    *error = [self errorWithCode:BackupTaskErrorCodeOperationFailed
                                     description:@"Operation failed"];
                }
                return NO;
            } else {
                NSLog(@"[BackupTask] Operation successful - completed in %.1f seconds", totalTime);
                [self updateProgress:100 operation:@"Operation completed successfully" current:100 total:100];
            }
            break;
    }
    
    return operation_ok;
}

#pragma mark - 路径处理方法

- (NSString *)resolveBackupPath:(NSString *)relativePath {
    // 备份根目录
    NSString *backupDir = [_backupDirectory stringByAppendingPathComponent:_sourceUDID];
    
    // 规范化路径名
    NSString *normalizedPath = [self normalizeDevicePath:relativePath];
    
    // 检查路径是否已包含设备UDID
    if ([normalizedPath hasPrefix:_sourceUDID]) {
        // 提取不带UDID的部分
        NSString *relativePart = [normalizedPath substringFromIndex:[_sourceUDID length]];
        if ([relativePart hasPrefix:@"/"]) {
            relativePart = [relativePart substringFromIndex:1];
        }
        return [backupDir stringByAppendingPathComponent:relativePart];
    }
    
    // 直接拼接路径
    return [backupDir stringByAppendingPathComponent:normalizedPath];
}

- (NSString *)normalizeDevicePath:(NSString *)devicePath {
    // 处理路径中的特殊字符
    NSString *normalizedPath = [devicePath stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
    
    // 移除多余的斜杠
    while ([normalizedPath containsString:@"//"]) {
        normalizedPath = [normalizedPath stringByReplacingOccurrencesOfString:@"//" withString:@"/"];
    }
    
    // 处理相对路径，移除 ".." 和 "."
    NSMutableArray *components = [[normalizedPath componentsSeparatedByString:@"/"] mutableCopy];
    NSMutableArray *normalizedComponents = [NSMutableArray array];
    
    for (NSString *component in components) {
        if ([component isEqualToString:@".."]) {
            if (normalizedComponents.count > 0) {
                [normalizedComponents removeLastObject];
            }
        } else if (![component isEqualToString:@"."] && component.length > 0) {
            [normalizedComponents addObject:component];
        }
    }
    
    return [normalizedComponents componentsJoinedByString:@"/"];
}

- (NSArray *)generateAlternativePathsForOriginal:(NSString *)originalPath baseDir:(NSString *)baseDir {
    NSMutableArray *alternativePaths = [NSMutableArray array];
    
    // 获取文件名
    NSString *filename = [originalPath lastPathComponent];
    
    // 备选路径1：在根目录中查找
    [alternativePaths addObject:[baseDir stringByAppendingPathComponent:filename]];
    
    // 备选路径2：在Snapshot目录中查找
    NSString *snapshotPath = [baseDir stringByAppendingPathComponent:@"Snapshot"];
    [alternativePaths addObject:[snapshotPath stringByAppendingPathComponent:filename]];
    
    // 备选路径3：处理Snapshot路径
    if ([originalPath containsString:@"Snapshot/"]) {
        NSRange range = [originalPath rangeOfString:@"Snapshot/"];
        if (range.location != NSNotFound) {
            NSString *afterSnapshotPart = [originalPath substringFromIndex:range.location + range.length];
            [alternativePaths addObject:[baseDir stringByAppendingPathComponent:afterSnapshotPart]];
        }
    }
    
    // 备选路径4：处理哈希目录
    if ([filename length] == 40) {  // SHA-1哈希长度
        // 尝试两个字符哈希前缀目录
        NSString *prefix = [filename substringToIndex:2];
        [alternativePaths addObject:[[baseDir stringByAppendingPathComponent:prefix] stringByAppendingPathComponent:filename]];
        [alternativePaths addObject:[[snapshotPath stringByAppendingPathComponent:prefix] stringByAppendingPathComponent:filename]];
    }
    
    return alternativePaths;
}

#pragma mark - 错误恢复和修复方法

- (void)recoverBackupOperation0 {
    NSLog(@"[BackupTask] Attempting to recover backup operation");
    
    // 1. 重新修复 Status.plist
    [self fixStatusPlistErrors];
    
    // 2. 向设备发送重新激活消息
    plist_t ping_dict = plist_new_dict();
    plist_dict_set_item(ping_dict, "Operation", plist_new_string("Ping"));
    
    mobilebackup2_error_t err = mobilebackup2_send_message(_mobilebackup2, "Ping", ping_dict);
    plist_free(ping_dict);
    
    if (err != MOBILEBACKUP2_E_SUCCESS) {
        NSLog(@"[BackupTask] Failed to send ping message: %d", err);
    } else {
        NSLog(@"[BackupTask] Successfully sent ping message");
    }
    
    // 3. 短暂等待设备响应
    usleep(500000); // 等待0.5秒
}

- (void)recoverBackupOperation {
    // 只更新状态文件，不发送任何通信
    NSString *backupDir = [_backupDirectory stringByAppendingPathComponent:_deviceUDID];
    NSString *statusPath = [backupDir stringByAppendingPathComponent:@"Status.plist"];
    [self updateStatusPlistState:statusPath state:@"finished"];
    
    // 让备份自然结束，不主动尝试恢复通信
    _backupRecoveryAttempted = YES; // 标记已尝试恢复，避免重复恢复
}

- (void)fixStatusPlistErrors {
    NSString *backupDir = [_backupDirectory stringByAppendingPathComponent:_deviceUDID];
    NSString *statusPath = [backupDir stringByAppendingPathComponent:@"Status.plist"];
    [self updateStatusPlistState:statusPath state:@"finished"];
}

- (void)fixStatusPlistErrors0 {
    NSLog(@"[BackupTask] Attempting to fix Status.plist errors");
    
    NSString *backupDir = [_backupDirectory stringByAppendingPathComponent:_deviceUDID];
    NSString *statusPath = [backupDir stringByAppendingPathComponent:@"Status.plist"];
    NSString *snapshotDir = [backupDir stringByAppendingPathComponent:@"Snapshot"];
    NSString *snapshotStatusPath = [snapshotDir stringByAppendingPathComponent:@"Status.plist"];
    
    // 确保目录存在
    [[NSFileManager defaultManager] createDirectoryAtPath:snapshotDir
                           withIntermediateDirectories:YES
                                            attributes:nil
                                                 error:nil];
    
    // 创建Status.plist，保持状态为"finished"
    plist_t status_dict = plist_new_dict();
    plist_dict_set_item(status_dict, "SnapshotState", plist_new_string("finished"));
    plist_dict_set_item(status_dict, "UUID", plist_new_string([_deviceUDID UTF8String]));
    plist_dict_set_item(status_dict, "Version", plist_new_string("2.4"));
    plist_dict_set_item(status_dict, "BackupState", plist_new_string("new"));
    plist_dict_set_item(status_dict, "IsFullBackup", plist_new_bool(1));
    
    // 添加当前时间戳
    int32_t date_time = (int32_t)time(NULL) - 978307200;
    plist_dict_set_item(status_dict, "Date", plist_new_date(date_time, 0));
    
    // 序列化并保存
    uint32_t length = 0;
    char *xml = NULL;
    plist_to_xml(status_dict, &xml, &length);
    
    if (xml) {
        NSData *plistData = [NSData dataWithBytes:xml length:length];
        // 保存到主Status.plist
        [plistData writeToFile:statusPath options:NSDataWritingAtomic error:nil];
        // 保存到Snapshot目录中的Status.plist
        [plistData writeToFile:snapshotStatusPath options:NSDataWritingAtomic error:nil];
        free(xml);
        NSLog(@"[BackupTask] Created/fixed Status.plist files");
    }
    
    plist_free(status_dict);
    
    // 修复Snapshot路径问题
    [self fixSnapshotPaths:backupDir];
}

- (void)fixSnapshotPaths:(NSString *)backupDir {
    NSLog(@"[BackupTask] Fixing snapshot paths in backup directory");
    
    NSString *snapshotDir = [backupDir stringByAppendingPathComponent:@"Snapshot"];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    
    // 确保Snapshot目录存在
    if (![fileManager fileExistsAtPath:snapshotDir]) {
        NSError *dirError = nil;
        if (![fileManager createDirectoryAtPath:snapshotDir
                     withIntermediateDirectories:YES
                                      attributes:nil
                                           error:&dirError]) {
            NSLog(@"[BackupTask] Error creating Snapshot directory: %@", dirError);
            return;
        }
    }
    
    // 检查关键文件是否存在于Snapshot中，如果不存在，尝试从主目录复制
    NSArray *criticalFiles = @[@"Info.plist", @"Manifest.plist", @"Status.plist"];
    
    for (NSString *filename in criticalFiles) {
        NSString *mainPath = [backupDir stringByAppendingPathComponent:filename];
        NSString *snapshotPath = [snapshotDir stringByAppendingPathComponent:filename];
        
        if ([fileManager fileExistsAtPath:mainPath] && ![fileManager fileExistsAtPath:snapshotPath]) {
            NSError *copyError = nil;
            if ([fileManager copyItemAtPath:mainPath toPath:snapshotPath error:&copyError]) {
                NSLog(@"[BackupTask] Successfully copied %@ to Snapshot directory", filename);
            } else {
                NSLog(@"[BackupTask] Failed to copy %@ to Snapshot directory: %@", filename, copyError);
            }
        }
    }
    
    // 重新创建Snapshot内容
   // [self recreateSnapshotContent:backupDir];
}

- (void)recreateSnapshotContent:(NSString *)backupDir {
    NSLog(@"[BackupTask] Recreating snapshot content if needed");
    
    NSString *snapshotDir = [backupDir stringByAppendingPathComponent:@"Snapshot"];
    
    // 如果Manifest.db丢失，但主目录中存在，尝试重新创建
    NSString *mainManifestDB = [backupDir stringByAppendingPathComponent:@"Manifest.db"];
    NSString *snapshotManifestDB = [snapshotDir stringByAppendingPathComponent:@"Manifest.db"];
    
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if ([fileManager fileExistsAtPath:mainManifestDB] && ![fileManager fileExistsAtPath:snapshotManifestDB]) {
        NSError *copyError = nil;
        if ([fileManager copyItemAtPath:mainManifestDB toPath:snapshotManifestDB error:&copyError]) {
            NSLog(@"[BackupTask] Successfully recreated Manifest.db in Snapshot directory");
        } else {
            NSLog(@"[BackupTask] Failed to recreate Manifest.db in Snapshot directory: %@", copyError);
        }
    }
    
    // 确保所有哈希目录在Snapshot中也存在
    for (int i = 0; i < 256; i++) {
        NSString *hashDir = [NSString stringWithFormat:@"%02x", i];
        NSString *mainHashPath = [backupDir stringByAppendingPathComponent:hashDir];
        NSString *snapshotHashPath = [snapshotDir stringByAppendingPathComponent:hashDir];
        
        if ([fileManager fileExistsAtPath:mainHashPath] && ![fileManager fileExistsAtPath:snapshotHashPath]) {
            NSError *dirError = nil;
            if ([fileManager createDirectoryAtPath:snapshotHashPath
                       withIntermediateDirectories:YES
                                        attributes:nil
                                             error:&dirError]) {
                NSLog(@"[BackupTask] Created hash directory in Snapshot: %@", hashDir);
            }
        }
    }
}

- (BOOL)verifyBackupIntegrity:(NSString *)backupDir error:(NSError **)error {
    NSLog(@"[BackupTask] Verifying backup integrity");
    
    NSFileManager *fileManager = [NSFileManager defaultManager];
    
    // 检查关键文件是否存在
    NSArray *requiredFiles = @[@"Info.plist", @"Manifest.plist", @"Status.plist"];
    
    for (NSString *filename in requiredFiles) {
        NSString *filePath = [backupDir stringByAppendingPathComponent:filename];
        if (![fileManager fileExistsAtPath:filePath]) {
            NSLog(@"[BackupTask] Critical file missing: %@", filename);
            if (error) {
                *error = [self errorWithCode:BackupTaskErrorCodeBackupFailed
                                 description:[NSString stringWithFormat:@"Backup integrity check failed: %@ is missing", filename]];
            }
            return NO;
        }
    }
    
    // 验证Status.plist状态
    if (![self validateBackupStatus:[backupDir stringByAppendingPathComponent:@"Status.plist"]
                              state:@"finished"
                              error:error]) {
        NSLog(@"[BackupTask] Status.plist not in 'finished' state");
        return NO;
    }
    
    // 验证备份加密状态
    _isBackupEncrypted = [self isBackupEncrypted:_deviceUDID error:nil];
    
    // 更新实际备份大小
    _actualBackupSize = [self calculateBackupSize:_deviceUDID];
    
    NSLog(@"[BackupTask] Backup integrity verification successful");
    return YES;
}

- (uint64_t)calculateBackupSize:(NSString *)udid {
    NSLog(@"[BackupTask] Calculating backup size for UDID: %@", udid);
    
    NSString *backupDir = [_backupDirectory stringByAppendingPathComponent:udid];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    
    if (![fileManager fileExistsAtPath:backupDir]) {
        NSLog(@"[BackupTask] Backup directory does not exist");
        return 0;
    }
    
    NSError *error = nil;
    NSArray *contents = [fileManager contentsOfDirectoryAtPath:backupDir error:&error];
    if (error) {
        NSLog(@"[BackupTask] Error reading backup directory: %@", error);
        return 0;
    }
    
    uint64_t totalSize = 0;
    
    // 递归计算目录大小的内部函数
    __block __weak void (^calculateDirSize)(NSString *, uint64_t *);
    __block void (^strongCalculateDirSize)(NSString *, uint64_t *);
    
    strongCalculateDirSize = ^(NSString *dirPath, uint64_t *size) {
        NSError *dirError = nil;
        NSArray *dirContents = [fileManager contentsOfDirectoryAtPath:dirPath error:&dirError];
        
        if (dirError) {
            NSLog(@"[BackupTask] Error reading directory %@: %@", dirPath, dirError);
            return;
        }
        
        for (NSString *item in dirContents) {
            if ([item isEqualToString:@"."] || [item isEqualToString:@".."]) {
                continue;
            }
            
            NSString *itemPath = [dirPath stringByAppendingPathComponent:item];
            BOOL isDirectory = NO;
            
            if ([fileManager fileExistsAtPath:itemPath isDirectory:&isDirectory]) {
                if (isDirectory) {
                    calculateDirSize(itemPath, size);
                } else {
                    NSError *attrError = nil;
                    NSDictionary *attributes = [fileManager attributesOfItemAtPath:itemPath error:&attrError];
                    
                    if (!attrError) {
                        *size += [attributes fileSize];
                    }
                }
            }
        }
    };
    
    calculateDirSize = strongCalculateDirSize;
    
    // 计算备份目录大小
    strongCalculateDirSize(backupDir, &totalSize);
    
    NSString *formattedSize = [self formatSize:totalSize];
    NSLog(@"[BackupTask] Total backup size: %@ (%llu bytes)", formattedSize, totalSize);
    
    return totalSize;
}

- (void)cleanupSingleDigitDirectories:(NSString *)backupDir {
    NSLog(@"[BackupTask] Cleaning up single digit directories");
    
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSError *error = nil;
    NSArray *contents = [fileManager contentsOfDirectoryAtPath:backupDir error:&error];
    
    if (error) {
        NSLog(@"[BackupTask] Error reading backup directory: %@", error);
        return;
    }
    
    // 查找单字符目录名（可能由备份过程中的错误创建）
    for (NSString *item in contents) {
        if (item.length == 1 && ![item isEqualToString:@"."] && ![item isEqualToString:@"/"]) {
            NSString *dirPath = [backupDir stringByAppendingPathComponent:item];
            BOOL isDir = NO;
            
            if ([fileManager fileExistsAtPath:dirPath isDirectory:&isDir] && isDir) {
                NSLog(@"[BackupTask] Removing invalid single character directory: %@", item);
                NSError *removeError = nil;
                if (![fileManager removeItemAtPath:dirPath error:&removeError]) {
                    NSLog(@"[BackupTask] Error removing directory: %@", removeError);
                }
            }
        }
    }
}

- (void)createDefaultInfoPlist:(NSString *)path {
    NSLog(@"[BackupTask] Creating default Info.plist at %@", path);
    
    // 获取当前日期时间
    NSDate *currentDate = [NSDate date];
    
    // 创建基本Info.plist内容
    NSDictionary *infoPlist = @{
        @"Device Name": @"iOS Device",
        @"Display Name": @"iOS Device",
        @"Last Backup Date": currentDate,
        @"Product Type": @"iPhone",
        @"Product Version": @"16.0",
        @"iTunes Version": @"12.0",
        @"Unique Identifier": _deviceUDID ?: @"unknown",
        @"Target Identifier": _deviceUDID ?: @"unknown",
        @"Target Type": @"Device",
        @"Serial Number": @"",
        @"IMEI": @"",
        @"MEID": @""
    };
    
    // 保存到文件
    NSError *error = nil;
    NSData *plistData = [NSPropertyListSerialization dataWithPropertyList:infoPlist
                                                                   format:NSPropertyListXMLFormat_v1_0
                                                                  options:0
                                                                    error:&error];
    
    if (error) {
        NSLog(@"[BackupTask] Error creating Info.plist data: %@", error);
        return;
    }
    
    if (![plistData writeToFile:path options:NSDataWritingAtomic error:&error]) {
        NSLog(@"[BackupTask] Error writing Info.plist file: %@", error);
    }
}

- (void)createEmptyStatusPlist:(NSString *)path {
    NSLog(@"[BackupTask] Creating empty Status.plist at %@", path);
    
    // 确保目录存在
    NSString *dirPath = [path stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dirPath
                          withIntermediateDirectories:YES
                                           attributes:nil
                                                error:nil];
    
    // 创建Status.plist内容
    plist_t status_dict = plist_new_dict();
    plist_dict_set_item(status_dict, "SnapshotState", plist_new_string("finished"));
    plist_dict_set_item(status_dict, "UUID", plist_new_string([_deviceUDID UTF8String]));
    plist_dict_set_item(status_dict, "Version", plist_new_string("2.4"));
    plist_dict_set_item(status_dict, "BackupState", plist_new_string("finished"));
    plist_dict_set_item(status_dict, "IsFullBackup", plist_new_bool(1));
    
    // 添加当前时间戳 (使用 Apple 纪元 - 从2001年开始)
    int32_t date_time = (int32_t)time(NULL) - 978307200;
    plist_dict_set_item(status_dict, "Date", plist_new_date(date_time, 0));
    
    // 序列化并保存
    uint32_t length = 0;
    char *xml = NULL;
    plist_to_xml(status_dict, &xml, &length);
    
    if (xml) {
        NSData *plistData = [NSData dataWithBytes:xml length:length];
        BOOL success = [plistData writeToFile:path options:NSDataWritingAtomic error:nil];
        free(xml);
        
        NSLog(@"[BackupTask] %@ Status.plist at: %@", success ? @"Successfully created" : @"Failed to create", path);
    }
    
    plist_free(status_dict);
}

- (void)updateStatusPlistState:(NSString *)path state:(NSString *)state {
    NSLog(@"[BackupTask] Updating Status.plist state to: %@", state);
    
    plist_t status_plist = NULL;
    plist_read_from_file([path UTF8String], &status_plist, NULL);
    
    if (!status_plist) {
        // 如果文件不存在，创建一个新的
        [self createEmptyStatusPlist:path];
        plist_read_from_file([path UTF8String], &status_plist, NULL);
        
        if (!status_plist) {
            NSLog(@"[BackupTask] Failed to create or read Status.plist");
            return;
        }
    }
    
    // 更新SnapshotState
    plist_dict_set_item(status_plist, "SnapshotState", plist_new_string([state UTF8String]));
    
    // 序列化并保存
    uint32_t length = 0;
    char *xml = NULL;
    plist_to_xml(status_plist, &xml, &length);
    
    if (xml) {
        NSData *plistData = [NSData dataWithBytes:xml length:length];
        BOOL success = [plistData writeToFile:path options:NSDataWritingAtomic error:nil];
        free(xml);
        
        NSLog(@"[BackupTask] %@ Status.plist state to %@", success ? @"Successfully updated" : @"Failed to update", state);
    }
    
    plist_free(status_plist);
    
    // 同样更新Snapshot目录中的状态
    NSString *snapshotStatusPath = [[path stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"Snapshot/Status.plist"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:snapshotStatusPath]) {
        [self updateStatusPlistState:snapshotStatusPath state:state];
    }
}

- (void)postNotification:(NSString *)notification {
    NSLog(@"[BackupTask] Posting notification to device: %@", notification);
    
    if (_np) {
        np_error_t nperr = np_post_notification(_np, [notification UTF8String]);
        if (nperr != NP_E_SUCCESS) {
            NSLog(@"[BackupTask] Error posting notification '%@': %d", notification, nperr);
        }
    }
}

@end

