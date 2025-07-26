//
//  GlobalLockController.m
//  全局设备锁定
//

#import "GlobalLockController.h"
#import <AppKit/AppKit.h>
#import "DeviceManager.h" // 引入设备管理模块
#import "LanguageManager.h" //语言

// 通知名称定义
NSString * const GlobalDeviceLockedNotification = @"GlobalDeviceLockedNotification";
NSString * const GlobalDeviceUnlockedNotification = @"GlobalDeviceUnlockedNotification";
NSString * const GlobalDeviceLockConflictNotification = @"GlobalDeviceLockConflictNotification";
NSString * const GlobalDeviceStatusChangedNotification = @"GlobalDeviceStatusChangedNotification";

// 错误域和错误码
static NSString * const GlobalLockErrorDomain = @"GlobalLockErrorDomain";
static const NSInteger GlobalLockErrorCodeConflict = 1001;
static const NSInteger GlobalLockErrorCodeInvalidDevice = 1002;
static const NSInteger GlobalLockErrorCodeSystemError = 1003;

// 持久化文件名
static NSString * const GlobalLockStateFileName = @"GlobalLockStates.plist";

#pragma mark - DeviceLockInfo 实现

@implementation DeviceLockInfo

+ (BOOL)supportsSecureCoding {
    return YES;
}

+ (instancetype)deviceWithID:(NSString *)deviceID
                         name:(NSString *)name
                         type:(NSString *)type
                         mode:(NSString *)mode
                      version:(NSString *)version {
    return [self deviceWithID:deviceID name:name type:type mode:mode version:version ecid:nil serialNumber:nil];
}

+ (instancetype)deviceWithID:(NSString *)deviceID
                         name:(NSString *)name
                         type:(NSString *)type
                         mode:(NSString *)mode
                      version:(NSString *)version
                         ecid:(NSString *)ecid
                 serialNumber:(NSString *)serialNumber {
    DeviceLockInfo *info = [[DeviceLockInfo alloc] init];
    info.deviceID = deviceID;
    info.deviceName = name;
    info.deviceType = type;
    info.deviceMode = mode;
    info.deviceVersion = version;
    info.deviceECID = ecid;
    info.deviceSerialNumber = serialNumber;
    info.lockStatus = DeviceLockStatusUnlocked;
    info.lockTime = [NSDate date];
    info.activeTaskCount = 0;
    return info;
}

- (NSDictionary *)toDictionary {
    return @{
        @"uniqueKey": self.deviceID ?: @"",
        @"officialName": self.deviceName ?: @"",
        @"type": self.deviceType ?: @"",
        @"mode": self.deviceMode ?: @"",
        @"deviceVersion": self.deviceVersion ?: @"",
        @"deviceECID": self.deviceECID ?: @"",
        @"deviceSerialNumber": self.deviceSerialNumber ?: @""
    };
}

- (NSString *)displayName {
    if (self.deviceName.length > 0) {
        return self.deviceName;
    }
    return [NSString stringWithFormat:@"%@ (%@)", self.deviceType ?: @"Unknown", self.deviceID ?: @""];
}

- (NSTimeInterval)lockDuration {
    return [[NSDate date] timeIntervalSinceDate:self.lockTime];
}

