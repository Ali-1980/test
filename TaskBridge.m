//
//  TaskBridge.m
//  MFCTOOL
//
//  Created by Monterey on 26/1/2025.
//  任务桥梁实现 - 视图控制器与任务管理器的协调桥梁
//

#import "TaskBridge.h"
#import "GlobalTaskManager.h"
#import "GlobalLockController.h"

NS_ASSUME_NONNULL_BEGIN

#pragma mark - TaskExecutionOptions 实现

@implementation TaskExecutionOptions

+ (instancetype)defaultOptions {
    TaskExecutionOptions *options = [[TaskExecutionOptions alloc] init];
    options.allowConcurrency = NO;
    options.allowViewSwitch = YES;
    options.showProgressUI = YES;
    options.autoHandleConflicts = YES;
    options.timeout = 300; // 5分钟
    options.customData = @{};
    return options;
}

+ (instancetype)exclusiveTaskOptions {
    TaskExecutionOptions *options = [self defaultOptions];
    options.allowConcurrency = NO;
    options.allowViewSwitch = NO;
    return options;
}

+ (instancetype)concurrentTaskOptions {
    TaskExecutionOptions *options = [self defaultOptions];
    options.allowConcurrency = YES;
    options.allowViewSwitch = YES;
    return options;
}

@end

#pragma mark - TaskBridge 实现

@interface TaskBridge ()

// 操作配置映射：操作名称 -> 任务配置
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *operationConfigs;

// 活跃任务映射：任务ID -> 回调信息
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *activeTaskCallbacks;

// 线程安全队列
@property (nonatomic, strong) dispatch_queue_t bridgeQueue;

// 调试模式
@property (nonatomic, assign) BOOL debugMode;

// 统计信息
@property (nonatomic, assign) NSInteger totalTasksExecuted;
@property (nonatomic, assign) NSInteger totalTasksSucceeded;
@property (nonatomic, assign) NSInteger totalTasksFailed;

@end

@implementation TaskBridge

#pragma mark - 单例模式

+ (instancetype)sharedBridge {
    static TaskBridge *_instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _instance = [[TaskBridge alloc] init];
    });
    return _instance;
}

- (instancetype)init {
    if (self = [super init]) {
        _operationConfigs = [NSMutableDictionary dictionary];
        _activeTaskCallbacks = [NSMutableDictionary dictionary];
        _bridgeQueue = dispatch_queue_create("com.mfctool.task.bridge", DISPATCH_QUEUE_CONCURRENT);
        _debugMode = NO;
        _totalTasksExecuted = 0;
        _totalTasksSucceeded = 0;
        _totalTasksFailed = 0;
        
        [self setupDefaultOperationConfigs];
        [self registerForTaskNotifications];
        
        [self debugLog:@"TaskBridge 初始化完成"];
    }
    return self;
}

#pragma mark - 默认操作配置

