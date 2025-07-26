//
//  GlobalTaskManager.m
//  MFCTOOL
//
//  Created by Monterey on 26/1/2025.
//  专注核心功能，与 TaskBridge 和 GlobalLockController 深度集成
//

#import "GlobalTaskManager.h"
#import "GlobalLockController.h"

NS_ASSUME_NONNULL_BEGIN

#pragma mark - 常量定义

static NSString * const GlobalTaskErrorDomain = @"GlobalTaskErrorDomain";
static NSString * const DeviceSelectionStateFileName = @"DeviceSelections.plist";
static NSString * const TaskStatesFileName = @"TaskStates.plist";

static const NSTimeInterval DefaultTaskTimeout = 3600; // 1小时
static const NSTimeInterval TaskCleanupInterval = 60;   // 1分钟清理一次
static const NSTimeInterval DeviceStatusUpdateInterval = 5; // 5秒更新设备状态

// 通知名称
NSString * const GlobalTaskCreatedNotification = @"GlobalTaskCreatedNotification";
NSString * const GlobalTaskStartedNotification = @"GlobalTaskStartedNotification";
NSString * const GlobalTaskUpdatedNotification = @"GlobalTaskUpdatedNotification";
NSString * const GlobalTaskCompletedNotification = @"GlobalTaskCompletedNotification";
NSString * const GlobalTaskCancelledNotification = @"GlobalTaskCancelledNotification";
NSString * const GlobalDeviceSelectionChangedNotification = @"GlobalDeviceSelectionChangedNotification";
NSString * const GlobalDeviceStatusChangedNotification = @"GlobalDeviceStatusChangedNotification";

#pragma mark - TaskInfo 实现

@implementation TaskInfo

- (instancetype)init {
    if (self = [super init]) {
        _status = TaskStatusIdle;
        _priority = TaskPriorityNormal;
        _progress = 0.0;
        _isExclusive = NO;
        _allowsConcurrency = YES;
        _canBeCancelled = YES;
        _requiresDeviceLock = NO;
        _maxDuration = DefaultTaskTimeout;
        _maxRetryCount = 3;
        _parameters = @{};
        _context = @{};
        _statusHistory = [NSMutableArray array];
        _startTime = [NSDate date];
        _updateTime = [NSDate date];
    }
    return self;
}

+ (instancetype)taskWithOperationIdentifier:(NSString *)operationIdentifier
                                    deviceID:(NSString *)deviceID
                                  sourceName:(NSString *)sourceName
                                 description:(NSString *)description
                                    priority:(TaskPriority)priority {
    TaskInfo *task = [[TaskInfo alloc] init];
    task.taskId = [[GlobalTaskManager sharedManager] generateTaskID:operationIdentifier forDevice:deviceID];
    task.operationIdentifier = operationIdentifier;
    task.deviceID = deviceID;
    task.sourceName = sourceName;
    task.taskDescription = description;
    task.priority = priority;
    return task;
}

- (BOOL)isActive {
    return (self.status == TaskStatusPreparing ||
            self.status == TaskStatusRunning ||
            self.status == TaskStatusCompleting);
}

- (BOOL)isCompleted {
    return (self.status == TaskStatusCompleted ||
            self.status == TaskStatusFailed ||
            self.status == TaskStatusCancelled);
}

- (BOOL)canBeInterrupted {
    return self.canBeCancelled && [self isActive];
}

- (BOOL)hasTimedOut {
    if (self.maxDuration <= 0 || ![self isActive]) return NO;
    
    NSTimeInterval elapsed = [[NSDate date] timeIntervalSinceDate:self.startTime];
    return elapsed > self.maxDuration;
}

- (void)addStatusEntry:(TaskStatus)status message:(NSString *)message {
    [self.statusHistory addObject:@{
        @"status": @(status),
        @"message": message ?: @"",
        @"timestamp": [NSDate date]
    }];
    
    self.status = status;
    self.updateTime = [NSDate date];
    
    if ([self isCompleted]) {
        self.completionTime = [NSDate date];
    }
}

- (NSArray *)getStatusHistory {
    return [self.statusHistory copy];
}

- (BOOL)hasReachedMaxRetries {
    if (self.maxRetryCount <= 0) return NO;
    
    NSInteger failureCount = 0;
    for (NSDictionary *entry in self.statusHistory) {
        if ([entry[@"status"] integerValue] == TaskStatusFailed) {
            failureCount++;
        }
    }
    
    return failureCount >= self.maxRetryCount;
}

#pragma mark - NSCopying

- (id)copyWithZone:(NSZone *)zone {
    TaskInfo *copy = [[TaskInfo alloc] init];
    copy.taskId = [self.taskId copy];
    copy.operationIdentifier = [self.operationIdentifier copy];
    copy.deviceID = [self.deviceID copy];
    copy.sourceName = [self.sourceName copy];
    copy.status = self.status;
    copy.priority = self.priority;
    copy.progress = self.progress;
    copy.taskDescription = [self.taskDescription copy];
    copy.startTime = [self.startTime copy];
    copy.updateTime = [self.updateTime copy];
    copy.completionTime = [self.completionTime copy];
    copy.isExclusive = self.isExclusive;
    copy.allowsConcurrency = self.allowsConcurrency;
    copy.canBeCancelled = self.canBeCancelled;
    copy.requiresDeviceLock = self.requiresDeviceLock;
    copy.maxDuration = self.maxDuration;
    copy.parameters = [self.parameters copy];
    copy.context = [self.context copy];
    copy.statusHistory = [self.statusHistory mutableCopy];
    copy.previousTaskId = [self.previousTaskId copy];
    copy.maxRetryCount = self.maxRetryCount;
    return copy;
}

