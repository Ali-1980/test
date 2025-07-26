//
//  GlobalTaskManager.h
//  MFCTOOL
//
//  与 TaskBridge 和 GlobalLockController 深度集成
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class GlobalLockController;

#pragma mark - 🔄 最小化的状态枚举（仅保留必要的）

typedef NS_ENUM(NSInteger, TaskStatus) {
    TaskStatusIdle = 0,
    TaskStatusPreparing = 1,
    TaskStatusRunning = 2,
    TaskStatusCompleting = 3,
    TaskStatusCompleted = 4,
    TaskStatusFailed = 5,
    TaskStatusCancelled = 6
};

typedef NS_ENUM(NSInteger, TaskPriority) {
    TaskPriorityLow = 0,
    TaskPriorityNormal = 1,
    TaskPriorityHigh = 2,
    TaskPriorityUrgent = 3
};

typedef NS_ENUM(NSInteger, TaskCreationResult) {
    TaskCreationAllowed = 0,
    TaskCreationWaitPrevious = 1,
    TaskCreationBlocked = 2,
    TaskCreationCanQueue = 3,
    TaskCreationDeviceUnavailable = 4,
    TaskCreationInvalidRequest = 5
};

#pragma mark - 🆕 灵活的任务信息模型

@interface TaskInfo : NSObject <NSCopying, NSCoding>

// 核心标识信息
@property (nonatomic, copy) NSString *taskId;                      // 任务唯一ID
@property (nonatomic, copy) NSString *operationIdentifier;         // 操作标识符（对应 TaskBridge 的 operationName）
@property (nonatomic, copy) NSString *deviceID;                    // 设备ID
@property (nonatomic, copy) NSString *sourceName;                  // 来源控制器名称

// 任务状态和进度
@property (nonatomic, assign) TaskStatus status;                   // 当前状态
@property (nonatomic, assign) TaskPriority priority;               // 优先级
@property (nonatomic, assign) double progress;                     // 进度（0.0-1.0）
@property (nonatomic, copy) NSString *taskDescription;             // 任务描述
@property (nonatomic, strong) NSDate *startTime;                   // 开始时间
@property (nonatomic, strong) NSDate *updateTime;                  // 最后更新时间
@property (nonatomic, strong) NSDate *completionTime;              // 完成时间

// 任务行为属性（由 TaskBridge 配置决定）
@property (nonatomic, assign) BOOL isExclusive;                    // 是否排他性
@property (nonatomic, assign) BOOL allowsViewSwitch;               // 是否允许视图切换
@property (nonatomic, assign) BOOL allowsConcurrency;              // 是否允许并发
@property (nonatomic, assign) BOOL canBeCancelled;                 // 是否可取消
@property (nonatomic, assign) BOOL requiresDeviceLock;             // 是否需要设备锁定
@property (nonatomic, assign) NSTimeInterval maxDuration;          // 最大执行时间

// 扩展属性
@property (nonatomic, strong) NSDictionary *parameters;            // 任务参数
@property (nonatomic, strong) NSDictionary *context;               // 执行上下文
@property (nonatomic, strong) NSMutableArray *statusHistory;       // 状态变更历史
@property (nonatomic, copy, nullable) NSString *previousTaskId;    // 前置任务ID
@property (nonatomic, assign) NSInteger maxRetryCount;             // 最大重试次数

// 工厂方法
+ (instancetype)taskWithOperationIdentifier:(NSString *)operationIdentifier
                                    deviceID:(NSString *)deviceID
                                  sourceName:(NSString *)sourceName
                                 description:(NSString *)description
                                    priority:(TaskPriority)priority;

// 状态判断
- (BOOL)isActive;
- (BOOL)isCompleted;
- (BOOL)canBeInterrupted;
- (BOOL)hasTimedOut;

// 状态操作
- (void)addStatusEntry:(TaskStatus)status message:(NSString *)message;
- (NSArray *)getStatusHistory;
- (BOOL)hasReachedMaxRetries;

@end

#pragma mark - 任务创建检查结果

@interface TaskCreationCheckResult : NSObject

@property (nonatomic, assign) TaskCreationResult result;
@property (nonatomic, copy) NSString *message;
@property (nonatomic, strong, nullable) TaskInfo *blockingTask;
@property (nonatomic, strong) NSArray<TaskInfo *> *conflictTasks;
@property (nonatomic, assign) NSTimeInterval estimatedWaitTime;
@property (nonatomic, assign) BOOL canForceExecute;
@property (nonatomic, strong) NSArray<NSString *> *suggestions;