- (void)setupDefaultOperationConfigs {
    // FlasherController 操作配置
    [self registerOperation:@"firmware_restore" withConfig:@{
        @"taskType": @(DeviceTaskTypeRestore),
        @"displayName": @"固件恢复",
        @"isExclusive": @YES,
        @"allowViewSwitch": @NO,
        @"priority": @(TaskPriorityHigh),
        @"description": @"iOS/iPadOS 固件恢复操作",
        @"conflictMessage": @"固件恢复正在进行，请等待完成后再执行其他操作"
    }];
    
    [self registerOperation:@"firmware_update" withConfig:@{
        @"taskType": @(DeviceTaskTypeFlashing),
        @"displayName": @"固件更新",
        @"isExclusive": @YES,
        @"allowViewSwitch": @NO,
        @"priority": @(TaskPriorityHigh),
        @"description": @"iOS/iPadOS 固件刷写操作",
        @"conflictMessage": @"固件刷写正在进行，请等待完成后再执行其他操作"
    }];
    
    [self registerOperation:@"firmware_download" withConfig:@{
        @"taskType": @(DeviceTaskTypeOther),
        @"displayName": @"固件下载",
        @"isExclusive": @NO,
        @"allowViewSwitch": @YES,
        @"priority": @(TaskPriorityNormal),
        @"description": @"固件文件下载",
        @"conflictMessage": @"固件下载正在进行中"
    }];
    
    [self registerOperation:@"enter_recovery_mode" withConfig:@{
        @"taskType": @(DeviceTaskTypeOther),
        @"displayName": @"进入恢复模式",
        @"isExclusive": @NO,
        @"allowViewSwitch": @YES,
        @"priority": @(TaskPriorityLow),
        @"description": @"设备进入恢复模式",
        @"conflictMessage": @"设备操作正在进行中"
    }];
    
    // DeviceBackupRestore 操作配置
    [self registerOperation:@"backup_create" withConfig:@{
        @"taskType": @(DeviceTaskTypeBackup),
        @"displayName": @"创建备份",
        @"isExclusive": @NO,
        @"allowViewSwitch": @YES,
        @"priority": @(TaskPriorityNormal),
        @"description": @"设备数据备份",
        @"conflictMessage": @"备份操作正在进行中"
    }];
    
    [self registerOperation:@"backup_restore" withConfig:@{
        @"taskType": @(DeviceTaskTypeRestore),
        @"displayName": @"恢复备份",
        @"isExclusive": @YES,
        @"allowViewSwitch": @NO,
        @"priority": @(TaskPriorityHigh),
        @"description": @"从备份恢复设备数据",
        @"conflictMessage": @"备份恢复正在进行，请等待完成后再执行其他操作"
    }];
    
    [self registerOperation:@"backup_manage" withConfig:@{
        @"taskType": @(DeviceTaskTypeOther),
        @"displayName": @"备份管理",
        @"isExclusive": @NO,
        @"allowViewSwitch": @YES,
        @"priority": @(TaskPriorityLow),
        @"description": @"备份文件管理操作",
        @"conflictMessage": @"备份管理操作正在进行中"
    }];
    
    [self debugLog:@"默认操作配置已加载：%lu个操作", (unsigned long)self.operationConfigs.count];
}

#pragma mark - 核心桥梁方法

- (NSString * _Nullable)executeTask:(NSString *)operationName
                           onDevice:(NSString *)deviceID
                         fromSource:(NSString *)sourceName
                     withParameters:(NSDictionary * _Nullable)parameters
                            options:(TaskExecutionOptions * _Nullable)options
                     progressCallback:(TaskProgressCallback _Nullable)progressCallback
                         completion:(TaskExecutionCompletion)completion {
    
    // 参数验证
    if (!operationName || !deviceID || !sourceName || !completion) {
        [self debugLog:@"❌ 参数验证失败：operationName=%@, deviceID=%@, sourceName=%@", operationName, deviceID, sourceName];
        completion(NO, @"必要参数不能为空", nil);
        return nil;
    }
    
    // 获取操作配置
    NSDictionary *operationConfig = self.operationConfigs[operationName];
    if (!operationConfig) {
        [self debugLog:@"❌ 未知操作：%@", operationName];
        completion(NO, [NSString stringWithFormat:@"未知操作：%@", operationName], nil);
        return nil;
    }
    
    // 使用默认选项
    if (!options) {
        options = [TaskExecutionOptions defaultOptions];
    }
    
    // 合并操作配置和用户选项
    TaskExecutionOptions *finalOptions = [self mergeOperationConfig:operationConfig withOptions:options];
    
    __block NSString *taskId = nil;
    __block NSString *errorMessage = nil;
    
    dispatch_barrier_sync(self.bridgeQueue, ^{
        // 1. 预检查
        NSDictionary *preCheckResult = [self performPreCheck:operationName
                                                    onDevice:deviceID
                                                  fromSource:sourceName
                                                 withOptions:finalOptions];
        
        if (![preCheckResult[@"canExecute"] boolValue]) {
            errorMessage = preCheckResult[@"message"];
            
            // 如果启用自动冲突处理，尝试解决
            if (finalOptions.autoHandleConflicts) {
                [self handleTaskConflict:preCheckResult completion:^(BOOL shouldContinue) {
                    if (shouldContinue) {
                        // 递归重试
                        taskId = [self executeTask:operationName
                                          onDevice:deviceID
                                        fromSource:sourceName
                                    withParameters:parameters
                                           options:finalOptions
                                    progressCallback:progressCallback
                                        completion:completion];
                    } else {
                        completion(NO, errorMessage, nil);
                    }
                }];
                return;
            } else {
                return;
            }
        }
        
        // 2. 创建任务
        taskId = [self createTaskForOperation:operationName
                                     onDevice:deviceID
                                   fromSource:sourceName
                               withParameters:parameters
                                      options:finalOptions];
        
        if (!taskId) {
            errorMessage = @"任务创建失败";
            return;
        }
        
        // 3. 保存回调信息
        [self storeCallbacksForTask:taskId
                   progressCallback:progressCallback
                         completion:completion];
        
        // 4. 开始任务执行
        BOOL started = [[GlobalTaskManager sharedManager] startTask:taskId];
        if (!started) {
            errorMessage = @"任务启动失败";
            [self.activeTaskCallbacks removeObjectForKey:taskId];
            return;
        }
        
        self.totalTasksExecuted++;
    });
    
    if (errorMessage) {
        completion(NO, errorMessage, nil);
        return nil;
    }
    
    [self debugLog:@"✅ 任务执行成功：%@ (ID: %@)", operationName, taskId];
    return taskId;
}