#pragma mark - NSCoding

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:self.taskId forKey:@"taskId"];
    [coder encodeObject:self.operationIdentifier forKey:@"operationIdentifier"];
    [coder encodeObject:self.deviceID forKey:@"deviceID"];
    [coder encodeObject:self.sourceName forKey:@"sourceName"];
    [coder encodeInteger:self.status forKey:@"status"];
    [coder encodeInteger:self.priority forKey:@"priority"];
    [coder encodeDouble:self.progress forKey:@"progress"];
    [coder encodeObject:self.taskDescription forKey:@"taskDescription"];
    [coder encodeObject:self.startTime forKey:@"startTime"];
    [coder encodeObject:self.updateTime forKey:@"updateTime"];
    [coder encodeObject:self.completionTime forKey:@"completionTime"];
    [coder encodeBool:self.isExclusive forKey:@"isExclusive"];
    [coder encodeBool:self.allowsConcurrency forKey:@"allowsConcurrency"];
    [coder encodeBool:self.canBeCancelled forKey:@"canBeCancelled"];
    [coder encodeBool:self.requiresDeviceLock forKey:@"requiresDeviceLock"];
    [coder encodeDouble:self.maxDuration forKey:@"maxDuration"];
    [coder encodeObject:self.parameters forKey:@"parameters"];
    [coder encodeObject:self.context forKey:@"context"];
    [coder encodeObject:self.statusHistory forKey:@"statusHistory"];
    [coder encodeObject:self.previousTaskId forKey:@"previousTaskId"];
    [coder encodeInteger:self.maxRetryCount forKey:@"maxRetryCount"];
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    if (self = [super init]) {
        _taskId = [coder decodeObjectOfClass:[NSString class] forKey:@"taskId"];
        _operationIdentifier = [coder decodeObjectOfClass:[NSString class] forKey:@"operationIdentifier"];
        _deviceID = [coder decodeObjectOfClass:[NSString class] forKey:@"deviceID"];
        _sourceName = [coder decodeObjectOfClass:[NSString class] forKey:@"sourceName"];
        _status = [coder decodeIntegerForKey:@"status"];
        _priority = [coder decodeIntegerForKey:@"priority"];
        _progress = [coder decodeDoubleForKey:@"progress"];
        _taskDescription = [coder decodeObjectOfClass:[NSString class] forKey:@"taskDescription"];
        _startTime = [coder decodeObjectOfClass:[NSDate class] forKey:@"startTime"];
        _updateTime = [coder decodeObjectOfClass:[NSDate class] forKey:@"updateTime"];
        _completionTime = [coder decodeObjectOfClass:[NSDate class] forKey:@"completionTime"];
        _isExclusive = [coder decodeBoolForKey:@"isExclusive"];
        _allowsConcurrency = [coder decodeBoolForKey:@"allowsConcurrency"];
        _canBeCancelled = [coder decodeBoolForKey:@"canBeCancelled"];
        _requiresDeviceLock = [coder decodeBoolForKey:@"requiresDeviceLock"];
        _maxDuration = [coder decodeDoubleForKey:@"maxDuration"];
        _parameters = [coder decodeObjectOfClass:[NSDictionary class] forKey:@"parameters"];
        _context = [coder decodeObjectOfClass:[NSDictionary class] forKey:@"context"];
        _statusHistory = [coder decodeObjectOfClass:[NSMutableArray class] forKey:@"statusHistory"];
        _previousTaskId = [coder decodeObjectOfClass:[NSString class] forKey:@"previousTaskId"];
        _maxRetryCount = [coder decodeIntegerForKey:@"maxRetryCount"];
    }
    return self;
}

@end

#pragma mark - TaskCreationCheckResult 实现

@implementation TaskCreationCheckResult

+ (instancetype)resultWithCode:(TaskCreationResult)result message:(NSString *)message {
    TaskCreationCheckResult *checkResult = [[TaskCreationCheckResult alloc] init];
    checkResult.result = result;
    checkResult.message = message;
    checkResult.blockingTask = nil;
    checkResult.conflictTasks = @[];
    checkResult.estimatedWaitTime = 0;
    checkResult.canForceExecute = NO;
    checkResult.suggestions = @[];
    return checkResult;
}

+ (instancetype)allowedResult {
    return [self resultWithCode:TaskCreationAllowed message:@"允许创建任务"];
}

+ (instancetype)waitPreviousResult:(TaskInfo *)blockingTask {
    TaskCreationCheckResult *result = [self resultWithCode:TaskCreationWaitPrevious
                                                   message:[NSString stringWithFormat:@"需要等待前置任务完成: %@", blockingTask.taskDescription]];
    result.blockingTask = blockingTask;
    result.canForceExecute = blockingTask.canBeInterrupted;
    if (result.canForceExecute) {
        result.suggestions = @[@"等待前置任务完成", @"取消前置任务"];
    } else {
        result.suggestions = @[@"等待前置任务完成"];
    }
    return result;
}

+ (instancetype)blockedResult:(TaskInfo *)blockingTask {
    TaskCreationCheckResult *result = [self resultWithCode:TaskCreationBlocked
                                                   message:[NSString stringWithFormat:@"与正在执行的任务冲突: %@", blockingTask.taskDescription]];
    result.blockingTask = blockingTask;
    result.conflictTasks = @[blockingTask];
    result.canForceExecute = blockingTask.canBeInterrupted;
    return result;
}

+ (instancetype)deviceUnavailableResult:(NSString *)reason {
    return [self resultWithCode:TaskCreationDeviceUnavailable
                        message:[NSString stringWithFormat:@"设备不可用: %@", reason ?: @"未知原因"]];
}

@end

#pragma mark - DeviceSelectionState & DeviceStatus 实现

@implementation DeviceSelectionState

- (id)copyWithZone:(NSZone *)zone {
    DeviceSelectionState *copy = [[DeviceSelectionState alloc] init];
    copy.deviceID = [self.deviceID copy];
    copy.sourceName = [self.sourceName copy];
    copy.deviceInfo = [self.deviceInfo copy];
    copy.selectionTime = [self.selectionTime copy];
    copy.isLocked = self.isLocked;
    return copy;
}

@end

@implementation DeviceStatus

- (instancetype)init {
    if (self = [super init]) {
        _isConnected = YES;
        _isAvailable = YES;
        _activeTasks = @[];
        _primaryTask = nil;
        _totalBusyTime = 0;
        _lastActivityTime = [NSDate date];
    }
    return self;
}

@end

#pragma mark - GlobalTaskManager 实现

@interface GlobalTaskManager ()

// 核心数据存储
@property (nonatomic, strong) NSMutableDictionary<NSString *, TaskInfo *> *allTasks;
@property (nonatomic, strong) NSMutableDictionary<NSString *, DeviceSelectionState *> *deviceSelections;
@property (nonatomic, strong) NSMutableDictionary<NSString *, DeviceStatus *> *deviceStatuses;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray<void(^)(TaskInfo *, BOOL)> *> *taskCompletionCallbacks;

// 集成组件
@property (nonatomic, strong) id<TaskCompatibilityChecker> compatibilityChecker;
@property (nonatomic, weak) GlobalLockController *lockController;

// 线程安全
@property (nonatomic, strong) dispatch_queue_t taskQueue;
@property (nonatomic, strong) NSTimer *cleanupTimer;

// 调试和统计
@property (nonatomic, assign) BOOL debugMode;
@property (nonatomic, assign) NSInteger totalTasksCreated;
@property (nonatomic, assign) NSInteger totalTasksCompleted;
@property (nonatomic, assign) NSInteger totalTasksFailed;
@property (nonatomic, strong) NSDate *lastSaveTime;

@end

@implementation GlobalTaskManager

#pragma mark - 单例模式

+ (instancetype)sharedManager {
    static GlobalTaskManager *_instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _instance = [[GlobalTaskManager alloc] init];
    });
    return _instance;
}

- (instancetype)init {
    if (self = [super init]) {
        _allTasks = [NSMutableDictionary dictionary];
        _deviceSelections = [NSMutableDictionary dictionary];
        _deviceStatuses = [NSMutableDictionary dictionary];
        _taskCompletionCallbacks = [NSMutableDictionary dictionary];
        _taskQueue = dispatch_queue_create("com.mfctool.task.manager", DISPATCH_QUEUE_CONCURRENT);
        _debugMode = NO;
        _totalTasksCreated = 0;
        _totalTasksCompleted = 0;
        _totalTasksFailed = 0;
        _lastSaveTime = [NSDate date];
        
        // 获取 GlobalLockController 实例
        _lockController = [GlobalLockController sharedController];
        
        [self loadStatesFromDisk];
        [self startCleanupTimer];
        
        // 监听应用生命周期
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(applicationWillTerminate:)
                                                     name:NSApplicationWillTerminateNotification
                                                   object:nil];
        
        [self debugLog:@"GlobalTaskManager 重构版本初始化完成"];
    }
    return self;
}

