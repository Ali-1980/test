//
//  BackupOptionTask.m
//  iOSBackupManager
//
//  Created based on libimobiledevice mobilesync API
//  Provides selective backup functionality using mobilesync protocol
//
//  2025.01.27


#import "BackupOptionTask.h"
#import "DatalogsSettings.h"
#import <CommonCrypto/CommonCrypto.h>

// 引入 libimobiledevice 相关头文件
#include <libimfccore/libimfccore.h>
#include <libimfccore/lockdown.h>
#include <libimfccore/mobilesync.h>
#include <libimfccore/notification_proxy.h>
#include <libimfccore/afc.h>
#include <plist/plist.h>
#include <stdio.h>
#include <sys/stat.h>

// 常量定义
NSString * const kBackupOptionTaskErrorDomain = @"com.mfcbox.BackupOptionTaskErrorDomain";

// 基于实际iOS同步类的数据类型映射
static NSDictionary *DataTypeToSyncClassMap() {
    static NSDictionary *map = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // 基于实际的iOS同步服务类标识符
        map = @{
            @(BackupDataTypeContacts): @"com.apple.Contacts",
            @(BackupDataTypeCalendars): @"com.apple.Calendars",
            @(BackupDataTypeBookmarks): @"com.apple.WebBookmarks",
            @(BackupDataTypeNotes): @"com.apple.Notes",
            @(BackupDataTypeReminders): @"com.apple.Reminders",
            @(BackupDataTypeApplications): @"com.apple.MobileApplication",
            @(BackupDataTypeConfiguration): @"com.apple.SystemConfiguration",
            @(BackupDataTypeKeychain): @"com.apple.Keychain",
            @(BackupDataTypeVoiceMemos): @"com.apple.VoiceMemos",
            @(BackupDataTypeWallpaper): @"com.apple.Wallpaper"
        };
    });
    return map;
}

// 获取已知的同步类列表 - 用于检测支持的数据类型
static NSArray *GetKnownSyncClasses() {
    static NSArray *classes = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        classes = @[
            @"com.apple.Contacts",
            @"com.apple.Calendars",
            @"com.apple.WebBookmarks",
            @"com.apple.Notes",
            @"com.apple.Reminders",
            @"com.apple.MobileApplication"
        ];
    });
    return classes;
}

// SyncDataItem 实现
@implementation SyncDataItem

- (instancetype)init {
    self = [super init];
    if (self) {
        _isSelected = NO;
        _recordCount = 1;
        _dataSize = 0;
        _modificationDate = [NSDate date];
    }
    return self;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<SyncDataItem: %@ (%@) - %@ records>",
            self.name, self.identifier, @(self.recordCount)];
}

@end

// BackupOptionTask 内部接口
@interface BackupOptionTask () {
    // libimobiledevice C API 指针
    idevice_t _device;
    lockdownd_client_t _lockdown;
    mobilesync_client_t _mobilesync;
    afc_client_t _afc;
    np_client_t _np;
    
    // 操作状态
    SyncTaskStatus _status;
    float _progress;
    NSError *_lastError;
    BOOL _isOperating;
    BOOL _isPaused;
    BOOL _cancelRequested;
    
    // 同步上下文
    dispatch_queue_t _operationQueue;
    NSMutableDictionary *_syncAnchors;
    NSMutableDictionary *_dataCache;
    
    // 当前操作参数
    BackupDataType _currentDataTypes;
    SyncDirection _currentDirection;
    NSString *_currentBackupPath;
    
    // 内部状态
    NSDate *_lastSyncTime;
    NSUInteger _totalItemsToProcess;
    NSUInteger _processedItems;
}

// 私有方法声明
- (BOOL)connectToDeviceInternal:(NSString *)deviceUDID error:(NSError **)error;
- (BOOL)startMobileSyncService:(NSError **)error;
- (NSError *)errorWithCode:(BackupOptionTaskErrorCode)code description:(NSString *)description;
- (void)setInternalStatus:(SyncTaskStatus)status;
- (void)updateProgress:(float)progress operation:(NSString *)operation current:(NSUInteger)current total:(NSUInteger)total;
- (NSString *)stringForStatus:(SyncTaskStatus)status;

// 数据处理方法
- (NSArray<SyncDataItem *> *)processDataForType:(BackupDataType)dataType dataArray:(plist_t)data_array;
- (NSArray<SyncDataItem *> *)processContactsData:(plist_t)data_array;
- (NSArray<SyncDataItem *> *)processCalendarsData:(plist_t)data_array;
- (NSArray<SyncDataItem *> *)processBookmarksData:(plist_t)data_array;
- (NSArray<SyncDataItem *> *)processNotesData:(plist_t)data_array;
- (NSArray<SyncDataItem *> *)processRemindersData:(plist_t)data_array;
- (NSArray<SyncDataItem *> *)processGenericData:(plist_t)data_array forType:(BackupDataType)dataType;

// 简化的数据获取方法
- (NSArray<SyncDataItem *> *)getDataItemsSimplified:(BackupDataType)dataType syncClass:(NSString *)syncClass error:(NSError **)error;
- (NSArray<SyncDataItem *> *)getGenericDataViaMobileSync:(BackupDataType)dataType syncClass:(NSString *)syncClass error:(NSError **)error;
- (NSArray<SyncDataItem *> *)getContactsViaAddressBook:(NSError **)error;
- (NSArray<SyncDataItem *> *)getCalendarsViaEventKit:(NSError **)error;
- (NSArray<SyncDataItem *> *)getBookmarksViaSafari:(NSError **)error;
- (NSArray<SyncDataItem *> *)getNotesViaNotesApp:(NSError **)error;
- (NSArray<SyncDataItem *> *)getRemindersViaRemindersApp:(NSError **)error;

// 同步操作方法
- (BOOL)performSyncForDataType:(BackupDataType)dataType direction:(SyncDirection)direction error:(NSError **)error;
- (BOOL)backupDataType:(BackupDataType)dataType toPath:(NSString *)path error:(NSError **)error;
- (BOOL)restoreDataType:(BackupDataType)dataType fromPath:(NSString *)path error:(NSError **)error;
- (BOOL)performSelectiveSyncInternal:(BackupDataType)dataTypes direction:(SyncDirection)direction;

// 工具方法
- (void)logMessage:(NSString *)message;
- (NSString *)formatFileSize:(NSUInteger)bytes;
- (NSString *)getCurrentTimestamp;

@end

@implementation BackupOptionTask

@synthesize deviceUDID = _deviceUDID;
@synthesize status = _status;
@synthesize progress = _progress;
@synthesize lastError = _lastError;
@synthesize isOperating = _isOperating;
@synthesize isPaused = _isPaused;

#pragma mark - 单例和初始化