- (NSString * _Nullable)simpleExecuteTask:(NSString *)operationName
                                 onDevice:(NSString *)deviceID
                               fromSource:(NSString *)sourceName
                               completion:(TaskExecutionCompletion)completion {
    return [self executeTask:operationName
                    onDevice:deviceID
                  fromSource:sourceName
              withParameters:nil
                     options:[TaskExecutionOptions defaultOptions]
              progressCallback:nil
                  completion:completion];
}

- (NSString * _Nullable)executeExclusiveTask:(NSString *)operationName
                                    onDevice:(NSString *)deviceID
                                  fromSource:(NSString *)sourceName
                              withParameters:(NSDictionary * _Nullable)parameters
                                  completion:(TaskExecutionCompletion)completion {
    return [self executeTask:operationName
                    onDevice:deviceID
                  fromSource:sourceName
              withParameters:parameters
                     options:[TaskExecutionOptions exclusiveTaskOptions]
              progressCallback:nil
                  completion:completion];
}

#pragma mark - 任务预检查

- (NSDictionary *)preCheckOperation:(NSString *)operationName
                           onDevice:(NSString *)deviceID
                         fromSource:(NSString *)sourceName {
    
    NSDictionary *operationConfig = self.operationConfigs[operationName];
    if (!operationConfig) {
        return @{
            @"canExecute": @NO,
            @"message": [NSString stringWithFormat:@"未知操作：%@", operationName],
            @"suggestions": @[]
        };
    }
    
    DeviceTaskType taskType = [operationConfig[@"taskType"] integerValue];
    
    // 使用 GlobalTaskManager 进行检查
    TaskCreationCheckResult *checkResult = [[GlobalTaskManager sharedManager]
                                          checkCanCreateTask:taskType
                                                    onDevice:deviceID
                                                  fromSource:sourceName
                                                withPriority:TaskPriorityNormal];
    
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"canExecute"] = @(checkResult.result == TaskCreationAllowed);
    result[@"message"] = checkResult.message ?: @"";
    result[@"suggestions"] = checkResult.suggestions ?: @[];
    result[@"conflictTasks"] = [self convertTasksToInfo:checkResult.conflictTasks];
    result[@"estimatedWaitTime"] = @(checkResult.estimatedWaitTime);
    
    if (checkResult.blockingTask) {
        result[@"blockingTask"] = [self convertTaskToInfo:checkResult.blockingTask];
    }
    
    return [result copy];
}

- (NSDictionary *)performPreCheck:(NSString *)operationName
                         onDevice:(NSString *)deviceID
                       fromSource:(NSString *)sourceName
                      withOptions:(TaskExecutionOptions *)options {
    
    // 基础检查
    NSDictionary *basicCheck = [self preCheckOperation:operationName onDevice:deviceID fromSource:sourceName];
    
    if (![basicCheck[@"canExecute"] boolValue]) {
        return basicCheck;
    }
    
    // 设备锁定检查
    NSString *currentOwner = [[GlobalLockController sharedController] getCurrentOwnerOfDevice:deviceID];
    if (currentOwner && ![currentOwner isEqualToString:sourceName]) {
        return @{
            @"canExecute": @NO,
            @"message": [NSString stringWithFormat:@"设备被 %@ 占用中", currentOwner],
            @"suggestions": @[@"等待当前任务完成", @"切换到占用该设备的视图"]
        };
    }
    
    return @{
        @"canExecute": @YES,
        @"message": @"可以执行操作"
    };
}

#pragma mark - 任务创建