#pragma mark - 🤝 与 TaskBridge 集成接口

- (void)setCompatibilityChecker:(id<TaskCompatibilityChecker>)checker {
    dispatch_barrier_async(self.taskQueue, ^{
        self.compatibilityChecker = checker;
        [self debugLog:@"✅ 设置兼容性检查器：%@", NSStringFromClass([checker class])];
    });
}

- (id<TaskCompatibilityChecker>)getCompatibilityChecker {
    __block id<TaskCompatibilityChecker> checker = nil;
    dispatch_sync(self.taskQueue, ^{
        checker = self.compatibilityChecker;
    });
    return checker;
}

#pragma mark - 🎯 核心任务管理功能

- (TaskCreationCheckResult *)checkCanCreateTaskWithOperation:(NSString *)operationIdentifier
                                                    onDevice:(NSString *)deviceID
                                                  fromSource:(NSString *)sourceName
                                                withPriority:(TaskPriority)priority {
    
    __block TaskCreationCheckResult *result = nil;
    
    dispatch_sync(self.taskQueue, ^{
        // 1. 检查设备可用性
        DeviceStatus *deviceStatus = [self getDeviceStatus:deviceID];
        if (!deviceStatus.isConnected || !deviceStatus.isAvailable) {
            result = [TaskCreationCheckResult deviceUnavailableResult:@"设备未连接或不可用"];
            return;
        }
        
        // 2. 检查设备锁定状态
        NSDictionary *lockStatus = [self checkDeviceLockStatus:deviceID forSource:sourceName];
        if (![lockStatus[@"canLock"] boolValue]) {
            result = [TaskCreationCheckResult deviceUnavailableResult:lockStatus[@"message"]];
            return;
        }
        
        // 3. 检查前置任务完成情况
        TaskInfo *previousTask = [self getLastTaskForSource:sourceName onDevice:deviceID];
        if (previousTask && [previousTask isActive]) {
            result = [TaskCreationCheckResult waitPreviousResult:previousTask];
            return;
        }
        
        // 4. 检查任务兼容性
        NSArray<TaskInfo *> *activeTasks = [self getActiveTasksForDevice:deviceID];
        
        if (self.compatibilityChecker) {
            NSMutableArray<NSString *> *activeOperations = [NSMutableArray array];
            for (TaskInfo *task in activeTasks) {
                [activeOperations addObject:task.operationIdentifier];
            }
            
            NSArray<NSString *> *conflicts = [self.compatibilityChecker getConflictingOperations:operationIdentifier
                                                                               withActiveOperations:activeOperations];
            
            if (conflicts.count > 0) {
                NSMutableArray<TaskInfo *> *conflictTasks = [NSMutableArray array];
                for (TaskInfo *task in activeTasks) {
                    if ([conflicts containsObject:task.operationIdentifier]) {
                        [conflictTasks addObject:task];
                    }
                }
                
                if (conflictTasks.count > 0) {
                    TaskInfo *blockingTask = conflictTasks.firstObject;
                    result = [TaskCreationCheckResult blockedResult:blockingTask];
                    result.conflictTasks = [conflictTasks copy];
                    return;
                }
            }
        }
        
        // 5. 所有检查通过
        result = [TaskCreationCheckResult allowedResult];
    });
    
    return result;
}

- (BOOL)createTask:(TaskInfo *)taskInfo force:(BOOL)forceCreate {
    if (!taskInfo || !taskInfo.operationIdentifier || !taskInfo.deviceID || !taskInfo.sourceName) {
        [self debugLog:@"❌ 任务创建失败：必要信息不完整"];
        return NO;
    }
    
    __block BOOL success = NO;
    
    dispatch_barrier_sync(self.taskQueue, ^{
        // 如果不是强制创建，进行检查
        if (!forceCreate) {
            TaskCreationCheckResult *checkResult = [self checkCanCreateTaskWithOperation:taskInfo.operationIdentifier
                                                                                onDevice:taskInfo.deviceID
                                                                              fromSource:taskInfo.sourceName
                                                                            withPriority:taskInfo.priority];
            
            if (checkResult.result != TaskCreationAllowed) {
                [self debugLog:@"❌ 任务创建被阻止：%@", checkResult.message];
                return;
            }
        }
        
        // 尝试锁定设备（如果需要）
        if (taskInfo.requiresDeviceLock) {
            if (![self tryLockDeviceForTask:taskInfo.deviceID fromSource:taskInfo.sourceName taskInfo:taskInfo]) {
                [self debugLog:@"❌ 任务创建失败：无法锁定设备"];
                return;
            }
        }
        
        // 创建任务
        self.allTasks[taskInfo.taskId] = taskInfo;
        self.totalTasksCreated++;
        
        // 更新设备状态
        [self updateDeviceStatusForTask:taskInfo];
        
        [self debugLog:@"✅ 任务创建成功：%@ (%@)", taskInfo.operationIdentifier, taskInfo.taskId];
        success = YES;
        
        // 发送通知
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:GlobalTaskCreatedNotification
                                                                object:taskInfo];
        });
    });
    
    return success;
}

- (BOOL)startTask:(NSString *)taskId {
    __block BOOL success = NO;
    
    dispatch_barrier_sync(self.taskQueue, ^{
        TaskInfo *task = self.allTasks[taskId];
        if (!task) {
            [self debugLog:@"❌ 任务启动失败：任务不存在 - %@", taskId];
            return;
        }
        
        if (task.status != TaskStatusIdle && task.status != TaskStatusPreparing) {
            [self debugLog:@"❌ 任务启动失败：任务状态不正确 - %@", taskId];
            return;
        }
        
        [task addStatusEntry:TaskStatusRunning message:@"任务开始执行"];
        [self debugLog:@"✅ 任务启动成功：%@ (%@)", task.operationIdentifier, taskId];
        success = YES;
        
        // 发送通知
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:GlobalTaskStartedNotification
                                                                object:task];
        });
    });
    
    return success;
}

- (void)updateTask:(NSString *)taskId
            status:(TaskStatus)status
          progress:(double)progress
           message:(NSString * _Nullable)message {
    
    dispatch_barrier_async(self.taskQueue, ^{
        TaskInfo *task = self.allTasks[taskId];
        if (!task) {
            [self debugLog:@"❌ 任务更新失败：任务不存在 - %@", taskId];
            return;
        }
        
        // 更新状态
        [task addStatusEntry:status message:message ?: @""];
        
        // 更新进度
        if (progress >= 0 && progress <= 1.0) {
            task.progress = progress;
        }
        
        // 更新设备状态
        [self updateDeviceStatusForTask:task];
        
        [self debugLog:@"📊 任务更新：%@ - 状态:%ld 进度:%.1f%%", taskId, (long)status, task.progress * 100];
        
        // 发送通知
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:GlobalTaskUpdatedNotification
                                                                object:task
                                                              userInfo:@{@"message": message ?: @""}];
        });
    });
}