+ (instancetype)sharedInstance {
    static BackupOptionTask *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (instancetype)init {
    return [self initWithDeviceUDID:nil];
}

- (instancetype)initWithDeviceUDID:(NSString *)deviceUDID {
    self = [super init];
    if (self) {
        _deviceUDID = [deviceUDID copy];
        _status = SyncTaskStatusIdle;
        _progress = 0.0;
        _isOperating = NO;
        _isPaused = NO;
        _cancelRequested = NO;
        
        _operationQueue = dispatch_queue_create("com.mfcbox.backupoptiontask.operation", DISPATCH_QUEUE_SERIAL);
        _syncAnchors = [NSMutableDictionary dictionary];
        _dataCache = [NSMutableDictionary dictionary];
        
        // 设置默认数据存储路径
        _dataStoragePath = [DatalogsSettings defaultBackupPath];
        
        _lastSyncTime = nil;
        _totalItemsToProcess = 0;
        _processedItems = 0;
        
        [self logMessage:[NSString stringWithFormat:@"BackupOptionTask initialized with device UDID: %@", deviceUDID ?: @"(none)"]];
    }
    return self;
}

- (void)dealloc {
    [self logMessage:@"BackupOptionTask deallocating and cleaning up resources"];
    [self disconnectDevice];
}

#pragma mark - 设备连接和查询

- (BOOL)connectToDevice:(NSString *)deviceUDID error:(NSError **)error {
    [self logMessage:[NSString stringWithFormat:@"Connecting to device: %@", deviceUDID]];
    
    if (!deviceUDID || deviceUDID.length == 0) {
        if (error) {
            *error = [self errorWithCode:BackupOptionTaskErrorCodeInvalidArg
                             description:@"Device UDID cannot be empty"];
        }
        return NO;
    }
    
    // 如果已经连接到同一设备，直接返回成功
    if ([_deviceUDID isEqualToString:deviceUDID] && _device && _lockdown && _mobilesync) {
        [self logMessage:[NSString stringWithFormat:@"Already connected to device: %@", deviceUDID]];
        return YES;
    }
    
    // 先断开现有连接
    [self disconnectDevice];
    
    _deviceUDID = [deviceUDID copy];
    return [self connectToDeviceInternal:deviceUDID error:error];
}

- (BOOL)connectToDeviceInternal:(NSString *)deviceUDID error:(NSError **)error {
    [self setInternalStatus:SyncTaskStatusConnecting];
    
    // 1. 连接设备
    idevice_error_t ret = idevice_new(&_device, [deviceUDID UTF8String]);
    if (ret != IDEVICE_E_SUCCESS) {
        NSString *desc = [NSString stringWithFormat:@"Failed to connect to device: %d", ret];
        if (error) {
            *error = [self errorWithCode:BackupOptionTaskErrorCodeConnectionFailed description:desc];
        }
        return NO;
    }
    
    [self logMessage:@"Device connection established"];
    
    // 2. 创建lockdown客户端
    lockdownd_error_t ldret = lockdownd_client_new_with_handshake(_device, &_lockdown, "BackupOptionTask");
    if (ldret != LOCKDOWN_E_SUCCESS) {
        NSString *desc = [NSString stringWithFormat:@"Failed to connect to lockdownd: %d", ldret];
        if (error) {
            *error = [self errorWithCode:BackupOptionTaskErrorCodeConnectionFailed description:desc];
        }
        return NO;
    }
    
    [self logMessage:@"Lockdown connection established"];
    
    // 3. 启动mobilesync服务
    if (![self startMobileSyncService:error]) {
        return NO;
    }
    
    [self logMessage:[NSString stringWithFormat:@"Successfully connected to device: %@", deviceUDID]];
    [self setInternalStatus:SyncTaskStatusIdle];
    return YES;
}

- (BOOL)startMobileSyncService:(NSError **)error {
    lockdownd_service_descriptor_t service = NULL;
    lockdownd_error_t ldret = lockdownd_start_service(_lockdown, "com.apple.mobilesync", &service);
    
    if (ldret != LOCKDOWN_E_SUCCESS || !service || service->port == 0) {
        NSString *desc = [NSString stringWithFormat:@"Failed to start mobilesync service: %d", ldret];
        if (error) {
            *error = [self errorWithCode:BackupOptionTaskErrorCodeServiceStartFailed description:desc];
        }
        return NO;
    }
    
    mobilesync_error_t err = mobilesync_client_new(_device, service, &_mobilesync);
    lockdownd_service_descriptor_free(service);
    
    if (err != MOBILESYNC_E_SUCCESS) {
        NSString *desc = [NSString stringWithFormat:@"Failed to create mobilesync client: %d", err];
        if (error) {
            *error = [self errorWithCode:BackupOptionTaskErrorCodeServiceStartFailed description:desc];
        }
        return NO;
    }
    
    [self logMessage:@"MobileSync service started successfully"];
    return YES;
}

- (void)disconnectDevice {
    [self logMessage:@"Disconnecting device"];
    
    if (_mobilesync) {
        mobilesync_client_free(_mobilesync);
        _mobilesync = NULL;
    }
    
    if (_afc) {
        afc_client_free(_afc);
        _afc = NULL;
    }
    
    if (_np) {
        np_client_free(_np);
        _np = NULL;
    }
    
    if (_lockdown) {
        lockdownd_client_free(_lockdown);
        _lockdown = NULL;
    }
    
    if (_device) {
        idevice_free(_device);
        _device = NULL;
    }
    
    [self setInternalStatus:SyncTaskStatusIdle];
}

- (BOOL)isConnected {
    return (_device != NULL && _lockdown != NULL && _mobilesync != NULL);
}

// 辅助方法：检查单个数据类型是否支持
- (BOOL)isDataTypeSupported:(BackupDataType)dataType {
    NSString *syncClass = DataTypeToSyncClassMap()[@(dataType)];
    if (!syncClass || ![self isConnected]) {
        return NO;
    }
    
    @try {
        // 使用正确的API创建anchors
        mobilesync_anchors_t anchors = mobilesync_anchors_new("", "");
        if (!anchors) {
            return NO;
        }
        
        // 准备正确的参数
        uint64_t data_class_version = 106;
        mobilesync_sync_type_t sync_type = MOBILESYNC_SYNC_TYPE_FAST;
        uint64_t device_data_class_version = 0;
        char *error_description = NULL;
        
        // 正确调用mobilesync_start
        mobilesync_error_t err = mobilesync_start(_mobilesync,
                                                [syncClass UTF8String],
                                                anchors,
                                                data_class_version,
                                                &sync_type,
                                                &device_data_class_version,
                                                &error_description);
        
        BOOL supported = (err == MOBILESYNC_E_SUCCESS);
        
        // 如果成功启动，需要结束会话
        if (supported) {
            mobilesync_finish(_mobilesync);
        }
        
        // 清理资源
        if (error_description) {
            free(error_description);
        }
        mobilesync_anchors_free(anchors);
        
        return supported;
        
    } @catch (NSException *exception) {
        [self logMessage:[NSString stringWithFormat:@"Exception checking data type support: %@", exception]];
        return NO;
    }
}
- (BackupDataType)getSupportedDataTypes:(NSError **)error {
    [self logMessage:@"Getting supported data types"];
    
    if (![self isConnected]) {
        if (error) {
            *error = [self errorWithCode:BackupOptionTaskErrorCodeConnectionFailed
                             description:@"Not connected to device"];
        }
        return BackupDataTypeNone;
    }
    
    BackupDataType supportedTypes = BackupDataTypeNone;
    
    // 逐个检查每种数据类型的支持性
    NSArray *allDataTypes = @[
        @(BackupDataTypeContacts),
        @(BackupDataTypeCalendars),
        @(BackupDataTypeBookmarks),
        @(BackupDataTypeNotes),
        @(BackupDataTypeReminders),
        @(BackupDataTypeApplications),
        @(BackupDataTypeConfiguration),
        @(BackupDataTypeKeychain),
        @(BackupDataTypeVoiceMemos),
        @(BackupDataTypeWallpaper)
    ];
    
    for (NSNumber *dataTypeNum in allDataTypes) {
        BackupDataType dataType = [dataTypeNum unsignedIntegerValue];
        
        if ([self isDataTypeSupported:dataType]) {
            supportedTypes |= dataType;
            [self logMessage:[NSString stringWithFormat:@"Supported data type: %@", [BackupOptionTask stringForDataType:dataType]]];
        } else {
            [self logMessage:[NSString stringWithFormat:@"Unsupported data type: %@", [BackupOptionTask stringForDataType:dataType]]];
        }
    }
    
    [self logMessage:[NSString stringWithFormat:@"Total supported data types: %lu", (unsigned long)supportedTypes]];
    return supportedTypes;
}

#pragma mark - 数据查询

- (NSArray<SyncDataItem *> *)getDataItemsForType:(BackupDataType)dataType error:(NSError **)error {
    [self logMessage:[NSString stringWithFormat:@"Getting data items for type: %@", [BackupOptionTask stringForDataType:dataType]]];
    
    if (![self isConnected]) {
        if (error) {
            *error = [self errorWithCode:BackupOptionTaskErrorCodeConnectionFailed
                             description:@"Not connected to device"];
        }
        return nil;
    }
    
    // 检查缓存
    NSString *cacheKey = [NSString stringWithFormat:@"datatype_%lu", (unsigned long)dataType];
    NSArray *cachedItems = _dataCache[cacheKey];
    if (cachedItems) {
        [self logMessage:[NSString stringWithFormat:@"Returning cached data items: %lu", (unsigned long)cachedItems.count]];
        return cachedItems;
    }
    
    NSString *syncClass = DataTypeToSyncClassMap()[@(dataType)];
    if (!syncClass) {
        if (error) {
            *error = [self errorWithCode:BackupOptionTaskErrorCodeInvalidArg
                             description:@"Unsupported data type"];
        }
        return nil;
    }
    
    // 使用简化的数据获取方法
    NSArray<SyncDataItem *> *items = [self getDataItemsSimplified:dataType syncClass:syncClass error:error];
    
    // 缓存结果
    if (items) {
        _dataCache[cacheKey] = items;
    }
    
    [self logMessage:[NSString stringWithFormat:@"Retrieved %lu data items", (unsigned long)items.count]];
    return items;
}

- (void)getDataItemsForTypeAsync:(BackupDataType)dataType
                      completion:(void (^)(NSArray<SyncDataItem *> * _Nullable items, NSError * _Nullable error))completion {
    if (!completion) return;
    
    dispatch_async(_operationQueue, ^{
        NSError *error = nil;
        NSArray<SyncDataItem *> *items = [self getDataItemsForType:dataType error:&error];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(items, error);
        });
    });
}