- (NSString * _Nullable)createTaskForOperation:(NSString *)operationName
                                      onDevice:(NSString *)deviceID
                                    fromSource:(NSString *)sourceName
                                withParameters:(NSDictionary *)parameters
                                       options:(TaskExecutionOptions *)options {
    
    NSDictionary *operationConfig = self.operationConfigs[operationName];
    DeviceTaskType taskType = [operationConfig[@"taskType"] integerValue];
    TaskPriority priority = [operationConfig[@"priority"] integerValue];
    NSString *description = operationConfig[@"description"];
    
    // 生成任务ID
    NSString *taskId = [[GlobalTaskManager sharedManager] generateTaskID:taskType forDevice:deviceID];
    
    // 创建任务信息
    TaskInfo *taskInfo = [TaskInfo taskWithID:taskId
                                     deviceID:deviceID
                                   sourceName:sourceName
                                     taskType:taskType
                                  description:description
                                     priority:priority];
    
    // 设置任务行为属性
    taskInfo.allowsConcurrency = options.allowConcurrency;
    taskInfo.allowsViewSwitch = options.allowViewSwitch;
    taskInfo.maxDuration = options.timeout;
    
    // 创建任务
    BOOL created = [[GlobalTaskManager sharedManager] createTask:taskInfo force:NO];
    
    if (created) {
        [self debugLog:@"✅ 任务创建成功：%@ -> %@", operationName, taskId];
        return taskId;
    } else {
        [self debugLog:@"❌ 任务创建失败：%@", operationName];
        return nil;
    }
}

#pragma mark - 任务状态查询

- (NSDictionary *)getDeviceTaskStatus:(NSString *)deviceID {
    NSArray<TaskInfo *> *activeTasks = [[GlobalTaskManager sharedManager] getActiveTasksForDevice:deviceID];
    TaskInfo *primaryTask = [[GlobalTaskManager sharedManager] getPrimaryTaskForDevice:deviceID];
    
    NSMutableArray *taskInfos = [NSMutableArray array];
    for (TaskInfo *task in activeTasks) {
        [taskInfos addObject:[self convertTaskToInfo:task]];
    }
    
    return @{
        @"deviceID": deviceID,
        @"isActive": @(activeTasks.count > 0),
        @"taskCount": @(activeTasks.count),
        @"activeTasks": taskInfos,
        @"primaryTask": primaryTask ? [self convertTaskToInfo:primaryTask] : [NSNull null]
    };
}

- (NSArray<NSDictionary *> *)getActiveTasksForSource:(NSString *)sourceName {
    NSArray<TaskInfo *> *allTasks = [[GlobalTaskManager sharedManager] getAllActiveTasks];
    NSMutableArray *sourceTasks = [NSMutableArray array];
    
    for (TaskInfo *task in allTasks) {
        if ([task.sourceName isEqualToString:sourceName]) {
            [sourceTasks addObject:[self convertTaskToInfo:task]];
        }
    }
    
    return [sourceTasks copy];
}

#pragma mark - 任务控制

- (BOOL)cancelTask:(NSString *)taskId withReason:(NSString * _Nullable)reason {
    BOOL cancelled = [[GlobalTaskManager sharedManager] cancelTask:taskId];
    
    if (cancelled) {
        [self debugLog:@"✅ 任务取消成功：%@ (原因：%@)", taskId, reason ?: @"用户取消"];
        
        // 调用完成回调
        [self notifyTaskCompletion:taskId success:NO errorMessage:reason ?: @"任务被取消"];
    }
    
    return cancelled;
}

- (NSInteger)forceStopAllTasksForDevice:(NSString *)deviceID fromSource:(NSString *)sourceName {
    NSArray<TaskInfo *> *activeTasks = [[GlobalTaskManager sharedManager] getActiveTasksForDevice:deviceID];
    NSInteger stoppedCount = 0;
    
    for (TaskInfo *task in activeTasks) {
        if ([task.sourceName isEqualToString:sourceName]) {
            if ([[GlobalTaskManager sharedManager] forceStopTask:task.taskId reason:@"用户强制停止"]) {
                stoppedCount++;
                [self notifyTaskCompletion:task.taskId success:NO errorMessage:@"任务被强制停止"];
            }
        }
    }
    
    [self debugLog:@"✅ 强制停止任务：%ld个 (设备：%@, 来源：%@)", (long)stoppedCount, deviceID, sourceName];
    return stoppedCount;
}