#pragma mark - NSCoding

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:self.deviceID forKey:@"deviceID"];
    [coder encodeObject:self.deviceName forKey:@"deviceName"];
    [coder encodeObject:self.deviceType forKey:@"deviceType"];
    [coder encodeObject:self.deviceMode forKey:@"deviceMode"];
    [coder encodeObject:self.deviceVersion forKey:@"deviceVersion"];
    [coder encodeObject:self.deviceECID forKey:@"deviceECID"];
    [coder encodeObject:self.deviceSerialNumber forKey:@"deviceSerialNumber"];
    [coder encodeInteger:self.lockStatus forKey:@"lockStatus"];
    [coder encodeInteger:self.lockSource forKey:@"lockSource"];
    [coder encodeObject:self.lockSourceName forKey:@"lockSourceName"];
    [coder encodeObject:self.lockTime forKey:@"lockTime"];
    [coder encodeInteger:self.activeTaskCount forKey:@"activeTaskCount"];
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    if (self = [super init]) {
        _deviceID = [coder decodeObjectOfClass:[NSString class] forKey:@"deviceID"];
        _deviceName = [coder decodeObjectOfClass:[NSString class] forKey:@"deviceName"];
        _deviceType = [coder decodeObjectOfClass:[NSString class] forKey:@"deviceType"];
        _deviceMode = [coder decodeObjectOfClass:[NSString class] forKey:@"deviceMode"];
        _deviceVersion = [coder decodeObjectOfClass:[NSString class] forKey:@"deviceVersion"];
        _deviceECID = [coder decodeObjectOfClass:[NSString class] forKey:@"deviceECID"];
        _deviceSerialNumber = [coder decodeObjectOfClass:[NSString class] forKey:@"deviceSerialNumber"];
        _lockStatus = [coder decodeIntegerForKey:@"lockStatus"];
        _lockSource = [coder decodeIntegerForKey:@"lockSource"];
        _lockSourceName = [coder decodeObjectOfClass:[NSString class] forKey:@"lockSourceName"];
        _lockTime = [coder decodeObjectOfClass:[NSDate class] forKey:@"lockTime"];
        _activeTaskCount = [coder decodeIntegerForKey:@"activeTaskCount"];
    }
    return self;
}

#pragma mark - NSCopying

- (id)copyWithZone:(NSZone *)zone {
    DeviceLockInfo *copy = [[[self class] allocWithZone:zone] init];
    
    copy->_deviceID = [_deviceID copyWithZone:zone];
    copy->_deviceName = [_deviceName copyWithZone:zone];
    copy->_deviceType = [_deviceType copyWithZone:zone];
    copy->_deviceMode = [_deviceMode copyWithZone:zone];
    copy->_deviceVersion = [_deviceVersion copyWithZone:zone];
    copy->_deviceECID = [_deviceECID copyWithZone:zone];
    copy->_deviceSerialNumber = [_deviceSerialNumber copyWithZone:zone];
    copy->_lockSourceName = [_lockSourceName copyWithZone:zone];
    copy->_lockTime = [_lockTime copyWithZone:zone];
    
    copy->_lockStatus = _lockStatus;
    copy->_lockSource = _lockSource;
    copy->_activeTaskCount = _activeTaskCount;
    
    return copy;
}

@end

#pragma mark - GlobalLockController 实现

@interface GlobalLockController ()

// 核心数据存储
@property (nonatomic, strong) NSMutableDictionary<NSString *, DeviceLockInfo *> *lockedDevices;

// 线程安全
@property (nonatomic, strong) dispatch_queue_t lockQueue;

// 调试选项
@property (nonatomic, assign) BOOL debugLoggingEnabled;

@end

@implementation GlobalLockController

#pragma mark - 单例和初始化

+ (instancetype)sharedController {
    static GlobalLockController *_instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _instance = [[GlobalLockController alloc] init];
    });
    return _instance;
}