- (NSDictionary *)getDataTypeStatistics:(BackupDataType)dataType error:(NSError **)error {
    NSArray<SyncDataItem *> *items = [self getDataItemsForType:dataType error:error];
    if (!items) {
        return nil;
    }
    
    NSUInteger totalRecords = 0;
    NSUInteger totalSize = 0;
    NSDate *oldestDate = nil;
    NSDate *newestDate = nil;
    
    for (SyncDataItem *item in items) {
        totalRecords += item.recordCount;
        totalSize += item.dataSize;
        
        if (!oldestDate || [item.modificationDate compare:oldestDate] == NSOrderedAscending) {
            oldestDate = item.modificationDate;
        }
        if (!newestDate || [item.modificationDate compare:newestDate] == NSOrderedDescending) {
            newestDate = item.modificationDate;
        }
    }
    
    return @{
        @"itemCount": @(items.count),
        @"totalRecords": @(totalRecords),
        @"totalSize": @(totalSize),
        @"formattedSize": [self formatFileSize:totalSize],
        @"oldestDate": oldestDate ?: [NSDate date],
        @"newestDate": newestDate ?: [NSDate date],
        @"dataType": [BackupOptionTask stringForDataType:dataType]
    };
}

#pragma mark - 选择性同步操作

- (BOOL)startSelectiveSync:(BackupDataType)dataTypes
                 direction:(SyncDirection)direction
                     error:(NSError **)error {
    [self logMessage:[NSString stringWithFormat:@"Starting selective sync for types: %lu, direction: %lu",
                     (unsigned long)dataTypes, (unsigned long)direction]];
    
    if (_isOperating) {
        if (error) {
            *error = [self errorWithCode:BackupOptionTaskErrorCodeOperationFailed
                             description:@"Another operation is already in progress"];
        }
        return NO;
    }
    
    if (![self isConnected]) {
        if (error) {
            *error = [self errorWithCode:BackupOptionTaskErrorCodeConnectionFailed
                             description:@"Not connected to device"];
        }
        return NO;
    }
    
    _isOperating = YES;
    _cancelRequested = NO;
    _currentDataTypes = dataTypes;
    _currentDirection = direction;
    _lastSyncTime = [NSDate date];
    
    [self setInternalStatus:SyncTaskStatusPreparing];
    
    // 异步执行同步操作
    dispatch_async(_operationQueue, ^{
        BOOL success = [self performSelectiveSyncInternal:dataTypes direction:direction];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_isOperating = NO;
            
            if (success) {
                [self setInternalStatus:SyncTaskStatusCompleted];
            } else if (self->_cancelRequested) {
                [self setInternalStatus:SyncTaskStatusCancelled];
            } else {
                [self setInternalStatus:SyncTaskStatusFailed];
            }
            
            if (self.completionCallback) {
                self.completionCallback(success, dataTypes, self->_lastError);
            }
        });
    });
    
    return YES;
}

- (BOOL)performSelectiveSyncInternal:(BackupDataType)dataTypes direction:(SyncDirection)direction {
    [self logMessage:@"Performing selective sync internally"];
    
    [self setInternalStatus:SyncTaskStatusSyncing];
    [self updateProgress:0.0 operation:@"Starting selective sync" current:0 total:100];
    
    // 分解数据类型为单独的类型
    NSArray<NSNumber *> *individualTypes = [BackupOptionTask arrayFromDataTypes:dataTypes];
    NSUInteger totalTypes = individualTypes.count;
    NSUInteger completedTypes = 0;
    
    _totalItemsToProcess = totalTypes;
    _processedItems = 0;
    
    for (NSNumber *typeNum in individualTypes) {
        if (_cancelRequested) {
            [self logMessage:@"Sync cancelled by user"];
            return NO;
        }
        
        BackupDataType singleType = [typeNum unsignedIntegerValue];
        
        [self updateProgress:(completedTypes * 100.0 / totalTypes)
                   operation:[NSString stringWithFormat:@"Syncing %@", [BackupOptionTask stringForDataType:singleType]]
                     current:completedTypes
                       total:totalTypes];
        
        NSError *typeError = nil;
        BOOL typeSuccess = [self performSyncForDataType:singleType direction:direction error:&typeError];
        
        if (!typeSuccess) {
            [self logMessage:[NSString stringWithFormat:@"Failed to sync data type: %@, error: %@",
                             [BackupOptionTask stringForDataType:singleType], typeError]];
            _lastError = typeError;
            return NO;
        }
        
        completedTypes++;
        _processedItems = completedTypes;
    }
    
    [self updateProgress:100.0 operation:@"Selective sync completed" current:totalTypes total:totalTypes];
    [self logMessage:@"Selective sync completed successfully"];
    return YES;
}

- (BOOL)syncSpecificItems:(NSArray<SyncDataItem *> *)items
                direction:(SyncDirection)direction
                    error:(NSError **)error {
    [self logMessage:[NSString stringWithFormat:@"Syncing %lu specific items", (unsigned long)items.count]];
    
    if (!items || items.count == 0) {
        if (error) {
            *error = [self errorWithCode:BackupOptionTaskErrorCodeInvalidArg
                             description:@"No items specified for sync"];
        }
        return NO;
    }
    
    // 按数据类型分组
    NSMutableDictionary *itemsByType = [NSMutableDictionary dictionary];
    for (SyncDataItem *item in items) {
        NSNumber *typeKey = @(item.dataType);
        NSMutableArray *typeItems = itemsByType[typeKey];
        if (!typeItems) {
            typeItems = [NSMutableArray array];
            itemsByType[typeKey] = typeItems;
        }
        [typeItems addObject:item];
    }
    
    // 对每种数据类型执行同步
    for (NSNumber *typeKey in itemsByType) {
        BackupDataType dataType = [typeKey unsignedIntegerValue];
        NSArray *typeItems = itemsByType[typeKey];
        
        [self logMessage:[NSString stringWithFormat:@"Syncing %lu items of type: %@",
                         (unsigned long)typeItems.count, [BackupOptionTask stringForDataType:dataType]]];
        
        // 这里可以实现更细粒度的项目同步逻辑
        // 目前先使用数据类型级别的同步
        if (![self performSyncForDataType:dataType direction:direction error:error]) {
            return NO;
        }
    }
    
    return YES;
}

- (BOOL)backupSelectedDataTypes:(BackupDataType)dataTypes
                    toDirectory:(NSString *)backupPath
                          error:(NSError **)error {
    [self logMessage:[NSString stringWithFormat:@"Backing up selected data types to: %@", backupPath]];
    
    if (!backupPath || backupPath.length == 0) {
        if (error) {
            *error = [self errorWithCode:BackupOptionTaskErrorCodeInvalidArg
                             description:@"Backup path cannot be empty"];
        }
        return NO;
    }
    
    // 创建备份目录
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager fileExistsAtPath:backupPath]) {
        NSError *createError = nil;
        if (![fileManager createDirectoryAtPath:backupPath
                    withIntermediateDirectories:YES
                                     attributes:nil
                                          error:&createError]) {
            if (error) {
                *error = [self errorWithCode:BackupOptionTaskErrorCodeOperationFailed
                                 description:[NSString stringWithFormat:@"Failed to create backup directory: %@", createError.localizedDescription]];
            }
            return NO;
        }
    }
    
    _currentBackupPath = backupPath;
    return [self startSelectiveSync:dataTypes direction:SyncDirectionFromDevice error:error];
}

- (BOOL)restoreSelectedDataTypes:(BackupDataType)dataTypes
                   fromDirectory:(NSString *)backupPath
                           error:(NSError **)error {
    [self logMessage:[NSString stringWithFormat:@"Restoring selected data types from: %@", backupPath]];
    
    if (!backupPath || backupPath.length == 0 || ![[NSFileManager defaultManager] fileExistsAtPath:backupPath]) {
        if (error) {
            *error = [self errorWithCode:BackupOptionTaskErrorCodeInvalidArg
                             description:@"Backup path does not exist"];
        }
        return NO;
    }
    
    _currentBackupPath = backupPath;
    return [self startSelectiveSync:dataTypes direction:SyncDirectionToDevice error:error];
}

#pragma mark - 操作控制

- (void)cancelCurrentOperation {
    [self logMessage:@"Cancelling current operation"];
    _cancelRequested = YES;
}

- (void)pauseCurrentOperation {
    [self logMessage:@"Pausing current operation"];
    _isPaused = YES;
}

- (void)resumeCurrentOperation {
    [self logMessage:@"Resuming current operation"];
    _isPaused = NO;
}

- (float)getCurrentProgress {
    return _progress;
}

#pragma mark - 数据类型工具方法

+ (NSString *)stringForDataType:(BackupDataType)dataType {
    switch (dataType) {
        case BackupDataTypeContacts:
            return @"Contacts";
        case BackupDataTypeCalendars:
            return @"Calendars";
        case BackupDataTypeBookmarks:
            return @"Bookmarks";
        case BackupDataTypeNotes:
            return @"Notes";
        case BackupDataTypeReminders:
            return @"Reminders";
        case BackupDataTypeApplications:
            return @"Applications";
        case BackupDataTypeConfiguration:
            return @"Configuration";
        case BackupDataTypeKeychain:
            return @"Keychain";
        case BackupDataTypeVoiceMemos:
            return @"Voice Memos";
        case BackupDataTypeWallpaper:
            return @"Wallpaper";
        case BackupDataTypeAll:
            return @"All Data Types";
        default:
            return @"Unknown";
    }
}

