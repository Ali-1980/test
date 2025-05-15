//
//  BackupTask.m
//  iOSBackupManager
//
//  Created based on libimobiledevice
//

#import "BackupTask.h"


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

// 定义常量
NSString * const kBackupTaskErrorDomain = @"com.example.BackupTaskErrorDomain";
NSString * const kNPSyncWillStart = @"com.apple.itunes.backup.willStart";
NSString * const kNPSyncLockRequest = @"com.apple.itunes.backup.lockRequest";
NSString * const kNPSyncDidStart = @"com.apple.itunes.backup.didStart";
NSString * const kNPSyncCancelRequest = @"com.apple.itunes.backup.cancelRequest";
NSString * const kNPBackupDomainChanged = @"com.apple.mobile.backup.domainChanged";

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
    
    // 备份过程变量
    uint64_t _lockfile;
    double _overall_progress;
    NSString *_currentOperationDescription;
    uint64_t _currentBytes;
    uint64_t _totalBytes;
}

// 内部设置状态的方法
- (void)setInternalStatus:(BackupTaskStatus)status;

@end

@implementation BackupTask

@synthesize status = _status;
@synthesize progress = _progress;
@synthesize lastError = _lastError;

#pragma mark - 单例实现

+ (instancetype)sharedInstance {
    static BackupTask *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

#pragma mark - 初始化和清理

- (instancetype)init {
    self = [super init];
    if (self) {
        _status = BackupTaskStatusIdle;
        _progress = 0.0;
        _operationQueue = dispatch_queue_create("com.example.backuptask.operation", DISPATCH_QUEUE_SERIAL);
        _operating = NO;
        _cancelRequested = NO;
        _backupDomainChanged = NO;
        _passcodeRequested = NO;
        _currentOperationDescription = @"Idle";
        
        // 设置默认值
        _backupDirectory = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Backups"];
        _useNetwork = NO;
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
        _progress = progress;
        _currentOperationDescription = operation;
        _currentBytes = current;
        _totalBytes = total;
        
        NSLog(@"[BackupTask] Progress: %.2f%% - %@ (%llu/%llu bytes)",
              progress, operation ?: @"", current, total);
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.progressCallback) {
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
    
    // 保存回调
    self.progressCallback = ^(float progress, NSString *operation, uint64_t current, uint64_t total) {
        if (progressBlock) {
            progressBlock(progress, operation);
        }
    };
    
    self.completionCallback = ^(BOOL success, BackupTaskMode mode, NSError *error) {
        if (completionBlock) {
            completionBlock(success, error);
        }
    };
    
    // 设置设备ID
    self.deviceUDID = deviceUDID;
    
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
        [self setInternalStatus:BackupTaskStatusPreparing];
        
        NSLog(@"[BackupTask] Starting operation in mode: %ld", (long)mode);
        
        // 执行前基本验证
        if (!_backupDirectory || [_backupDirectory length] == 0) {
            if (error) {
                *error = [self errorWithCode:BackupTaskErrorCodeInvalidArg
                                 description:@"No backup directory specified"];
            }
            _operating = NO;
            [self setInternalStatus:BackupTaskStatusIdle];
            return NO;
        }
        
        // 确保备份目录存在
        if (mode != BackupTaskModeErase && mode != BackupTaskModeCloud &&
            mode != BackupTaskModeChangePw) {
            NSFileManager *fileManager = [NSFileManager defaultManager];
            BOOL isDirectory = NO;
            if (![fileManager fileExistsAtPath:_backupDirectory isDirectory:&isDirectory] || !isDirectory) {
                NSError *dirError = nil;
                if (![fileManager createDirectoryAtPath:_backupDirectory
                               withIntermediateDirectories:YES
                                                attributes:nil
                                                     error:&dirError]) {
                    if (error) {
                        *error = [self errorWithCode:BackupTaskErrorCodeInvalidBackupDirectory
                                         description:[NSString stringWithFormat:@"Could not create backup directory: %@",
                                                      dirError.localizedDescription]];
                    }
                    _operating = NO;
                    [self setInternalStatus:BackupTaskStatusIdle];
                    return NO;
                }
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
    
    self.backupPassword = password;
    
    return [self startOperationWithMode:BackupTaskModeChangePw error:error];
}

- (BOOL)changeBackupPassword:(NSString *)oldPassword newPassword:(NSString *)newPassword error:(NSError **)error {
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
    
    NSLog(@"[BackupTask] Device backup encryption is %@", willEncrypt ? @"enabled" : @"disabled");
    
    // 6. 获取设备版本信息
    char *product_version = NULL;
    node_tmp = NULL;
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
        free(product_version);
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
    
    // 11. 协议版本协商
    double local_versions[2] = {2.0, 2.1};
    double remote_version = 0.0;
    mobilebackup2_error_t err = mobilebackup2_version_exchange(_mobilebackup2, local_versions, 2, &remote_version);
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

#pragma mark - 实现各种操作

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
    
    // 当设备已启用备份加密，但未提供密码时
    int passwordAttempts = 0;
    const int MAX_PASSWORD_ATTEMPTS = 3;
    BOOL passwordVerified = NO;
    
    // 确保在设备已加密时请求密码
    if (isEncrypted) {
        NSLog(@"[BackupTask] 设备备份已加密，需要输入密码");
        
        // 密码验证循环
        while (!passwordVerified && passwordAttempts < MAX_PASSWORD_ATTEMPTS) {
            if (!_backupPassword) {
                if (_interactiveMode && self.passwordRequestCallback) {
                    NSString *message = (passwordAttempts == 0) ?
                        @"设备备份已加密，请输入备份密码" :
                        [NSString stringWithFormat:@"密码不正确，请重新输入（尝试 %d/%d）",
                            passwordAttempts + 1, MAX_PASSWORD_ATTEMPTS];
                    
                    // 提示用户输入密码
                    _backupPassword = self.passwordRequestCallback(message, NO);
                }
                
                if (!_backupPassword) {
                    if (error) {
                        *error = [self errorWithCode:BackupTaskErrorCodeMissingPassword
                                        description:@"备份已加密但未提供密码"];
                    }
                    return NO;
                }
            }
            
            // 验证密码
            NSLog(@"[BackupTask] 正在验证备份密码...");
            if ([self verifyBackupPassword:_backupPassword error:error]) {
                passwordVerified = YES;
                NSLog(@"[BackupTask] 备份密码验证成功");
            } else {
                NSLog(@"[BackupTask] 备份密码验证失败");
                _backupPassword = nil; // 清除密码以便重新请求
                passwordAttempts++;
                
                // 如果已达到最大尝试次数，返回错误
                if (passwordAttempts >= MAX_PASSWORD_ATTEMPTS) {
                    if (error) {
                        *error = [self errorWithCode:BackupTaskErrorCodeWrongPassword
                                        description:@"密码尝试次数过多，备份已中止。"];
                    }
                    return NO;
                }
            }
        }
    }
    
    // 1. 发送准备通知
    [self postNotification:kNPSyncWillStart];
    
    // 2. 创建备份锁
    if (_afc) {
        afc_file_open(_afc, "/com.apple.itunes.lock_sync", AFC_FOPEN_RW, &_lockfile);
        if (_lockfile) {
            [self postNotification:kNPSyncLockRequest];
            
            // 尝试获取锁
            for (int i = 0; i < LOCK_ATTEMPTS; i++) {
                afc_error_t aerr = afc_file_lock(_afc, _lockfile, AFC_LOCK_EX);
                if (aerr == AFC_E_SUCCESS) {
                    [self postNotification:kNPSyncDidStart];
                    break;
                }
                if (aerr == AFC_E_OP_WOULD_BLOCK) {
                    usleep(LOCK_WAIT);
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
    
    // 3. 确保设备备份目录存在
    NSString *devBackupDir = [_backupDirectory stringByAppendingPathComponent:_sourceUDID];
    BOOL isDir;
    if (![[NSFileManager defaultManager] fileExistsAtPath:devBackupDir isDirectory:&isDir] || !isDir) {
        NSLog(@"[BackupTask] Creating backup directory: %@", devBackupDir);
        NSError *dirError = nil;
        if (![[NSFileManager defaultManager] createDirectoryAtPath:devBackupDir
                                     withIntermediateDirectories:YES
                                                      attributes:nil
                                                           error:&dirError]) {
            NSLog(@"[BackupTask] Error creating backup directory: %@", dirError);
            if (error) {
                *error = [self errorWithCode:BackupTaskErrorCodeInvalidBackupDirectory
                                 description:[NSString stringWithFormat:@"Could not create backup directory: %@",
                                             dirError.localizedDescription]];
            }
            return NO;
        }
    }
    
    // 添加：创建初始状态文件
    NSString *statusPath = [devBackupDir stringByAppendingPathComponent:@"Status.plist"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:statusPath]) {
        // 创建初始状态文件
        plist_t status_dict = plist_new_dict();
        plist_dict_set_item(status_dict, "SnapshotState", plist_new_string("new"));
        plist_dict_set_item(status_dict, "UUID", plist_new_string([_deviceUDID UTF8String]));
        
        // 添加当前日期 (从2001年开始，苹果的Mac纪元)
        int32_t date_time = (int32_t)time(NULL) - 978307200;
        plist_dict_set_item(status_dict, "Date", plist_new_date(date_time, 0));
        
        uint32_t length = 0;
        char *xml = NULL;
        plist_to_xml(status_dict, &xml, &length);
        if (xml) {
            NSData *plistData = [NSData dataWithBytes:xml length:length];
            BOOL writeSuccess = [plistData writeToFile:statusPath atomically:YES];
            free(xml);
            
            if (writeSuccess) {
                NSLog(@"[BackupTask] Created initial Status.plist at: %@", statusPath);
            } else {
                NSLog(@"[BackupTask] Failed to write Status.plist to: %@", statusPath);
            }
        }
        plist_free(status_dict);
    } else {
        NSLog(@"[BackupTask] Status.plist already exists at: %@", statusPath);
    }
    
    // 验证不会在错误的路径创建 Status.plist
    NSString *wrongPath = [devBackupDir stringByAppendingPathComponent:[_deviceUDID stringByAppendingPathComponent:@"Status.plist"]];
    if ([[NSFileManager defaultManager] fileExistsAtPath:wrongPath]) {
        NSLog(@"[BackupTask] Warning: Status.plist found at incorrect path: %@", wrongPath);
        NSError *removeError;
        if ([[NSFileManager defaultManager] removeItemAtPath:wrongPath error:&removeError]) {
            NSLog(@"[BackupTask] Removed duplicate Status.plist file at incorrect path");
        } else {
            NSLog(@"[BackupTask] Failed to remove duplicate Status.plist: %@", removeError);
        }
    }
    
    if (![_sourceUDID isEqualToString:_deviceUDID]) {
        // 处理不同源备份目录
        NSString *targetBackupDir = [_backupDirectory stringByAppendingPathComponent:_deviceUDID];
        [[NSFileManager defaultManager] createDirectoryAtPath:targetBackupDir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
    }
    
    // 4. 创建选项
    plist_t opts = NULL;
    if (_options & BackupTaskOptionForceFullBackup) {
        NSLog(@"[BackupTask] Enforcing full backup from device");
        opts = plist_new_dict();
        plist_dict_set_item(opts, "ForceFullBackup", plist_new_bool(1));
    }
    
    // 如果备份需要加密，添加密码到选项中
    if (isEncrypted && _backupPassword) {
        if (!opts) {
            opts = plist_new_dict();
        }
        plist_dict_set_item(opts, "Password", plist_new_string([_backupPassword UTF8String]));
        NSLog(@"[BackupTask] Using backup password for encrypted backup");
    }
    
    // 5. 请求备份
    [self updateProgress:5 operation:@"Requesting backup from device" current:5 total:100];
    
    NSLog(@"[BackupTask] Backup %@ and will %sbe encrypted",
          (_options & BackupTaskOptionForceFullBackup) ? @"will be full" : @"may be incremental",
          isEncrypted ? "" : "not ");
    
    _estimatedBackupSize = 0; // 初始化估计备份大小
    _actualBackupSize = 0;    // 初始化实际备份大小
    
    // 发送备份请求
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
    
    // 6. 处理设备上的密码请求
    if (_passcodeRequested) {
        NSLog(@"[BackupTask] Waiting for device passcode entry");
        [self updateProgress:10 operation:@"Waiting for device passcode" current:10 total:100];
    }
    
    // 7. 处理备份消息
    BOOL result = [self processBackupMessages:error];
    
    // 8. 解锁备份锁
    if (_lockfile) {
        afc_file_lock(_afc, _lockfile, AFC_LOCK_UN);
        afc_file_close(_afc, _lockfile);
        _lockfile = 0;
        [self postNotification:kNPSyncDidStart];
    }
    
    return result;
}

// 输入密码

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

// 密码验证方法
- (BOOL)verifyBackupPassword:(NSString *)password error:(NSError **)error {
    NSLog(@"[BackupTask] Verifying backup password");
    
    // 创建临时检查请求
    plist_t opts = plist_new_dict();
    plist_dict_set_item(opts, "Password", plist_new_string([password UTF8String]));
    plist_dict_set_item(opts, "PasswordCheck", plist_new_bool(1));  // 仅检查密码，不执行实际备份
    
    // 发送验证请求
    mobilebackup2_error_t err = mobilebackup2_send_message(_mobilebackup2, "CheckPassword", opts);
    plist_free(opts);
    
    if (err != MOBILEBACKUP2_E_SUCCESS) {
        NSLog(@"[BackupTask] Error sending password check request: %d", err);
        return NO;
    }
    
    // 接收响应
    plist_t response = NULL;
    char *dlmsg = NULL;
    err = mobilebackup2_receive_message(_mobilebackup2, &response, &dlmsg);
    
    if (err != MOBILEBACKUP2_E_SUCCESS || !response) {
        NSLog(@"[BackupTask] Error receiving password check response: %d", err);
        if (dlmsg) free(dlmsg);
        return NO;
    }
    
    BOOL passwordValid = NO;
    
    if (response) {
        // 检查响应消息类型
        char *msg_type = NULL;
        plist_t msg_node = plist_array_get_item(response, 0);
        if (msg_node && (plist_get_node_type(msg_node) == PLIST_STRING)) {
            plist_get_string_val(msg_node, &msg_type);
        }
        
        if (msg_type && strcmp(msg_type, "DLMessagePasswordAccepted") == 0) {
            NSLog(@"[BackupTask] Password accepted");
            passwordValid = YES;
        } else if (msg_type && strcmp(msg_type, "DLMessageProcessMessage") == 0) {
            plist_t dict = plist_array_get_item(response, 1);
            if (dict && plist_get_node_type(dict) == PLIST_DICT) {
                // 检查错误码
                plist_t error_code_node = plist_dict_get_item(dict, "ErrorCode");
                if (error_code_node && plist_get_node_type(error_code_node) == PLIST_UINT) {
                    uint64_t error_code = 0;
                    plist_get_uint_val(error_code_node, &error_code);
                    
                    if (error_code == 0) {
                        passwordValid = YES;
                    } else {
                        // 记录错误信息
                        plist_t error_desc = plist_dict_get_item(dict, "ErrorDescription");
                        if (error_desc && plist_get_node_type(error_desc) == PLIST_STRING) {
                            char *err_str = NULL;
                            plist_get_string_val(error_desc, &err_str);
                            NSLog(@"[BackupTask] Password error: %s (code: %llu)",
                                  err_str ? err_str : "Unknown", error_code);
                            if (err_str) free(err_str);
                        }
                    }
                }
            }
        }
        
        if (msg_type) free(msg_type);
        plist_free(response);
    }
    
    if (dlmsg) free(dlmsg);
    
    return passwordValid;
}

- (BOOL)verifyBackupPasswordAlternative:(NSString *)password error:(NSError **)error {
    NSLog(@"[BackupTask] Verifying backup password (alternative method)");
    
    // 验证加密备份的密码有两种常见方法：
    // 1. 尝试解密现有的 Manifest.db 文件 (如果有)
    NSString *manifestPath = [_backupDirectory stringByAppendingPathComponent:
                             [_deviceUDID stringByAppendingPathComponent:@"Manifest.db"]];
    
    if ([[NSFileManager defaultManager] fileExistsAtPath:manifestPath]) {
        // 尝试使用 SQLite 打开加密的数据库，这需要使用 SQLCipher 或类似库
        // 这里我们模拟这个过程
        
        if ([password isEqualToString:@"testpassword"]) {  // 替换为实际验证逻辑
            return YES;
        }
    }
    
    // 2. 如果还没有备份文件，我们可以向设备发送一个带密码的测试请求
    // 创建一个临时目录请求 - 如果密码正确，这个请求会成功
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
                        
                        // 密码错误通常有特定的错误代码，例如 -6 或类似的代码
                        if (error_code != 0) {
                            NSLog(@"[BackupTask] Password error detected: %llu", error_code);
                            passwordValid = NO;
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
    }
    
    return passwordValid;
}


- (BOOL)performRestore:(NSError **)error {
    NSLog(@"[BackupTask] Starting restore operation");
    [self updateProgress:0 operation:@"Starting restore" current:0 total:100];
    
    // 1. 获取加密状态信息
    BOOL isEncrypted = [self isBackupEncrypted:_sourceUDID error:error];
    if (isEncrypted && !_backupPassword) {
        if (_interactiveMode && self.passwordRequestCallback) {
            _backupPassword = self.passwordRequestCallback(@"Enter backup password", NO);
        }
        
        if (!_backupPassword) {
            if (error) {
                *error = [self errorWithCode:BackupTaskErrorCodeMissingPassword
                                 description:@"Backup is encrypted but no password provided"];
            }
            return NO;
        }
    }
    
    // 2. 验证备份状态 - 确保从成功的备份中恢复
    if (![self verifyBackupStatus:_sourceUDID state:@"finished" error:error]) {
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
            for (int i = 0; i < LOCK_ATTEMPTS; i++) {
                afc_error_t aerr = afc_file_lock(_afc, _lockfile, AFC_LOCK_EX);
                if (aerr == AFC_E_SUCCESS) {
                    [self postNotification:kNPSyncDidStart];
                    break;
                }
                if (aerr == AFC_E_OP_WOULD_BLOCK) {
                    usleep(LOCK_WAIT);
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
    if (_backupPassword != nil) {
        plist_dict_set_item(opts, "Password", plist_new_string([_backupPassword UTF8String]));
        NSLog(@"[BackupTask] Using backup password: Yes");
    }
    
    // 6. 准备RestoreApplications.plist
    if (!(_options & BackupTaskOptionRestoreSkipApps)) {
        // 读取Info.plist
        NSString *infoPath = [_backupDirectory stringByAppendingPathComponent:[_sourceUDID stringByAppendingPathComponent:@"Info.plist"]];
        plist_t info_plist = NULL;
        plist_read_from_file([infoPath UTF8String], &info_plist, NULL);
        
        if (info_plist) {
            [self writeRestoreApplications:info_plist error:error];
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
            }
            
            if (!_backupPassword) {
                if (error) {
                    *error = [self errorWithCode:BackupTaskErrorCodeMissingPassword
                                     description:@"Backup is encrypted but no password provided"];
                }
                return NO;
            }
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
                }
                
                if (!_backupNewPassword) {
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
                }
                
                if (!_backupPassword) {
                    if (error) {
                        *error = [self errorWithCode:BackupTaskErrorCodeMissingPassword
                                         description:@"Current backup password required but not provided"];
                    }
                    plist_free(opts);
                    return NO;
                }
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
                }
                
                if (!_backupPassword) {
                    if (error) {
                        *error = [self errorWithCode:BackupTaskErrorCodeMissingPassword
                                         description:@"Current backup password required but not provided"];
                    }
                    plist_free(opts);
                    return NO;
                }
            }
            
            if (!_backupNewPassword) {
                if (_interactiveMode && self.passwordRequestCallback) {
                    _backupNewPassword = self.passwordRequestCallback(@"Enter new backup password", YES);
                }
                
                if (!_backupNewPassword) {
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

- (BOOL)verifyBackupStatus:(NSString *)udid state:(NSString *)state error:(NSError **)error {
    NSString *statusPath = [_backupDirectory stringByAppendingPathComponent:[udid stringByAppendingPathComponent:@"Status.plist"]];
    
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

- (void)postNotification:(NSString *)notification {
    if (!_device || !notification) {
        return;
    }
    
    NSLog(@"[BackupTask] Posting notification: %@", notification);
    
    lockdownd_client_t lockdown = NULL;
    if (lockdownd_client_new_with_handshake(_device, &lockdown, "iOSBackupManager") != LOCKDOWN_E_SUCCESS) {
        return;
    }
    
    lockdownd_service_descriptor_t service = NULL;
    lockdownd_error_t ldret = lockdownd_start_service(lockdown, "com.apple.mobile.notification_proxy", &service);
    if (ldret == LOCKDOWN_E_SUCCESS && service && service->port) {
        np_client_t np = NULL;
        np_client_new(_device, service, &np);
        if (np) {
            np_post_notification(np, [notification UTF8String]);
            np_client_free(np);
        }
    }
    
    if (service) {
        lockdownd_service_descriptor_free(service);
    }
    
    lockdownd_client_free(lockdown);
}

- (BOOL)writeRestoreApplications:(plist_t)info_plist error:(NSError **)error {
    if (!_afc || !info_plist) {
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
    if (afc_err != AFC_E_SUCCESS || !restore_applications_file) {
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
    if (afc_err != AFC_E_SUCCESS || bytes_written != applications_plist_xml_length) {
        NSLog(@"[BackupTask] Error writing /iTunesRestore/RestoreApplications.plist, error code %d, wrote %u of %u bytes",
              afc_err, bytes_written, applications_plist_xml_length);
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
    const NSTimeInterval TIMEOUT_INTERVAL = 60.0; // 60秒超时
    
    // 消息处理循环
    do {
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
            NSLog(@"[BackupTask] Operation timed out after %.1f seconds of inactivity",
                 currentTime - lastActivityTime);
            if (error) {
                *error = [self errorWithCode:BackupTaskErrorCodeOperationFailed
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
            if (operation_ok && [self verifyBackupStatus:_deviceUDID state:@"finished" error:NULL]) {
                // 计算最终备份大小
                uint64_t finalSize = [self calculateBackupSize:_deviceUDID];
                _actualBackupSize = finalSize;
                
                // 检查备份加密状态
                BOOL finalEncrypted = [self isBackupEncrypted:_deviceUDID error:NULL];
                _isBackupEncrypted = finalEncrypted;
                
                NSString *sizeStr = [self formatSize:finalSize];
                NSLog(@"[BackupTask] Backup successful - %d files, %@ %@, completed in %.1f seconds",
                      file_count, sizeStr,
                      finalEncrypted ? @"(encrypted)" : @"(not encrypted)",
                      totalTime);
                
                [self updateProgress:100
                          operation:[NSString stringWithFormat:@"Backup completed successfully (%@%@)",
                                     sizeStr,
                                     finalEncrypted ? @", encrypted" : @""]
                            current:100
                              total:100];
                              
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

// 新增备份大小计算方法
- (uint64_t)calculateBackupSize:(NSString *)udid {
    NSString *backupPath = [_backupDirectory stringByAppendingPathComponent:udid];
    return [self calculateDirectorySize:backupPath];
}

- (uint64_t)calculateDirectorySize:(NSString *)directoryPath {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    BOOL isDir = NO;
    
    if (![fileManager fileExistsAtPath:directoryPath isDirectory:&isDir] || !isDir) {
        return 0;
    }
    
    NSError *error = nil;
    NSArray *contents = [fileManager contentsOfDirectoryAtPath:directoryPath error:&error];
    if (error) {
        NSLog(@"[BackupTask] Error reading directory %@: %@", directoryPath, error);
        return 0;
    }
    
    uint64_t size = 0;
    
    for (NSString *item in contents) {
        if ([item hasPrefix:@"."])
            continue; // 跳过隐藏文件
            
        NSString *itemPath = [directoryPath stringByAppendingPathComponent:item];
        BOOL isDirectory = NO;
        
        if ([fileManager fileExistsAtPath:itemPath isDirectory:&isDirectory]) {
            if (isDirectory) {
                size += [self calculateDirectorySize:itemPath];
            } else {
                NSDictionary *attributes = [fileManager attributesOfItemAtPath:itemPath error:nil];
                size += [attributes fileSize];
            }
        }
    }
    
    return size;
}

// 提取备份信息
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
    
    // 添加文件总数估计
    NSString *manifestDBPath = [_backupDirectory stringByAppendingPathComponent:
                               [udid stringByAppendingPathComponent:@"Manifest.db"]];
    if ([[NSFileManager defaultManager] fileExistsAtPath:manifestDBPath]) {
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:manifestDBPath error:nil];
        if (attrs) {
            [info setObject:attrs forKey:@"ManifestDBInfo"];
        }
    }
    
    return info;
}

#pragma mark - DL消息处理方法

- (void)handleSendFiles:(plist_t)message {
    if (!message || plist_get_node_type(message) != PLIST_ARRAY || plist_array_get_size(message) < 2) {
        return;
    }
    
    plist_t files = plist_array_get_item(message, 1);
    uint32_t cnt = plist_array_get_size(files);
    
    plist_t errplist = NULL;
    
    // 处理要发送的文件
    for (uint32_t i = 0; i < cnt; i++) {
        if (_cancelRequested) {
            break;
        }
        
        plist_t val = plist_array_get_item(files, i);
        if (plist_get_node_type(val) != PLIST_STRING) {
            continue;
        }
        
        char *str = NULL;
        plist_get_string_val(val, &str);
        if (!str) {
            continue;
        }
        
        [self sendFile:str toDevice:&errplist];
        free(str);
    }
    
    // 发送终止标记
    uint32_t zero = 0;
    uint32_t sent = 0;
    mobilebackup2_send_raw(_mobilebackup2, (char*)&zero, 4, &sent);
    
    // 发送状态响应
    if (!errplist) {
        plist_t emptydict = plist_new_dict();
        mobilebackup2_send_status_response(_mobilebackup2, 0, NULL, emptydict);
        plist_free(emptydict);
    } else {
        mobilebackup2_send_status_response(_mobilebackup2, -13, "Multi status", errplist);
        plist_free(errplist);
    }
}


- (BOOL)sendFile:(const char *)path toDevice:(plist_t *)errplist {
    NSLog(@"[BackupTask] Sending file: %s", path);
    
    // 所有变量声明放在函数开头
    uint32_t nlen = 0;
    uint32_t bytes = 0;
    char *localfile = NULL;
    NSString *backupDir = [_backupDirectory stringByAppendingPathComponent:_sourceUDID];
    FILE *f = NULL;
    int errcode = -1;
    int result = -1;
    uint32_t length;
    uint64_t total;
    uint64_t sent;
    size_t pathlen = strlen(path);
    uint32_t pathlen_uint32 = (uint32_t)pathlen;
    struct stat fst;
    NSString *formattedSize;
    char buf[32768];
    size_t r;
    float progress;
    NSString *operation;
    char *errdesc;
    size_t errdesc_len;
    uint32_t errdesc_len_uint32;
    plist_t filedict;
    char resultBuf[5];
    char *error_buf;
    mobilebackup2_error_t err;
    plist_t temp_plist = NULL;
    char *xml_data = NULL;
    uint32_t xml_length = 0;
    BOOL is_status_plist = (strstr(path, "Status.plist") != NULL);
    
    // 路径检查和修正
    NSString *requestedPath = [NSString stringWithUTF8String:path];
    NSString *filePath;
    const char *send_path = path; // 默认使用原始路径发送回设备
    
    // 检查路径中是否包含设备 UDID
    if ([requestedPath hasPrefix:_sourceUDID]) {
        // 如果路径已经包含 UDID，用于本地查找时去掉 UDID
        filePath = [backupDir stringByAppendingPathComponent:[requestedPath substringFromIndex:[_sourceUDID length] + 1]];
        NSLog(@"[BackupTask] Path contains UDID, using local path: %@", filePath);
        
        // 关键修改：发送回设备时去掉 UDID 前缀
        // 例如：设备请求 "00008030-0008352034B9802E/Status.plist"，但我们只发送 "Status.plist"
        if (is_status_plist) {
            // 特殊处理 Status.plist，只发送文件名部分
            send_path = "Status.plist";
            pathlen = strlen(send_path);
            pathlen_uint32 = (uint32_t)pathlen;
            NSLog(@"[BackupTask] Sending modified path to device: %s", send_path);
        }
    } else {
        // 否则正常拼接路径
        filePath = [backupDir stringByAppendingPathComponent:requestedPath];
        NSLog(@"[BackupTask] Using path for file: %@", filePath);
    }
    
    // 使用修正后的路径
    localfile = strdup([filePath UTF8String]);
    
    // 发送路径长度
    nlen = htonl(pathlen_uint32);
    err = mobilebackup2_send_raw(_mobilebackup2, (const char*)&nlen, sizeof(nlen), &bytes);
    if (err != MOBILEBACKUP2_E_SUCCESS || bytes != sizeof(nlen)) {
        NSLog(@"[BackupTask] Error sending path length");
        errcode = -1;
        goto leave;
    }
    
    // 发送路径 - 使用可能修改过的 send_path
    err = mobilebackup2_send_raw(_mobilebackup2, send_path, pathlen_uint32, &bytes);
    if (err != MOBILEBACKUP2_E_SUCCESS || bytes != pathlen_uint32) {
        NSLog(@"[BackupTask] Error sending path");
        errcode = -1;
        goto leave;
    }
    
    // 获取文件信息
    if (stat(localfile, &fst) < 0) {
        if (errno == ENOENT) {
            NSLog(@"[BackupTask] File not found: %s", localfile);
            
            // 特殊处理Status.plist
            if (is_status_plist) {
                NSLog(@"[BackupTask] Creating default Status.plist content");
                
                // 创建默认Status.plist内容
                temp_plist = plist_new_dict();
                plist_dict_set_item(temp_plist, "SnapshotState", plist_new_string("new"));
                plist_dict_set_item(temp_plist, "UUID", plist_new_string([_deviceUDID UTF8String]));
                
                // 添加当前日期 (从2001年开始，苹果的Mac纪元)
                int32_t date_time = (int32_t)time(NULL) - 978307200;
                plist_dict_set_item(temp_plist, "Date", plist_new_date(date_time, 0));
                
                // 转换为XML
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
                        goto leave;
                    }
                    
                    // 发送XML数据
                    err = mobilebackup2_send_raw(_mobilebackup2, xml_data, xml_length, &bytes);
                    if (err != MOBILEBACKUP2_E_SUCCESS || bytes != xml_length) {
                        NSLog(@"[BackupTask] Error sending file data");
                        free(xml_data);
                        plist_free(temp_plist);
                        errcode = -1;
                        goto leave;
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
                    result = 0;
                    goto leave;
                }
                
                if (temp_plist) {
                    plist_free(temp_plist);
                }
            }
        } else {
            NSLog(@"[BackupTask] stat failed on '%s': %d", localfile, errno);
        }
        errcode = errno;
        goto leave;
    }
    
    // 文件找到，其余代码保持不变
    total = fst.st_size;
    
    formattedSize = [self formatSize:total];
    NSLog(@"[BackupTask] Sending '%s' (%@)", send_path, formattedSize);
    
    if (total == 0) {
        errcode = 0;
        goto leave;
    }
    
    // 打开文件
    f = fopen(localfile, "rb");
    if (!f) {
        NSLog(@"[BackupTask] Error opening local file '%s': %d", localfile, errno);
        errcode = errno;
        goto leave;
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
            goto leave;
        }
        
        // 发送文件内容
        r = fread(buf, 1, sizeof(buf), f);
        if (r <= 0) {
            NSLog(@"[BackupTask] Read error");
            errcode = errno;
            goto leave;
        }
        
        err = mobilebackup2_send_raw(_mobilebackup2, buf, (uint32_t)r, &bytes);
        if (err != MOBILEBACKUP2_E_SUCCESS || bytes != (uint32_t)r) {
            NSLog(@"[BackupTask] Error sending file data: sent only %d of %d bytes", bytes, (int)r);
            errcode = -1;
            goto leave;
        }
        
        sent += r;
        
        // 更新进度
        progress = ((float)sent / (float)total) * 100.0f;
        operation = [NSString stringWithFormat:@"Sending file %s", send_path];
        [self updateProgress:progress operation:operation current:sent total:total];
        
    } while (sent < total);
    
    if (f) {
        fclose(f);
        f = NULL;
    }
    
    errcode = 0;
    result = 0;
    
leave:
    // 发送结果
    if (errcode == 0) {
        result = 0;
        nlen = htonl(1);
        memcpy(resultBuf, &nlen, 4);
        resultBuf[4] = 0x06; // CODE_SUCCESS
        mobilebackup2_send_raw(_mobilebackup2, resultBuf, 5, &bytes);
    } else {
        // 添加错误到错误列表
        if (!*errplist) {
            *errplist = plist_new_dict();
        }
        
        errdesc = strerror(errcode);
        errdesc_len = strlen(errdesc);
        errdesc_len_uint32 = (uint32_t)errdesc_len;
        
        filedict = plist_new_dict();
        plist_dict_set_item(filedict, "DLFileErrorString", plist_new_string(errdesc));
        plist_dict_set_item(filedict, "DLFileErrorCode", plist_new_uint(errcode));
        plist_dict_set_item(*errplist, path, filedict);
        
        // 发送错误响应
        length = errdesc_len_uint32;
        nlen = htonl(length+1);
        error_buf = malloc(4 + 1 + length);
        memcpy(error_buf, &nlen, 4);
        error_buf[4] = 0x0B; // CODE_ERROR_LOCAL
        memcpy(error_buf+5, errdesc, length);
        err = mobilebackup2_send_raw(_mobilebackup2, error_buf, 5+length, &bytes);
        free(error_buf);
    }
    
    if (f) {
        fclose(f);
    }
    
    if (localfile) {
        free(localfile);
    }
    
    return result == 0;
}



- (int)handleReceiveFiles:(plist_t)message {
    if (!message || plist_get_node_type(message) != PLIST_ARRAY || plist_array_get_size(message) < 4) {
        return 0;
    }
    
    NSLog(@"[BackupTask] Handling file receive request");
    NSString *backupDir = [_backupDirectory stringByAppendingPathComponent:_deviceUDID];
    
    // 获取总大小信息
    uint64_t backup_total_size = 0;
    uint64_t backup_real_size = 0;
    plist_t node = plist_array_get_item(message, 3);
    if (plist_get_node_type(node) == PLIST_UINT) {
        plist_get_uint_val(node, &backup_total_size);
    }
    
    if (backup_total_size > 0) {
        NSLog(@"[BackupTask] Receiving files with total size: %llu bytes", backup_total_size);
    }
    
    int file_count = 0;
    int errcode = 0;
    char *errdesc = NULL;
    
    // 接收文件循环
    do {
        if (_cancelRequested) {
            NSLog(@"[BackupTask] File receive cancelled");
            break;
        }
        
        // 接收目录名
        char *dname = NULL;
        uint32_t nlen = [self receiveFilename:&dname];
        if (nlen == 0) {
            if (dname) {
                free(dname);
            }
            break;
        }
        
        // 接收文件名
        char *fname = NULL;
        nlen = [self receiveFilename:&fname];
        if (nlen == 0) {
            if (dname) {
                free(dname);
            }
            if (fname) {
                free(fname);
            }
            break;
        }
        
        // 构建完整路径
        NSString *filePath = [backupDir stringByAppendingPathComponent:[NSString stringWithUTF8String:fname]];
        
        NSLog(@"[BackupTask] Receiving file: %s", fname);
        
        // 获取数据包长度
        uint32_t r = 0;
        mobilebackup2_receive_raw(_mobilebackup2, (char*)&nlen, 4, &r);
        if (r != 4) {
            NSLog(@"[BackupTask] Error receiving code length");
            free(dname);
            free(fname);
            break;
        }
        
        nlen = ntohl(nlen);
        
        // 获取代码类型
        char code = 0;
        char last_code = 0;
        mobilebackup2_receive_raw(_mobilebackup2, &code, 1, &r);
        if (r != 1) {
            NSLog(@"[BackupTask] Error receiving code");
            free(dname);
            free(fname);
            break;
        }
        
        // 删除可能存在的旧文件
        [[NSFileManager defaultManager] removeItemAtPath:filePath error:nil];
        
        // 打开文件准备写入
        FILE *f = fopen([filePath UTF8String], "wb");
        uint32_t blocksize = 0;
        
        // 接收文件内容循环
        while (f && (code == 0x0C)) { // CODE_FILE_DATA
            blocksize = nlen - 1;
            uint32_t bdone = 0;
            
            NSLog(@"[BackupTask] Receiving block of %u bytes for %s", blocksize, fname);
            
            // 接收数据块
            while (bdone < blocksize) {
                char buf[32768];
                uint32_t rlen = (blocksize - bdone) < sizeof(buf) ? (blocksize - bdone) : sizeof(buf);
                
                mobilebackup2_receive_raw(_mobilebackup2, buf, rlen, &r);
                if ((int)r <= 0) {
                    break;
                }
                
                fwrite(buf, 1, r, f);
                bdone += r;
            }
            
            if (bdone == blocksize) {
                backup_real_size += blocksize;
            }
            
            if (backup_total_size > 0) {
                float progress = ((float)backup_real_size / (float)backup_total_size) * 100.0f;
                NSString *operation = [NSString stringWithFormat:@"Receiving file %s", fname];
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
        } else {
            errcode = errno;
            errdesc = strerror(errno);
            NSLog(@"[BackupTask] Error opening '%s' for writing: %s", [filePath UTF8String], errdesc);
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
        
        free(dname);
        free(fname);
        
    } while (1);
    
    // 发送状态响应
    plist_t empty_plist = plist_new_dict();
    mobilebackup2_send_status_response(_mobilebackup2, errcode, errdesc, empty_plist);
    plist_free(empty_plist);
    
    return file_count;
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
    
    if (!message || plist_get_node_type(message) != PLIST_ARRAY || plist_array_get_size(message) < 2) {
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
    
    // 构建完整路径
    NSString *backupDir = [_backupDirectory stringByAppendingPathComponent:_sourceUDID];
    NSString *newPath = [backupDir stringByAppendingPathComponent:[NSString stringWithUTF8String:str]];
    free(str);
    
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
                    // 路径处理：检查是否包含设备 UDID 前缀并处理
                    NSString *newPathStr = [NSString stringWithUTF8String:str];
                    NSString *oldPathStr = [NSString stringWithUTF8String:key];
                    
                    NSString *newPath;
                    NSString *oldPath;
                    
                    // 处理新路径
                    if ([newPathStr hasPrefix:_sourceUDID]) {
                        // 如果包含 UDID 前缀，去掉
                        newPath = [backupDir stringByAppendingPathComponent:[newPathStr substringFromIndex:[_sourceUDID length] + 1]];
                    } else {
                        newPath = [backupDir stringByAppendingPathComponent:newPathStr];
                    }
                    
                    // 处理旧路径
                    if ([oldPathStr hasPrefix:_sourceUDID]) {
                        // 如果包含 UDID 前缀，去掉
                        oldPath = [backupDir stringByAppendingPathComponent:[oldPathStr substringFromIndex:[_sourceUDID length] + 1]];
                    } else {
                        oldPath = [backupDir stringByAppendingPathComponent:oldPathStr];
                    }
                    
                    // 创建必要的目录
                    [[NSFileManager defaultManager] createDirectoryAtPath:[newPath stringByDeletingLastPathComponent]
                                             withIntermediateDirectories:YES
                                                              attributes:nil
                                                                   error:nil];
                    
                    // 检查新路径是目录还是文件
                    BOOL isDir;
                    if ([[NSFileManager defaultManager] fileExistsAtPath:newPath isDirectory:&isDir] && isDir) {
                        // 新路径是目录，则删除
                        [[NSFileManager defaultManager] removeItemAtPath:newPath error:nil];
                    } else {
                        // 新路径是文件，则删除
                        [[NSFileManager defaultManager] removeItemAtPath:newPath error:nil];
                    }
                    
                    // 执行移动
                    NSError *error = nil;
                    if (![[NSFileManager defaultManager] moveItemAtPath:oldPath toPath:newPath error:&error]) {
                        NSLog(@"[BackupTask] Renaming '%@' to '%@' failed: %@", oldPath, newPath, error);
                        errcode = -(int)error.code;
                        errdesc = [error.localizedDescription UTF8String];
                        break;
                    }
                    
                    free(str);
                }
                
                free(key);
                key = NULL;
            }
        } while (val);
        
        free(iter);
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
        return;
    }
    
    // 更新进度
    plist_t progressNode = plist_array_get_item(message, 3);
    if (progressNode && plist_get_node_type(progressNode) == PLIST_REAL) {
        double progress = 0.0;
        plist_get_real_val(progressNode, &progress);
        _overall_progress = progress;
    }
    
    // 获取删除项目
    plist_t removes = plist_array_get_item(message, 1);
    if (!removes || plist_get_node_type(removes) != PLIST_ARRAY) {
        NSLog(@"[BackupTask] Error: Invalid removes array");
        return;
    }
    
    uint32_t cnt = plist_array_get_size(removes);
    NSLog(@"[BackupTask] Removing %d file%s", cnt, (cnt == 1) ? "" : "s");
    
    int errcode = 0;
    const char *errdesc = NULL;
    NSString *backupDir = [_backupDirectory stringByAppendingPathComponent:_sourceUDID];
    
    for (uint32_t i = 0; i < cnt; i++) {
        plist_t val = plist_array_get_item(removes, i);
        if (plist_get_node_type(val) == PLIST_STRING) {
            char *str = NULL;
            plist_get_string_val(val, &str);
            
            if (str) {
                // 忽略对Manifest.mbdx的警告 (正常行为)
                BOOL suppressWarning = NO;
                const char *checkfile = strchr(str, '/');
                if (checkfile && (strcmp(checkfile+1, "Manifest.mbdx") == 0)) {
                    suppressWarning = YES;
                }
                
                NSString *itemPath = [backupDir stringByAppendingPathComponent:[NSString stringWithUTF8String:str]];
                free(str);
                
                NSError *error = nil;
                BOOL isDirectory = NO;
                
                // 检查项目类型
                if ([[NSFileManager defaultManager] fileExistsAtPath:itemPath isDirectory:&isDirectory]) {
                    // 删除项目
                    if (![[NSFileManager defaultManager] removeItemAtPath:itemPath error:&error]) {
                        if (!suppressWarning) {
                            NSLog(@"[BackupTask] Could not remove '%@': %@", itemPath, error);
                        }
                        errcode = -(int)error.code;
                        errdesc = [error.localizedDescription UTF8String];
                    }
                }
            }
        }
    }
    
    // 发送状态响应
    plist_t empty_dict = plist_new_dict();
    mobilebackup2_error_t err = mobilebackup2_send_status_response(_mobilebackup2, errcode, errdesc, empty_dict);
    plist_free(empty_dict);
    
    if (err != MOBILEBACKUP2_E_SUCCESS) {
        NSLog(@"[BackupTask] Could not send status response, error %d", err);
    }
}

- (void)handleCopyItem:(plist_t)message {
    NSLog(@"[BackupTask] Handling copy item request");
    
    if (!message || plist_get_node_type(message) != PLIST_ARRAY || plist_array_get_size(message) < 3) {
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
            NSString *backupDir = [_backupDirectory stringByAppendingPathComponent:_sourceUDID];
            NSString *oldPath = [backupDir stringByAppendingPathComponent:[NSString stringWithUTF8String:src]];
            NSString *newPath = [backupDir stringByAppendingPathComponent:[NSString stringWithUTF8String:dst]];
            
            NSLog(@"[BackupTask] Copying '%@' to '%@'", oldPath, newPath);
            
            // 创建目标目录
            [[NSFileManager defaultManager] createDirectoryAtPath:[newPath stringByDeletingLastPathComponent]
                                     withIntermediateDirectories:YES
                                                      attributes:nil
                                                           error:nil];
            
            // 检查源项目
            BOOL isDirectory = NO;
            if ([[NSFileManager defaultManager] fileExistsAtPath:oldPath isDirectory:&isDirectory]) {
                NSError *error = nil;
                
                // 复制项目
                if (![[NSFileManager defaultManager] copyItemAtPath:oldPath toPath:newPath error:&error]) {
                    NSLog(@"[BackupTask] Could not copy '%@' to '%@': %@", oldPath, newPath, error);
                    errcode = -(int)error.code;
                    errdesc = [error.localizedDescription UTF8String];
                }
            }
            
            free(src);
            free(dst);
        }
    }
    
    // 发送状态响应
    plist_t empty_dict = plist_new_dict();
    mobilebackup2_error_t err = mobilebackup2_send_status_response(_mobilebackup2, errcode, errdesc, empty_dict);
    plist_free(empty_dict);
    
    if (err != MOBILEBACKUP2_E_SUCCESS) {
        NSLog(@"[BackupTask] Could not send status response, error %d", err);
    }
}

#pragma mark - 辅助工具方法

- (NSString *)formatSize:(uint64_t)size {
    if (size < 1024) {
        return [NSString stringWithFormat:@"%llu Bytes", size];
    } else if (size < 1024 * 1024) {
        return [NSString stringWithFormat:@"%.1f KB", size / 1024.0];
    } else if (size < 1024 * 1024 * 1024) {
        return [NSString stringWithFormat:@"%.1f MB", size / (1024.0 * 1024.0)];
    } else {
        return [NSString stringWithFormat:@"%.1f GB", size / (1024.0 * 1024.0 * 1024.0)];
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

@end
