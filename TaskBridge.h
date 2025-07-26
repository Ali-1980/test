//
//  TaskBridge.h
//  MFCTOOL
//
//  Created by Monterey on 26/1/2025.
//  任务桥梁 - 解决视图控制器与任务管理器的职责边界问题
//  视图控制器只需调用简单的桥梁函数，无需了解复杂的任务管理逻辑
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - 回调定义

// 任务执行结果回调
typedef void(^TaskExecutionCompletion)(BOOL success, NSString * _Nullable errorMessage, NSDictionary * _Nullable resultInfo);

// 任务进度回调
typedef void(^TaskProgressCallback)(double progress, NSString * _Nullable statusMessage);

// 任务冲突处理回调
typedef void(^TaskConflictHandler)(NSString *conflictMessage, NSArray<NSString *> *suggestions, void(^resolver)(BOOL shouldContinue));

#pragma mark - 任务执行选项

@interface TaskExecutionOptions : NSObject

@property (nonatomic, assign) BOOL allowConcurrency;        // 是否允许并发
@property (nonatomic, assign) BOOL allowViewSwitch;         // 是否允许切换视图
@property (nonatomic, assign) BOOL showProgressUI;          // 是否显示进度界面
@property (nonatomic, assign) BOOL autoHandleConflicts;     // 是否自动处理冲突
@property (nonatomic, assign) NSTimeInterval timeout;       // 超时时间
@property (nonatomic, strong) NSDictionary *customData;     // 自定义数据

+ (instancetype)defaultOptions;
+ (instancetype)exclusiveTaskOptions;    // 排他性任务选项
+ (instancetype)concurrentTaskOptions;   // 并发任务选项

@end

#pragma mark - 任务桥梁主类

@interface TaskBridge : NSObject

+ (instancetype)sharedBridge;

#pragma mark - 核心桥梁方法（视图控制器调用这些方法）

/**
 * 执行任务的核心桥梁方法
 * @param operationName 操作名称（如：@"firmware_restore", @"backup_create"）
 * @param deviceID 设备ID
 * @param sourceName 来源控制器名称（如：@"FlasherController"）
 * @param parameters 操作参数
 * @param options 执行选项
 * @param progressCallback 进度回调
 * @param completion 完成回调
 * @return 任务ID，失败返回nil
 */
- (NSString * _Nullable)executeTask:(NSString *)operationName
                           onDevice:(NSString *)deviceID
                         fromSource:(NSString *)sourceName
                     withParameters:(NSDictionary * _Nullable)parameters
                            options:(TaskExecutionOptions * _Nullable)options
                     progressCallback:(TaskProgressCallback _Nullable)progressCallback
                         completion:(TaskExecutionCompletion)completion;

/**
 * 便捷方法：执行简单任务（使用默认选项）
 */
- (NSString * _Nullable)simpleExecuteTask:(NSString *)operationName
                                 onDevice:(NSString *)deviceID
                               fromSource:(NSString *)sourceName
                               completion:(TaskExecutionCompletion)completion;

/**
 * 便捷方法：执行排他性任务
 */
- (NSString * _Nullable)executeExclusiveTask:(NSString *)operationName
                                    onDevice:(NSString *)deviceID
                                  fromSource:(NSString *)sourceName
                              withParameters:(NSDictionary * _Nullable)parameters
                                  completion:(TaskExecutionCompletion)completion;

#pragma mark - 任务状态查询

/**
 * 检查是否可以执行操作（预检查）
 * @param operationName 操作名称
 * @param deviceID 设备ID
 * @param sourceName 来源名称
 * @return 检查结果字典，包含可否执行、冲突信息等
 */
- (NSDictionary *)preCheckOperation:(NSString *)operationName
                           onDevice:(NSString *)deviceID
                         fromSource:(NSString *)sourceName;

/**
 * 获取设备当前任务状态
 */
- (NSDictionary *)getDeviceTaskStatus:(NSString *)deviceID;

/**
 * 获取源的活跃任务
 */
- (NSArray<NSDictionary *> *)getActiveTasksForSource:(NSString *)sourceName;

#pragma mark - 任务控制

/**
 * 取消任务
 */
- (BOOL)cancelTask:(NSString *)taskId withReason:(NSString * _Nullable)reason;

/**
 * 强制停止设备的所有任务
 */
- (NSInteger)forceStopAllTasksForDevice:(NSString *)deviceID fromSource:(NSString *)sourceName;

#pragma mark - 视图切换检查

/**
 * 检查是否可以切换到指定视图
 * @param targetView 目标视图名称
 * @param currentSource 当前来源
 * @return 检查结果字典
 */
- (NSDictionary *)checkViewSwitchPermission:(NSString *)targetView
                               fromSource:(NSString *)currentSource;

#pragma mark - 操作配置管理

/**
 * 注册操作配置（在应用启动时调用）
 * @param operationName 操作名称
 * @param config 操作配置
 */
- (void)registerOperation:(NSString *)operationName withConfig:(NSDictionary *)config;

/**
 * 批量注册操作配置
 */
- (void)registerOperationsFromConfigFile:(NSString *)configFilePath;

#pragma mark - 调试和统计

/**
 * 获取桥梁统计信息
 */
- (NSDictionary *)getBridgeStatistics;

/**
 * 启用调试模式
 */
- (void)setDebugMode:(BOOL)enabled;

/**
 * 打印当前状态
 */
- (void)printBridgeStatus;

@end

NS_ASSUME_NONNULL_END
