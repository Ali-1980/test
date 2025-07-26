//
//  GlobalLockController.h
//  MFCTOOL
//
//  全局设备锁定控制器 - 统一管理所有设备锁定逻辑
//  替代 DeviceBackupRestore.m、FlasherController.m、DeviceAppController.m 中的重复锁定代码
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// 设备锁定状态枚举
typedef NS_ENUM(NSInteger, DeviceLockStatus) {
    DeviceLockStatusUnlocked = 0,    // 未锁定
    DeviceLockStatusLocked = 1,      // 已锁定
    DeviceLockStatusBusy = 2,        // 忙碌中（有任务运行）
    DeviceLockStatusConflict = 3     // 冲突状态
};

// 锁定来源类型枚举
typedef NS_ENUM(NSInteger, LockSourceType) {
    LockSourceTypeBackup = 0,        // 备份功能
    LockSourceTypeFirmware = 1,      // 固件功能
    LockSourceTypeAppManage = 2,     // 应用管理
    LockSourceTypeOther = 99         // 其他
};

// 设备锁定信息模型
@interface DeviceLockInfo : NSObject <NSCoding, NSSecureCoding, NSCopying>

// 基础设备信息
@property (nonatomic, copy) NSString *deviceID;                    // 设备ID (UDID/ECID)
@property (nonatomic, copy) NSString *deviceName;                  // 设备名称
@property (nonatomic, copy) NSString *deviceType;                  // 设备类型
@property (nonatomic, copy) NSString *deviceMode;                  // 设备模式 (Normal/Recovery/DFU)
@property (nonatomic, copy) NSString *deviceVersion;               // 系统版本
@property (nonatomic, copy, nullable) NSString *deviceECID;        // ECID
@property (nonatomic, copy, nullable) NSString *deviceSerialNumber;// 序列号

// 锁定状态信息
@property (nonatomic, assign) DeviceLockStatus lockStatus;         // 锁定状态
@property (nonatomic, assign) LockSourceType lockSource;           // 锁定来源类型
@property (nonatomic, copy) NSString *lockSourceName;              // 锁定来源名称 ("DeviceBackupRestore", "FlasherController", "DeviceAppController")
@property (nonatomic, strong) NSDate *lockTime;                    // 锁定时间
@property (nonatomic, assign) NSInteger activeTaskCount;           // 活跃任务数（由外部任务管理器维护）

// 便捷创建方法
+ (instancetype)deviceWithID:(NSString *)deviceID
                         name:(NSString *)name
                         type:(NSString *)type
                         mode:(NSString *)mode
                      version:(NSString *)version;

+ (instancetype)deviceWithID:(NSString *)deviceID
                         name:(NSString *)name
                         type:(NSString *)type
                         mode:(NSString *)mode
                      version:(NSString *)version
                         ecid:(nullable NSString *)ecid
                 serialNumber:(nullable NSString *)serialNumber;

// 实用方法
- (NSDictionary *)toDictionary;                                     // 转换为字典格式（兼容现有代码）
- (NSString *)displayName;                                          // 显示名称
- (NSTimeInterval)lockDuration;                                     // 锁定持续时间

@end

// 锁定结果枚举
typedef NS_ENUM(NSInteger, LockResult) {
    LockResultSuccess = 0,           // 锁定成功
    LockResultConflict = 1,          // 设备冲突
    LockResultInvalidDevice = 2,     // 无效设备
    LockResultSystemError = 3        // 系统错误
};

// 通知名称常量
extern NSString * const GlobalDeviceLockedNotification;       // 设备被锁定
extern NSString * const GlobalDeviceUnlockedNotification;     // 设备被解锁
extern NSString * const GlobalDeviceLockConflictNotification; // 设备锁定冲突
extern NSString * const GlobalDeviceStatusChangedNotification;// 设备状态变更

// 全局设备锁定控制器
@interface GlobalLockController : NSObject

// 单例实例
+ (instancetype)sharedController;

#pragma mark - 核心锁定功能

/**
 * 锁定设备 - 主要锁定方法
 * @param deviceInfo 设备信息对象
 * @param sourceType 锁定来源类型
 * @param sourceName 锁定来源名称（控制器名称）
 * @param error 错误信息输出
 * @return 锁定结果
 */
- (LockResult)lockDevice:(DeviceLockInfo *)deviceInfo
              sourceType:(LockSourceType)sourceType
              sourceName:(NSString *)sourceName
                   error:(NSError **)error;

/**
 * 解锁设备
 * @param deviceID 设备ID
 * @param sourceName 解锁来源（必须与锁定来源一致）
 * @return 是否解锁成功
 */
- (BOOL)unlockDevice:(NSString *)deviceID sourceName:(NSString *)sourceName;

/**
 * 强制解锁设备（管理员权限）
 * @param deviceID 设备ID
 * @param reason 强制解锁原因
 * @return 是否解锁成功
 */