- (void)completeTask:(NSString *)taskId
             success:(BOOL)success
              result:(NSDictionary * _Nullable)result {
    
    dispatch_barrier_async(self.taskQueue, ^{
        TaskInfo *task = self.allTasks[taskId];
        if (!task) {
            [self debugLog:@"❌ 任务完成失败：任务不存在 - %@", taskId];
            return;
        }
        
        // 更新状态
        TaskStatus finalStatus = success ? TaskStatusCompleted : TaskStatusFailed;
        NSString *message = success ? @"任务成功完成" : @"任务执行失败";
        [task addStatusEntry:finalStatus message:message];
        
        if (success) {
            task.progress = 1.0;
            self.totalTasksCompleted++;
        } else {
            self.totalTasksFailed++;
        }
        
        // 释放设备锁定
        if (task.requiresDeviceLock) {
            [self releaseDeviceLockForTask:task.deviceID fromSource:task.sourceName taskId:taskId];
        }
        
        // 更新设备状态
        [self updateDeviceStatusForTask:task];
        
        // 调用完成回调
        [self notifyTaskCompletionCallbacks:taskId success:success];
        
        [self debugLog:@"🎯 任务完成：%@ - %@", taskId, success ? @"成功" : @"失败"];
        
        // 发送通知
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:GlobalTaskCompletedNotification
                                                                object:task
                                                              userInfo:@{
                                                                  @"success": @(success),
                                                                  @"result": result ?: @{}
                                                              }];
        });
    });
}

- (BOOL)cancelTask:(NSString *)taskId reason:(NSString * _Nullable)reason {
    __block BOOL success = NO;
    
    dispatch_barrier_sync(self.taskQueue, ^{
        TaskInfo *task = self.allTasks[taskId];
        if (!task) {
            [self debugLog:@"❌ 任务取消失败：任务不存在 - %@", taskId];
            return;
        }
        
        if (![task canBeInterrupted]) {
            [self debugLog:@"❌ 任务取消失败：任务不可中断 - %@", taskId];
            return;
        }
        
        [task addStatusEntry:TaskStatusCancelled message:reason ?: @"任务被取消"];
        
        // 释放设备锁定
        if (task.requiresDeviceLock) {
            [self releaseDeviceLockForTask:task.deviceID fromSource:task.sourceName taskId:taskId];
        }
        
        // 更新设备状态
        [self updateDeviceStatusForTask:task];
        
        // 调用完成回调
        [self notifyTaskCompletionCallbacks:taskId success:NO];
        
        [self debugLog:@"🚫 任务取消：%@ - %@", taskId, reason ?: @"用户取消"];
        success = YES;
        
        // 发送通知
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:GlobalTaskCancelledNotification
                                                                object:task
                                                              userInfo:@{@"reason": reason ?: @""}];
        });
    });
    
    return success;
}

- (BOOL)forceStopTask:(NSString *)taskId reason:(NSString *)reason {
    __block BOOL success = NO;
    
    dispatch_barrier_sync(self.taskQueue, ^{
        TaskInfo *task = self.allTasks[taskId];
        if (!task) {
            [self debugLog:@"❌ 强制停止失败：任务不存在 - %@", taskId];
            return;
        }
        
        [task addStatusEntry:TaskStatusCancelled message:[NSString stringWithFormat:@"强制停止：%@", reason]];
        
        // 释放设备锁定
        if (task.requiresDeviceLock) {
            [self releaseDeviceLockForTask:task.deviceID fromSource:task.sourceName taskId:taskId];
        }
        
        // 更新设备状态
        [self updateDeviceStatusForTask:task];
        
        // 调用完成回调
        [self notifyTaskCompletionCallbacks:taskId success:NO];
        
        [self debugLog:@"💥 强制停止任务：%@ - %@", taskId, reason];
        success = YES;
        
        // 发送通知
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:GlobalTaskCancelledNotification
                                                                object:task
                                                              userInfo:@{@"reason": [NSString stringWithFormat:@"强制停止：%@", reason]}];
        });
    });
    
    return success;
}

#pragma mark - 📊 任务查询功能

- (TaskInfo * _Nullable)getTask:(NSString *)taskId {
    __block TaskInfo *task = nil;
    
    dispatch_sync(self.taskQueue, ^{
        task = [self.allTasks[taskId] copy];
    });
    
    return task;
}

- (NSArray<TaskInfo *> *)getActiveTasksForDevice:(NSString *)deviceID {
    __block NSArray<TaskInfo *> *tasks = nil;
    
    dispatch_sync(self.taskQueue, ^{
        NSMutableArray *activeTasks = [NSMutableArray array];
        
        for (TaskInfo *task in self.allTasks.allValues) {
            if ([task.deviceID isEqualToString:deviceID] && [task isActive]) {
                [activeTasks addObject:task];
            }
        }
        
        // 按优先级排序
        [activeTasks sortUsingComparator:^NSComparisonResult(TaskInfo *obj1, TaskInfo *obj2) {
            return [@(obj2.priority) compare:@(obj1.priority)];
        }];
        
        tasks = [activeTasks copy];
    });
    
    return tasks;
}

- (TaskInfo * _Nullable)getPrimaryTaskForDevice:(NSString *)deviceID {
    NSArray<TaskInfo *> *activeTasks = [self getActiveTasksForDevice:deviceID];
    return activeTasks.firstObject; // 已按优先级排序，第一个就是主要任务
}

- (NSArray<TaskInfo *> *)getActiveTasksForSource:(NSString *)sourceName {
    __block NSArray<TaskInfo *> *tasks = nil;
    
    dispatch_sync(self.taskQueue, ^{
        NSMutableArray *activeTasks = [NSMutableArray array];
        
        for (TaskInfo *task in self.allTasks.allValues) {
            if ([task.sourceName isEqualToString:sourceName] && [task isActive]) {
                [activeTasks addObject:task];
            }
        }
        
        tasks = [activeTasks copy];
    });
    
    return tasks;
}

- (NSArray<TaskInfo *> *)getActiveTasksForOperation:(NSString *)operationIdentifier
                                            onDevice:(NSString * _Nullable)deviceID {
    __block NSArray<TaskInfo *> *tasks = nil;
    
    dispatch_sync(self.taskQueue, ^{
        NSMutableArray *activeTasks = [NSMutableArray array];
        
        for (TaskInfo *task in self.allTasks.allValues) {
            if ([task.operationIdentifier isEqualToString:operationIdentifier] && [task isActive]) {
                if (!deviceID || [task.deviceID isEqualToString:deviceID]) {
                    [activeTasks addObject:task];
                }
            }
        }
        
        tasks = [activeTasks copy];
    });
    
    return tasks;
}

