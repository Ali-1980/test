//
//  BackupTask.h
//
//  Created by Monterey on 5/5/2025.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// 错误域
extern NSString *const MFCToolBackupErrorDomain;

// 错误代码 在 MFCToolBackupError 枚举中添加新的错误类型
typedef NS_ENUM(NSInteger, MFCToolBackupError) {
    MFCToolBackupErrorInternal = 1,          // 内部错误
    MFCToolBackupErrorDeviceConnection = 2,   // 设备连接错误
    MFCToolBackupErrorLockdown = 3,           // Lockdown错误
    MFCToolBackupErrorService = 4,            // 服务错误
    MFCToolBackupErrorProtocol = 5,           // 协议错误
    MFCToolBackupErrorFileOperation = 6,      // 文件操作错误
    MFCToolBackupErrorDiskSpace = 7,          // 磁盘空间不足
    MFCToolBackupErrorTrustNotEstablished = 8,// 设备未信任
    MFCToolBackupErrorCancelled = 9,          // 用户取消
    MFCToolBackupErrorTimeout = 10,           // 操作超时
    // 新增错误类型
    MFCToolBackupErrorInvalidPassword = 11,   // 无效密码
    MFCToolBackupErrorEncryptionFailed = 12,  // 加密失败
    MFCToolBackupErrorIncomplete = 13,        // 备份未完成
    MFCToolBackupErrorBackupFailed = 14,      // 备份失败
    MFCToolBackupErrorDeviceLocked = 15,      // 设备已锁定
    MFCToolBackupErrorNetworkError = 16,      // 网络错误
    MFCToolBackupErrorProtocolMismatch = 17,  // 协议不匹配
    MFCToolBackupErrorInsufficientPermission = 18, // 权限不足
    MFCToolBackupErrorDeviceDetached = 19,    // 设备已分离
    MFCToolBackupErrorSSL = -1004,  // 添加专门的SSL错误类型
    MFCToolBackupErrorCommunication = -21,
    MFCToolBackupErrorDeviceBusy = 20         // 设备忙
};



// 备份状态
typedef NS_ENUM(NSInteger, BackupState) {
    BackupStateIdle,                // 空闲状态
    BackupStateInitializing,        // 初始化中
    BackupStateNegotiating,         // 协议协商中
    BackupStateRequiringPassword,   // 需要密码
    BackupStateBackingUp,           // 备份进行中
    BackupStateCompleted,           // 已完成
    BackupStateError,               // 错误状态
    BackupStateCancelled            // 已取消
};

// 回调块定义
typedef void (^BackupProgressBlock)(double progress, NSString *message);
typedef void (^BackupCompletionBlock)(BOOL success, NSError * _Nullable error);
typedef void (^BackupPasswordBlock)(NSString * _Nullable password);

/**
 * BackupTask - 用于管理设备备份操作的类
 *
 * 此类负责执行iOS设备的备份操作，提供进度追踪和状态管理功能。
 * 采用单例模式确保在整个应用中只有一个备份任务实例。
 */
@interface BackupTask : NSObject

// 进度和估算信息
@property (nonatomic, assign, readonly) long long estimatedTotalBytes;
@property (nonatomic, assign, readonly) double currentProgress;
@property (nonatomic, assign, readonly) BackupState currentState;

@property (nonatomic, strong) dispatch_source_t lockMonitorTimer;  // 锁定监控定时器
@property (nonatomic, assign) BOOL pausedDueToLock;               // 因锁定而暂停的标志

/**
 * 获取单例实例
 */
+ (instancetype)sharedInstance;

/**
 * 开始备份指定设备
 *
 * @param udid 设备的UDID
 * @param progressCallback 进度更新回调
 * @param completionCallback 完成回调
 */
- (void)startBackupForDevice:(NSString *)udid
                    progress:(nullable BackupProgressBlock)progressCallback
                  completion:(nullable BackupCompletionBlock)completionCallback;

/**
 * 暂停当前备份操作
 */
- (void)pauseBackup;

/**
 * 恢复已暂停的备份操作
 */
- (void)resumeBackup;

/**
 * 取消当前备份操作
 */
- (void)cancelBackup;

/**
 * 提供加密备份所需的密码
 *
 * @param password 加密备份密码
 */
- (void)providePassword:(nullable NSString *)password;

/**
 * 获取估计的备份总大小（字节数）
 */
- (long long)getEstimatedTotalBytes;

/**
 * 获取格式化的估计备份大小（如"10.5 GB"）
 */
- (NSString *)getEstimatedTotalBytesFormatted;

/**
 * 设置诊断日志级别
 *
 * @param level 日志级别（0-4，默认为1）
 */
- (void)setLogLevel:(NSInteger)level;

@end

NS_ASSUME_NONNULL_END