+ (instancetype)resultWithCode:(TaskCreationResult)result message:(NSString *)message;
+ (instancetype)allowedResult;
+ (instancetype)waitPreviousResult:(TaskInfo *)blockingTask;
+ (instancetype)blockedResult:(TaskInfo *)blockingTask;
+ (instancetype)deviceUnavailableResult:(NSString *)reason;

@end

#pragma mark - 设备状态管理

@interface DeviceSelectionState : NSObject <NSCopying>

@property (nonatomic, copy) NSString *deviceID;
@property (nonatomic, copy) NSString *sourceName;
@property (nonatomic, strong) NSDictionary *deviceInfo;
@property (nonatomic, strong) NSDate *selectionTime;
@property (nonatomic, assign) BOOL isLocked;

@end

@interface DeviceStatus : NSObject

@property (nonatomic, copy) NSString *deviceID;
@property (nonatomic, assign) BOOL isConnected;
@property (nonatomic, assign) BOOL isAvailable;
@property (nonatomic, strong) NSArray<TaskInfo *> *activeTasks;
@property (nonatomic, strong, nullable) TaskInfo *primaryTask;
@property (nonatomic, assign) NSTimeInterval totalBusyTime;
@property (nonatomic, strong) NSDate *lastActivityTime;

@end

#pragma mark - 任务兼容性检查协议

@protocol TaskCompatibilityChecker <NSObject>

- (BOOL)canOperation:(NSString *)operationIdentifier coexistWith:(NSString *)otherOperationIdentifier;
- (NSArray<NSString *> *)getConflictingOperations:(NSString *)operationIdentifier
                                   withActiveOperations:(NSArray<NSString *> *)activeOperations;
- (NSString *)getConflictMessage:(NSString *)operationIdentifier
                  conflictingWith:(NSString *)conflictingOperation;

@end

#pragma mark - 通知名称

extern NSString * const GlobalTaskCreatedNotification;
extern NSString * const GlobalTaskStartedNotification;
extern NSString * const GlobalTaskUpdatedNotification;
extern NSString * const GlobalTaskCompletedNotification;
extern NSString * const GlobalTaskCancelledNotification;
extern NSString * const GlobalDeviceSelectionChangedNotification;
extern NSString * const GlobalDeviceStatusChangedNotification;

#pragma mark - 重构后的全局任务管理器

@interface GlobalTaskManager : NSObject

+ (instancetype)sharedManager;

#pragma mark - 🤝 与 TaskBridge 集成接口

/**
 * 注册兼容性检查器（通常由 TaskBridge 注册）
 * @param checker 兼容性检查器
 */
- (void)setCompatibilityChecker:(id<TaskCompatibilityChecker>)checker;

/**
 * 获取当前兼容性检查器
 */
- (id<TaskCompatibilityChecker>)getCompatibilityChecker;

#pragma mark - 🎯 核心任务管理功能

/**
 * 检查是否可以创建任务
 * @param operationIdentifier 操作标识符
 * @param deviceID 设备ID
 * @param sourceName 来源名称
 * @param priority 任务优先级
 * @return 检查结果
 */
- (TaskCreationCheckResult *)checkCanCreateTaskWithOperation:(NSString *)operationIdentifier
                                                    onDevice:(NSString *)deviceID
                                                  fromSource:(NSString *)sourceName
                                                withPriority:(TaskPriority)priority;

/**
 * 创建任务
 * @param taskInfo 任务信息
 * @param forceCreate 是否强制创建
 * @return 是否成功创建
 */
- (BOOL)createTask:(TaskInfo *)taskInfo force:(BOOL)forceCreate;

/**
 * 开始任务执行
 * @param taskId 任务ID
 * @return 是否成功开始
 */
- (BOOL)startTask:(NSString *)taskId;

/**
 * 更新任务状态和进度
 * @param taskId 任务ID
 * @param status 新状态
 * @param progress 进度（0.0-1.0，传-1表示不更新进度）
 * @param message 状态消息
 */
- (void)updateTask:(NSString *)taskId
            status:(TaskStatus)status
          progress:(double)progress
           message:(NSString * _Nullable)message;

/**
 * 完成任务
 * @param taskId 任务ID
 * @param success 是否成功完成
 * @param result 完成结果数据
 */