- (NSArray<TaskInfo *> *)getAllActiveTasks {
    __block NSArray<TaskInfo *> *tasks = nil;
    
    dispatch_sync(self.taskQueue, ^{
        NSMutableArray *activeTasks = [NSMutableArray array];
        
        for (TaskInfo *task in self.allTasks.allValues) {
            if ([task isActive]) {
                [activeTasks addObject:task];
            }
        }
        
        tasks = [activeTasks copy];
    });
    
    return tasks;
}

- (NSArray<TaskInfo *> *)getTasksForDevice:(NSString *)deviceID withStatus:(TaskStatus)status {
    __block NSArray<TaskInfo *> *tasks = nil;
    
    dispatch_sync(self.taskQueue, ^{
        NSMutableArray *filteredTasks = [NSMutableArray array];
        
        for (TaskInfo *task in self.allTasks.allValues) {
            if ([task.deviceID isEqualToString:deviceID] && task.status == status) {
                [filteredTasks addObject:task];
            }
        }
        
        tasks = [filteredTasks copy];
    });
    
    return tasks;
}

- (TaskInfo * _Nullable)getLastTaskForSource:(NSString *)sourceName onDevice:(NSString *)deviceID {
    __block TaskInfo *lastTask = nil;
    
    dispatch_sync(self.taskQueue, ^{
        NSDate *latestStartTime = nil;
        
        for (TaskInfo *task in self.allTasks.allValues) {
            if ([task.sourceName isEqualToString:sourceName] && [task.deviceID isEqualToString:deviceID]) {
                if (!latestStartTime || [task.startTime isLaterThan:latestStartTime]) {
                    latestStartTime = task.startTime;
                    lastTask = task;
                }
            }
        }
    });
    
    return lastTask;
}

#pragma mark - 🔧 设备状态管理

- (DeviceStatus *)getDeviceStatus:(NSString *)deviceID {
    __block DeviceStatus *status = nil;
    
    dispatch_sync(self.taskQueue, ^{
        status = self.deviceStatuses[deviceID];
        if (!status) {
            status = [[DeviceStatus alloc] init];
            status.deviceID = deviceID;
            self.deviceStatuses[deviceID] = status;
        }
        
        // 更新活跃任务列表
        NSArray<TaskInfo *> *activeTasks = [self getActiveTasksForDevice:deviceID];
        status.activeTasks = activeTasks;
        status.primaryTask = activeTasks.firstObject;
    });
    
    return status;
}

- (void)updateDeviceConnectionStatus:(NSString *)deviceID connected:(BOOL)connected {
    dispatch_barrier_async(self.taskQueue, ^{
        DeviceStatus *status = [self getDeviceStatus:deviceID];
        status.isConnected = connected;
        status.isAvailable = connected;
        status.lastActivityTime = [NSDate date];
        
        [self debugLog:@"📱 设备状态更新：%@ - %@", deviceID, connected ? @"已连接" : @"已断开"];
        
        if (!connected) {
            // 设备断开时，取消所有相关任务
            [self cancelAllTasksForDevice:deviceID reason:@"设备断开连接"];
        }
        
        // 发送通知
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:GlobalDeviceStatusChangedNotification
                                                                object:status
                                                              userInfo:@{@"connected": @(connected)}];
        });
    });
}

- (BOOL)isDeviceBusy:(NSString *)deviceID {
    NSArray<TaskInfo *> *activeTasks = [self getActiveTasksForDevice:deviceID];
    return activeTasks.count > 0;
}

- (BOOL)canDeviceAcceptOperation:(NSString *)deviceID forOperation:(NSString *)operationIdentifier {
    TaskCreationCheckResult *result = [self checkCanCreateTaskWithOperation:operationIdentifier
                                                                    onDevice:deviceID
                                                                  fromSource:@"anonymous"
                                                                withPriority:TaskPriorityNormal];
    
    return (result.result == TaskCreationAllowed || result.result == TaskCreationCanQueue);
}

- (void)updateDeviceStatusForTask:(TaskInfo *)task {
    DeviceStatus *status = [self getDeviceStatus:task.deviceID];
    status.lastActivityTime = [NSDate date];
    
    // 计算忙碌时间
    if ([task isActive]) {
        NSTimeInterval taskDuration = [[NSDate date] timeIntervalSinceDate:task.startTime];
        status.totalBusyTime += taskDuration;
    }
}

#pragma mark - 💾 设备选择状态管理（保持原有功能）

- (void)saveDeviceSelection:(NSString *)deviceID
                 deviceInfo:(NSDictionary *)deviceInfo
                 forSource:(NSString *)sourceName {
    
    if (!deviceID || !sourceName) {
        [self debugLog:@"❌ 保存设备选择失败: 参数不能为空"];
        return;
    }
    
    dispatch_barrier_async(self.taskQueue, ^{
        DeviceSelectionState *state = [[DeviceSelectionState alloc] init];
        state.deviceID = deviceID;
        state.sourceName = sourceName;
        state.deviceInfo = deviceInfo ?: @{};
        state.selectionTime = [NSDate date];
        state.isLocked = NO;
        
        self.deviceSelections[sourceName] = state;
        
        [self debugLog:@"✅ 保存设备选择：%@ -> %@", sourceName, deviceID];
        
        // 立即持久化
        [self saveDeviceSelectionsToDisk];
        
        // 发送通知
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:GlobalDeviceSelectionChangedNotification
                                                                object:state];
        });
    });
}

- (DeviceSelectionState * _Nullable)getDeviceSelectionForSource:(NSString *)sourceName {
    __block DeviceSelectionState *state = nil;
    
    dispatch_sync(self.taskQueue, ^{
        state = [self.deviceSelections[sourceName] copy];
    });
    
    return state;
}

- (void)clearDeviceSelectionForSource:(NSString *)sourceName {
    dispatch_barrier_async(self.taskQueue, ^{
        [self.deviceSelections removeObjectForKey:sourceName];
        [self debugLog:@"🗑️ 清除设备选择：%@", sourceName];
        [self saveDeviceSelectionsToDisk];
    });
}

- (NSDictionary<NSString *, DeviceSelectionState *> *)getAllDeviceSelections {
    __block NSDictionary *selections = nil;
    
    dispatch_sync(self.taskQueue, ^{
        selections = [self.deviceSelections copy];
    });
    
    return selections;
}

- (BOOL)lockDeviceSelection:(NSString *)deviceID forSource:(NSString *)sourceName {
    __block BOOL success = NO;
    
    dispatch_barrier_sync(self.taskQueue, ^{
        DeviceSelectionState *state = self.deviceSelections[sourceName];
        if (state && [state.deviceID isEqualToString:deviceID]) {
            state.isLocked = YES;
            success = YES;
            [self debugLog:@"🔒 锁定设备选择：%@ -> %@", sourceName, deviceID];
        }
    });
    
    return success;
}