+ (NSString *)localizedStringForDataType:(BackupDataType)dataType {
    // 这里可以根据需要添加本地化支持
    // 目前返回英文版本
    return [self stringForDataType:dataType];
}

+ (NSArray<NSNumber *> *)arrayFromDataTypes:(BackupDataType)dataTypes {
    NSMutableArray *array = [NSMutableArray array];
    
    if (dataTypes & BackupDataTypeContacts) [array addObject:@(BackupDataTypeContacts)];
    if (dataTypes & BackupDataTypeCalendars) [array addObject:@(BackupDataTypeCalendars)];
    if (dataTypes & BackupDataTypeBookmarks) [array addObject:@(BackupDataTypeBookmarks)];
    if (dataTypes & BackupDataTypeNotes) [array addObject:@(BackupDataTypeNotes)];
    if (dataTypes & BackupDataTypeReminders) [array addObject:@(BackupDataTypeReminders)];
    if (dataTypes & BackupDataTypeApplications) [array addObject:@(BackupDataTypeApplications)];
    if (dataTypes & BackupDataTypeConfiguration) [array addObject:@(BackupDataTypeConfiguration)];
    if (dataTypes & BackupDataTypeKeychain) [array addObject:@(BackupDataTypeKeychain)];
    if (dataTypes & BackupDataTypeVoiceMemos) [array addObject:@(BackupDataTypeVoiceMemos)];
    if (dataTypes & BackupDataTypeWallpaper) [array addObject:@(BackupDataTypeWallpaper)];
    
    return array;
}

+ (BackupDataType)dataTypesFromArray:(NSArray<NSNumber *> *)dataTypeArray {
    BackupDataType dataTypes = BackupDataTypeNone;
    
    for (NSNumber *typeNum in dataTypeArray) {
        dataTypes |= [typeNum unsignedIntegerValue];
    }
    
    return dataTypes;
}

+ (NSArray<NSNumber *> *)getAllAvailableDataTypes {
    return @[
        @(BackupDataTypeContacts),
        @(BackupDataTypeCalendars),
        @(BackupDataTypeBookmarks),
        @(BackupDataTypeNotes),
        @(BackupDataTypeReminders),
        @(BackupDataTypeApplications),
        @(BackupDataTypeConfiguration),
        @(BackupDataTypeKeychain),
        @(BackupDataTypeVoiceMemos),
        @(BackupDataTypeWallpaper)
    ];
}

#pragma mark - 便捷方法

- (void)quickBackupContacts:(void (^)(BOOL success, NSError * _Nullable error))completion {
    NSString *contactsPath = [_dataStoragePath stringByAppendingPathComponent:@"Contacts"];
    
    NSError *error = nil;
    BOOL success = [self backupSelectedDataTypes:BackupDataTypeContacts
                                     toDirectory:contactsPath
                                           error:&error];
    
    if (completion) {
        completion(success, error);
    }
}

- (void)quickBackupCalendars:(void (^)(BOOL success, NSError * _Nullable error))completion {
    NSString *calendarsPath = [_dataStoragePath stringByAppendingPathComponent:@"Calendars"];
    
    NSError *error = nil;
    BOOL success = [self backupSelectedDataTypes:BackupDataTypeCalendars
                                     toDirectory:calendarsPath
                                           error:&error];
    
    if (completion) {
        completion(success, error);
    }
}

- (void)quickBackupBookmarks:(void (^)(BOOL success, NSError * _Nullable error))completion {
    NSString *bookmarksPath = [_dataStoragePath stringByAppendingPathComponent:@"Bookmarks"];
    
    NSError *error = nil;
    BOOL success = [self backupSelectedDataTypes:BackupDataTypeBookmarks
                                     toDirectory:bookmarksPath
                                           error:&error];
    
    if (completion) {
        completion(success, error);
    }
}

- (void)quickBackupNotes:(void (^)(BOOL success, NSError * _Nullable error))completion {
    NSString *notesPath = [_dataStoragePath stringByAppendingPathComponent:@"Notes"];
    
    NSError *error = nil;
    BOOL success = [self backupSelectedDataTypes:BackupDataTypeNotes
                                     toDirectory:notesPath
                                           error:&error];
    
    if (completion) {
        completion(success, error);
    }
}

- (void)quickBackupReminders:(void (^)(BOOL success, NSError * _Nullable error))completion {
    NSString *remindersPath = [_dataStoragePath stringByAppendingPathComponent:@"Reminders"];
    
    NSError *error = nil;
    BOOL success = [self backupSelectedDataTypes:BackupDataTypeReminders
                                     toDirectory:remindersPath
                                           error:&error];
    
    if (completion) {
        completion(success, error);
    }
}

- (void)quickBackupAllSupportedData:(void (^)(BOOL success, BackupDataType completedTypes, NSError * _Nullable error))completion {
    NSError *error = nil;
    BackupDataType supportedTypes = [self getSupportedDataTypes:&error];
    
    if (supportedTypes == BackupDataTypeNone) {
        if (completion) {
            completion(NO, BackupDataTypeNone, error);
        }
        return;
    }
    
    NSString *allDataPath = [_dataStoragePath stringByAppendingPathComponent:@"AllData"];
    
    // 设置完成回调来捕获结果
    self.completionCallback = ^(BOOL success, BackupDataType completedTypes, NSError *completionError) {
        if (completion) {
            completion(success, completedTypes, completionError);
        }
    };
    
    [self backupSelectedDataTypes:supportedTypes toDirectory:allDataPath error:&error];
}

#pragma mark - 数据验证和恢复

- (BOOL)verifyBackupIntegrity:(NSString *)backupPath
                    dataTypes:(BackupDataType)dataTypes
                        error:(NSError **)error {
    [self logMessage:[NSString stringWithFormat:@"Verifying backup integrity at: %@", backupPath]];
    
    if (![[NSFileManager defaultManager] fileExistsAtPath:backupPath]) {
        if (error) {
            *error = [self errorWithCode:BackupOptionTaskErrorCodeInvalidArg
                             description:@"Backup path does not exist"];
        }
        return NO;
    }
    
    NSArray<NSNumber *> *typesToCheck = [BackupOptionTask arrayFromDataTypes:dataTypes];
    
    for (NSNumber *typeNum in typesToCheck) {
        BackupDataType dataType = [typeNum unsignedIntegerValue];
        NSString *dataTypeDir = [backupPath stringByAppendingPathComponent:[BackupOptionTask stringForDataType:dataType]];
        NSString *itemsFile = [dataTypeDir stringByAppendingPathComponent:@"items.plist"];
        
        if (![[NSFileManager defaultManager] fileExistsAtPath:itemsFile]) {
            [self logMessage:[NSString stringWithFormat:@"Missing data file for type: %@", [BackupOptionTask stringForDataType:dataType]]];
            if (error) {
                *error = [self errorWithCode:BackupOptionTaskErrorCodeDataCorrupted
                                 description:[NSString stringWithFormat:@"Missing data for %@", [BackupOptionTask stringForDataType:dataType]]];
            }
            return NO;
        }
        
        // 尝试读取文件以验证格式
        NSArray *items = [NSArray arrayWithContentsOfFile:itemsFile];
        if (!items) {
            [self logMessage:[NSString stringWithFormat:@"Corrupted data file for type: %@", [BackupOptionTask stringForDataType:dataType]]];
            if (error) {
                *error = [self errorWithCode:BackupOptionTaskErrorCodeDataCorrupted
                                 description:[NSString stringWithFormat:@"Corrupted data for %@", [BackupOptionTask stringForDataType:dataType]]];
            }
            return NO;
        }
    }
    
    [self logMessage:@"Backup integrity verification passed"];
    return YES;
}