- (instancetype)init {
    if (self = [super init]) {
        _lockedDevices = [NSMutableDictionary dictionary];
        _lockQueue = dispatch_queue_create("com.mfctool.global.lock", DISPATCH_QUEUE_CONCURRENT);
        _debugLoggingEnabled = NO;
        
        // 加载持久化状态
        [self loadLockStates];
        
        // 监听应用生命周期
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(applicationWillTerminate:)
                                                     name:NSApplicationWillTerminateNotification
                                                   object:nil];
        
        [self debugLog:@"GlobalLockController 初始化完成"];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - 核心锁定功能

- (LockResult)lockDevice:(DeviceLockInfo *)deviceInfo
              sourceType:(LockSourceType)sourceType
              sourceName:(NSString *)sourceName
                   error:(NSError **)error {
    
    // 参数验证
    if (!deviceInfo || !deviceInfo.deviceID || !sourceName) {
        if (error) {
            *error = [self errorWithCode:GlobalLockErrorCodeInvalidDevice
                             description:@"设备信息或来源名称不能为空"];
        }
        return LockResultInvalidDevice;
    }
    
    __block LockResult result = LockResultSystemError;
    __block NSError *lockError = nil;
    
    dispatch_barrier_sync(self.lockQueue, ^{
        NSString *deviceID = deviceInfo.deviceID;
        
        // 检查设备是否已被其他来源锁定
        DeviceLockInfo *existingLock = self.lockedDevices[deviceID];
        
        if (existingLock && ![existingLock.lockSourceName isEqualToString:sourceName]) {
            // 设备已被其他来源锁定 - 冲突
            lockError = [self createConflictError:existingLock requestSource:sourceName];
            result = LockResultConflict;
            
            [self debugLog:@"设备锁定冲突: %@ 已被 %@ 锁定，%@ 请求被拒绝",
             deviceInfo.displayName, existingLock.lockSourceName, sourceName];
            
            // 发送冲突通知
            [self postConflictNotification:existingLock requestSource:sourceName];
            return;
        }
        
        // 锁定设备
        deviceInfo.lockStatus = DeviceLockStatusLocked;
        deviceInfo.lockSource = sourceType;
        deviceInfo.lockSourceName = sourceName;
        deviceInfo.lockTime = [NSDate date];
        
        self.lockedDevices[deviceID] = deviceInfo;
        result = LockResultSuccess;
        
        [self debugLog:@"设备锁定成功: %@ 被 %@ 锁定", deviceInfo.displayName, sourceName];
    });
    
    if (error) {
        *error = lockError;
    }
    
    if (result == LockResultSuccess) {
        // 发送锁定成功通知
        [self postDeviceLockedNotification:deviceInfo];
        
        // 保存状态
        [self saveLockStates];
    }
    
    return result;
}

- (BOOL)unlockDevice:(NSString *)deviceID sourceName:(NSString *)sourceName {
    if (!deviceID || !sourceName) {
        [self debugLog:@"解锁失败: 参数不能为空"];
        return NO;
    }
    
    __block BOOL success = NO;
    __block DeviceLockInfo *unlockedInfo = nil;
    
    dispatch_barrier_sync(self.lockQueue, ^{
        DeviceLockInfo *lockInfo = self.lockedDevices[deviceID];
        
        if (lockInfo && [lockInfo.lockSourceName isEqualToString:sourceName]) {
            unlockedInfo = [lockInfo copy];
            [self.lockedDevices removeObjectForKey:deviceID];
            success = YES;
            
            [self debugLog:@"设备解锁成功: %@ 被 %@ 解锁", lockInfo.displayName, sourceName];
        } else if (lockInfo) {
            [self debugLog:@"解锁失败: %@ 不是由 %@ 锁定的（实际锁定者: %@）",
             deviceID, sourceName, lockInfo.lockSourceName];
        } else {
            [self debugLog:@"解锁失败: 设备 %@ 未被锁定", deviceID];
        }
    });
    
    if (success && unlockedInfo) {
        // 发送解锁通知
        [self postDeviceUnlockedNotification:unlockedInfo];
        
        // 保存状态
        [self saveLockStates];
    }
    
    return success;
}

- (BOOL)forceUnlockDevice:(NSString *)deviceID reason:(NSString *)reason {
    if (!deviceID) {
        return NO;
    }
    
    __block BOOL success = NO;
    __block DeviceLockInfo *unlockedInfo = nil;
    
    dispatch_barrier_sync(self.lockQueue, ^{
        DeviceLockInfo *lockInfo = self.lockedDevices[deviceID];
        
        if (lockInfo) {
            unlockedInfo = [lockInfo copy];
            [self.lockedDevices removeObjectForKey:deviceID];
            success = YES;
            
            [self debugLog:@"设备强制解锁: %@ (原锁定者: %@, 原因: %@)",
             lockInfo.displayName, lockInfo.lockSourceName, reason ?: @"无原因"];
        }
    });
    
    if (success && unlockedInfo) {
        // 发送强制解锁通知
        NSDictionary *userInfo = @{
            @"deviceInfo": unlockedInfo,
            @"reason": reason ?: @"",
            @"isForceUnlock": @YES
        };
        
        [[NSNotificationCenter defaultCenter] postNotificationName:GlobalDeviceUnlockedNotification
                                                            object:unlockedInfo
                                                          userInfo:userInfo];
        
        // 保存状态
        [self saveLockStates];
    }
    
    return success;
}

- (void)unlockAllDevices {
    __block NSArray *allLocked = nil;
    
    dispatch_barrier_sync(self.lockQueue, ^{
        allLocked = [self.lockedDevices.allValues copy];
        [self.lockedDevices removeAllObjects];
    });
    
    [self debugLog:@"解锁所有设备: %ld 个设备被解锁", allLocked.count];
    
    // 发送解锁通知
    for (DeviceLockInfo *info in allLocked) {
        [self postDeviceUnlockedNotification:info];
    }
    
    // 保存状态
    [self saveLockStates];
}

// 解除锁定状态
- (void)unlockAllDevicesFromSource:(NSString *)sourceName {
    if (!sourceName) return;
    
    __block NSMutableArray *unlockedDevices = [NSMutableArray array];
    
    dispatch_barrier_sync(self.lockQueue, ^{
        NSMutableArray *toRemove = [NSMutableArray array];
        
        for (NSString *deviceID in self.lockedDevices) {
            DeviceLockInfo *info = self.lockedDevices[deviceID];
            if ([info.lockSourceName isEqualToString:sourceName]) {
                [unlockedDevices addObject:[info copy]];
                [toRemove addObject:deviceID];
            }
        }
        
        for (NSString *deviceID in toRemove) {
            [self.lockedDevices removeObjectForKey:deviceID];
        }
    });
    
    [self debugLog:@"解锁来源 %@ 的所有设备: %ld 个设备被解锁", sourceName, unlockedDevices.count];
    
    // 发送解锁通知
    for (DeviceLockInfo *info in unlockedDevices) {
        [self postDeviceUnlockedNotification:info];
    }
    
    // 保存状态
    [self saveLockStates];
}

#pragma mark - 状态查询

- (DeviceLockInfo *)getDeviceLockInfo:(NSString *)deviceID {
    if (!deviceID) return nil;
    
    __block DeviceLockInfo *lockInfo = nil;
    
    dispatch_sync(self.lockQueue, ^{
        lockInfo = [self.lockedDevices[deviceID] copy];
    });
    
    return lockInfo;
}

- (BOOL)canLockDevice:(NSString *)deviceID fromSource:(NSString *)sourceName {
    if (!deviceID || !sourceName) return NO;
    
    __block BOOL canLock = NO;
    
    dispatch_sync(self.lockQueue, ^{
        DeviceLockInfo *existingLock = self.lockedDevices[deviceID];
        
        if (!existingLock) {
            // 设备未被锁定，可以锁定
            canLock = YES;
        } else if ([existingLock.lockSourceName isEqualToString:sourceName]) {
            // 设备被同一来源锁定，可以重新锁定
            canLock = YES;
        } else {
            // 设备被其他来源锁定，不能锁定
            canLock = NO;
        }
    });
    
    return canLock;
}

- (BOOL)isDeviceLocked:(NSString *)deviceID {
    if (!deviceID) return NO;
    
    __block BOOL isLocked = NO;
    
    dispatch_sync(self.lockQueue, ^{
        isLocked = (self.lockedDevices[deviceID] != nil);
    });
    
    return isLocked;
}

- (BOOL)isDevice:(NSString *)deviceID lockedBySource:(NSString *)sourceName {
    if (!deviceID || !sourceName) return NO;
    
    __block BOOL isLockedBySource = NO;
    
    dispatch_sync(self.lockQueue, ^{
        DeviceLockInfo *lockInfo = self.lockedDevices[deviceID];
        isLockedBySource = (lockInfo && [lockInfo.lockSourceName isEqualToString:sourceName]);
    });
    
    return isLockedBySource;
}

- (NSArray<DeviceLockInfo *> *)getAllLockedDevices {
    __block NSArray *lockedDevices = nil;
    
    dispatch_sync(self.lockQueue, ^{
        NSMutableArray *result = [NSMutableArray arrayWithCapacity:self.lockedDevices.count];
        for (DeviceLockInfo *info in self.lockedDevices.allValues) {
            [result addObject:[info copy]];
        }
        lockedDevices = [result copy];
    });
    
    return lockedDevices;
}

- (NSArray<DeviceLockInfo *> *)getDevicesLockedBySource:(NSString *)sourceName {
    if (!sourceName) return @[];
    
    __block NSArray *result = nil;
    
    dispatch_sync(self.lockQueue, ^{
        NSMutableArray *filtered = [NSMutableArray array];
        for (DeviceLockInfo *info in self.lockedDevices.allValues) {
            if ([info.lockSourceName isEqualToString:sourceName]) {
                [filtered addObject:[info copy]];
            }
        }
        result = [filtered copy];
    });
    
    return result;
}

- (NSString *)getCurrentOwnerOfDevice:(NSString *)deviceID {
    if (!deviceID) return nil;
    
    __block NSString *owner = nil;
    
    dispatch_sync(self.lockQueue, ^{
        DeviceLockInfo *lockInfo = self.lockedDevices[deviceID];
        owner = lockInfo.lockSourceName;
    });
    
    return owner;
}

#pragma mark - 任务计数管理

- (void)increaseTaskCountForDevice:(NSString *)deviceID {
    if (!deviceID) return;
    
    dispatch_barrier_async(self.lockQueue, ^{
        DeviceLockInfo *lockInfo = self.lockedDevices[deviceID];
        if (lockInfo) {
            lockInfo.activeTaskCount++;
            if (lockInfo.activeTaskCount > 0) {
                lockInfo.lockStatus = DeviceLockStatusBusy;
            }
            
            [self debugLog:@"设备 %@ 任务计数增加到 %ld", lockInfo.displayName, lockInfo.activeTaskCount];
            
            dispatch_async(dispatch_get_main_queue(), ^{
                [self postDeviceStatusChangedNotification:lockInfo];
            });
        }
    });
}

- (void)decreaseTaskCountForDevice:(NSString *)deviceID {
    if (!deviceID) return;
    
    dispatch_barrier_async(self.lockQueue, ^{
        DeviceLockInfo *lockInfo = self.lockedDevices[deviceID];
        if (lockInfo && lockInfo.activeTaskCount > 0) {
            lockInfo.activeTaskCount--;
            if (lockInfo.activeTaskCount == 0) {
                lockInfo.lockStatus = DeviceLockStatusLocked;
            }
            
            [self debugLog:@"设备 %@ 任务计数减少到 %ld", lockInfo.displayName, lockInfo.activeTaskCount];
            
            dispatch_async(dispatch_get_main_queue(), ^{
                [self postDeviceStatusChangedNotification:lockInfo];
            });
        }
    });
}

- (void)setTaskCount:(NSInteger)count forDevice:(NSString *)deviceID {
    if (!deviceID) return;
    
    dispatch_barrier_async(self.lockQueue, ^{
        DeviceLockInfo *lockInfo = self.lockedDevices[deviceID];
        if (lockInfo) {
            lockInfo.activeTaskCount = MAX(0, count);
            lockInfo.lockStatus = (lockInfo.activeTaskCount > 0) ? DeviceLockStatusBusy : DeviceLockStatusLocked;
            
            [self debugLog:@"设备 %@ 任务计数设置为 %ld", lockInfo.displayName, lockInfo.activeTaskCount];
            
            dispatch_async(dispatch_get_main_queue(), ^{
                [self postDeviceStatusChangedNotification:lockInfo];
            });
        }
    });
}

- (NSInteger)getTaskCountForDevice:(NSString *)deviceID {
    if (!deviceID) return 0;
    
    __block NSInteger count = 0;
    
    dispatch_sync(self.lockQueue, ^{
        DeviceLockInfo *lockInfo = self.lockedDevices[deviceID];
        count = lockInfo ? lockInfo.activeTaskCount : 0;
    });
    
    return count;
}

#pragma mark - 兼容性方法

- (BOOL)lockDeviceWithInfo:(NSString *)uniqueKey
             officialName:(NSString *)officialName
                     type:(NSString *)type
                     mode:(NSString *)mode
            deviceVersion:(NSString *)deviceVersion
               sourceName:(NSString *)sourceName
                    error:(NSError **)error {
    
    DeviceLockInfo *deviceInfo = [DeviceLockInfo deviceWithID:uniqueKey
                                                          name:officialName
                                                          type:type
                                                          mode:mode
                                                       version:deviceVersion];
    
    LockSourceType sourceType = [self sourceTypeFromSourceName:sourceName];
    LockResult result = [self lockDevice:deviceInfo sourceType:sourceType sourceName:sourceName error:error];
    
    return (result == LockResultSuccess);
}

- (BOOL)lockDeviceWithInfo:(NSString *)uniqueKey
             officialName:(NSString *)officialName
                     type:(NSString *)type
                     mode:(NSString *)mode
                  version:(NSString *)deviceVersion
                     ecid:(NSString *)deviceECID
             serialNumber:(NSString *)deviceSerialNumber
               sourceName:(NSString *)sourceName
                    error:(NSError **)error {
    
    DeviceLockInfo *deviceInfo = [DeviceLockInfo deviceWithID:uniqueKey
                                                          name:officialName
                                                          type:type
                                                          mode:mode
                                                       version:deviceVersion
                                                          ecid:deviceECID
                                                  serialNumber:deviceSerialNumber];
    
    LockSourceType sourceType = [self sourceTypeFromSourceName:sourceName];
    LockResult result = [self lockDevice:deviceInfo sourceType:sourceType sourceName:sourceName error:error];
    
    return (result == LockResultSuccess);
}

- (NSString *)getLockedDeviceIDForSource:(NSString *)sourceName {
    if (!sourceName) return nil;
    
    __block NSString *deviceID = nil;
    
    dispatch_sync(self.lockQueue, ^{
        for (DeviceLockInfo *lockInfo in self.lockedDevices.allValues) {
            if ([lockInfo.lockSourceName isEqualToString:sourceName]) {
                deviceID = lockInfo.deviceID;
                break;
            }
        }
    });
    
    return deviceID;
}

- (NSDictionary *)getLockedDeviceInfoForSource:(NSString *)sourceName {
    if (!sourceName) return nil;
    
    __block NSDictionary *deviceInfo = nil;
    
    dispatch_sync(self.lockQueue, ^{
        for (DeviceLockInfo *lockInfo in self.lockedDevices.allValues) {
            if ([lockInfo.lockSourceName isEqualToString:sourceName]) {
                deviceInfo = [lockInfo toDictionary];
                break;
            }
        }
    });
    
    return deviceInfo;
}

#pragma mark - 持久化功能

- (void)saveLockStates {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @try {
            NSArray<DeviceLockInfo *> *allLocks = [self getAllLockedDevices];
            NSData *data = [NSKeyedArchiver archivedDataWithRootObject:allLocks
                                                 requiringSecureCoding:YES
                                                                 error:nil];
            
            if (data) {
                NSString *filePath = [self lockStatesFilePath];
                [data writeToFile:filePath atomically:YES];
                
                [self debugLog:@"锁定状态已保存到磁盘: %ld 个设备", allLocks.count];
            }
        } @catch (NSException *exception) {
            NSLog(@"[GlobalLockController] 保存锁定状态失败: %@", exception.reason);
        }
    });
}