- (void)completeTask:(NSString *)taskId
             success:(BOOL)success
              result:(NSDictionary * _Nullable)result;

/**
 * 取消任务
 * @param taskId 任务ID
 * @param reason 取消原因
 * @return 是否成功取消
 */
- (BOOL)cancelTask:(NSString *)taskId reason:(NSString * _Nullable)reason;

/**
 * 强制停止任务
 * @param taskId 任务ID
 * @param reason 停止原因
 * @return 是否成功停止
 */
- (BOOL)forceStopTask:(NSString *)taskId reason:(NSString *)reason;

#pragma mark - 📊 任务查询功能

/**
 * 获取任务信息
 * @param taskId 任务ID
 * @return 任务信息
 */
- (TaskInfo * _Nullable)getTask:(NSString *)taskId;

/**
 * 获取设备的活跃任务
 * @param deviceID 设备ID
 * @return 活跃任务数组
 */
- (NSArray<TaskInfo *> *)getActiveTasksForDevice:(NSString *)deviceID;

/**
 * 获取设备的主要任务（最高优先级）
 * @param deviceID 设备ID
 * @return 主要任务
 */
- (TaskInfo * _Nullable)getPrimaryTaskForDevice:(NSString *)deviceID;

/**
 * 获取来源的活跃任务
 * @param sourceName 来源名称
 * @return 活跃任务数组
 */
- (NSArray<TaskInfo *> *)getActiveTasksForSource:(NSString *)sourceName;

/**
 * 获取指定操作的活跃任务
 * @param operationIdentifier 操作标识符
 * @param deviceID 设备ID（可选）
 * @return 活跃任务数组
 */
- (NSArray<TaskInfo *> *)getActiveTasksForOperation:(NSString *)operationIdentifier
                                            onDevice:(NSString * _Nullable)deviceID;

/**
 * 获取所有活跃任务
 * @return 所有活跃任务数组
 */
- (NSArray<TaskInfo *> *)getAllActiveTasks;

/**
 * 获取指定状态的任务
 * @param deviceID 设备ID
 * @param status 任务状态
 * @return 符合条件的任务数组
 */
- (NSArray<TaskInfo *> *)getTasksForDevice:(NSString *)deviceID withStatus:(TaskStatus)status;

#pragma mark - 🔧 设备状态管理

/**
 * 获取设备状态
 * @param deviceID 设备ID
 * @return 设备状态信息
 */
- (DeviceStatus *)getDeviceStatus:(NSString *)deviceID;

/**
 * 更新设备连接状态
 * @param deviceID 设备ID
 * @param connected 是否连接
 */
- (void)updateDeviceConnectionStatus:(NSString *)deviceID connected:(BOOL)connected;

/**
 * 设备是否忙碌
 * @param deviceID 设备ID
 * @return 是否忙碌
 */
- (BOOL)isDeviceBusy:(NSString *)deviceID;

/**
 * 设备是否可以接受新的操作
 * @param deviceID 设备ID
 * @param operationIdentifier 操作标识符
 * @return 是否可以接受
 */
- (BOOL)canDeviceAcceptOperation:(NSString *)deviceID
                   forOperation:(NSString *)operationIdentifier;

#pragma mark - 💾 设备选择状态管理

/**
 * 保存设备选择状态
 * @param deviceID 设备ID
 * @param deviceInfo 设备信息字典
 * @param sourceName 来源名称
 */
- (void)saveDeviceSelection:(NSString *)deviceID
                 deviceInfo:(NSDictionary *)deviceInfo
                 forSource:(NSString *)sourceName;

/**
 * 获取设备选择状态
 * @param sourceName 来源名称
 * @return 设备选择状态
 */
- (DeviceSelectionState * _Nullable)getDeviceSelectionForSource:(NSString *)sourceName;

/**
 * 清除设备选择状态
 * @param sourceName 来源名称
 */
- (void)clearDeviceSelectionForSource:(NSString *)sourceName;

/**
 * 获取所有设备选择状态
 * @return 所有设备选择状态字典
 */
- (NSDictionary<NSString *, DeviceSelectionState *> *)getAllDeviceSelections;

/**
 * 锁定设备选择
 * @param deviceID 设备ID
 * @param sourceName 来源名称
 * @return 是否锁定成功
 */