- (void)unlockDeviceSelection:(NSString *)deviceID forSource:(NSString *)sourceName {
    dispatch_barrier_async(self.taskQueue, ^{
        DeviceSelectionState *state = self.deviceSelections[sourceName];
        if (state && [state.deviceID isEqualToString:deviceID]) {
            state.isLocked = NO;
            [self debugLog:@"🔓 解锁设备选择：%@ -> %@", sourceName, deviceID];
        }
    });
}

#pragma mark - 🔒 与 GlobalLockController 集成

- (void)setLockController:(GlobalLockController *)lockController {
    self.lockController = lockController;
    [self debugLog:@"✅ 设置 GlobalLockController 实例"];
}

- (GlobalLockController * _Nullable)getLockController {
    return self.lockController;
}

- (NSDictionary *)checkDeviceLockStatus:(NSString *)deviceID forSource:(NSString *)sourceName {
    if (!self.lockController) {
        return @{
            @"canLock": @YES,
            @"message": @"无锁控制器，允许操作"
        };
    }
    
    NSString *currentOwner = [self.lockController getCurrentOwnerOfDevice:deviceID];
    
    if (!currentOwner) {
        return @{
            @"canLock": @YES,
            @"message": @"设备可用"
        };
    }
    
    if ([currentOwner isEqualToString:sourceName]) {
        return @{
            @"canLock": @YES,
            @"message": @"设备已被当前来源锁定"
        };
    }
    
    return @{
        @"canLock": @NO,
        @"message": [NSString stringWithFormat:@"设备被 %@ 占用中", currentOwner],
        @"currentOwner": currentOwner
    };
}

- (BOOL)tryLockDeviceForTask:(NSString *)deviceID
                  fromSource:(NSString *)sourceName
                    taskInfo:(TaskInfo *)taskInfo {
    
    if (!self.lockController || !taskInfo.requiresDeviceLock) {
        return YES; // 不需要锁定或无锁控制器
    }
    
    // 创建设备锁定信息
    DeviceLockInfo *lockInfo = [[DeviceLockInfo alloc] init];
    lockInfo.deviceID = deviceID;
    lockInfo.deviceName = taskInfo.parameters[@"deviceName"] ?: @"Unknown Device";
    lockInfo.deviceType = taskInfo.parameters[@"deviceType"] ?: @"Unknown";
    lockInfo.deviceMode = taskInfo.parameters[@"deviceMode"] ?: @"Unknown";
    lockInfo.deviceVersion = taskInfo.parameters[@"deviceVersion"] ?: @"Unknown";
    lockInfo.deviceECID = taskInfo.parameters[@"deviceECID"] ?: @"";
    lockInfo.deviceSerialNumber = taskInfo.parameters[@"deviceSerialNumber"] ?: @"";
    lockInfo.lockStatus = DeviceLockStatusLocked;
    lockInfo.lockSource = LockSourceFlasher; // 默认来源
    lockInfo.lockSourceName = sourceName;
    lockInfo.lockTime = [NSDate date];
    lockInfo.activeTaskCount = 1;
    
    NSError *error = nil;
    LockResult result = [self.lockController lockDevice:lockInfo
                                             sourceType:LockSourceFlasher
                                             sourceName:sourceName
                                                  error:&error];
    
    if (result == LockResultSuccess) {
        [self debugLog:@"🔒 设备锁定成功：%@ -> %@", sourceName, deviceID];
        return YES;
    } else {
        [self debugLog:@"❌ 设备锁定失败：%@ -> %@ (%@)", sourceName, deviceID, error.localizedDescription];
        return NO;
    }
}

- (void)releaseDeviceLockForTask:(NSString *)deviceID
                      fromSource:(NSString *)sourceName
                          taskId:(NSString *)taskId {
    
    if (!self.lockController) {
        return;
    }
    
    BOOL unlocked = [self.lockController unlockDevice:deviceID sourceName:sourceName];
    if (unlocked) {
        [self debugLog:@"🔓 设备锁定已释放：%@ -> %@", sourceName, deviceID];
    } else {
        [self debugLog:@"❌ 设备锁定释放失败：%@ -> %@", sourceName, deviceID];
    }
}

#pragma mark - 🚀 高级功能

- (NSTimeInterval)estimateWaitTimeForOperation:(NSString *)operationIdentifier
                                      onDevice:(NSString *)deviceID {
    NSArray<TaskInfo *> *activeTasks = [self getActiveTasksForDevice:deviceID];
    
    NSTimeInterval maxWaitTime = 0;
    for (TaskInfo *task in activeTasks) {
        NSTimeInterval elapsed = [[NSDate date] timeIntervalSinceDate:task.startTime];
        NSTimeInterval estimated = task.maxDuration - elapsed;
        maxWaitTime = MAX(maxWaitTime, estimated);
    }
    
    return MAX(maxWaitTime, 0);
}

- (void)notifyWhenTaskCompletes:(NSString *)taskId
                     completion:(void(^)(TaskInfo *task, BOOL success))completion {
    if (!taskId || !completion) return;
    
    dispatch_barrier_async(self.taskQueue, ^{
        if (!self.taskCompletionCallbacks[taskId]) {
            self.taskCompletionCallbacks[taskId] = [NSMutableArray array];
        }
        [self.taskCompletionCallbacks[taskId] addObject:[completion copy]];
    });
}

- (NSInteger)cancelAllTasksForDevice:(NSString *)deviceID reason:(NSString * _Nullable)reason {
    __block NSInteger cancelledCount = 0;
    
    dispatch_barrier_sync(self.taskQueue, ^{
        NSArray<TaskInfo *> *activeTasks = [self getActiveTasksForDevice:deviceID];
        
        for (TaskInfo *task in activeTasks) {
            if ([task canBeInterrupted]) {
                [self cancelTask:task.taskId reason:reason ?: @"批量取消"];
                cancelledCount++;
            }
        }
    });
    
    [self debugLog:@"🚫 批量取消设备任务：%@ - %ld个", deviceID, (long)cancelledCount];
    return cancelledCount;
}

- (NSInteger)cancelAllTasksForSource:(NSString *)sourceName reason:(NSString * _Nullable)reason {
    __block NSInteger cancelledCount = 0;
    
    dispatch_barrier_sync(self.taskQueue, ^{
        NSArray<TaskInfo *> *activeTasks = [self getActiveTasksForSource:sourceName];
        
        for (TaskInfo *task in activeTasks) {
            if ([task canBeInterrupted]) {
                [self cancelTask:task.taskId reason:reason ?: @"批量取消"];
                cancelledCount++;
            }
        }
    });
    
    [self debugLog:@"🚫 批量取消来源任务：%@ - %ld个", sourceName, (long)cancelledCount];
    return cancelledCount;
}

- (NSInteger)cleanupTimedOutTasks {
    __block NSInteger cleanedCount = 0;
    
    dispatch_barrier_sync(self.taskQueue, ^{
        NSMutableArray<NSString *> *timedOutTaskIds = [NSMutableArray array];
        
        for (TaskInfo *task in self.allTasks.allValues) {
            if ([task hasTimedOut]) {
                [timedOutTaskIds addObject:task.taskId];
            }
        }
        
        for (NSString *taskId in timedOutTaskIds) {
            [self forceStopTask:taskId reason:@"任务超时"];
            cleanedCount++;
        }
    });
    
    if (cleanedCount > 0) {
        [self debugLog:@"🧹 清理超时任务：%ld个", (long)cleanedCount];
    }
    
    return cleanedCount;
}