- (void)loadLockStates {
    @try {
        NSString *filePath = [self lockStatesFilePath];
        NSData *data = [NSData dataWithContentsOfFile:filePath];
        
        if (data) {
            NSArray<DeviceLockInfo *> *loadedLocks = [NSKeyedUnarchiver unarchivedObjectOfClasses:
                                                     [NSSet setWithObjects:[NSArray class], [DeviceLockInfo class], nil]
                                                                                           fromData:data
                                                                                              error:nil];
            
            if (loadedLocks) {
                dispatch_barrier_sync(self.lockQueue, ^{
                    [self.lockedDevices removeAllObjects];
                    for (DeviceLockInfo *lockInfo in loadedLocks) {
                        self.lockedDevices[lockInfo.deviceID] = lockInfo;
                    }
                });
                
                [self debugLog:@"从磁盘加载锁定状态: %ld 个设备", loadedLocks.count];
            }
        }
    } @catch (NSException *exception) {
        NSLog(@"[GlobalLockController] 加载锁定状态失败: %@", exception.reason);
    }
}

- (void)clearPersistedLockStates {
    NSString *filePath = [self lockStatesFilePath];
    [[NSFileManager defaultManager] removeItemAtPath:filePath error:nil];
    
    [self debugLog:@"已清除持久化的锁定状态"];
}