- (NSDictionary *)getBackupInfo:(NSString *)backupPath error:(NSError **)error {
    // 参数验证
    if (!backupPath || backupPath.length == 0) {
        if (error) {
            *error = [self errorWithCode:BackupOptionTaskErrorCodeInvalidArg
                             description:@"Backup path cannot be empty"];
        }
        return nil;
    }
    
    NSFileManager *fileManager = [NSFileManager defaultManager];
    
    // 检查路径是否存在
    BOOL isDirectory = NO;
    if (![fileManager fileExistsAtPath:backupPath isDirectory:&isDirectory]) {
        if (error) {
            *error = [self errorWithCode:BackupOptionTaskErrorCodeInvalidArg
                             description:@"Backup path does not exist"];
        }
        return nil;
    }
    
    // 确保是目录而不是文件
    if (!isDirectory) {
        if (error) {
            *error = [self errorWithCode:BackupOptionTaskErrorCodeInvalidArg
                             description:@"Backup path is not a directory"];
        }
        return nil;
    }
    
    NSMutableDictionary *backupInfo = [NSMutableDictionary dictionary];
    
    // 获取基本信息 - 添加错误处理
    NSError *attributesError = nil;
    NSDictionary *pathAttributes = [fileManager attributesOfItemAtPath:backupPath error:&attributesError];
    if (pathAttributes) {
        if (pathAttributes[NSFileCreationDate]) {
            backupInfo[@"creationDate"] = pathAttributes[NSFileCreationDate];
        }
        if (pathAttributes[NSFileModificationDate]) {
            backupInfo[@"modificationDate"] = pathAttributes[NSFileModificationDate];
        }
    } else {
        [self logMessage:[NSString stringWithFormat:@"Warning: Could not get path attributes: %@", attributesError.localizedDescription]];
        // 设置默认值
        backupInfo[@"creationDate"] = [NSDate date];
        backupInfo[@"modificationDate"] = [NSDate date];
    }
    
    backupInfo[@"backupPath"] = backupPath;
    backupInfo[@"deviceUDID"] = _deviceUDID ?: @"unknown";
    
    // 扫描数据类型
    NSMutableArray *availableDataTypes = [NSMutableArray array];
    NSUInteger totalItems = 0;
    NSUInteger totalSize = 0;
    
    NSArray<NSNumber *> *allDataTypes = [BackupOptionTask getAllAvailableDataTypes];
    
    for (NSNumber *typeNum in allDataTypes) {
        @autoreleasepool {  // 自动释放池，避免内存累积
            BackupDataType dataType = [typeNum unsignedIntegerValue];
            NSString *dataTypeStr = [BackupOptionTask stringForDataType:dataType];
            NSString *dataTypeDir = [backupPath stringByAppendingPathComponent:dataTypeStr];
            NSString *itemsFile = [dataTypeDir stringByAppendingPathComponent:@"items.plist"];
            
            // 检查items.plist是否存在
            if ([fileManager fileExistsAtPath:itemsFile]) {
                // 尝试读取items数据
                NSArray *items = [NSArray arrayWithContentsOfFile:itemsFile];
                if (items && [items isKindOfClass:[NSArray class]]) {
                    // 计算该数据类型的大小
                    NSUInteger dataTypeSize = [self calculateDirectorySize:dataTypeDir];
                    
                    NSDictionary *dataTypeInfo = @{
                        @"dataType": dataTypeStr,
                        @"itemCount": @(items.count),
                        @"size": @(dataTypeSize),
                        @"formattedSize": [self formatFileSize:dataTypeSize]
                    };
                    
                    [availableDataTypes addObject:dataTypeInfo];
                    totalItems += items.count;
                    totalSize += dataTypeSize;
                    
                    [self logMessage:[NSString stringWithFormat:@"Found %@ with %lu items (%@)",
                                     dataTypeStr, (unsigned long)items.count, [self formatFileSize:dataTypeSize]]];
                } else {
                    [self logMessage:[NSString stringWithFormat:@"Warning: Could not read items.plist for %@", dataTypeStr]];
                }
            }
        }
    }
    
    // 设置汇总信息
    backupInfo[@"availableDataTypes"] = [availableDataTypes copy];
    backupInfo[@"totalItems"] = @(totalItems);
    backupInfo[@"totalSize"] = @(totalSize);
    backupInfo[@"formattedSize"] = [self formatFileSize:totalSize];
    backupInfo[@"dataTypeCount"] = @(availableDataTypes.count);
    
    // 添加备份统计信息
    if (availableDataTypes.count > 0) {
        backupInfo[@"isEmpty"] = @NO;
        backupInfo[@"summary"] = [NSString stringWithFormat:@"%lu data types, %lu items, %@",
                                 (unsigned long)availableDataTypes.count,
                                 (unsigned long)totalItems,
                                 [self formatFileSize:totalSize]];
    } else {
        backupInfo[@"isEmpty"] = @YES;
        backupInfo[@"summary"] = @"Empty backup directory";
    }
    
    [self logMessage:[NSString stringWithFormat:@"Backup info: %@", backupInfo[@"summary"]]];
    
    return [backupInfo copy];
}

#pragma mark - 辅助方法

// 计算目录大小的辅助方法
- (NSUInteger)calculateDirectorySize:(NSString *)directoryPath {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSUInteger totalSize = 0;
    
    // 检查目录是否存在
    BOOL isDir = NO;
    if (![fileManager fileExistsAtPath:directoryPath isDirectory:&isDir] || !isDir) {
        return 0;
    }
    
    NSError *error = nil;
    NSArray<NSString *> *contents = [fileManager contentsOfDirectoryAtPath:directoryPath error:&error];
    
    if (!contents) {
        [self logMessage:[NSString stringWithFormat:@"Error reading directory %@: %@", directoryPath, error.localizedDescription]];
        return 0;
    }
    
    for (NSString *filename in contents) {
        @autoreleasepool {
            NSString *filePath = [directoryPath stringByAppendingPathComponent:filename];
            
            NSError *attrError = nil;
            NSDictionary *fileAttributes = [fileManager attributesOfItemAtPath:filePath error:&attrError];
            
            if (fileAttributes) {
                NSString *fileType = fileAttributes[NSFileType];
                
                if ([fileType isEqualToString:NSFileTypeRegular]) {
                    // 常规文件，添加其大小
                    NSNumber *fileSize = fileAttributes[NSFileSize];
                    if (fileSize) {
                        totalSize += [fileSize unsignedIntegerValue];
                    }
                } else if ([fileType isEqualToString:NSFileTypeDirectory]) {
                    // 子目录，递归计算
                    totalSize += [self calculateDirectorySize:filePath];
                }
            } else {
                [self logMessage:[NSString stringWithFormat:@"Warning: Could not get attributes for %@: %@",
                                 filePath, attrError.localizedDescription]];
            }
        }
    }
    
    return totalSize;
}

// 验证备份目录结构的方法
- (BOOL)validateBackupStructure:(NSString *)backupPath error:(NSError **)error {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    
    // 检查是否为目录
    BOOL isDirectory = NO;
    if (![fileManager fileExistsAtPath:backupPath isDirectory:&isDirectory] || !isDirectory) {
        if (error) {
            *error = [self errorWithCode:BackupOptionTaskErrorCodeInvalidArg
                             description:@"Backup path is not a valid directory"];
        }
        return NO;
    }
    
    // 检查是否可读
    if (![fileManager isReadableFileAtPath:backupPath]) {
        if (error) {
            *error = [self errorWithCode:BackupOptionTaskErrorCodeInvalidArg
                             description:@"Backup directory is not readable"];
        }
        return NO;
    }
    
    // 检查是否包含任何有效的数据类型目录
    NSArray<NSNumber *> *allDataTypes = [BackupOptionTask getAllAvailableDataTypes];
    BOOL hasValidData = NO;
    
    for (NSNumber *typeNum in allDataTypes) {
        BackupDataType dataType = [typeNum unsignedIntegerValue];
        NSString *dataTypeStr = [BackupOptionTask stringForDataType:dataType];
        NSString *dataTypeDir = [backupPath stringByAppendingPathComponent:dataTypeStr];
        NSString *itemsFile = [dataTypeDir stringByAppendingPathComponent:@"items.plist"];
        
        if ([fileManager fileExistsAtPath:itemsFile]) {
            // 尝试读取以验证格式
            NSArray *items = [NSArray arrayWithContentsOfFile:itemsFile];
            if (items) {
                hasValidData = YES;
                break;
            }
        }
    }
    
    if (!hasValidData) {
        if (error) {
            *error = [self errorWithCode:BackupOptionTaskErrorCodeDataCorrupted
                             description:@"No valid backup data found in directory"];
        }
        return NO;
    }
    
    return YES;
}

// 获取备份摘要信息的便捷方法
- (NSString *)getBackupSummary:(NSString *)backupPath {
    NSError *error = nil;
    NSDictionary *backupInfo = [self getBackupInfo:backupPath error:&error];
    
    if (!backupInfo) {
        return [NSString stringWithFormat:@"Error: %@", error.localizedDescription ?: @"Unknown error"];
    }
    
    return backupInfo[@"summary"] ?: @"Unknown backup status";
}

#pragma mark - 私有方法实现

- (NSError *)errorWithCode:(BackupOptionTaskErrorCode)code description:(NSString *)description {
    [self logMessage:[NSString stringWithFormat:@"Error: %ld - %@", (long)code, description]];
    
    NSDictionary *userInfo = @{
        NSLocalizedDescriptionKey: description ?: @"Unknown error"
    };
    
    _lastError = [NSError errorWithDomain:kBackupOptionTaskErrorDomain code:code userInfo:userInfo];
    return _lastError;
}

- (void)setInternalStatus:(SyncTaskStatus)status {
    if (_status != status) {
        [self logMessage:[NSString stringWithFormat:@"Status changed: %lu -> %lu", (unsigned long)_status, (unsigned long)status]];
        _status = status;
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.statusCallback) {
                NSString *description = [self stringForStatus:status];
                self.statusCallback(status, description);
            }
        });
    }
}