#pragma mark - 视图切换检查

- (NSDictionary *)checkViewSwitchPermission:(NSString *)targetView
                               fromSource:(NSString *)currentSource {
    
    // 获取当前源的活跃任务
    NSArray<NSDictionary *> *activeTasks = [self getActiveTasksForSource:currentSource];
    
    for (NSDictionary *taskInfo in activeTasks) {
        if (![taskInfo[@"allowsViewSwitch"] boolValue]) {
            return @{
                @"canSwitch": @NO,
                @"message": [NSString stringWithFormat:@"%@ 正在进行，无法切换视图", taskInfo[@"displayName"]],
                @"blockingTask": taskInfo
            };
        }
    }
    
    return @{
        @"canSwitch": @YES,
        @"message": @"可以切换视图"
    };
}

#pragma mark - 操作配置管理

- (void)registerOperation:(NSString *)operationName withConfig:(NSDictionary *)config {
    if (operationName && config) {
        self.operationConfigs[operationName] = [config copy];
        [self debugLog:@"注册操作配置：%@ -> %@", operationName, config[@"displayName"]];
    }
}

- (void)registerOperationsFromConfigFile:(NSString *)configFilePath {
    NSDictionary *configs = [NSDictionary dictionaryWithContentsOfFile:configFilePath];
    if (configs) {
        for (NSString *operationName in configs) {
            [self registerOperation:operationName withConfig:configs[operationName]];
        }
        [self debugLog:@"从配置文件加载了 %lu 个操作配置", (unsigned long)configs.count];
    }
}

#pragma mark - 辅助方法

- (TaskExecutionOptions *)mergeOperationConfig:(NSDictionary *)config withOptions:(TaskExecutionOptions *)options {
    TaskExecutionOptions *merged = [[TaskExecutionOptions alloc] init];
    
    // 优先使用配置中的设置，其次使用用户选项
    merged.allowConcurrency = config[@"isExclusive"] ? ![config[@"isExclusive"] boolValue] : options.allowConcurrency;
    merged.allowViewSwitch = config[@"allowViewSwitch"] ? [config[@"allowViewSwitch"] boolValue] : options.allowViewSwitch;
    merged.showProgressUI = options.showProgressUI;
    merged.autoHandleConflicts = options.autoHandleConflicts;
    merged.timeout = options.timeout;
    merged.customData = options.customData;
    
    return merged;
}

- (void)storeCallbacksForTask:(NSString *)taskId
             progressCallback:(TaskProgressCallback _Nullable)progressCallback
                   completion:(TaskExecutionCompletion)completion {
    
    NSMutableDictionary *callbacks = [NSMutableDictionary dictionary];
    if (progressCallback) {
        callbacks[@"progress"] = [progressCallback copy];
    }
    callbacks[@"completion"] = [completion copy];
    
    self.activeTaskCallbacks[taskId] = [callbacks copy];
}

- (void)handleTaskConflict:(NSDictionary *)conflictInfo completion:(void(^)(BOOL shouldContinue))completion {
    // 简单的自动处理：等待冲突任务完成
    NSDictionary *blockingTask = conflictInfo[@"blockingTask"];
    if (blockingTask) {
        NSString *blockingTaskId = blockingTask[@"taskId"];
        
        // 监听任务完成
        [[GlobalTaskManager sharedManager] notifyWhenTaskCompletes:blockingTaskId completion:^(TaskInfo *task, BOOL success) {
            completion(YES); // 冲突解决，可以继续
        }];
    } else {
        completion(NO); // 无法自动解决
    }
}

- (NSDictionary *)convertTaskToInfo:(TaskInfo *)task {
    if (!task) return @{};
    
    return @{
        @"taskId": task.taskId,
        @"deviceID": task.deviceID,
        @"sourceName": task.sourceName,
        @"taskType": @(task.taskType),
        @"status": @(task.status),
        @"priority": @(task.priority),
        @"description": task.taskDescription ?: @"",
        @"progress": @(task.progress),
        @"allowsViewSwitch": @(task.allowsViewSwitch),
        @"canBeCancelled": @(task.canBeCancelled),
        @"displayName": [self getDisplayNameForTask:task]
    };
}