#pragma mark - 辅助方法

- (void)notifyTaskCompletionCallbacks:(NSString *)taskId success:(BOOL)success {
    NSMutableArray *callbacks = self.taskCompletionCallbacks[taskId];
    if (callbacks) {
        TaskInfo *task = self.allTasks[taskId];
        
        for (void(^callback)(TaskInfo *, BOOL) in callbacks) {
            callback(task, success);
        }
        
        [self.taskCompletionCallbacks removeObjectForKey:taskId];
    }
}

- (void)startCleanupTimer {
    self.cleanupTimer = [NSTimer scheduledTimerWithTimeInterval:TaskCleanupInterval
                                                         target:self
                                                       selector:@selector(performCleanup)
                                                       userInfo:nil
                                                        repeats:YES];
    [self debugLog:@"⏰ 启动定时清理器"];
}

- (void)performCleanup {
    [self cleanupTimedOutTasks];
    
    // 清理已完成的旧任务（保留最近24小时的）
    dispatch_barrier_async(self.taskQueue, ^{
        NSDate *cutoffDate = [NSDate dateWithTimeIntervalSinceNow:-24 * 3600];
        NSMutableArray<NSString *> *taskIdsToRemove = [NSMutableArray array];
        
        for (TaskInfo *task in self.allTasks.allValues) {
            if ([task isCompleted] && task.completionTime && [task.completionTime isEarlierThan:cutoffDate]) {
                [taskIdsToRemove addObject:task.taskId];
            }
        }
        
        for (NSString *taskId in taskIdsToRemove) {
            [self.allTasks removeObjectForKey:taskId];
        }
        
        if (taskIdsToRemove.count > 0) {
            [self debugLog:@"🗑️ 清理旧任务：%lu个", (unsigned long)taskIdsToRemove.count];
        }
    });
}

#pragma mark - 💿 持久化和配置

- (void)saveStatesToDisk {
    [self saveDeviceSelectionsToDisk];
    [self saveTaskStatesToDisk];
}

- (void)saveDeviceSelectionsToDisk {
    @try {
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
        NSString *appSupportPath = paths.firstObject;
        NSString *mfcDataPath = [appSupportPath stringByAppendingPathComponent:@"com.mfcbox.imfcdata"];
        
        NSFileManager *fileManager = [NSFileManager defaultManager];
        if (![fileManager fileExistsAtPath:mfcDataPath]) {
            [fileManager createDirectoryAtPath:mfcDataPath withIntermediateDirectories:YES attributes:nil error:nil];
        }
        
        NSString *filePath = [mfcDataPath stringByAppendingPathComponent:DeviceSelectionStateFileName];
        NSData *data = [NSKeyedArchiver archivedDataWithRootObject:self.deviceSelections requiringSecureCoding:NO error:nil];
        
        if (data) {
            [data writeToFile:filePath atomically:YES];
            self.lastSaveTime = [NSDate date];
            [self debugLog:@"💾 设备选择状态已保存"];
        }
    } @catch (NSException *exception) {
        [self debugLog:@"❌ 保存设备选择状态失败：%@", exception.reason];
    }
}

- (void)saveTaskStatesToDisk {
    @try {
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
        NSString *appSupportPath = paths.firstObject;
        NSString *mfcDataPath = [appSupportPath stringByAppendingPathComponent:@"com.mfcbox.imfcdata"];
        
        NSString *filePath = [mfcDataPath stringByAppendingPathComponent:TaskStatesFileName];
        
        // 只保存活跃任务和最近完成的任务
        NSMutableDictionary *tasksToSave = [NSMutableDictionary dictionary];
        NSDate *cutoffDate = [NSDate dateWithTimeIntervalSinceNow:-3600]; // 1小时内
        
        for (NSString *taskId in self.allTasks) {
            TaskInfo *task = self.allTasks[taskId];
            if ([task isActive] || (task.completionTime && [task.completionTime isLaterThan:cutoffDate])) {
                tasksToSave[taskId] = task;
            }
        }
        
        NSData *data = [NSKeyedArchiver archivedDataWithRootObject:tasksToSave requiringSecureCoding:NO error:nil];
        
        if (data) {
            [data writeToFile:filePath atomically:YES];
            [self debugLog:@"💾 任务状态已保存：%lu个", (unsigned long)tasksToSave.count];
        }
    } @catch (NSException *exception) {
        [self debugLog:@"❌ 保存任务状态失败：%@", exception.reason];
    }
}

- (void)loadStatesFromDisk {
    [self loadDeviceSelectionsFromDisk];
    [self loadTaskStatesFromDisk];
}