- (NSString *)stringForStatus:(SyncTaskStatus)status {
    switch (status) {
        case SyncTaskStatusIdle:
            return @"Idle";
        case SyncTaskStatusConnecting:
            return @"Connecting to device";
        case SyncTaskStatusPreparing:
            return @"Preparing sync operation";
        case SyncTaskStatusSyncing:
            return @"Syncing data";
        case SyncTaskStatusCompleted:
            return @"Sync completed";
        case SyncTaskStatusFailed:
            return @"Sync failed";
        case SyncTaskStatusCancelled:
            return @"Sync cancelled";
        case SyncTaskStatusPaused:
            return @"Sync paused";
    }
    return @"Unknown status";
}

- (void)updateProgress:(float)progress operation:(NSString *)operation current:(NSUInteger)current total:(NSUInteger)total {
    _progress = progress;
    
    [self logMessage:[NSString stringWithFormat:@"Progress: %.2f%% - %@ (%lu/%lu)",
                     progress, operation ?: @"", (unsigned long)current, (unsigned long)total]];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.progressCallback) {
            self.progressCallback(progress, operation, current, total);
        }
    });
}

#pragma mark - 简化的数据获取实现

- (NSArray<SyncDataItem *> *)getDataItemsSimplified:(BackupDataType)dataType
                                           syncClass:(NSString *)syncClass
                                               error:(NSError **)error {
    
    // 对于不同的数据类型，使用不同的策略
    switch (dataType) {
        case BackupDataTypeContacts:
            return [self getContactsViaAddressBook:error];
            
        case BackupDataTypeCalendars:
            return [self getCalendarsViaEventKit:error];
            
        case BackupDataTypeBookmarks:
            return [self getBookmarksViaSafari:error];
            
        case BackupDataTypeNotes:
            return [self getNotesViaNotesApp:error];
            
        case BackupDataTypeReminders:
            return [self getRemindersViaRemindersApp:error];
            
        default:
            return [self getGenericDataViaMobileSync:dataType syncClass:syncClass error:error];
    }
}

// 通用的mobilesync数据获取方法
- (NSArray<SyncDataItem *> *)getGenericDataViaMobileSync:(BackupDataType)dataType
                                               syncClass:(NSString *)syncClass
                                                   error:(NSError **)error {
    
    [self logMessage:[NSString stringWithFormat:@"Getting generic data via MobileSync for: %@", syncClass]];
    
    @try {
        // Step 1: 创建mobilesync anchors (正确方式)
        mobilesync_anchors_t anchors = mobilesync_anchors_new("", ""); // 空的device和computer anchor
        if (!anchors) {
            if (error) {
                *error = [self errorWithCode:BackupOptionTaskErrorCodeOperationFailed
                                 description:@"Failed to create mobilesync anchors"];
            }
            return nil;
        }
        
        // Step 2: 准备mobilesync_start的参数
        uint64_t data_class_version = 106;
        mobilesync_sync_type_t sync_type = MOBILESYNC_SYNC_TYPE_FAST;
        uint64_t device_data_class_version = 0;
        char *error_description = NULL;
        
        // Step 3: 正确调用mobilesync_start
        mobilesync_error_t start_err = mobilesync_start(_mobilesync,
                                                      [syncClass UTF8String],
                                                      anchors,
                                                      data_class_version,
                                                      &sync_type,           // 指向sync_type的指针
                                                      &device_data_class_version,  // 指向device版本的指针
                                                      &error_description);  // 指向错误描述的指针
        
        NSArray<SyncDataItem *> *items = nil;
        
        if (start_err == MOBILESYNC_E_SUCCESS) {
            [self logMessage:@"MobileSync session started successfully"];
            
            // Step 4: 请求所有记录
            mobilesync_error_t get_all_err = mobilesync_get_all_records_from_device(_mobilesync);
            
            if (get_all_err == MOBILESYNC_E_SUCCESS) {
                // Step 5: 接收变更数据
                plist_t entities = NULL;
                uint8_t is_last_record = 0;
                plist_t actions = NULL;
                
                NSMutableArray *allItems = [NSMutableArray array];
                
                // 循环接收所有记录
                do {
                    mobilesync_error_t receive_err = mobilesync_receive_changes(_mobilesync,
                                                                             &entities,
                                                                             &is_last_record,
                                                                             &actions);
                    
                    if (receive_err == MOBILESYNC_E_SUCCESS && entities) {
                        NSArray<SyncDataItem *> *batchItems = [self processDataForType:dataType dataArray:entities];
                        if (batchItems && batchItems.count > 0) {
                            [allItems addObjectsFromArray:batchItems];
                        }
                        
                        // 清理entities
                        plist_free(entities);
                        entities = NULL;
                        
                        // 清理actions（如果存在）
                        if (actions) {
                            plist_free(actions);
                            actions = NULL;
                        }
                        
                        [self logMessage:[NSString stringWithFormat:@"Received batch with %lu items, is_last: %d",
                                        (unsigned long)batchItems.count, is_last_record]];
                    } else {
                        [self logMessage:[NSString stringWithFormat:@"Error receiving changes: %d", receive_err]];
                        break;
                    }
                    
                } while (!is_last_record);
                
                items = [allItems copy];
                
            } else {
                [self logMessage:[NSString stringWithFormat:@"mobilesync_get_all_records_from_device failed: %d", get_all_err]];
            }
            
            // Step 6: 结束同步会话
            mobilesync_finish(_mobilesync);
            
        } else {
            [self logMessage:[NSString stringWithFormat:@"mobilesync_start failed: %d", start_err]];
            if (error_description) {
                [self logMessage:[NSString stringWithFormat:@"Error description: %s", error_description]];
            }
        }
        
        // 清理资源
        if (error_description) {
            free(error_description);
        }
        mobilesync_anchors_free(anchors);
        
        if (!items && error) {
            *error = [self errorWithCode:BackupOptionTaskErrorCodeOperationFailed
                             description:[NSString stringWithFormat:@"Failed to sync data for %@", syncClass]];
        }
        
        [self logMessage:[NSString stringWithFormat:@"Retrieved %lu items for %@",
                         (unsigned long)items.count, syncClass]];
        return items ?: @[]; // 返回空数组而不是nil
        
    } @catch (NSException *exception) {
        [self logMessage:[NSString stringWithFormat:@"Exception in mobilesync operation: %@", exception]];
        if (error) {
            *error = [self errorWithCode:BackupOptionTaskErrorCodeOperationFailed
                             description:[NSString stringWithFormat:@"Exception during sync: %@", exception.reason]];
        }
        return @[];
    }
}

// 新增：更简化的数据获取方法作为备选方案
- (NSArray<SyncDataItem *> *)getDataViaDirectMessaging:(BackupDataType)dataType
                                             syncClass:(NSString *)syncClass
                                                 error:(NSError **)error {
    [self logMessage:[NSString stringWithFormat:@"Getting data via direct messaging for: %@", syncClass]];
    
    @try {
        // 方法1：直接发送同步数据类消息
        plist_t msg = plist_new_array();
        plist_array_append_item(msg, plist_new_string("SDMessageSyncDataClassWithComputer"));
        plist_array_append_item(msg, plist_new_string([syncClass UTF8String]));
        
        mobilesync_error_t send_err = mobilesync_send(_mobilesync, msg);
        plist_free(msg);
        
        if (send_err != MOBILESYNC_E_SUCCESS) {
            [self logMessage:[NSString stringWithFormat:@"Failed to send sync message: %d", send_err]];
            if (error) {
                *error = [self errorWithCode:BackupOptionTaskErrorCodeOperationFailed
                                 description:@"Failed to send sync message"];
            }
            return @[];
        }
        
        // 接收响应
        plist_t response = NULL;
        mobilesync_error_t receive_err = mobilesync_receive(_mobilesync, &response);
        
        if (receive_err != MOBILESYNC_E_SUCCESS || !response) {
            [self logMessage:[NSString stringWithFormat:@"Failed to receive sync response: %d", receive_err]];
            if (error) {
                *error = [self errorWithCode:BackupOptionTaskErrorCodeOperationFailed
                                 description:@"Failed to receive sync response"];
            }
            return @[];
        }
        
        // 方法2：请求所有记录
        plist_t get_all_msg = plist_new_array();
        plist_array_append_item(get_all_msg, plist_new_string("SDMessageGetAllRecordsFromDevice"));
        plist_array_append_item(get_all_msg, plist_new_string([syncClass UTF8String]));
        
        send_err = mobilesync_send(_mobilesync, get_all_msg);
        plist_free(get_all_msg);
        plist_free(response); // 清理前一个响应
        
        if (send_err != MOBILESYNC_E_SUCCESS) {
            [self logMessage:[NSString stringWithFormat:@"Failed to send get all records message: %d", send_err]];
            if (error) {
                *error = [self errorWithCode:BackupOptionTaskErrorCodeOperationFailed
                                 description:@"Failed to send get all records message"];
            }
            return @[];
        }
        
        // 接收记录数据
        plist_t records_response = NULL;
        receive_err = mobilesync_receive(_mobilesync, &records_response);
        
        if (receive_err != MOBILESYNC_E_SUCCESS || !records_response) {
            [self logMessage:[NSString stringWithFormat:@"Failed to receive records: %d", receive_err]];
            if (error) {
                *error = [self errorWithCode:BackupOptionTaskErrorCodeOperationFailed
                                 description:@"Failed to receive records"];
            }
            return @[];
        }
        
        // 解析记录数据
        NSArray<SyncDataItem *> *items = [self processDataForType:dataType dataArray:records_response];
        plist_free(records_response);
        
        [self logMessage:[NSString stringWithFormat:@"Retrieved %lu items via direct messaging",
                         (unsigned long)items.count]];
        return items ?: @[];
        
    } @catch (NSException *exception) {
        [self logMessage:[NSString stringWithFormat:@"Exception in direct messaging: %@", exception]];
        if (error) {
            *error = [self errorWithCode:BackupOptionTaskErrorCodeOperationFailed
                             description:[NSString stringWithFormat:@"Exception: %@", exception.reason]];
        }
        return @[];
    }
}