- (NSArray<NSDictionary *> *)convertTasksToInfo:(NSArray<TaskInfo *> *)tasks {
    NSMutableArray *result = [NSMutableArray array];
    for (TaskInfo *task in tasks) {
        [result addObject:[self convertTaskToInfo:task]];
    }
    return [result copy];
}

- (NSString *)getDisplayNameForTask:(TaskInfo *)task {
    // 从操作配置中获取显示名称
    for (NSString *operationName in self.operationConfigs) {
        NSDictionary *config = self.operationConfigs[operationName];
        if ([config[@"taskType"] integerValue] == task.taskType) {
            return config[@"displayName"] ?: task.taskDescription;
        }
    }
    return task.taskDescription ?: @"未知任务";
}

#pragma mark - 通知处理

- (void)registerForTaskNotifications {
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onTaskCompleted:)
                                                 name:GlobalTaskCompletedNotification
                                               object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onTaskCancelled:)
                                                 name:GlobalTaskCancelledNotification
                                               object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onTaskUpdated:)
                                                 name:GlobalTaskUpdatedNotification
                                               object:nil];
}

- (void)onTaskCompleted:(NSNotification *)notification {
    TaskInfo *task = notification.object;
    BOOL success = [notification.userInfo[@"success"] boolValue];
    
    [self notifyTaskCompletion:task.taskId
                       success:success
                  errorMessage:success ? nil : @"任务执行失败"];
}

- (void)onTaskCancelled:(NSNotification *)notification {
    TaskInfo *task = notification.object;
    NSString *reason = notification.userInfo[@"reason"];
    
    [self notifyTaskCompletion:task.taskId
                       success:NO
                  errorMessage:reason ?: @"任务被取消"];
}

- (void)onTaskUpdated:(NSNotification *)notification {
    TaskInfo *task = notification.object;
    
    NSDictionary *callbacks = self.activeTaskCallbacks[task.taskId];
    TaskProgressCallback progressCallback = callbacks[@"progress"];
    
    if (progressCallback) {
        NSString *statusMessage = [NSString stringWithFormat:@"%@ - %.1f%%",
                                  [self getDisplayNameForTask:task],
                                  task.progress * 100];
        progressCallback(task.progress, statusMessage);
    }
}

- (void)notifyTaskCompletion:(NSString *)taskId success:(BOOL)success errorMessage:(NSString * _Nullable)errorMessage {
    NSDictionary *callbacks = self.activeTaskCallbacks[taskId];
    TaskExecutionCompletion completion = callbacks[@"completion"];
    
    if (completion) {
        NSDictionary *resultInfo = success ? @{@"taskId": taskId} : nil;
        completion(success, errorMessage, resultInfo);
    }
    
    // 清理回调
    [self.activeTaskCallbacks removeObjectForKey:taskId];
    
    // 更新统计
    if (success) {
        self.totalTasksSucceeded++;
    } else {
        self.totalTasksFailed++;
    }
}

#pragma mark - 调试和统计

- (NSDictionary *)getBridgeStatistics {
    return @{
        @"totalOperations": @(self.operationConfigs.count),
        @"totalTasksExecuted": @(self.totalTasksExecuted),
        @"totalTasksSucceeded": @(self.totalTasksSucceeded),
        @"totalTasksFailed": @(self.totalTasksFailed),
        @"activeCallbacks": @(self.activeTaskCallbacks.count),
        @"successRate": self.totalTasksExecuted > 0 ? @((double)self.totalTasksSucceeded / self.totalTasksExecuted) : @0
    };
}

- (void)setDebugMode:(BOOL)enabled {
    self.debugMode = enabled;
    [self debugLog:@"调试模式 %@", enabled ? @"开启" : @"关闭"];
}

- (void)printBridgeStatus {
    [self debugLog:@"=== TaskBridge 状态报告 ==="];
    [self debugLog:@"已注册操作：%lu个", (unsigned long)self.operationConfigs.count];
    [self debugLog:@"活跃回调：%lu个", (unsigned long)self.activeTaskCallbacks.count];
    [self debugLog:@"执行统计：总计%ld，成功%ld，失败%ld",
     (long)self.totalTasksExecuted, (long)self.totalTasksSucceeded, (long)self.totalTasksFailed];
    [self debugLog:@"========================"];
}

- (void)debugLog:(NSString *)format, ... {
    if (!self.debugMode) return;
    
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    
    NSLog(@"[TaskBridge] %@", message);
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end

NS_ASSUME_NONNULL_END