- (BOOL)forceUnlockDevice:(NSString *)deviceID reason:(NSString *)reason;

/**
 * 解锁所有设备
 */
- (void)unlockAllDevices;

/**
 * 解锁指定来源的所有设备
 * @param sourceName 来源名称
 */
- (void)unlockAllDevicesFromSource:(NSString *)sourceName;

#pragma mark - 状态查询

/**
 * 获取设备锁定信息
 * @param deviceID 设备ID
 * @return 锁定信息，如果未锁定返回nil
 */
- (DeviceLockInfo * _Nullable)getDeviceLockInfo:(NSString *)deviceID;

/**
 * 检查设备是否可以被指定来源锁定
 * @param deviceID 设备ID
 * @param sourceName 请求来源
 * @return 是否可以锁定
 */
- (BOOL)canLockDevice:(NSString *)deviceID fromSource:(NSString *)sourceName;

/**
 * 检查设备是否被锁定
 * @param deviceID 设备ID
 * @return 是否被锁定
 */
- (BOOL)isDeviceLocked:(NSString *)deviceID;

/**
 * 检查设备是否被指定来源锁定
 * @param deviceID 设备ID
 * @param sourceName 来源名称
 * @return 是否被指定来源锁定
 */
- (BOOL)isDevice:(NSString *)deviceID lockedBySource:(NSString *)sourceName;

/**
 * 获取当前所有已锁定的设备
 * @return 锁定设备信息数组
 */
- (NSArray<DeviceLockInfo *> *)getAllLockedDevices;

/**
 * 获取指定来源锁定的设备
 * @param sourceName 来源名称
 * @return 锁定设备信息数组
 */
- (NSArray<DeviceLockInfo *> *)getDevicesLockedBySource:(NSString *)sourceName;

/**
 * 获取设备的当前锁定者
 * @param deviceID 设备ID
 * @return 锁定来源名称，如果未锁定返回nil
 */
- (NSString * _Nullable)getCurrentOwnerOfDevice:(NSString *)deviceID;

#pragma mark - 任务计数管理（与任务控制器协作）

/**
 * 增加设备任务计数
 * @param deviceID 设备ID
 */
- (void)increaseTaskCountForDevice:(NSString *)deviceID;

/**
 * 减少设备任务计数
 * @param deviceID 设备ID
 */
- (void)decreaseTaskCountForDevice:(NSString *)deviceID;

/**
 * 设置设备任务计数
 * @param count 任务数量
 * @param deviceID 设备ID
 */
- (void)setTaskCount:(NSInteger)count forDevice:(NSString *)deviceID;

/**
 * 获取设备任务计数
 * @param deviceID 设备ID
 * @return 任务数量
 */
- (NSInteger)getTaskCountForDevice:(NSString *)deviceID;

#pragma mark - 兼容性方法（用于现有控制器迁移）

/**
 * 兼容 DeviceBackupRestore 的锁定方法
 */
- (BOOL)lockDeviceWithInfo:(NSString *)uniqueKey
             officialName:(NSString *)officialName
                     type:(NSString *)type
                     mode:(NSString *)mode
            deviceVersion:(NSString *)deviceVersion
               sourceName:(NSString *)sourceName
                    error:(NSError **)error;

/**
 * 兼容 FlasherController 的锁定方法
 */
- (BOOL)lockDeviceWithInfo:(NSString *)uniqueKey
             officialName:(NSString *)officialName
                     type:(NSString *)type
                     mode:(NSString *)mode
                  version:(NSString *)deviceVersion
                     ecid:(NSString *)deviceECID
             serialNumber:(NSString *)deviceSerialNumber
               sourceName:(NSString *)sourceName
                    error:(NSError **)error;

/**
 * 获取锁定的设备ID（兼容现有 getter）
 * @param sourceName 来源名称
 * @return 设备ID，如果未锁定返回nil
 */
- (NSString * _Nullable)getLockedDeviceIDForSource:(NSString *)sourceName;

/**
 * 获取锁定的设备信息字典（兼容现有格式）
 * @param sourceName 来源名称
 * @return 设备信息字典，如果未锁定返回nil
 */
- (NSDictionary * _Nullable)getLockedDeviceInfoForSource:(NSString *)sourceName;

#pragma mark - 持久化功能

/**
 * 保存锁定状态到磁盘
 */
- (void)saveLockStates;

/**
 * 从磁盘加载锁定状态
 */
- (void)loadLockStates;

/**
 * 清除持久化的锁定状态
 */
- (void)clearPersistedLockStates;

#pragma mark - 统计和调试

/**
 * 获取锁定统计信息
 * @return 统计信息字典
 */
- (NSDictionary *)getLockStatistics;

/**
 * 打印当前锁定状态（调试用）
 */
- (void)printCurrentLockStatus;

/**
 * 启用/禁用调试日志
 * @param enabled 是否启用
 */
- (void)setDebugLoggingEnabled:(BOOL)enabled;

@end

NS_ASSUME_NONNULL_END