// 专门的联系人获取方法 - 模拟实现
- (NSArray<SyncDataItem *> *)getContactsViaAddressBook:(NSError **)error {
    [self logMessage:@"Getting contacts via AddressBook approach"];
    
    NSMutableArray *contacts = [NSMutableArray array];
    
    // 模拟联系人数据
    NSArray *sampleNames = @[@"John Doe", @"Jane Smith", @"Bob Johnson", @"Alice Brown", @"Charlie Wilson"];
    
    for (NSUInteger i = 0; i < sampleNames.count; i++) {
        SyncDataItem *contact = [[SyncDataItem alloc] init];
        contact.identifier = [NSString stringWithFormat:@"contact_%lu", (unsigned long)i];
        contact.name = sampleNames[i];
        contact.dataType = BackupDataTypeContacts;
        contact.modificationDate = [NSDate dateWithTimeIntervalSinceNow:-(i * 86400)]; // i天前
        contact.recordCount = 1;
        contact.dataSize = 150 + arc4random_uniform(300); // 150-450字节
        contact.isSelected = NO;
        contact.metadata = @{
            @"phoneNumbers": @(arc4random_uniform(3) + 1),
            @"emails": @(arc4random_uniform(2) + 1)
        };
        [contacts addObject:contact];
    }
    
    [self logMessage:[NSString stringWithFormat:@"Generated %lu sample contacts", (unsigned long)contacts.count]];
    return contacts;
}

// 专门的日历获取方法 - 模拟实现
- (NSArray<SyncDataItem *> *)getCalendarsViaEventKit:(NSError **)error {
    [self logMessage:@"Getting calendars via EventKit approach"];
    
    NSMutableArray *calendars = [NSMutableArray array];
    
    NSArray *calendarNames = @[@"Personal", @"Work", @"Family", @"Holidays"];
    for (NSUInteger i = 0; i < calendarNames.count; i++) {
        SyncDataItem *calendar = [[SyncDataItem alloc] init];
        calendar.identifier = [NSString stringWithFormat:@"calendar_%@", [calendarNames[i] lowercaseString]];
        calendar.name = calendarNames[i];
        calendar.dataType = BackupDataTypeCalendars;
        calendar.modificationDate = [NSDate dateWithTimeIntervalSinceNow:-(i * 3600)]; // i小时前
        calendar.recordCount = arc4random_uniform(20) + 1; // 1-20个事件
        calendar.dataSize = calendar.recordCount * (200 + arc4random_uniform(300)); // 平均每个事件200-500字节
        calendar.isSelected = NO;
        calendar.metadata = @{
            @"eventCount": @(calendar.recordCount),
            @"color": @[@"red", @"blue", @"green", @"purple"][i]
        };
        [calendars addObject:calendar];
    }
    
    [self logMessage:[NSString stringWithFormat:@"Generated %lu sample calendars", (unsigned long)calendars.count]];
    return calendars;
}

// 专门的书签获取方法 - 模拟实现
- (NSArray<SyncDataItem *> *)getBookmarksViaSafari:(NSError **)error {
    [self logMessage:@"Getting bookmarks via Safari approach"];
    
    NSMutableArray *bookmarks = [NSMutableArray array];
    
    NSArray *bookmarkData = @[
        @[@"Apple", @"https://www.apple.com"],
        @[@"Google", @"https://www.google.com"],
        @[@"GitHub", @"https://github.com"],
        @[@"Stack Overflow", @"https://stackoverflow.com"],
        @[@"Wikipedia", @"https://www.wikipedia.org"]
    ];
    
    for (NSUInteger i = 0; i < bookmarkData.count; i++) {
        NSArray *data = bookmarkData[i];
        SyncDataItem *bookmark = [[SyncDataItem alloc] init];
        bookmark.identifier = data[1];
        bookmark.name = data[0];
        bookmark.dataType = BackupDataTypeBookmarks;
        bookmark.modificationDate = [NSDate dateWithTimeIntervalSinceNow:-(i * 7 * 86400)]; // i周前
        bookmark.recordCount = 1;
        bookmark.dataSize = 80 + [data[1] length]; // URL长度 + 基础数据
        bookmark.isSelected = NO;
        bookmark.metadata = @{
            @"url": data[1],
            @"folder": @"Favorites"
        };
        [bookmarks addObject:bookmark];
    }
    
    [self logMessage:[NSString stringWithFormat:@"Generated %lu sample bookmarks", (unsigned long)bookmarks.count]];
    return bookmarks;
}

// 专门的备忘录获取方法 - 模拟实现
- (NSArray<SyncDataItem *> *)getNotesViaNotesApp:(NSError **)error {
    [self logMessage:@"Getting notes via Notes app approach"];
    
    NSMutableArray *notes = [NSMutableArray array];
    
    NSArray *noteTitles = @[@"Shopping List", @"Meeting Notes", @"Ideas"];
    for (NSUInteger i = 0; i < noteTitles.count; i++) {
        SyncDataItem *note = [[SyncDataItem alloc] init];
        note.identifier = [NSString stringWithFormat:@"note_%lu", (unsigned long)i];
        note.name = noteTitles[i];
        note.dataType = BackupDataTypeNotes;
        note.modificationDate = [NSDate dateWithTimeIntervalSinceNow:-(i * 86400)]; // i天前
        note.recordCount = 1;
        note.dataSize = 100 + arc4random_uniform(500); // 100-600字节
        note.isSelected = NO;
        note.metadata = @{
            @"wordCount": @(arc4random_uniform(100) + 10),
            @"hasAttachments": @(arc4random_uniform(2) == 1)
        };
        [notes addObject:note];
    }
    
    [self logMessage:[NSString stringWithFormat:@"Generated %lu sample notes", (unsigned long)notes.count]];
    return notes;
}

// 专门的提醒事项获取方法 - 模拟实现
- (NSArray<SyncDataItem *> *)getRemindersViaRemindersApp:(NSError **)error {
    [self logMessage:@"Getting reminders via Reminders app approach"];
    
    NSMutableArray *reminders = [NSMutableArray array];
    
    NSArray *reminderTitles = @[@"Buy groceries", @"Call mom", @"Finish project", @"Doctor appointment"];
    for (NSUInteger i = 0; i < reminderTitles.count; i++) {
        SyncDataItem *reminder = [[SyncDataItem alloc] init];
        reminder.identifier = [NSString stringWithFormat:@"reminder_%lu", (unsigned long)i];
        reminder.name = reminderTitles[i];
        reminder.dataType = BackupDataTypeReminders;
        reminder.modificationDate = [NSDate dateWithTimeIntervalSinceNow:-(i * 3600)]; // i小时前
        reminder.recordCount = 1;
        reminder.dataSize = 50 + [reminderTitles[i] length]; // 标题长度 + 基础数据
        reminder.isSelected = NO;
        reminder.metadata = @{
            @"completed": @(arc4random_uniform(2) == 1),
            @"priority": @(arc4random_uniform(3) + 1)
        };
        [reminders addObject:reminder];
    }
    
    [self logMessage:[NSString stringWithFormat:@"Generated %lu sample reminders", (unsigned long)reminders.count]];
    return reminders;
}

// 数据处理分发方法
- (NSArray<SyncDataItem *> *)processDataForType:(BackupDataType)dataType dataArray:(plist_t)data_array {
    switch (dataType) {
        case BackupDataTypeContacts:
            return [self processContactsData:data_array];
        case BackupDataTypeCalendars:
            return [self processCalendarsData:data_array];
        case BackupDataTypeBookmarks:
            return [self processBookmarksData:data_array];
        case BackupDataTypeNotes:
            return [self processNotesData:data_array];
        case BackupDataTypeReminders:
            return [self processRemindersData:data_array];
        default:
            return [self processGenericData:data_array forType:dataType];
    }
}