- (NSString *)lockStatesFilePath {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
    NSString *appSupportPath = paths.firstObject;
    NSString *appPath = [appSupportPath stringByAppendingPathComponent:@"MFCTOOL"];
    
    // 创建目录（如果不存在）
    [[NSFileManager defaultManager] createDirectoryAtPath:appPath
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    
    return [appPath stringByAppendingPathComponent:GlobalLockStateFileName];
}

#pragma mark - 统计和调试

- (NSDictionary *)getLockStatistics {
    __block NSDictionary *stats = nil;
    
    dispatch_sync(self.lockQueue, ^{
        NSInteger totalLocked = self.lockedDevices.count;
        NSInteger busyCount = 0;
        NSInteger lockedCount = 0;
        NSMutableDictionary *sourceStats = [NSMutableDictionary dictionary];
        
        for (DeviceLockInfo *info in self.lockedDevices.allValues) {
            if (info.lockStatus == DeviceLockStatusBusy) {
                busyCount++;
            } else if (info.lockStatus == DeviceLockStatusLocked) {
                lockedCount++;
            }
            
            NSNumber *count = sourceStats[info.lockSourceName] ?: @0;
            sourceStats[info.lockSourceName] = @(count.integerValue + 1);
        }
        
        stats = @{
            @"totalLocked": @(totalLocked),
            @"busyCount": @(busyCount),
            @"lockedCount": @(lockedCount),
            @"sourceStats": [sourceStats copy]
        };
    });
    
    return stats;
}

- (void)printCurrentLockStatus {
    NSArray<DeviceLockInfo *> *allLocks = [self getAllLockedDevices];
    
    NSLog(@"========== 当前锁定状态 ==========");
    NSLog(@"总锁定设备数: %ld", allLocks.count);
    
    if (allLocks.count == 0) {
        NSLog(@"无设备被锁定");
    } else {
        for (DeviceLockInfo *info in allLocks) {
            NSString *statusString = [self stringForLockStatus:info.lockStatus];
            NSTimeInterval duration = info.lockDuration;
            
            NSLog(@"设备: %@ | 锁定者: %@ | 状态: %@ | 任务数: %ld | 持续时间: %.0f秒",
                  info.displayName, info.lockSourceName, statusString,
                  info.activeTaskCount, duration);
        }
    }
    NSLog(@"================================");
}

- (void)setDebugLoggingEnabled:(BOOL)enabled {
    self.debugLoggingEnabled = enabled;
    [self debugLog:@"调试日志已%@", enabled ? @"启用" : @"禁用"];
}

#pragma mark - 私有方法

- (LockSourceType)sourceTypeFromSourceName:(NSString *)sourceName {
    if ([sourceName containsString:@"Backup"] || [sourceName containsString:@"Restore"]) {
        return LockSourceTypeBackup;
    } else if ([sourceName containsString:@"Flasher"] || [sourceName containsString:@"Firmware"]) {
        return LockSourceTypeFirmware;
    } else if ([sourceName containsString:@"App"]) {
        return LockSourceTypeAppManage;
    }
    return LockSourceTypeOther;
}

- (NSError *)errorWithCode:(NSInteger)code description:(NSString *)description {
    return [NSError errorWithDomain:GlobalLockErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

- (NSError *)createConflictError:(DeviceLockInfo *)existingLock requestSource:(NSString *)requestSource {
    NSTimeInterval lockDuration = existingLock.lockDuration;
    
    NSDictionary *userInfo = @{
        NSLocalizedDescriptionKey: @"设备已被其他功能锁定",
        @"currentOwner": existingLock.lockSourceName,
        @"deviceName": existingLock.displayName,
        @"deviceID": existingLock.deviceID,
        @"lockTime": existingLock.lockTime,
        @"lockDuration": @(lockDuration),
        @"requestSource": requestSource,
        @"activeTaskCount": @(existingLock.activeTaskCount)
    };
    
    return [NSError errorWithDomain:GlobalLockErrorDomain
                               code:GlobalLockErrorCodeConflict
                           userInfo:userInfo];
}

- (NSString *)stringForLockStatus:(DeviceLockStatus)status {
    switch (status) {
        case DeviceLockStatusUnlocked: return @"未锁定";
        case DeviceLockStatusLocked: return @"已锁定";
        case DeviceLockStatusBusy: return @"忙碌中";
        case DeviceLockStatusConflict: return @"冲突";
        default: return @"未知";
    }
}

- (void)debugLog:(NSString *)format, ... {
    if (!self.debugLoggingEnabled) return;
    
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    
    NSLog(@"[GlobalLockController] %@", message);
}

#pragma mark - 通知发送

- (void)postDeviceLockedNotification:(DeviceLockInfo *)deviceInfo {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSDictionary *userInfo = @{
            @"deviceInfo": deviceInfo,
            @"sourceName": deviceInfo.lockSourceName
        };
        
        [[NSNotificationCenter defaultCenter] postNotificationName:GlobalDeviceLockedNotification
                                                            object:deviceInfo
                                                          userInfo:userInfo];
    });
}

- (void)postDeviceUnlockedNotification:(DeviceLockInfo *)deviceInfo {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSDictionary *userInfo = @{
            @"deviceInfo": deviceInfo,
            @"sourceName": deviceInfo.lockSourceName
        };
        
        [[NSNotificationCenter defaultCenter] postNotificationName:GlobalDeviceUnlockedNotification
                                                            object:deviceInfo
                                                          userInfo:userInfo];
    });
}

- (void)postConflictNotification:(DeviceLockInfo *)existingLock requestSource:(NSString *)requestSource {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSDictionary *userInfo = @{
            @"existingLock": existingLock,
            @"requestSource": requestSource,
            @"deviceID": existingLock.deviceID
        };
        
        [[NSNotificationCenter defaultCenter] postNotificationName:GlobalDeviceLockConflictNotification
                                                            object:existingLock
                                                          userInfo:userInfo];
    });
}

- (void)postDeviceStatusChangedNotification:(DeviceLockInfo *)deviceInfo {
    NSDictionary *userInfo = @{
        @"deviceInfo": deviceInfo,
        @"deviceID": deviceInfo.deviceID
    };
    
    [[NSNotificationCenter defaultCenter] postNotificationName:GlobalDeviceStatusChangedNotification
                                                        object:deviceInfo
                                                      userInfo:userInfo];
}

#pragma mark - 应用生命周期

- (void)applicationWillTerminate:(NSNotification *)notification {
    [self saveLockStates];
    [self debugLog:@"应用将终止，锁定状态已保存"];
}

@end