- (void)loadDeviceSelectionsFromDisk {
    @try {
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
        NSString *appSupportPath = paths.firstObject;
        NSString *mfcDataPath = [appSupportPath stringByAppendingPathComponent:@"com.mfcbox.imfcdata"];
        NSString *filePath = [mfcDataPath stringByAppendingPathComponent:DeviceSelectionStateFileName];
        
        if ([[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
            NSData *data = [NSData dataWithContentsOfFile:filePath];
            if (data) {
                NSDictionary *loadedSelections = [NSKeyedUnarchiver unarchiveObjectWithData:data];
                if (loadedSelections && [loadedSelections isKindOfClass:[NSDictionary class]]) {
                    [self.deviceSelections addEntriesFromDictionary:loadedSelections];
                    [self debugLog:@"📁 设备选择状态已加载：%lu个", (unsigned long)loadedSelections.count];
                }
            }
        }
    } @catch (NSException *exception) {
        [self debugLog:@"❌ 加载设备选择状态失败：%@", exception.reason];
    }
}

- (void)loadTaskStatesFromDisk {
    @try {
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
        NSString *appSupportPath = paths.firstObject;
        NSString *mfcDataPath = [appSupportPath stringByAppendingPathComponent:@"com.mfcbox.imfcdata"];
        NSString *filePath = [mfcDataPath stringByAppendingPathComponent:TaskStatesFileName];
        
        if ([[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
            NSData *data = [NSData dataWithContentsOfFile:filePath];
            if (data) {
                NSDictionary *loadedTasks = [NSKeyedUnarchiver unarchiveObjectWithData:data];
                if (loadedTasks && [loadedTasks isKindOfClass:[NSDictionary class]]) {
                    [self.allTasks addEntriesFromDictionary:loadedTasks];
                    [self debugLog:@"📁 任务状态已加载：%lu个", (unsigned long)loadedTasks.count];
                }
            }
        }
    } @catch (NSException *exception) {
        [self debugLog:@"❌ 加载任务状态失败：%@", exception.reason];
    }
}

- (void)clearAllStates {
    dispatch_barrier_async(self.taskQueue, ^{
        [self.allTasks removeAllObjects];
        [self.deviceSelections removeAllObjects];
        [self.deviceStatuses removeAllObjects];
        [self.taskCompletionCallbacks removeAllObjects];
        
        self.totalTasksCreated = 0;
        self.totalTasksCompleted = 0;
        self.totalTasksFailed = 0;
        
        [self debugLog:@"🗑️ 所有状态已清除"];
    });
}

#pragma mark - 📈 调试和统计

- (void)printDetailedStatus {
    [self debugLog:@"=== GlobalTaskManager 详细状态 ==="];
    [self debugLog:@"活跃任务：%lu个", (unsigned long)[self getAllActiveTasks].count];
    [self debugLog:@"设备选择：%lu个", (unsigned long)self.deviceSelections.count];
    [self debugLog:@"设备状态：%lu个", (unsigned long)self.deviceStatuses.count];
    [self debugLog:@"完成回调：%lu个", (unsigned long)self.taskCompletionCallbacks.count];
    [self debugLog:@"总创建：%ld，总完成：%ld，总失败：%ld",
     (long)self.totalTasksCreated, (long)self.totalTasksCompleted, (long)self.totalTasksFailed];
    [self debugLog:@"================================"];
}

- (NSDictionary *)getPerformanceStatistics {
    NSArray<TaskInfo *> *activeTasks = [self getAllActiveTasks];
    
    return @{
        @"activeTasksCount": @(activeTasks.count),
        @"deviceSelectionsCount": @(self.deviceSelections.count),
        @"deviceStatusesCount": @(self.deviceStatuses.count),
        @"totalTasksCreated": @(self.totalTasksCreated),
        @"totalTasksCompleted": @(self.totalTasksCompleted),
        @"totalTasksFailed": @(self.totalTasksFailed),
        @"successRate": self.totalTasksCreated > 0 ? @((double)self.totalTasksCompleted / self.totalTasksCreated) : @0,
        @"lastSaveTime": self.lastSaveTime ?: [NSNull null],
        @"debugMode": @(self.debugMode),
        @"hasCompatibilityChecker": @(self.compatibilityChecker != nil),
        @"hasLockController": @(self.lockController != nil),
        @"timestamp": [NSDate date]
    };
}

- (void)setDebugMode:(BOOL)enabled {
    self.debugMode = enabled;
    [self debugLog:@"调试模式 %@", enabled ? @"开启" : @"关闭"];
}

#pragma mark - 🔧 便捷方法

- (NSString *)generateTaskID:(NSString *)operationIdentifier forDevice:(NSString *)deviceID {
    NSString *deviceSuffix = deviceID.length > 8 ? [deviceID substringToIndex:8] : deviceID;
    NSString *operationPrefix = [operationIdentifier stringByReplacingOccurrencesOfString:@"." withString:@"_"];
    NSTimeInterval timestamp = [[NSDate date] timeIntervalSince1970];
    
    return [NSString stringWithFormat:@"%@_%@_%ld", operationPrefix, deviceSuffix, (long)timestamp];
}

- (NSString *)getDisplayNameForOperation:(NSString *)operationIdentifier {
    // 这个方法会被 TaskBridge 调用，从其配置中获取显示名称
    // 默认返回操作标识符本身
    return operationIdentifier;
}

- (BOOL)operationRequiresDeviceLock:(NSString *)operationIdentifier {
    // 默认策略：固件相关操作需要锁定
    return [operationIdentifier containsString:@"firmware"] || [operationIdentifier containsString:@"restore"];
}

/**
 * 视图切换时的状态检查
 * @param targetView 目标视图标识
 * @param currentView 当前视图标识
 * @return 返回当前视图的任务状态信息
 */
- (NSDictionary *)checkViewTransitionState:(NSString *)targetView
                              currentView:(NSString *)currentView {
    NSMutableDictionary *state = [NSMutableDictionary dictionary];
    
    // 获取当前视图的活跃任务
    NSArray<TaskInfo *> *activeTasks = [self getActiveTasksForSource:currentView];
    
    if (activeTasks.count > 0) {
        // 有活跃任务，但允许切换
        state[@"hasActiveTasks"] = @YES;
        state[@"activeTaskCount"] = @(activeTasks.count);
        state[@"canSwitch"] = @YES;  // 始终允许切换
        
        // 提供任务信息供UI展示
        NSMutableArray *taskInfo = [NSMutableArray array];
        for (TaskInfo *task in activeTasks) {
            [taskInfo addObject:@{
                @"taskId": task.taskId,
                @"description": task.taskDescription,
                @"progress": @(task.progress)
            }];
        }
        state[@"tasks"] = taskInfo;
    } else {
        // 没有活跃任务
        state[@"hasActiveTasks"] = @NO;
        state[@"canSwitch"] = @YES;
    }
    
    return state;
}

/**
 * 处理视图返回逻辑
 * @param viewIdentifier 视图标识
 * @return 视图状态信息
 */
- (NSDictionary *)handleViewReturn:(NSString *)viewIdentifier {
    NSArray<TaskInfo *> *tasks = [self getActiveTasksForSource:viewIdentifier];
    
    if (tasks.count > 0) {
        // 有未完成的任务，返回该视图并继续任务
        return @{
            @"action": @"continueTask",
            @"hasActiveTasks": @YES,
            @"tasks": tasks
        };
    } else {
        // 没有任务，可以返回默认视图
        return @{
            @"action": @"returnToDefault",
            @"hasActiveTasks": @NO
        };
    }
}

/**
 切换到其他视图时
 // 在 FlasherController.m
 - (void)switchToOtherView {
     NSDictionary *state = [[GlobalTaskManager sharedManager]
                           checkViewTransitionState:@"targetView"
                           currentView:@"FlasherController"];
     
     // 允许切换，但如果有活跃任务，可以显示提示
     if ([state[@"hasActiveTasks"] boolValue]) {
         // 可以选择显示一个提示，告知用户有任务正在进行
         NSString *message = [NSString stringWithFormat:@"有%@个任务正在进行，切换后任务会继续在后台执行",
                             state[@"activeTaskCount"]];
         [self showNotification:message];
     }
     
     // 执行视图切换
     [self performViewTransition];
 }
 
 返回到原视图时：
 
 - (void)returnToView {
     NSDictionary *state = [[GlobalTaskManager sharedManager]
                           handleViewReturn:@"FlasherController"];
     
     if ([state[@"hasActiveTasks"] boolValue]) {
         // 有未完成的任务，返回并继续显示任务状态
         [self updateTaskUI:state[@"tasks"]];
     } else {
         // 没有任务，显示默认状态
         [self resetToDefaultState];
     }
 }
 
 
 
 */

#pragma mark - 应用生命周期

- (void)applicationWillTerminate:(NSNotification *)notification {
    [self.cleanupTimer invalidate];
    [self saveStatesToDisk];
    [self debugLog:@"应用将终止，状态已保存"];
}

- (void)debugLog:(NSString *)format, ... {
    if (!self.debugMode) return;
    
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    
    NSLog(@"[GlobalTaskManager] %@", message);
}

- (void)dealloc {
    [self.cleanupTimer invalidate];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end

NS_ASSUME_NONNULL_END