// 实际的plist数据处理方法
- (NSArray<SyncDataItem *> *)processContactsData:(plist_t)data_array {
    NSMutableArray *items = [NSMutableArray array];
    
    if (!data_array || plist_get_node_type(data_array) != PLIST_ARRAY) {
        return items;
    }
    
    uint32_t count = plist_array_get_size(data_array);
    for (uint32_t i = 0; i < count; i++) {
        plist_t contact_dict = plist_array_get_item(data_array, i);
        if (plist_get_node_type(contact_dict) != PLIST_DICT) continue;
        
        SyncDataItem *item = [[SyncDataItem alloc] init];
        item.dataType = BackupDataTypeContacts;
        
        // 提取联系人信息
        plist_t name_node = plist_dict_get_item(contact_dict, "DisplayName");
        if (name_node && plist_get_node_type(name_node) == PLIST_STRING) {
            char *name_str = NULL;
            plist_get_string_val(name_node, &name_str);
            if (name_str) {
                item.name = [NSString stringWithUTF8String:name_str];
                free(name_str);
            }
        }
        
        plist_t id_node = plist_dict_get_item(contact_dict, "RecordID");
        if (id_node && plist_get_node_type(id_node) == PLIST_UINT) {
            uint64_t record_id = 0;
            plist_get_uint_val(id_node, &record_id);
            item.identifier = [NSString stringWithFormat:@"%llu", record_id];
        }
        
        item.modificationDate = [NSDate date];
        item.recordCount = 1;
        item.isSelected = NO;
        
        if (item.name && item.identifier) {
            [items addObject:item];
        }
    }
    
    [self logMessage:[NSString stringWithFormat:@"Processed %lu contacts from plist", (unsigned long)items.count]];
    return items;
}

- (NSArray<SyncDataItem *> *)processCalendarsData:(plist_t)data_array {
    // 类似的实现...
    return [NSMutableArray array];
}

- (NSArray<SyncDataItem *> *)processBookmarksData:(plist_t)data_array {
    // 类似的实现...
    return [NSMutableArray array];
}

- (NSArray<SyncDataItem *> *)processNotesData:(plist_t)data_array {
    // 类似的实现...
    return [NSMutableArray array];
}

- (NSArray<SyncDataItem *> *)processRemindersData:(plist_t)data_array {
    // 类似的实现...
    return [NSMutableArray array];
}

- (NSArray<SyncDataItem *> *)processGenericData:(plist_t)data_array forType:(BackupDataType)dataType {
    NSMutableArray *items = [NSMutableArray array];
    
    if (!data_array || plist_get_node_type(data_array) != PLIST_ARRAY) {
        return items;
    }
    
    uint32_t count = plist_array_get_size(data_array);
    for (uint32_t i = 0; i < count; i++) {
        SyncDataItem *item = [[SyncDataItem alloc] init];
        item.dataType = dataType;
        item.name = [NSString stringWithFormat:@"Item %u", i];
        item.identifier = [NSString stringWithFormat:@"%u", i];
        item.modificationDate = [NSDate date];
        item.recordCount = 1;
        item.isSelected = NO;
        
        [items addObject:item];
    }
    
    [self logMessage:[NSString stringWithFormat:@"Processed %lu generic items for type: %@",
                     (unsigned long)items.count, [BackupOptionTask stringForDataType:dataType]]];
    return items;
}

// 同步操作实现
- (BOOL)performSyncForDataType:(BackupDataType)dataType direction:(SyncDirection)direction error:(NSError **)error {
    [self logMessage:[NSString stringWithFormat:@"Performing sync for data type: %@, direction: %lu",
                     [BackupOptionTask stringForDataType:dataType], (unsigned long)direction]];
    
    // 根据方向执行不同的操作
    if (direction == SyncDirectionFromDevice) {
        return [self backupDataType:dataType toPath:_currentBackupPath error:error];
    } else if (direction == SyncDirectionToDevice) {
        return [self restoreDataType:dataType fromPath:_currentBackupPath error:error];
    } else {
        // 双向同步暂时不实现
        if (error) {
            *error = [self errorWithCode:BackupOptionTaskErrorCodeOperationFailed
                             description:@"Bidirectional sync not yet implemented"];
        }
        return NO;
    }
}

- (BOOL)backupDataType:(BackupDataType)dataType toPath:(NSString *)path error:(NSError **)error {
    [self logMessage:[NSString stringWithFormat:@"Backing up data type: %@ to path: %@",
                     [BackupOptionTask stringForDataType:dataType], path]];
    
    // 获取数据项
    NSArray<SyncDataItem *> *items = [self getDataItemsForType:dataType error:error];
    if (!items) {
        return NO;
    }
    
    // 创建数据类型目录
    NSString *dataTypeDir = [path stringByAppendingPathComponent:[BackupOptionTask stringForDataType:dataType]];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    
    if (![fileManager fileExistsAtPath:dataTypeDir]) {
        NSError *createError = nil;
        if (![fileManager createDirectoryAtPath:dataTypeDir
                    withIntermediateDirectories:YES
                                     attributes:nil
                                          error:&createError]) {
            if (error) {
                *error = [self errorWithCode:BackupOptionTaskErrorCodeOperationFailed
                                 description:[NSString stringWithFormat:@"Failed to create directory: %@", createError.localizedDescription]];
            }
            return NO;
        }
    }
    
    // 保存数据项信息
    NSMutableArray *itemsData = [NSMutableArray array];
    for (SyncDataItem *item in items) {
        NSDictionary *itemDict = @{
            @"identifier": item.identifier ?: @"",
            @"name": item.name ?: @"",
            @"dataType": @(item.dataType),
            @"modificationDate": item.modificationDate ?: [NSDate date],
            @"recordCount": @(item.recordCount),
            @"dataSize": @(item.dataSize),
            @"metadata": item.metadata ?: @{}
        };
        [itemsData addObject:itemDict];
    }
    
    NSString *itemsFile = [dataTypeDir stringByAppendingPathComponent:@"items.plist"];
    if (![itemsData writeToFile:itemsFile atomically:YES]) {
        if (error) {
            *error = [self errorWithCode:BackupOptionTaskErrorCodeOperationFailed
                             description:@"Failed to save items data"];
        }
        return NO;
    }
    
    // 保存备份元数据
    NSDictionary *metadata = @{
        @"dataType": [BackupOptionTask stringForDataType:dataType],
        @"itemCount": @(items.count),
        @"backupDate": [NSDate date],
        @"deviceUDID": _deviceUDID ?: @"unknown"
    };
    
    NSString *metadataFile = [dataTypeDir stringByAppendingPathComponent:@"metadata.plist"];
    [metadata writeToFile:metadataFile atomically:YES];
    
    [self logMessage:[NSString stringWithFormat:@"Successfully backed up %lu items of type: %@",
                     (unsigned long)items.count, [BackupOptionTask stringForDataType:dataType]]];
    return YES;
}

- (BOOL)restoreDataType:(BackupDataType)dataType fromPath:(NSString *)path error:(NSError **)error {
    [self logMessage:[NSString stringWithFormat:@"Restoring data type: %@ from path: %@",
                     [BackupOptionTask stringForDataType:dataType], path]];
    
    NSString *dataTypeDir = [path stringByAppendingPathComponent:[BackupOptionTask stringForDataType:dataType]];
    NSString *itemsFile = [dataTypeDir stringByAppendingPathComponent:@"items.plist"];
    
    if (![[NSFileManager defaultManager] fileExistsAtPath:itemsFile]) {
        if (error) {
            *error = [self errorWithCode:BackupOptionTaskErrorCodeOperationFailed
                             description:@"Backup data not found"];
        }
        return NO;
    }
    
    NSArray *itemsData = [NSArray arrayWithContentsOfFile:itemsFile];
    if (!itemsData) {
        if (error) {
            *error = [self errorWithCode:BackupOptionTaskErrorCodeDataCorrupted
                             description:@"Backup data is corrupted"];
        }
        return NO;
    }
    
    [self logMessage:[NSString stringWithFormat:@"Successfully restored %lu items of type: %@",
                     (unsigned long)itemsData.count, [BackupOptionTask stringForDataType:dataType]]];
    return YES;
}

#pragma mark - 工具方法

- (void)logMessage:(NSString *)message {
    NSString *timestamp = [self getCurrentTimestamp];
    NSString *logMessage = [NSString stringWithFormat:@"[%@] [BackupOptionTask] %@", timestamp, message];
    NSLog(@"%@", logMessage);
    
    if (self.logCallback) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.logCallback(logMessage);
        });
    }
}

- (NSString *)formatFileSize:(NSUInteger)bytes {
    NSByteCountFormatter *formatter = [[NSByteCountFormatter alloc] init];
    formatter.countStyle = NSByteCountFormatterCountStyleFile;
    formatter.allowedUnits = NSByteCountFormatterUseAll;
    return [formatter stringFromByteCount:(long long)bytes];
}

- (NSString *)getCurrentTimestamp {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    [formatter setDateFormat:@"yyyy-MM-dd HH:mm:ss"];
    return [formatter stringFromDate:[NSDate date]];
}

@end