- (BOOL)lockDeviceSelection:(NSString *)deviceID forSource:(NSString *)sourceName;

/**
 * 解锁设备选择
 * @param deviceID 设备ID
 * @param sourceName 来源名称
 */
- (void)unlockDeviceSelection:(NSString *)deviceID forSource:(NSString *)sourceName;

#pragma mark - 🔒 与 GlobalLockController 集成

/**
 * 设置 GlobalLockController 实例
 * @param lockController 锁控制器实例
 */
- (void)setLockController:(GlobalLockController *)lockController;

/**
 * 获取当前 GlobalLockController 实例
 */
- (GlobalLockController * _Nullable)getLockController;

/**
 * 检查设备锁定状态
 * @param deviceID 设备ID
 * @param sourceName 来源名称
 * @return 检查结果字典
 */
- (NSDictionary *)checkDeviceLockStatus:(NSString *)deviceID forSource:(NSString *)sourceName;

/**
 * 尝试锁定设备（如果任务需要）
 * @param deviceID 设备ID
 * @param sourceName 来源名称
 * @param taskInfo 任务信息
 * @return 是否成功锁定
 */
- (BOOL)tryLockDeviceForTask:(NSString *)deviceID
                  fromSource:(NSString *)sourceName
                    taskInfo:(TaskInfo *)taskInfo;

/**
 * 释放设备锁定（当任务完成时）
 * @param deviceID 设备ID
 * @param sourceName 来源名称
 * @param taskId 任务ID
 */
- (void)releaseDeviceLockForTask:(NSString *)deviceID
                      fromSource:(NSString *)sourceName
                          taskId:(NSString *)taskId;

#pragma mark - 🚀 高级功能

/**
 * 预估任务等待时间
 * @param operationIdentifier 操作标识符
 * @param deviceID 设备ID
 * @return 预估等待时间（秒）
 */
- (NSTimeInterval)estimateWaitTimeForOperation:(NSString *)operationIdentifier
                                      onDevice:(NSString *)deviceID;

/**
 * 任务完成通知回调
 * @param taskId 任务ID
 * @param completion 完成回调
 */
- (void)notifyWhenTaskCompletes:(NSString *)taskId
                     completion:(void(^)(TaskInfo *task, BOOL success))completion;

/**
 * 取消设备的所有任务
 * @param deviceID 设备ID
 * @param reason 取消原因
 * @return 取消的任务数量
 */
- (NSInteger)cancelAllTasksForDevice:(NSString *)deviceID reason:(NSString * _Nullable)reason;

/**
 * 取消来源的所有任务
 * @param sourceName 来源名称
 * @param reason 取消原因
 * @return 取消的任务数量
 */
- (NSInteger)cancelAllTasksForSource:(NSString *)sourceName reason:(NSString * _Nullable)reason;

/**
 * 清理超时任务
 * @return 清理的任务数量
 */
- (NSInteger)cleanupTimedOutTasks;

#pragma mark - 💿 持久化和配置

/**
 * 保存状态到磁盘
 */
- (void)saveStatesToDisk;

/**
 * 从磁盘加载状态
 */
- (void)loadStatesFromDisk;

/**
 * 清除所有状态
 */
- (void)clearAllStates;

#pragma mark - 📈 调试和统计

/**
 * 打印详细状态
 */
- (void)printDetailedStatus;

/**
 * 获取性能统计
 * @return 统计信息字典
 */
- (NSDictionary *)getPerformanceStatistics;

/**
 * 启用/禁用调试模式
 * @param enabled 是否启用
 */
- (void)setDebugMode:(BOOL)enabled;

#pragma mark - 🔧 便捷方法

/**
 * 生成唯一任务ID
 * @param operationIdentifier 操作标识符
 * @param deviceID 设备ID
 * @return 唯一任务ID
 */
- (NSString *)generateTaskID:(NSString *)operationIdentifier forDevice:(NSString *)deviceID;

/**
 * 获取操作的显示名称（从 TaskBridge 配置获取）
 * @param operationIdentifier 操作标识符
 * @return 显示名称
 */
- (NSString *)getDisplayNameForOperation:(NSString *)operationIdentifier;

/**
 * 检查操作是否需要设备锁定
 * @param operationIdentifier 操作标识符
 * @return 是否需要锁定
 */
- (BOOL)operationRequiresDeviceLock:(NSString *)operationIdentifier;

@end

NS_ASSUME_NONNULL_END
