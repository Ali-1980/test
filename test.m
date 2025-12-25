//
//  DiagController.m
//
//  Created by Monterey on 19/1/2025.
//

#import "DiagController.h"
#import "DeviceManager.h" // 引入设备管理模块
#import "DatalogsSettings.h"//日志保存路径全局
#import "LanguageManager.h" //语言
#import "DataBaseManager.h" //数据储存管理
#import "AlertWindowController.h" //引入提示消息弹窗
#import "CurrentHistoryController.h" //历史操作记录
#import "DeviceDataManager.h" //更新数据库数据
#import "CustomTableRowView.h" //表格高亮部分
#import "DeviceDatabaseController.h"
#import "SidebarViewController.h"
#import "DeviceBackupRestore.h"
#import "BackupTask.h"
#import "LogUtility.h" // 自定义日志函数LogWithTimestamp，自动添加时间戳
#import "LogManager.h" //全局日志区域
#import <CommonCrypto/CommonCrypto.h>
#import <CommonCrypto/CommonKeyDerivation.h>
#import <objc/runtime.h> // 用于关联对象
#import "UserManager.h" //登录
#import <recore_helpers.h>
#import "GasterRunner.h"
#import "GlobalLockController.h"  // 全局设备锁定
#import "GlobalTaskBridge.h"      // 当前任务注册
#import "FlasherTabsController.h"

#import <libimfccore/libimfccore.h>
#include <libimfccore/mobilebackup2.h>
#import <libimfccore/installation_proxy.h>
#import <libimfccore/notification_proxy.h>

#import <libimfccore/lockdown.h>         // 引入 lockdown 服务头文件
#import <plist/plist.h>
#import <libimfccore/afc.h>
#import <Cocoa/Cocoa.h>
#import <arpa/inet.h>
#import <sys/stat.h>
#import <sys/types.h>
#import <fcntl.h>
#import <unistd.h>

#import <IOKit/IOKitLib.h>
#import <IOKit/serial/IOSerialKeys.h>
#import <IOKit/usb/USB.h>          // kUSBSerialNumberString
#import <IOKit/IOBSD.h>            // kIOCalloutDeviceKey

#import <termios.h>
#import <errno.h>


static void diag_log_callback(void *user, const char *msg) {
    if (!msg) return;
    DiagController *ctrl = (__bridge DiagController *)user;
    NSString *log = [NSString stringWithUTF8String:msg];
    dispatch_async(dispatch_get_main_queue(), ^{
        [ctrl showLogsWithMessage:log];  // ✅ 现在这个方法在头文件中声明了
    });
}

static void diag_progress_callback(void *user, double percent) {
    DiagController *ctrl = (__bridge DiagController *)user;

    // 只在“Diag流程 + Step5 + 正在发送Diags”时，才允许标记到100%
    BOOL isDiagStage =
        (ctrl.isDiagFlowRunning &&
         ctrl.currentFlowStep == 5 &&
         ctrl.isSendingDiags);

    // 防止 percent 略大于 100 或负数导致 UI 异常
    double safePercent = percent;
    if (safePercent < 0) safePercent = 0;
    if (safePercent > 100) safePercent = 100;

    if (isDiagStage && safePercent >= 99.9) {
        ctrl.diagSendReached100 = YES;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        [ctrl updateProgress:safePercent];
    });
}

static void diag_error_callback(void *user, int code, const char *msg) {
    DiagController *ctrl = (__bridge DiagController *)user;
    NSString *m = msg ? [NSString stringWithUTF8String:msg] : @"Unknown";

    // ✅ 更稳：Step5 发送 Diags 到 100% 后，-6 基本就是尾段断开导致的“非致命”
    BOOL isExpectedTailDisconnect =
        (ctrl.isDiagFlowRunning &&
         ctrl.currentFlowStep == 5 &&
         ctrl.diagSendReached100 &&
         code == -6);

    if (isExpectedTailDisconnect) {
        NSString *war = [NSString stringWithFormat:@"[WAR] %d: %s (expected disconnect after diag reached 100%%)", code, msg ?: "Unknown"];
        dispatch_async(dispatch_get_main_queue(), ^{
            [ctrl showLogsWithMessage:war];
        });
        return;
    }

    NSString *err = [NSString stringWithFormat:@"[ER] %d: %s", code, msg ?: "Unknown"];
    dispatch_async(dispatch_get_main_queue(), ^{
        [ctrl showLogsWithMessage:err];
    });
}




@interface DiagController () <NSTextViewDelegate>
{
    NSScrollView *_consoleScrollView;
    NSTextView   *_consoleTextView;
}
@end



@interface DiagController ()

//父容器控制器引用
@property (nonatomic, weak) FlasherTabsController *parentTabsController;
// Gaster
@property(nonatomic, strong) GasterTaskToken *currentToken;

// recore_helpers 上下文
@property (nonatomic, assign) irecv_client_t recoreClient;
// SysCFG 备份恢复
@property (nonatomic, assign) BOOL syscfgBackupInProgress;
@property (nonatomic, assign) BOOL syscfgNandsizeInProgress;
@property (nonatomic, strong) NSMutableArray *syscfgBackupData;

@end

@implementation DiagController

#pragma mark - 初始化
- (void)viewDidLoad {
    [super viewDidLoad];
    NSLog(@"DiagController: viewDidLoad");
    
    // 获取父容器控制器引用
    [self setupParentTabsController];
    
    // 初始化 NSPopUpButton
    [self populateDevicePopUpButton];
    
    // 填充 Diags CDC Serial 串口列表
    [self populateSerialPortPopUpButton];
    
    self.serialFD = -1;
    self.serialQueue = dispatch_queue_create("diag.serial.queue", DISPATCH_QUEUE_SERIAL);
    self.serialLineBuffer = [NSMutableData data];
    
    
    self.syscfgStream = [NSMutableString string];
    self.syscfgValues = [NSMutableDictionary dictionary];
    self.syscfgListening = NO;
    
    // ✅ 初始化备份恢复相关属性
    self.syscfgBackupInProgress = NO;
    self.syscfgNandsizeInProgress = NO;
    self.syscfgBackupData = [NSMutableArray array];

    // 先默认新设备（你也可以做成 UI 选项或自动判断）
    self.syscfgSuffix = @"\n[";
    self.pendingSyscfgKeys = [NSMutableArray array];
    self.currentSyscfgKey = nil;

    
    // 设置进度条
    [self.progressBar setMinValue:0.0];
    [self.progressBar setMaxValue:100.0];
    [self.progressBar setDoubleValue:0.0];
    
    // 设置文本视图
     self.collectedLogs = [[NSMutableString alloc] init]; // 初始化日志缓存
    
    // ✅ 初始化BootChian路径
    [self setupBootChianPaths];

    // ✅ 加载设备映射配置
    [self loadDeviceMapFromPlist];
    
    // 默认显示 SysCFG，隐藏 Console
    self.syscfgContentView.hidden = NO;
    self.consoleContentView.hidden = YES;
    self.toolsContentView.hidden = YES;

    // ✅ 初始化窗口
    [self setupSysCFGUI]; // 初始化 SysCFG UI
    [self setupConsoleUI]; // 初始化 Console UI
    [self setupToolUI]; // 初始化 Tools UI

    // 刷新父视图
    [self.view setNeedsDisplay:YES];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onDeviceDisconnectWithContext:)
                                                 name:DeviceManagerDidDisconnectWithContextNotification
                                               object:nil];
    
    // ✅ 监听文本编辑开始（输入框获得焦点）
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onTextFieldDidBeginEditing:)
                                                 name:NSTextDidBeginEditingNotification
                                               object:nil];
    
    // ✅ 监听文本编辑结束（输入框失去焦点）
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onTextFieldDidEndEditing:)
                                                 name:NSTextDidEndEditingNotification
                                               object:nil];
    

    
    
    NSLog(@"DiagController: 控件已初始化");
}


#pragma mark - 生命周期方法
- (void)viewWillAppear {
    [super viewWillAppear];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        NSWindow *win = self.view.window;
        if (win) win.identifier = @"DiagControllerWindow";
    });
    
    [self setupDedicatedDeviceLogChannel];
        
    if (self.deviceLogChannel) {
        NSScrollView *chScroll = nil;
        @try {
            chScroll = self.deviceLogChannel.logScrollView;
        } @catch (NSException *ex) {
            chScroll = nil;
        }
        
        if (chScroll) {
            // ✅ 先移除
            [chScroll removeFromSuperview];
            
            // ✅ 使用 Auto Layout
            chScroll.translatesAutoresizingMaskIntoConstraints = NO;
            [self.view addSubview:chScroll positioned:NSWindowBelow relativeTo:nil];
            
            // ✅ 完全自适应约束：
            // - 左边贴合父视图
            // - 右边留出188空间给按钮区域（自适应宽度）
            // - 顶部距离父视图顶部400（给上面的控件留空间）
            // - 底部距离父视图底部-4（自适应高度）
            [NSLayoutConstraint activateConstraints:@[
                // 左右约束（宽度自适应）
                [chScroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
                [chScroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-188],
                
                // 上下约束（高度自适应）
                [chScroll.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:415],
                [chScroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:4]
            ]];
            
            NSLog(@"[DiagController] 使用 Auto Layout 添加日志区域（完全自适应）");
        }
        
        if ([self.deviceLogChannel respondsToSelector:@selector(flushPendingLogs)]) {
            [self.deviceLogChannel flushPendingLogs];
        }
    }
    
    // ✅ 验证
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self.deviceLogChannel && self.deviceLogChannel.logScrollView) {
            NSScrollView *chScroll = self.deviceLogChannel.logScrollView;
            NSLog(@"[DiagController] 验证 - 父视图: %.0f x %.0f, 日志区域: %.0f x %.0f",
                  NSWidth(self.view.frame), NSHeight(self.view.frame),
                  NSWidth(chScroll.frame), NSHeight(chScroll.frame));
        }
    });
}

- (void)viewDidAppear {
    [super viewDidAppear];
    if (self.deviceLogChannel) {
          [self.deviceLogChannel flushPendingLogs];
          NSLog(@"[DiagController] Tab 已显示 刷新待处理日志");
    }
}


- (void)viewWillDisappear {
    [super viewWillDisappear];
    
    // ✅ 清理 recore 资源
    if (self.recoreClient) {
        recore_close(self.recoreClient);
        self.recoreClient = NULL;
    }
}


#pragma mark - 设置设备专属日志通道
- (void)setupDedicatedDeviceLogChannel {
    // 如果已经有通道且标识仍然匹配，直接返回
    if (self.deviceLogChannel && self.logChannelIdentifier) {
        return;
    }

    // 统一一个可读的标识（仅做调试用途）
    self.logChannelIdentifier = [NSString stringWithFormat:@"diag_device"];

    // 通过 LogManager 获取（或创建）设备专属的 LogChannel（由 LogManager 负责缓存）
    LogChannel *channel = [[LogManager sharedManager] logChannelForDevice:@"diag_device"];
    if (!channel) {
        NSLog(@"[DiagController] 无法从 LogManager 获取 deviceLogChannel");
        return;
    }

    self.deviceLogChannel = channel;
    

    // 绑定通道到当前视图（如果还没绑定）
    @try {
        // 如果 channel 已经在其它 superview 中并且当前 session 需要可见性，
        // attachToViewController: 内部会先 removeFromSuperview 再 addSubview（LogChannel 有这个保护）。
        [self.deviceLogChannel attachToViewController:self];
    } @catch (NSException *ex) {
        NSLog(@"[DiagController] attachToViewController 异常: %@", ex);
    }

    // 立即刷新/滚动（如果有 pending）
    if ([self.deviceLogChannel respondsToSelector:@selector(flushPendingLogs)]) {
        @try {
            [self.deviceLogChannel flushPendingLogs];
        } @catch (NSException *ex) {
            NSLog(@"[DiagController] flushPendingLogs 异常: %@", ex);
        }
    }

    NSLog(@"[DiagController] 已初始化/绑定设备日志通道");
}


#pragma mark - 监听USB变化

- (void)onDeviceDisconnectWithContext0000:(NSNotification *)note {
    NSDictionary *ui = note.userInfo ?: @{};
    NSString *deviceID = ui[DeviceManagerDisconnectDeviceIDKey];
    BOOL hasDiagTask = [ui[DeviceManagerDisconnectHasDiagTaskKey] boolValue];

    // ✅ 只在“Diag流程运行中 + Step5 + 且任务系统显示 DiagController 活跃”时标记
    if (hasDiagTask && self.isDiagFlowRunning && self.currentFlowStep == 5) {
        self.sawDisconnectAfterDiagSend = YES;

        // 可选：打一个 debug log，方便对照你现在的 “设备断开: ECID=...”
        NSLog(@"[DiagController] ✅ sawDisconnectAfterDiagSend = YES (deviceID=%@)", deviceID ?: @"");
    }
}

- (void)onDeviceDisconnectWithContext:(NSNotification *)note {
    NSDictionary *ui = note.userInfo ?: @{};
    NSString *deviceID = ui[DeviceManagerDisconnectDeviceIDKey];

    // 原来依赖 hasDiagTask，这里改为：Step5 期间断开就标记
    if (self.isDiagFlowRunning && self.currentFlowStep == 5) {
        self.sawDisconnectAfterDiagSend = YES;
        NSLog(@"[DiagController] ✅ sawDisconnectAfterDiagSend = YES (Step5 disconnect, deviceID=%@)", deviceID ?: @"");
    }
}


#pragma mark - 填充 NSPopUpButton 表头当前连接的设备列表
- (void)populateDevicePopUpButton {
    NSLog(@"[DiagController DEBUG] 开始执行 populateDevicePopUpButton 方法");
    
    NSLog(@"[DiagController DEBUG] FlasherTabsController 的 deviceUDID: %@, deviceECID: %@", self.deviceUDID, self.deviceECID);
    
    NSDictionary *allDevicesData = [[DeviceManager sharedManager] getCurrentConnectedDevicesFromHistorylistSqlite];
    if (!allDevicesData) {
        NSLog(@"DiagController [ERROR] 无法提取设备信息，因为 Plist 文件读取失败。");
        return;
    }
    
    // 清空当前的菜单项
    NSLog(@"[DiagController DEBUG] 清空当前的菜单项");
    [self.devicePopUpButton removeAllItems];
    
    // 添加一个默认的选项
    NSString *pleaseSelectDeviceTitle = [[LanguageManager sharedManager] localizedStringForKeys:@"PleaseSelectDeviceTitle" inModule:@"Flasher" defaultValue:@"Please Select Device"];
    [self.devicePopUpButton addItemWithTitle:pleaseSelectDeviceTitle];
    
    BOOL hasAvailableDevices = NO;
    
    // 确保 NSPopUpButton 已布局完成，以获取正确的宽度
    [self.devicePopUpButton layoutSubtreeIfNeeded];
    
    // 获取 NSPopUpButton 的宽度
    CGFloat popupWidth = self.devicePopUpButton.bounds.size.width;
    
    // 设定制表符在宽度的85%，留出15%的边距
    CGFloat tabLocation = popupWidth * 0.90;
    
    // 创建段落样式并设置制表符位置
    NSMutableParagraphStyle *paragraphStyle = [[NSMutableParagraphStyle alloc] init];
    NSTextTab *rightTab = [[NSTextTab alloc] initWithType:NSRightTabStopType location:tabLocation];
    [paragraphStyle setTabStops:@[rightTab]];
    [paragraphStyle setDefaultTabInterval:tabLocation];
    
    // 设置字体大小
    CGFloat fontSize = 12.0;
    
    // 遍历所有设备数据
    NSLog(@"[DiagController DEBUG] 遍历所有设备数据");
    for (NSString *key in allDevicesData) {
        NSDictionary *device = allDevicesData[key];
        
        // 获取设备连接状态和模式
        BOOL isConnected = [device[@"IsConnected"] boolValue];
        NSString *deviceMode = device[@"Mode"];
        
        // 排除未连接的设备或模式为 "-" 的设备
        if (!isConnected || [deviceMode isEqualToString:@"-"]) {
            NSLog(@"[INFO] 排除设备 - OfficialName: %@, IsConnected: %@, Mode: %@",
                  device[@"OfficialName"] ?: @"Unknown Name",
                  isConnected ? @"YES" : @"NO",
                  deviceMode ?: @"Unknown Mode");
            continue; // 跳过当前循环，处理下一个设备
        }
        
        NSString *officialName = device[@"OfficialName"] ?: @"Unknown Name";
        NSString *udid = device[@"UDID"];
        NSString *ecid = device[@"ECID"] ?: @"Unknown ECID";
        NSString *type = device[@"TYPE"];
        NSString *deviceVersion = device[@"VERSION"];
        NSString *deviceSerialNumber = device[@"SerialNumber"];
        
        NSString *idString;
        NSString *uniqueKey;
        
        if (udid && udid.length > 0) {
            idString = [NSString stringWithFormat:@"UDID: %@", [udid stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]];
            uniqueKey = udid;
        } else if (ecid && ecid.length > 0) {
            idString = [NSString stringWithFormat:@"ECID: %@", [ecid stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]];
            uniqueKey = ecid;
        } else {
            idString = @"Unknown ID";
            uniqueKey = key; // 使用 plist 中的 key 作为备用
        }
        
        // 获取本地化后的 mode
        NSString *localizedMode = [self getLocalizedDeviceModeForDevice:device];
        
        // 使用制表符分隔左侧和右侧内容，使用本地化后的 mode
        // 结构: 左侧信息 \t 右侧信息
        NSString *rawString = [NSString stringWithFormat:@"  %@  -  %@ \t  %@", localizedMode, officialName, type];
        
        // 创建属性字符串
        NSDictionary *attributes = @{
            NSParagraphStyleAttributeName: paragraphStyle,
            NSFontAttributeName: [NSFont systemFontOfSize:fontSize]
        };
        NSAttributedString *attrTitle = [[NSAttributedString alloc] initWithString:rawString attributes:attributes];
        
        // 创建 NSMenuItem 并设置 attributedTitle
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:rawString action:nil keyEquivalent:@""];
        item.attributedTitle = attrTitle;
        item.representedObject = uniqueKey;
        
        // 检查当前设备是否为选中设备
        BOOL isSelected = ([uniqueKey isEqualToString:self.deviceUDID] || [uniqueKey isEqualToString:self.deviceECID]);
        if (isSelected) {
            [self.devicePopUpButton selectItem:item];
            self.currentDeviceType = type; // 设置当前 deviceType
            self.currentDeviceMode = deviceMode;
            self.currentDeviceVersion = deviceVersion;
            self.currentDeviceSerialNumber = deviceSerialNumber;
            
            NSLog(@"DiagController [DEBUG] 已选中设备信息: %@  Type: %@  Mode: %@ Ver: %@  ECID: %@ SNR: %@",self.deviceOfficialName, self.currentDeviceType, self.currentDeviceMode, self.currentDeviceVersion, self.currentDeviceECID, self.currentDeviceSerialNumber);
                          
            [self lockDeviceWithInfo:uniqueKey officialName:self.deviceOfficialName type:self.currentDeviceType mode:self.currentDeviceMode version:self.currentDeviceVersion ecid:self.currentDeviceECID snr:self.currentDeviceSerialNumber];
            NSLog(@"DiagController [DEBUG] 已选中设备并锁定: %@  Type: %@  Mode: %@  Ver: %@ ECID: %@ SNR: %@",self.deviceOfficialName, self.currentDeviceType, self.currentDeviceMode, self.currentDeviceVersion, self.currentDeviceECID, self.currentDeviceSerialNumber);
   
        }
        
        // 添加到 NSPopUpButton
        [self.devicePopUpButton.menu addItem:item];
        
        hasAvailableDevices = YES;
    }
    
    // 如果没有可用设备，显示提示信息
    if (!hasAvailableDevices) {
        NSString *pleaseConnectDeviceTitle = [[LanguageManager sharedManager] localizedStringForKeys:@"PleaseConnectDeviceTitle" inModule:@"Flasher" defaultValue:@"Please Connect Device"];
        [self.devicePopUpButton addItemWithTitle:pleaseConnectDeviceTitle];
    }
    
    
    // 自动选中对应的设备项（根据 deviceUDID 或 deviceECID）
    [self AutoSelectDeviceInPopUpButton];
    
    NSLog(@"[DEBUG] DiagController 方法执行完成");
}

#pragma mark -  获取当前设备的模式，并返回本地化后的字符串
- (NSString *)getLocalizedDeviceModeForDevice:(NSDictionary *)device {
    LanguageManager *languageManager = [LanguageManager sharedManager];
    
    // 定义设备模式到本地化键的映射
    NSDictionary<NSString *, NSString *> *modeLocalizationKeys = @{
        @"Normal" : @"isNormalModeTitle",
        @"Recovery" : @"isRecoveryModeTitle",
        @"DFU" : @"isDFUModeTitle",
        @"WiFi" : @"isWiFiModeTitle",
        @"WTF" : @"isWTFModeTitle"
    };
    
    // 获取设备的原始模式
    NSString *originalMode = device[@"Mode"];
    
    // 获取对应的本地化键
    NSString *localizationKey = modeLocalizationKeys[originalMode];
    
    // 如果找到对应的本地化键，则进行本地化
    if (localizationKey) {
        NSString *localizedMode = [languageManager localizedStringForKeys:localizationKey inModule:@"DeviceModes" defaultValue:originalMode];
        
        // 检查本地化是否成功（即 localizedMode 不等于 defaultValue）
        if ([localizedMode isEqualToString:originalMode]) {
            NSLog(@"[DEBUG] 模式相同，无须进行本地化. 本地化模式: %@，使用设备原始模式: %@", localizedMode, originalMode);
        }
        
        return localizedMode;
    } else {
        // 如果没有找到对应的本地化键，返回原始模式并记录日志
        NSLog(@"[DEBUG] 未知模式，本地化失败，使用设备原始模式: %@", originalMode);
        return originalMode;
    }
}


#pragma mark - 手动选择后获取当前选择的设备信息
- (IBAction)devicePopUpButtonChanged:(id)sender {
    // 获取当前选中的 NSMenuItem
    NSMenuItem *selectedItem = [self.devicePopUpButton selectedItem];
    
    // 从 selectedItem 中获取对应的设备唯一标识符
    NSString *selectedDeviceID = selectedItem.representedObject;
    
    // 通过唯一标识符找到设备的详细信息（比如从缓存的数据中查找）
    NSDictionary *selectedDeviceInfo = [self getDeviceInfoByID:selectedDeviceID];
    
    // 打印设备信息或执行相关操作
    NSLog(@"[INFO] 手动选中设备的详细信息：%@ 选中的ID %@ ", selectedDeviceInfo, selectedDeviceID);
    
    NSString *deviceOfficialName = selectedDeviceInfo[@"OfficialName"] ?: @"Unknown Name";
    NSString *deviceUDID = selectedDeviceInfo[@"UDID"];
    NSString *deviceECID = selectedDeviceInfo[@"ECID"] ?: @"Unknown ECID";
    NSString *deviceTYPE = selectedDeviceInfo[@"TYPE"];
    NSString *devicePairStatus = selectedDeviceInfo[@"IsPair"];
    //NSString *deviceModel = selectedDeviceInfo[@"MODEL"];
    NSString *deviceMode = selectedDeviceInfo[@"Mode"];
    NSString *deviceVersion = selectedDeviceInfo[@"VERSION"];
    NSString *deviceSerialNumber = selectedDeviceInfo[@"SerialNumber"] ?: @"";
    
    NSLog(@"[INFO] 手动选中设备的名称：%@ 模式：%@ 类型：%@ 匹配：%@ 版本：%@", deviceOfficialName, deviceMode, deviceTYPE, devicePairStatus, deviceVersion);
    
    NSString *idString;
    NSString *uniqueKey;
    
    if (deviceUDID && deviceUDID.length > 0) {
        idString = [NSString stringWithFormat:@"UDID: %@", [deviceUDID stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]];
        uniqueKey = deviceUDID;
    } else if (deviceECID && deviceECID.length > 0) {
        idString = [NSString stringWithFormat:@"ECID: %@", [deviceECID stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]];
        uniqueKey = deviceECID;
    } else {
        idString = @"Unknown ID";
        uniqueKey = selectedDeviceID; // 使用 plist 中的 key 作为备用
    }
    
    
    if (deviceTYPE) {
        // 更新当前设备的 deviceType
        self.currentDeviceType = deviceTYPE;
        NSLog(@"DiagController devicePopUpButtonChanged 当前设备的 deviceType: %@", self.currentDeviceType);

        // 锁定并持久化设备信息
        [self lockDeviceWithInfo:uniqueKey officialName:deviceOfficialName type:deviceTYPE mode:deviceMode version:deviceVersion ecid:deviceECID snr:deviceSerialNumber];
                
        // 示例操作：显示设备信息
        NSString *logdeviceOfficialName = [[LanguageManager sharedManager] localizedStringForKeys:@"CurrentDeviceSwitchedto" inModule:@"Flasher" defaultValue:@"The device has been switched to: %@, %@\n"];
        
        // 在 logdeviceOfficialName 前面追加 [warning]
        logdeviceOfficialName = [NSString stringWithFormat:@"[WAR] %@", logdeviceOfficialName];
        
        NSString *choosedDeviceMessage = [NSString stringWithFormat:logdeviceOfficialName, deviceOfficialName, deviceTYPE];
        
        [self showLogsWithMessage:choosedDeviceMessage];//设备切换日志
        
    } else {
        NSLog(@"[ERROR] 无法根据 uniqueKey 获取设备信息: %@", uniqueKey);
    }
    
    //判断按钮显示状态
    NSLog(@"手动选择后当前设备模式: %@", deviceMode);
    
    //是否是Watch
    if ([deviceTYPE.lowercaseString containsString:@"watch"]) {
        LanguageManager *languageManager = [LanguageManager sharedManager];
        // 当前选择的设备不支持应用管理
        NSString *logsNotSupportBackupsManagementMessage = [languageManager localizedStringForKeys:@"backupsManageNotSupport" inModule:@"BackupManager" defaultValue:@"[WAR]The currently selected device does not support backups management"];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            [[AlertWindowController sharedController] showResultMessageOnly:logsNotSupportBackupsManagementMessage inWindow:self.view.window];
        });
        return;
    }
    
    //判断当前模式
    if (![deviceMode isEqualToString:@"Normal"]) {
        LanguageManager *languageManager = [LanguageManager sharedManager];
        // 当前选择的设备需要处于正常模式
        NSString *logeraseModeErrorsMessage = [languageManager localizedStringForKeys:@"nonNormalModeErrorsMessage" inModule:@"GlobaMessages" defaultValue:@"[WAR] This operation can only be performed when the device is in normal mode\n"];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            [[AlertWindowController sharedController] showResultMessageOnly:logeraseModeErrorsMessage inWindow:self.view.window];
        });
        return;
    }
    
    //检测设备匹配状态
    BOOL isPaired = [[DeviceManager sharedManager] triggerPairStatusForDeviceWithUDID:selectedDeviceID];
    if (!isPaired) {
        NSString *logerasePairErrorsMessage = [[LanguageManager sharedManager] localizedStringForKeys:@"pairErrorsMessage"
                                                                                                     inModule:@"GlobaMessages"
                                                                                                defaultValue:@"[WAR] Only paired devices can operate this function\n"];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            [[AlertWindowController sharedController] showResultMessageOnly:logerasePairErrorsMessage inWindow:self.view.window];
        });
        
        return;
    }
    // 直接更新UI，使用现有设备
    dispatch_async(dispatch_get_main_queue(), ^{
        [self selectAndRequestDeviceLock];
    });
}

/**
 * 选择设备并请求父控制器锁定
 */
- (void)selectAndRequestDeviceLock {
    NSDictionary *devicesData = [[DeviceManager sharedManager] getCurrentConnectedDevicesFromHistorylistSqlite];
    
    if (!devicesData || devicesData.count == 0) {
        NSLog(@"[DeviceBackupRestore] ❌ 没有可用设备");
        return;
    }
    
    // 选择第一个可用设备
    for (NSString *key in devicesData) {
        NSDictionary *device = devicesData[key];
        if (![device[@"IsConnected"] boolValue]) continue;
        NSString *udid = device[@"UDID"];
        NSString *ecid = device[@"ECID"];
        NSString *deviceID = (udid && udid.length > 0) ? udid : ecid;
        if (!deviceID || deviceID.length == 0) continue;
        NSLog(@"[DiagController] 🎯 请求锁定设备: %@", device[@"OfficialName"]);
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            //
        });
    }
}


- (NSDictionary *)getDeviceInfoByID:(NSString *)deviceID {
    // 示例：从当前已加载的设备列表中找到设备详情
    NSDictionary *allDevicesData = [[DeviceManager sharedManager] getCurrentConnectedDevicesFromHistorylistSqlite];
    return allDevicesData[deviceID];
}

#pragma mark -锁定设备并持久化设备信息 同步更新

- (void)lockDeviceWithInfo:(NSString *)uniqueKey
             officialName:(NSString *)officialName
                     type:(NSString *)type
                     mode:(NSString *)mode
                  version:(NSString *)deviceVersion
                     ecid:(NSString *)deviceECID
                      snr:(NSString *)deviceSerialNumber {
    
    NSLog(@"[DiagController] 🔄 开始使用新的GlobalLockController锁定设备");
    NSLog(@"[DiagController] 设备信息 - uniqueKey: %@, officialName: %@, type: %@, mode: %@", uniqueKey, officialName, type, mode);

    self.deviceType = type;
    //self.password = password;
    
    // 🔥 创建包含完整信息的 DeviceLockInfo 对象
    DeviceLockInfo *deviceInfo = [DeviceLockInfo deviceWithID:uniqueKey
                                                          name:officialName ?: @"Unknown"
                                                          type:type ?: @""
                                                          mode:mode ?: @""
                                                       version:deviceVersion ?: @""
                                                          ecid:deviceECID ?: @""
                                                  serialNumber:deviceSerialNumber ?: @""];
    
    NSError *lockError = nil;
    LockResult result = [[GlobalLockController sharedController]
                        lockDevice:deviceInfo
                        sourceName:@"DiagController"
                        allowsSharedLocking:YES
                             error:&lockError];
    
    NSString *unrecognizedDeviceInformationMessage = [[LanguageManager sharedManager] localizedStringForKeys:@"unrecognizedDeviceInformation" inModule:@"GlobalTasks" defaultValue:@"Unrecognized device information"];
    
    NSString *unknownSystemErrorMessage = [[LanguageManager sharedManager] localizedStringForKeys:@"unknownSystemError" inModule:@"GlobalTasks" defaultValue:@"Unknown system error"];
    
    switch (result) {
        case LockResultSuccess:
            NSLog(@"[DeviceBackupRestore] ✅ 设备锁定成功: %@", officialName);
            
            // 🔥 更新本地缓存属性（保持兼容性）
            self.lockedDeviceID = uniqueKey;
            self.deviceType = type;
            self.deviceMode = mode;
            self.deviceVersion = deviceVersion;
            self.deviceECID = deviceECID;
            self.deviceSerialNumber = deviceSerialNumber;
            
            break;
            
        case LockResultConflict:
            NSLog(@"[DiagController] ⚠️ 设备锁定冲突");
            [self handleFlasherLockConflict:lockError];
            break;
            
        case LockResultInvalidDevice:
            NSLog(@"[DiagController] ❌ 设备信息无效");
            [[AlertWindowController sharedController] showResultMessageOnly:unrecognizedDeviceInformationMessage inWindow:self.view.window];
            break;
            
        case LockResultSystemError:
            NSLog(@"[DiagController] ❌ 系统错误");
            [[AlertWindowController sharedController] showResultMessageOnly:unknownSystemErrorMessage inWindow:self.view.window];
            break;
    }

    // 验证设备信息同步
    NSDictionary *syncedDeviceInfo = [self getLockedDeviceInfo];
    NSLog(@"[INFO] 锁定设备同步信息 - %@", syncedDeviceInfo);
}

- (void)handleFlasherLockConflict:(NSError *)error {
    if (error.code != 1001) {
        NSString *failedLockDeviceMessage = [[LanguageManager sharedManager] localizedStringForKeys:@"failedLockDevice" inModule:@"GlobalTasks" defaultValue:@"[ER]Failed to lock the device"];
        
        [[AlertWindowController sharedController] showResultMessageOnly:failedLockDeviceMessage inWindow:self.view.window];
        return;
    }
    
    NSString *currentOwner = error.userInfo[@"currentOwner"];
    NSString *deviceName = error.userInfo[@"deviceName"];
    NSNumber *activeTaskCount = error.userInfo[@"activeTaskCount"];
    
    NSAlert *alert = [[NSAlert alloc] init];
    
    NSString *usageConflictMessage = [[LanguageManager sharedManager] localizedStringForKeys:@"usageConflict" inModule:@"GlobalTasks" defaultValue:@"Device usage conflict"];
    
    alert.messageText = usageConflictMessage;
    
    NSString *taskInfo = @"";
    if (activeTaskCount && activeTaskCount.integerValue > 0) {
        NSString *runningNTasksMessage = [[LanguageManager sharedManager] localizedStringForKeys:@"runningNTasks" inModule:@"GlobalTasks" defaultValue:@"\nCurrently running %ld tasks"];
        
        taskInfo = [NSString stringWithFormat:runningNTasksMessage, activeTaskCount.integerValue];
    }
    
    NSString *usageConflictDescMessage = [[LanguageManager sharedManager] localizedStringForKeys:@"usageConflictDesc" inModule:@"GlobalTasks" defaultValue:@"Device %@ is currently being used by %@%@\n\n⚠️ This operation requires full control of the device and will forcibly interrupt the current operation!\n\nDo you want to continue?"];
    
    alert.informativeText = [NSString stringWithFormat:usageConflictDescMessage,
        deviceName, currentOwner, taskInfo];
    
    NSString *forceExecutionButton = [[LanguageManager sharedManager] localizedStringForKeys:@"forceExecution" inModule:@"GlobalTasks" defaultValue:@"Force Execution"];
    NSString *CancelButton = [[LanguageManager sharedManager] localizedStringForKeys:@"CancelButton" inModule:@"GlobaButtons" defaultValue:@"Cancel"];
    
    [alert addButtonWithTitle:forceExecutionButton];
    [alert addButtonWithTitle:CancelButton];
}

#pragma mark - 父容器控制器设置

- (void)setupParentTabsController {
    // 向上查找父容器控制器
    NSViewController *parent = self.parentViewController;
    while (parent) {
        if ([parent isKindOfClass:[FlasherTabsController class]]) {
            self.parentTabsController = (FlasherTabsController *)parent;
            NSLog(@"[DiagController] ✅ 找到父容器控制器");
            break;
        }
        parent = parent.parentViewController;
    }
    
    if (!self.parentTabsController) {
        NSLog(@"[DiagController] ⚠️ 未找到 FlasherTabsController 父容器");
    }
}

#pragma mark - 日志操作

// 便捷的日志方法
- (void)addLogMessage:(NSString *)message {
    if (!message || message.length == 0) return;
    
    // 🆕 使用设备专属日志通道
    if (self.deviceLogChannel) {
        [self.deviceLogChannel logWithTimestamp:message];
    } else {
        // 降级处理：如果日志通道还没准备好，尝试创建
        NSLog(@"⚠️ FlasherController: 日志通道未就绪，尝试创建...");
        [self setupDedicatedDeviceLogChannel];
        
        if (self.deviceLogChannel) {
            [self.deviceLogChannel logWithTimestamp:message];
        } else {
            // 最终降级：输出到控制台
            NSLog(@"⚠️ [日志丢失] %@", message);
        }
    }
}

- (void)clearLogs {
    if (self.deviceLogChannel) {
        [self.deviceLogChannel clearLog];
    } else {
        // 降级：清空 LogManager 为当前 view 缓存的日志
        [[LogManager sharedManager] clearLogForViewController:self];
    }
}

#pragma mark - 统一权限管理
- (BOOL)validateForAction {
     UserManager *userManager = [UserManager sharedManager];
    if (!userManager.isUserLoggedIn) {
        
       // self.devicePopUpButton.enabled = NO; //设备选择项目
        
        //NSLog(@"没有登录");
        // 发送通知以触发登录流程
        [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowLoginNotification" object:nil];
        return NO;
    }
    return YES;
}

#pragma mark - 🔧 补充：设备状态验证（可选）

/**
 * 验证设备锁定状态的一致性
 */
- (void)validateDeviceLockState {
    NSString *globalDeviceID = [[GlobalLockController sharedController]
                               getLockedDeviceIDForSource:@"DiagController"];
    
    NSString *currentDeviceID = [self getLockedDeviceID];
    
    if (![globalDeviceID isEqualToString:currentDeviceID]) {
        NSLog(@"[DiagController] ⚠️ 设备锁定状态不一致 - 全局: %@, 本地: %@",
              globalDeviceID, currentDeviceID);
        
        // 同步状态
        self.lockedDeviceID = globalDeviceID;
    }
}


#pragma mark - 从内存获取锁定的设备ID
- (NSString *)getLockedDeviceID {
    return [[GlobalLockController sharedController]
            getLockedDeviceIDForSource:@"DiagController"];
}

#pragma mark - 设备锁定信息存入内存
- (void)setLockedDeviceID:(NSString *)lockedDeviceID {
    if (!lockedDeviceID) {
        [[GlobalLockController sharedController] unlockAllDevicesFromSource:@"DiagController"];
    }
}

#pragma mark - 从内存获取已锁定的设备信息
- (NSDictionary *)getLockedDeviceInfo {
    return [[GlobalLockController sharedController]
            getLockedDeviceInfoForSource:@"DiagController"];
}

/**
 * 检查设备是否被锁定
 */
- (BOOL)isDeviceLocked {
    NSString *deviceID = [self getLockedDeviceID];
    return (deviceID != nil);
}

/**
 * 解锁当前设备
 */
- (BOOL)unlockCurrentDevice {
    NSString *deviceID = [self getLockedDeviceID];
    if (deviceID) {
        return [[GlobalLockController sharedController] unlockDevice:deviceID
                                                          sourceName:@"DiagController"];
    }
    return YES;
}

- (BOOL)hasActiveOperations {
    return self.isWorking;
}

#pragma mark -  辅助方法：根据 deviceUDID 或 deviceECID 自动选中对应的设备项
// 🔧 完全参照FlasherController实现，删除错误的全局锁定检测
- (void)AutoSelectDeviceInPopUpButton {
    NSLog(@"[DiagController] 🔍 执行自动选中对应的设备项");
    
    BOOL found = NO;
    NSString *selectedDeviceID = nil;

    // 在执行操作之前移除 deviceListDidChange 监听
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"DeviceListChangedNotification" object:nil];

    // 🔥 直接获取全局锁定的设备ID
    NSString *globalDeviceID = [[GlobalLockController sharedController] getGlobalLockedDeviceID];
    NSLog(@"[DiagController] ✅ 使用全局锁定设备: %@", globalDeviceID);
    NSDictionary *selectedDeviceInfo = [self getDeviceInfoByID:globalDeviceID];
    
    NSLog(@"[DiagController INFO] 自动选中设备的详细信息：%@ 选中的ID %@ ", selectedDeviceInfo, globalDeviceID);
    
    if (globalDeviceID && globalDeviceID.length > 0) {
        for (NSMenuItem *item in self.devicePopUpButton.menu.itemArray) {
            if ([item.representedObject isEqualToString:globalDeviceID]) {
                [self.devicePopUpButton selectItem:item];
                selectedDeviceID = globalDeviceID; //自动选中的
                found = YES;
                break;
            }
        }
    }
    
    if (found && globalDeviceID) {
        NSLog(@"[DiagController] 🎯 找到匹配设备，selectedDeviceID: %@", globalDeviceID);
        
        // ✅ 修改：通过标准流程锁定设备
        [self lockDeviceWithInfo:globalDeviceID
                   officialName:selectedDeviceInfo[@"OfficialName"] ?: @"Unknown Device"
                           type:selectedDeviceInfo[@"TYPE"] ?: @""
                           mode:selectedDeviceInfo[@"Mode"] ?: @""
                        version:selectedDeviceInfo[@"VERSION"] ?: @""
                           ecid:selectedDeviceInfo[@"ECID"] ?: @""
                            snr:selectedDeviceInfo[@"SerialNumber"] ?: @""];

    }
    
    //判读设备状态/类型/模式
    //是否是Watch
    if ([self.currentDeviceType.lowercaseString containsString:@"watch"]) {
        LanguageManager *languageManager = [LanguageManager sharedManager];
        // 当前选择的设备不支持恢复备份
        NSString *logsNotSupportRestoreBackupMessage = [languageManager localizedStringForKeys:@"restoreBackupNotSupport" inModule:@"BackupManager" defaultValue:@"[WAR] The currently selected device does not support restore backup"];

        dispatch_async(dispatch_get_main_queue(), ^{
            [[AlertWindowController sharedController] showResultMessageOnly:logsNotSupportRestoreBackupMessage inWindow:self.view.window];
        });
        return;
    }

    // 直接更新UI，使用现有设备
    dispatch_async(dispatch_get_main_queue(), ^{
        [self selectAndRequestDeviceLock];
    });
}


- (void)updateProgress:(double)progress {
    NSLog(@"DiagController: 更新进度: %.1f%%", progress);
    [self.progressBar setDoubleValue:progress];
}

- (void)appendLog:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        // 生成时间戳
        NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
        [dateFormatter setDateFormat:@"yyyy-MM-dd HH:mm:ss"];
        NSString *timestamp = [dateFormatter stringFromDate:[NSDate date]];

        // 手动生成带时间戳的日志
        NSString *formattedLog = [NSString stringWithFormat:@"[%@] %@", timestamp, message];

        // 获取日志显示的 NSTextView
        NSTextView *textView = (NSTextView *)self.deviceLogChannel.logScrollView.documentView;
        if (textView) {
            // ✅ 直接调用 AppendLogToTextView 追加日志（仍然是原始 message）
            AppendLogToTextView(textView, message);

            // 自动滚动到底部
            NSRange endRange = NSMakeRange(textView.string.length, 0);
            [textView scrollRangeToVisible:endRange];

            // ✅ 存入 collectedLogs，但加上时间戳，确保最终日志文件有完整格式
            [self.collectedLogs appendFormat:@"%@\n", formattedLog];
        } else {
            NSLog(@"[ERROR] Failed to access NSTextView.");
        }
    });
}


#pragma mark - 刷新日志显示

- (void)showLogsWithMessage:(NSString *)message {
    // 先确保 msg 有值
    NSString *msg = message ?: @"";

    // ✅ 把 Step5 的这个特定错误降级成 warning（仅限当前条件满足）
    if (self.isDiagFlowRunning &&
        self.currentFlowStep == 5 &&
        self.diagSendReached100 &&
        self.sawDisconnectAfterDiagSend &&
        [msg containsString:@"[ER] -6"] &&
        [msg containsString:@"Unable to upload data to device"]) {

        msg = [msg stringByReplacingOccurrencesOfString:@"[ER]" withString:@"[WAR]"];
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        // 生成时间戳
        NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
        [dateFormatter setDateFormat:@"yyyy-MM-dd HH:mm:ss"];
        NSString *timestamp = [dateFormatter stringFromDate:[NSDate date]];

        // 带时间戳的日志（用于存档）
        NSString *formattedLog = [NSString stringWithFormat:@"[%@] %@", timestamp, msg];

        // 获取日志显示的 NSTextView
        NSTextView *textView = (NSTextView *)self.deviceLogChannel.logScrollView.documentView;
        
        if (textView) {
            // ✅ 这里必须用 msg（降级后的），否则 UI 还是显示 ERR
            AppendLogToTextView(textView, msg);

            // 自动滚动到底部
            NSRange endRange = NSMakeRange(textView.string.length, 0);
            [textView scrollRangeToVisible:endRange];

            // ✅ collectedLogs 存带时间戳的（同样用 msg）
            [self.collectedLogs appendFormat:@"%@\n", formattedLog];
        } else {
            NSLog(@"[ERROR] Failed to access NSTextView.");
        }
    });
}

#pragma mark - Diag 连接端口时 禁用启用 UI 按钮
typedef NS_ENUM(NSInteger, DiagState) {
    DiagStateNotReady,          // 全禁用
    DiagStateReady,             // 可连接串口
    DiagStateModemConnected,    // Modem已连接，全启用
};

- (void)updateUIForState:(DiagState)state {
    dispatch_async(dispatch_get_main_queue(), ^{
        BOOL enableDevice = (state != DiagStateNotReady);
        BOOL enablePort = (state >= DiagStateReady);
        BOOL enableConnect = (state >= DiagStateReady);
        BOOL enableConsole = (state == DiagStateModemConnected);
        BOOL enableReadWrite = (state == DiagStateModemConnected);
        BOOL enableBatch = (state == DiagStateModemConnected);
        
        // 设备和端口
        self.devicePopUpButton.enabled = enableDevice;
        self.portPopUpButton.enabled = enablePort;
        self.speedPopUpButton.enabled = enablePort;
        
        // 串口连接
        self.connectSerialButton.enabled = enableConnect;
        self.onConsoleToggleButton.enabled = enableConsole;
        self.disconnectSerialButton.enabled = enableConsole;
        
        // 批量操作
        self.clearAllButton.enabled = enableBatch;
        self.selectAllButton.enabled = enableBatch;
        self.deselectAllButton.enabled = enableBatch;
        self.writeSelectedButton.enabled = enableBatch;
        self.readAllButton.enabled = enableBatch;
        self.readSelectedButton.enabled = enableBatch;
        
        // SysCFG写入
        self.batteryWriteButton.enabled = enableReadWrite;
        self.bcmsWriteButton.enabled = enableReadWrite;
        self.bmacWriteButton.enabled = enableReadWrite;
        self.colorWriteButton.enabled = enableReadWrite;
        self.CLHSWriteButton.enabled = enableReadWrite;
        self.emacWriteButton.enabled = enableReadWrite;
        self.fcmsWriteButton.enabled = enableReadWrite;
        self.lcmWriteButton.enabled = enableReadWrite;
        self.modeWriteButton.enabled = enableReadWrite;
        self.modelWriteButton.enabled = enableReadWrite;
        self.mlbWriteButton.enabled = enableReadWrite;
        self.mtsnWriteButton.enabled = enableReadWrite;
        self.nsrnWriteButton.enabled = enableReadWrite;
        self.nvsnWriteButton.enabled = enableReadWrite;
        self.regionWriteButton.enabled = enableReadWrite;
        self.snWriteButton.enabled = enableReadWrite;
        self.wifiWriteButton.enabled = enableReadWrite;
        
        // SysCFG读取
        self.batteryReadButton.enabled = enableReadWrite;
        self.bcmsReadButton.enabled = enableReadWrite;
        self.bmacReadButton.enabled = enableReadWrite;
        self.colorReadButton.enabled = enableReadWrite;
        self.CLHSReadButton.enabled = enableReadWrite;
        self.emacReadButton.enabled = enableReadWrite;
        self.fcmsReadButton.enabled = enableReadWrite;
        self.lcmReadButton.enabled = enableReadWrite;
        self.modeReadButton.enabled = enableReadWrite;
        self.modelReadButton.enabled = enableReadWrite;
        self.mlbReadButton.enabled = enableReadWrite;
        self.mtsnReadButton.enabled = enableReadWrite;
        self.nsrnReadButton.enabled = enableReadWrite;
        self.nvsnReadButton.enabled = enableReadWrite;
        self.regionReadButton.enabled = enableReadWrite;
        self.snReadButton.enabled = enableReadWrite;
        self.wifiReadButton.enabled = enableReadWrite;
    });
}

- (void)setButtonsEnabled:(BOOL)enabled buttons:(NSArray<NSButton *> *)buttons {
    for (NSButton *btn in buttons) btn.enabled = enabled;
}

#pragma mark - SysCFG / Console 内容视窗切换

- (IBAction)onConsoleToggle:(id)sender {

    BOOL showingConsole = !self.consoleContentView.hidden;

    if (showingConsole) {
        // ===== 切回 SysCFG =====
        self.consoleContentView.hidden = YES;
        self.toolsContentView.hidden = YES;
        self.syscfgContentView.hidden = NO;
        self.consoleVisible = NO;

        // 标题显示为 Console（表示“可以切到 Console”）
        self.onConsoleToggleButton.title = @"Console";
        
        // ✅ 切到 Console：恢复 terminal 图标（leading）
        self.onConsoleToggleButton.image = [NSImage imageNamed:@"terminal"];
        self.onConsoleToggleButton.imagePosition = NSImageLeft;

    } else {
        // ===== 切到 Console =====
        self.syscfgContentView.hidden = YES;
        self.toolsContentView.hidden = YES;
        self.consoleContentView.hidden = NO;
        self.consoleVisible = YES;

        // 标题显示为 SysCFG（表示“可以切回 SysCFG”）
        self.onConsoleToggleButton.title = @"SysCFG";

        // ✅ 切回 SysCFG：移除 storyboard 设置的 terminal 图标
        self.onConsoleToggleButton.image = nil;
        self.onConsoleToggleButton.imagePosition = NSNoImage;

        // 第一次显示时初始化 UI
        if (_consoleTextView == nil) {
            [self setupConsoleUI];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (self->_consoleTextView) {
                [self.view.window makeFirstResponder:self->_consoleTextView];
            }
        });
    }
}



#pragma mark - Gaster I18N + Log Processing

- (NSString *)localizedFormatKey:(NSString *)key
                          module:(NSString *)module
                    defaultValue:(NSString *)defaultValue
                            args:(NSArray<NSString *> *)args {

    LanguageManager *lm = [LanguageManager sharedManager];
    NSString *tmpl = [lm localizedStringForKeys:key inModule:module defaultValue:defaultValue];
    if (tmpl.length == 0) tmpl = defaultValue ?: @"";

    // 跟你工程里类似的处理：只有模板含 %@ 才插值，否则返回模板本身
    if ([tmpl containsString:@"%@"] && args.count > 0) {
        if (args.count == 1) return [NSString stringWithFormat:tmpl, args[0]];
        return [NSString stringWithFormat:tmpl, args[0], args[1]];
    }
    return tmpl;
}

- (NSString *)gasterDisplayLineFromRaw:(NSString *)rawLine {
    if (rawLine.length == 0) return rawLine;

    NSString *line = [rawLine stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (line.length == 0) return @"";

    // 1) Waiting for USB (VID/PID)
    if ([line containsString:@"Waiting for the USB"] &&
        [line containsString:@"VID:"] &&
        [line containsString:@"PID:"]) {

        NSString *vid = @"?";
        NSString *pid = @"?";

        NSRegularExpression *re =
        [NSRegularExpression regularExpressionWithPattern:@"VID:\\s*(0x[0-9A-Fa-f]+)\\s*,\\s*PID:\\s*(0x[0-9A-Fa-f]+)"
                                                  options:0
                                                    error:nil];
        NSTextCheckingResult *m = [re firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
        if (m.numberOfRanges >= 3) {
            vid = [line substringWithRange:[m rangeAtIndex:1]] ?: @"?";
            pid = [line substringWithRange:[m rangeAtIndex:2]] ?: @"?";
        }

        return [self localizedFormatKey:@"GasterWaitingUSB"
                                 module:@"Gaster"
                           defaultValue:@"Waiting for the USB device with VID: %@, PID: %@"
                                   args:@[vid, pid]];
    }

    // 2) CPID
    if ([line hasPrefix:@"CPID:"]) {
        NSString *value = [[line componentsSeparatedByString:@":"] lastObject];
        value = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (value.length == 0) value = @"?";
        
        // ✅ 添加这段（保存 CPID）
        if (![value isEqualToString:@"?"]) {
            if ([value hasPrefix:@"0x"] || [value hasPrefix:@"0X"]) {
                self.detectedCPID = [[value substringFromIndex:2] uppercaseString];
            } else {
                self.detectedCPID = [value uppercaseString];
            }
            NSLog(@"[DiagController] 💾 Saved CPID: %@", self.detectedCPID);
        }
        // ✅ 添加结束
        
        return [self localizedFormatKey:@"GasterCPID"
                                 module:@"Gaster"
                           defaultValue:@"CPID: %@"
                                   args:@[value]];
    }

    // 3) Got USB handle
    if ([line containsString:@"Successfully obtained the USB device handle"]) {
        return [self localizedFormatKey:@"GasterUSBHandleOK"
                                 module:@"Gaster"
                           defaultValue:@"Successfully obtained the USB device handle"
                                   args:@[]];
    }

    // 4) Untrusted images OK
    if ([line containsString:@"Untrusted images can now be booted"]) {
        return [self localizedFormatKey:@"GasterUntrustedOK"
                                 module:@"Gaster"
                           defaultValue:@"Untrusted images can now be booted"
                                   args:@[]];
    }

    // 其它行：不翻译，原样透传（符合 BootChian 流程“关键节点本地化，其余原样”）
    return rawLine;
}

// 固件风格：去空 / 去重 / 节流，避免刷屏
- (BOOL)shouldEmitGasterLogLine:(NSString *)line {
    NSString *trim = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trim.length == 0) return NO;

    NSDate *now = [NSDate date];

    // 同一行重复出现且间隔很短 → 忽略（节流）
    if (self.lastGasterLogLine && [self.lastGasterLogLine isEqualToString:trim]) {
        if (self.lastGasterLogTime && [now timeIntervalSinceDate:self.lastGasterLogTime] < 0.25) {
            return NO;
        }
    }

    self.lastGasterLogLine = trim;
    self.lastGasterLogTime = now;
    return YES;
}

#pragma mark - Gaster Internal

- (void)startGasterWithArguments:(NSArray<NSString *> *)args
                         timeout:(NSTimeInterval)timeout {

    __weak typeof(self) weakSelf = self;

    self.currentToken =
    [[GasterRunner shared] runAsyncWithArguments:args
                                        timeout:timeout
                                  outputHandler:^(GasterStream stream, NSString *line) {

        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;

        NSString *mapped = [self gasterDisplayLineFromRaw:line];
        if (![self shouldEmitGasterLogLine:mapped]) return;

        NSString *prefix = (stream == GasterStreamStdout) ? @"" : @"[ER] ";
        [self showLogsWithMessage:[NSString stringWithFormat:@"%@%@", prefix, mapped]];

    } completion:^(GasterResult * _Nullable result, NSError * _Nullable error) {

        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;

        self.currentToken = nil;

        BOOL ok = NO;
        NSError *finalError = error;

        if (error) {
            [self showLogsWithMessage:[NSString stringWithFormat:@"[ER] %@", error.localizedDescription]];
        } else {
            ok = (result.exitCode == 0);
            if (!ok) {
                finalError = [NSError errorWithDomain:@"Gaster"
                                                 code:result.exitCode
                                             userInfo:@{NSLocalizedDescriptionKey:
                                                            @"gaster exited with non-zero code"}];
            }
        }

        //[self showLogsWithMessage:[NSString stringWithFormat:@"[Done] exit=%d", result.exitCode]];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (finalError) {
                // ❌ 失败：解锁设备，恢复UI
                [self.parentTabsController unlockDeviceForSource:@"DiagController"
                                                      withReason:@"gaster failed"];
                self.runButton.enabled = YES;
                self.cancelButton.enabled = NO;
                [self showLogsWithMessage:[NSString stringWithFormat:@"[ER] %@", finalError.localizedDescription]];
                return;
            }

            // ✅ 成功：自动继续诊断流程
            if (ok) {
                [self showLogsWithMessage:@"[SUC]Device pwn succeeded\n"];
                
                // ⚡️ 关键：不要 unlock 设备，直接继续流程
                // 延迟 2 秒让设备进入 Recovery 模式
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                              dispatch_get_main_queue(), ^{
                    [self autoStartDiagnosticsFlowAfterGaster];
                });
            } else {
                // 非零退出码：解锁设备
                [self.parentTabsController unlockDeviceForSource:@"DiagController"
                                                      withReason:@"gaster finished"];
                self.runButton.enabled = YES;
                self.cancelButton.enabled = NO;
            }
        });
    }];
}


// ==========================================
// 完整的基于 device_map.plist 的固件检测和发送系统
// ==========================================

#pragma mark - 初始化：加载设备映射 plist

- (void)loadDeviceMapFromPlist {

    NSString *mfcDataPath = [DatalogsSettings mfcDataDirectory];
    NSString *BootChianPath = [mfcDataPath stringByAppendingPathComponent:@"BootChian"];

    NSString *plistPath = [BootChianPath stringByAppendingPathComponent:@"device_map.plist"];
    
    NSLog(@"[DeviceMap] Loading from: %@", plistPath);
    
    if (![[NSFileManager defaultManager] fileExistsAtPath:plistPath]) {
        NSLog(@"[DeviceMap][ER] device_map.plist not found at: %@", plistPath);
        [self showLogsWithMessage:@"[WAR] device_map.plist not found, using built-in mappings"];
        self.deviceMapArray = nil;
        return;
    }
    
    // 2. 加载 plist
    NSArray *mapArray = [NSArray arrayWithContentsOfFile:plistPath];
    
    if (!mapArray || ![mapArray isKindOfClass:[NSArray class]]) {
        NSLog(@"[DeviceMap][ER] Failed to load device_map.plist or invalid format");
        [self showLogsWithMessage:@"[ER] Failed to load device_map.plist"];
        self.deviceMapArray = nil;
        return;
    }
    
    self.deviceMapArray = mapArray;
    NSLog(@"[DeviceMap] ✅ Loaded %lu device configurations", (unsigned long)mapArray.count);
    [self showLogsWithMessage:[NSString stringWithFormat:@"✅ Loaded %lu device configurations from device_map.plist",
                              (unsigned long)mapArray.count]];
}

#pragma mark - 核心方法：从 plist 查找设备配置

- (NSDictionary *)findDeviceConfigInPlist:(NSInteger)chipId boardId:(NSInteger)boardId {
    if (!self.deviceMapArray || self.deviceMapArray.count == 0) {
        NSLog(@"[DeviceMap][ER] deviceMapArray is empty");
        return nil;
    }
    
    NSLog(@"[DeviceMap] Searching for ChipId=%ld BoardId=%ld", (long)chipId, (long)boardId);
    
    for (NSDictionary *config in self.deviceMapArray) {
        // 获取 ChipId（可能是 NSNumber(integer) 或 NSNumber(real)）
        id chipIdObj = config[@"ChipId"];
        NSInteger configChipId = 0;
        
        if ([chipIdObj isKindOfClass:[NSNumber class]]) {
            configChipId = [chipIdObj integerValue];
        } else if ([chipIdObj isKindOfClass:[NSString class]]) {
            configChipId = [chipIdObj integerValue];
        }
        
        // 获取 BoardId
        NSInteger configBoardId = [config[@"BoardId"] integerValue];
        
        // 匹配
        if (configChipId == chipId && configBoardId == boardId) {
            NSLog(@"[DeviceMap] ✅ Found match: %@", config[@"MarketingName"]);
            return config;
        }
    }
    
    NSLog(@"[DeviceMap][WAR] No match found for ChipId=%ld BoardId=%ld", (long)chipId, (long)boardId);
    return nil;
}

#pragma mark - 改进的 autoDetectBootChain 方法

- (NSDictionary *)autoDetectBootChian {
    [self showLogsWithMessage:@"Auto-detecting BootChain files..."];
    NSLog(@"[BootChain] Auto-detecting BootChain files...");
    
    // 1. 获取设备的 CPID/BDID
    NSDictionary *deviceInfo = [[DeviceDatabaseController sharedInstance]
        identifyDeviceWithDeviceTypeOrDeviceModel:self.deviceType];
    
    NSString *dbBDID = deviceInfo[@"DeviceBDID"];   // @"0x04" 或 @"4"
    NSString *dbCPID = deviceInfo[@"DeviceCPID"];   // @"0x8015" 或 @"32789"
    
    NSLog(@"[BootChain] Raw from DB: CPID=%@ BDID=%@", dbCPID, dbBDID);
    
    if (!dbCPID.length || !dbBDID.length) {
        [self showLogsWithMessage:@"[ER] DeviceDatabase missing CPID/BDID"];
        NSLog(@"[BootChain][ER] DeviceDatabase missing CPID/BDID (deviceType=%@)", self.deviceType);
        return nil;
    }
    
    // 2. 转换为整数（支持 0x 前缀和十进制）
    NSInteger chipId = 0;
    NSInteger boardId = 0;
    
    // 解析 CPID
    if ([dbCPID hasPrefix:@"0x"] || [dbCPID hasPrefix:@"0X"]) {
        NSScanner *scanner = [NSScanner scannerWithString:dbCPID];
        [scanner setScanLocation:2]; // 跳过 "0x"
        unsigned int temp = 0;
        [scanner scanHexInt:&temp];
        chipId = temp;
    } else {
        chipId = [dbCPID integerValue];
    }
    
    // 解析 BDID
    if ([dbBDID hasPrefix:@"0x"] || [dbBDID hasPrefix:@"0X"]) {
        NSScanner *scanner = [NSScanner scannerWithString:dbBDID];
        [scanner setScanLocation:2];
        unsigned int temp = 0;
        [scanner scanHexInt:&temp];
        boardId = temp;
    } else {
        boardId = [dbBDID integerValue];
    }
    
    NSLog(@"[BootChain] Parsed: ChipId=%ld (0x%lX) BoardId=%ld (0x%lX)",
          (long)chipId, (long)chipId, (long)boardId, (long)boardId);
    
    // 3. 从 plist 查找设备配置
    NSDictionary *deviceConfig = [self findDeviceConfigInPlist:chipId boardId:boardId];
    
    if (!deviceConfig) {
        [self showLogsWithMessage:@"[ER] Device not found in device_map.plist"];
        [self showLogsWithMessage:[NSString stringWithFormat:@"    ChipId: %ld (0x%lX)",
                                  (long)chipId, (long)chipId]];
        [self showLogsWithMessage:[NSString stringWithFormat:@"    BoardId: %ld (0x%lX)",
                                  (long)boardId, (long)boardId]];
        NSLog(@"[BootChain][ER] Device not found in plist");
        return nil;
    }
    
    NSString *marketingName = deviceConfig[@"MarketingName"];
    NSString *firstStage = deviceConfig[@"FirstStage"];      // 必需
    NSString *secondStage = deviceConfig[@"SecondStage"];    // 可选
    NSString *diags = deviceConfig[@"Diags"];                // 必需
    
    NSLog(@"[BootChain] Device: %@", marketingName);
    NSLog(@"[BootChain] FirstStage: %@", firstStage);
    NSLog(@"[BootChain] SecondStage: %@", secondStage ?: @"(none)");
    NSLog(@"[BootChain] Diags: %@", diags);
    
    // 4. 查找实际文件
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    NSMutableArray *foundFiles = [NSMutableArray array];
    NSMutableArray *missingFiles = [NSMutableArray array];
    
    // 4.1 查找 FirstStage（必需）
    NSString *firstStagePath = [self findBootChainFile:firstStage];
    if (firstStagePath) {
        result[@"FirstStage"] = firstStagePath;
        [foundFiles addObject:[NSString stringWithFormat:@"✅ FirstStage: %@",
                              [firstStagePath lastPathComponent]]];
    } else {
        [missingFiles addObject:[NSString stringWithFormat:@"❌ FirstStage: %@ (NOT FOUND)",
                                firstStage]];
    }
    
    // 4.2 查找 SecondStage（可选）
    if (secondStage.length > 0) {
        NSString *secondStagePath = [self findBootChainFile:secondStage];
        if (secondStagePath) {
            result[@"SecondStage"] = secondStagePath;
            [foundFiles addObject:[NSString stringWithFormat:@"✅ SecondStage: %@",
                                  [secondStagePath lastPathComponent]]];
        } else {
            [missingFiles addObject:[NSString stringWithFormat:@"❌ SecondStage: %@ (NOT FOUND)",
                                    secondStage]];
        }
    }
    
    // 4.3 查找 Diags（必需）
    NSString *diagsPath = [self findBootChainFile:diags];
    if (diagsPath) {
        result[@"Diags"] = diagsPath;
        [foundFiles addObject:[NSString stringWithFormat:@"✅ Diags: %@",
                              [diagsPath lastPathComponent]]];
    } else {
        [missingFiles addObject:[NSString stringWithFormat:@"❌ Diags: %@ (NOT FOUND)",
                                diags]];
    }
    
    // 5. 检查是否所有必需文件都找到
    if (missingFiles.count > 0) {
        [self showLogsWithMessage:@"[ER] Missing required boot files:"];
        for (NSString *msg in missingFiles) {
            [self showLogsWithMessage:[NSString stringWithFormat:@"   %@", msg]];
        }
        
        if (foundFiles.count > 0) {
            [self showLogsWithMessage:@""];
            [self showLogsWithMessage:@"[INF] Found files:"];
            for (NSString *msg in foundFiles) {
                [self showLogsWithMessage:[NSString stringWithFormat:@"   %@", msg]];
            }
        }
        
        return nil;
    }
    
    // 6. 全部找到，显示成功信息
    [self showLogsWithMessage:[NSString stringWithFormat:@"✅ Detected: %@", marketingName]];
    for (NSString *msg in foundFiles) {
        [self showLogsWithMessage:[NSString stringWithFormat:@"   %@", msg]];
    }
    
    // 7. 返回结果
    result[@"deviceName"] = marketingName ?: @"";
    result[@"chipId"] = @(chipId);
    result[@"boardId"] = @(boardId);
    result[@"hasSecondStage"] = @(secondStage.length > 0);
    
    NSLog(@"[BootChain] ✅ Detection complete: %@", result);
    return [result copy];
}

#pragma mark - 辅助方法：查找 BootChain 文件

- (NSString *)findBootChainFile:(NSString *)relativePath {
    if (!relativePath || relativePath.length == 0) {
        return nil;
    }
    
    // relativePath 格式: "bootchain/iBoot.D21.img4"
    
    // 方案1：直接拼接固件基础路径
    NSString *fullPath = [self.firmwareBasePath stringByAppendingPathComponent:relativePath];
    if ([[NSFileManager defaultManager] fileExistsAtPath:fullPath]) {
        NSLog(@"[BootChain] Found: %@", fullPath);
        return fullPath;
    }
    
    // 方案2：提取文件名，尝试多种模式
    NSString *fileName = [relativePath lastPathComponent];  // "iBoot.D21.img4"
    
    // 生成可能的文件名变体（大小写组合）
    NSArray *fileNameVariants = [self generateFileNameVariants:fileName];
    
    // 2.1 先在 bootchain 子目录查找
    NSString *bootchainFolder = [self.firmwareBasePath stringByAppendingPathComponent:@"bootchain"];
    for (NSString *variant in fileNameVariants) {
        NSString *path = [bootchainFolder stringByAppendingPathComponent:variant];
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
            NSLog(@"[BootChain] Found variant: %@", path);
            return path;
        }
    }
    
    // 2.2 在固件根目录查找
    for (NSString *variant in fileNameVariants) {
        NSString *path = [self.firmwareBasePath stringByAppendingPathComponent:variant];
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
            NSLog(@"[BootChain] Found variant in root: %@", path);
            return path;
        }
    }
    
    // 2.3 尝试从文件名提取 board 代号，在对应目录查找
    // 例如 "iBoot.D21.img4" -> 提取 "D21" 或 "d21ap"
    NSString *boardPrefix = [self extractBoardPrefixFromFileName:fileName];
    if (boardPrefix.length > 0) {
        NSString *boardFolder = [self.firmwareBasePath stringByAppendingPathComponent:boardPrefix];
        for (NSString *variant in fileNameVariants) {
            NSString *path = [boardFolder stringByAppendingPathComponent:variant];
            if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
                NSLog(@"[BootChain] Found in board folder: %@", path);
                return path;
            }
        }
    }
    
    NSLog(@"[BootChain][WAR] File not found: %@ (tried %lu variants)",
          relativePath, (unsigned long)fileNameVariants.count);
    return nil;
}

#pragma mark - 辅助方法：生成文件名变体

- (NSArray<NSString *> *)generateFileNameVariants:(NSString *)fileName {
    NSMutableArray *variants = [NSMutableArray arrayWithObject:fileName];
    
    // 例如 "iBoot.D21.img4"
    // 生成: "iboot.d21.img4", "IBOOT.D21.IMG4" 等
    
    // 小写版本
    [variants addObject:[fileName lowercaseString]];
    
    // 大写版本
    [variants addObject:[fileName uppercaseString]];
    
    // 首字母小写版本（iBoot -> iboot）
    if (fileName.length > 0) {
        NSString *firstLower = [[fileName substringToIndex:1] lowercaseString];
        NSString *rest = [fileName substringFromIndex:1];
        [variants addObject:[firstLower stringByAppendingString:rest]];
    }
    
    // 去重
    NSOrderedSet *set = [NSOrderedSet orderedSetWithArray:variants];
    return [set array];
}

#pragma mark - 辅助方法：从文件名提取 Board 前缀

- (NSString *)extractBoardPrefixFromFileName:(NSString *)fileName {
    // 例如: "iBoot.D21.img4" -> "d21ap" 或 "D21"
    // "iBSS.N71m.img4" -> "n71map" 或 "N71m"
    
    // 移除扩展名
    NSString *baseName = [fileName stringByDeletingPathExtension];  // "iBoot.D21"
    
    // 按点分割
    NSArray *parts = [baseName componentsSeparatedByString:@"."];
    
    if (parts.count >= 2) {
        NSString *boardCode = parts[1];  // "D21" 或 "N71m"
        
        // 尝试添加 "ap" 后缀的小写版本
        NSString *withAp = [[boardCode lowercaseString] stringByAppendingString:@"ap"];
        
        // 返回两种可能
        // 优先返回带 "ap" 的版本，因为大多数 board 文件夹是这种格式
        return withAp;  // "d21ap"
    }
    
    return nil;
}

#pragma mark - 改进的启动流程执行

- (void)autoStartDiagnosticsFlowAfterGaster {
    NSLog(@"[DiagController] 🚀 Auto-starting diagnostics flow after Gaster success");
    
    // 1. 自动检测固件
    NSDictionary *bootChainInfo = [self autoDetectBootChian];
    
    if (!bootChainInfo) {
        [self showLogsWithMessage:@"[ER] BootChain auto-detection failed!"];
        [self showLogsWithMessage:@"[WAR] Please check:"];
        [self showLogsWithMessage:@"   1. device_map.plist exists in firmware folder"];
        [self showLogsWithMessage:@"   2. BootChain files are in correct location"];
        [self showLogsWithMessage:@"   3. Device is supported\n"];
        
        // 检测失败：解锁设备，恢复UI
        [self.parentTabsController unlockDeviceForSource:@"DiagController"
                                              withReason:@"BootChain detection failed"];
        self.runButton.enabled = YES;
        self.cancelButton.enabled = NO;
        [[NSSound soundNamed:@"Funk"] play];
        return;
    }
    
    // 2. 提取文件路径
    NSString *firstStagePath = bootChainInfo[@"FirstStage"];
    NSString *secondStagePath = bootChainInfo[@"SecondStage"];  // 可能为 nil
    NSString *diagsPath = bootChainInfo[@"Diags"];
    NSString *deviceName = bootChainInfo[@"deviceName"];
    BOOL hasSecondStage = [bootChainInfo[@"hasSecondStage"] boolValue];
    
    NSLog(@"[BootChain] Starting boot sequence for: %@", deviceName);
    NSLog(@"[BootChain] FirstStage: %@", [firstStagePath lastPathComponent]);
    if (hasSecondStage) {
        NSLog(@"[BootChain] SecondStage: %@", [secondStagePath lastPathComponent]);
    }
    NSLog(@"[BootChain] Diags: %@", [diagsPath lastPathComponent]);
    
    // 3. 获取 USB Serial 设置
    BOOL enableUSB = NO;
    if (self.enableUSBSerialCheckbox) {
        enableUSB = (self.enableUSBSerialCheckbox.state == NSControlStateValueOn);
    }
    
    // 4. 开始完整流程
    [self showLogsWithMessage:@"[INF] Auto-launching diagnostics flow..."];
    
    // 标记流程运行中
    self.isDiagFlowRunning = YES;
    self.currentFlowStep = 1; // Gaster (Step 1) 已完成
    
    // 5. ✅ 根据设备配置选择不同的启动流程
    if (hasSecondStage) {
        // 三阶段启动: FirstStage -> SecondStage -> Diags
        [self continueFlowWithThreeStages:firstStagePath
                              secondStage:secondStagePath
                                    diags:diagsPath
                                enableUSB:enableUSB];
    } else {
        // 两阶段启动: FirstStage -> Diags
        [self continueFlowWithTwoStages:firstStagePath
                                  diags:diagsPath
                              enableUSB:enableUSB];
    }
}

#pragma mark - 两阶段启动流程 (FirstStage -> Diags)

- (void)continueFlowWithTwoStages:(NSString *)firstStagePath
                            diags:(NSString *)diagsPath
                        enableUSB:(BOOL)enableUSB {
    __weak typeof(self) weakSelf = self;
    
    NSLog(@"[BootChain] ✅ Using TWO-STAGE boot sequence");
    
    // Step 2: 等待 Recovery 模式
    [self flowStep2_WaitForRecovery:^(BOOL success) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || !success) {
            [self finishDiagnosticsFlow:NO error:@"Device not ready"];
            return;
        }
        
        // Step 3: 发送 FirstStage (iBSS 或 iBoot)
        [self flowStep3_SendFirstStage:firstStagePath completion:^(BOOL success) {
            if (!success) {
                [self finishDiagnosticsFlow:NO error:@"Failed to send FirstStage"];
                return;
            }
            
            // Step 4: 等待 FirstStage 启动
            [self flowStep4_WaitAfterFirstStage:^(BOOL success) {
                if (!success) {
                    [self finishDiagnosticsFlow:NO error:@"Device not ready after FirstStage"];
                    return;
                }
                
                // ✅ Step 4.5: 对于 A10/A11 设备，先设置 boot-args
                [self flowStep4_5_SetBootArgs:enableUSB completion:^(BOOL bootArgsSuccess) {
                    if (!bootArgsSuccess) {
                        [self finishDiagnosticsFlow:NO error:@"Failed to set boot-args"];
                        return;
                    }
                    
                    // Step 5: 发送 Diags
                    [self flowStep5_SendDiags:diagsPath completion:^(BOOL success) {
                        if (!success) {
                            [self finishDiagnosticsFlow:NO error:@"Failed to send Diags"];
                            return;
                        }
                        
                        // ✅ Step 7: 启动 Diags (执行 go 命令)
                        [self flowStep7_StartDiags:enableUSB completion:^(BOOL startSuccess) {
                            if (!startSuccess) {
                                NSLog(@"[WAR] Start diags command failed, but continuing...");
                            }
                            
                            // Step 6: 等待 Diags 启动
                            [self flowStep6_WaitForDiagBoot:^(BOOL success) {
                                if (!success) {
                                    [self finishDiagnosticsFlow:NO error:@"Diag boot timeout"];
                                    return;
                                }
                                
                                // Step 8: 读取 SysCFG
                                [self flowStep8_ReadSysCFG:^(BOOL success) {
                                    [self finishDiagnosticsFlow:success error:success ? nil : @"Failed to read SysCFG"];
                                }];
                            }];
                        }];
                    }];
                }];
            }];
        }];
    }];
}



#pragma mark - 三阶段启动流程 (FirstStage -> SecondStage -> Diags)

- (void)continueFlowWithThreeStages:(NSString *)firstStagePath
                        secondStage:(NSString *)secondStagePath
                              diags:(NSString *)diagsPath
                          enableUSB:(BOOL)enableUSB {
    __weak typeof(self) weakSelf = self;
    
    NSLog(@"[BootChain] ✅ Using THREE-STAGE boot sequence");
    
    // Step 2: 等待 Recovery 模式
    [self flowStep2_WaitForRecovery:^(BOOL success) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || !success) {
            [self finishDiagnosticsFlow:NO error:@"Device not ready"];
            return;
        }
        
        // Step 3: 发送 FirstStage (iBSS)
        [self flowStep3_SendFirstStage:firstStagePath completion:^(BOOL success) {
            if (!success) {
                [self finishDiagnosticsFlow:NO error:@"Failed to send FirstStage"];
                return;
            }
            
            // Step 4: 等待 FirstStage 启动
            [self flowStep4_WaitAfterFirstStage:^(BOOL success) {
                if (!success) {
                    [self finishDiagnosticsFlow:NO error:@"Device not ready after FirstStage"];
                    return;
                }
                
                // Step 4.5: 发送 SecondStage (iBEC 或 iBoot)
                [self flowStep4_5_SendSecondStage:secondStagePath completion:^(BOOL success) {
                    if (!success) {
                        [self finishDiagnosticsFlow:NO error:@"Failed to send SecondStage"];
                        return;
                    }
                    
                    // Step 4.75: 等待 SecondStage 启动
                    [self flowStep4_75_WaitAfterSecondStage:^(BOOL success) {
                        if (!success) {
                            [self finishDiagnosticsFlow:NO error:@"Device not ready after SecondStage"];
                            return;
                        }
                        
                        // Step 5: 发送 Diags
                        [self flowStep5_SendDiags:diagsPath completion:^(BOOL success) {
                            if (!success) {
                                [self finishDiagnosticsFlow:NO error:@"Failed to send Diags"];
                                return;
                            }
                            
                            // Step 6: 等待 Diags 启动
                            [self flowStep6_WaitForDiagBoot:^(BOOL success) {
                                if (!success) {
                                    [self finishDiagnosticsFlow:NO error:@"Diag boot timeout"];
                                    return;
                                }
                                
                                // Step 7: 读取 SysCFG
                                [self flowStep8_ReadSysCFG:^(BOOL success) {
                                    [self finishDiagnosticsFlow:success error:success ? nil : @"Failed to read SysCFG"];
                                }];
                            }];
                        }];
                    }];
                }];
            }];
        }];
    }];
}

#pragma mark - 通用发送方法 (重命名以适应新流程)

// ✅ Step 3: 发送 FirstStage (iBSS 或 iBoot)
- (void)flowStep3_SendFirstStage:(NSString *)path completion:(void(^)(BOOL))completion {
    self.currentFlowStep = 3;
    
    NSString *fileName = [[path lastPathComponent] lowercaseString];
    NSString *fileType = @"FirstStage";
    if ([fileName containsString:@"ibss"]) {
        fileType = @"iBSS";
    } else if ([fileName containsString:@"iboot"]) {
        fileType = @"iBoot";
    }
    
    [self showLogsWithMessage:[NSString stringWithFormat:@"📤 Step 3/8: Sending %@...", fileType]];
    [self sendFirmwareFile:path fileType:fileType completion:completion];
}

// ✅ Step 4.5: 发送 SecondStage (iBEC 或 iBoot)
- (void)flowStep4_5_SendSecondStage:(NSString *)path completion:(void(^)(BOOL))completion {
    self.currentFlowStep = 4;
    
    NSString *fileName = [[path lastPathComponent] lowercaseString];
    NSString *fileType = @"SecondStage";
    if ([fileName containsString:@"ibec"]) {
        fileType = @"iBEC";
    } else if ([fileName containsString:@"iboot"]) {
        fileType = @"iBoot";
    }
    
    [self showLogsWithMessage:[NSString stringWithFormat:@"📤 Step 4.5/8: Sending %@...", fileType]];
    [self sendFirmwareFile:path fileType:fileType completion:completion];
}

// ✅ Step 4.75: 等待 SecondStage 启动后重新连接
- (void)flowStep4_75_WaitAfterSecondStage:(void(^)(BOOL))completion {
    [self showLogsWithMessage:@"⏳ Step 4.75/8: Waiting for SecondStage to load..."];
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (completion) completion(YES);
    });
}

// ✅ Step 5: 发送 Diags
- (void)flowStep5_SendDiags:(NSString *)path completion:(void(^)(BOOL))completion {
    self.currentFlowStep = 5;
    [self showLogsWithMessage:@"📤 Step 5/8: Sending Diags..."];

    // ✅ 修复：Step5开始就清理标志，避免被其它发送阶段污染
    self.diagSendReached100 = NO;
    self.sawDisconnectAfterDiagSend = NO;

    // ✅ 标记进入“发送Diags”窗口（让 progress/error callback 有正确语义）
    self.isSendingDiags = YES;

    // ✅ 对 A10/A11 设备增加稳定性延迟
    NSInteger chipId = [self getCurrentChipId];
    BOOL isA10A11 = (chipId == 0x8010 || chipId == 32784 ||
                     chipId == 0x8015 || chipId == 32789);

    if (isA10A11) {
        NSLog(@"[SendDiags] A10/A11 device (ChipId: 0x%lX), adding 2s stabilization delay...", (long)chipId);
        [self showLogsWithMessage:@"⏳ Stabilizing connection for A10/A11..."];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                       dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [self sendFirmwareFile:path fileType:@"Diags" completion:completion];
        });
    } else {
        [self sendFirmwareFile:path fileType:@"Diags" completion:completion];
    }
}


// ✅ 通用固件发送方法
- (void)sendFirmwareFile:(NSString *)path fileType:(NSString *)fileType completion:(void(^)(BOOL))completion {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        uint64_t ecid = [self getDeviceECID];

        if (ecid == 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self showLogsWithMessage:@"❌ ECID is 0 (invalid)"];
                if (completion) completion(NO);
            });
            // 如果是 Diags，别忘了退出发送窗口
            if ([fileType isEqualToString:@"Diags"]) {
                self.isSendingDiags = NO;
            }
            return;
        }

        NSString *fileName = [[path lastPathComponent] lowercaseString];
        const char *pathCStr = [path UTF8String];

        // 更严格：以 fileType 判断是否为“本次发送是Diags”
        BOOL isDiagFile = [fileType isEqualToString:@"Diags"] || [fileName containsString:@"diag"];

        irecv_error_t err = IRECV_E_UNKNOWN_ERROR;

        int maxRetries = 3;
        BOOL success = NO;

        // ✅ 修复：Attempt 1 也要重置（之前你只在 attempt>1 才重置）
        if (isDiagFile) {
            self.diagSendReached100 = NO;
            self.sawDisconnectAfterDiagSend = NO;
            NSLog(@"[SendFirmware] Reset Diag flags (attempt 1)");
        }

        for (int attempt = 1; attempt <= maxRetries; attempt++) {
            if (attempt > 1) {
                NSLog(@"[SendFirmware] Retry attempt %d/%d for %@", attempt, maxRetries, fileName);
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self showLogsWithMessage:[NSString stringWithFormat:@"🔄 Retrying... (%d/%d)", attempt, maxRetries]];
                });

                // 增加重试前延迟
                sleep(3);

                // 重试前等待设备就绪
                BOOL deviceReady = NO;
                int waitAttempts = 20;  // 最多等待 10 秒
                NSLog(@"[SendFirmware] Waiting for device to be ready before retry...");

                for (int w = 0; w < waitAttempts; w++) {
                    usleep(500000);  // 0.5 秒

                    irecv_client_t testClient = NULL;
                    irecv_error_t testErr = recore_open_with_ecid(&testClient, ecid, NULL);

                    if (testErr == IRECV_E_SUCCESS && testClient) {
                        recore_close(testClient);
                        deviceReady = YES;
                        NSLog(@"[SendFirmware] Device ready after %.1f seconds", (w + 1) * 0.5);
                        break;
                    }
                }

                if (!deviceReady) {
                    NSLog(@"[SendFirmware] ⚠️ Device not ready, but attempting anyway...");
                } else {
                    usleep(1000000);  // 1 秒稳定
                }

                // ✅ 重试前重置 Diag 标志
                if (isDiagFile) {
                    self.diagSendReached100 = NO;
                    self.sawDisconnectAfterDiagSend = NO;
                    NSLog(@"[SendFirmware] Reset Diag flags for retry");
                }
            }

            // ✅ callbacks
            imfc_callbacks_t cbs;
            memset(&cbs, 0, sizeof(cbs));
            cbs.on_log = diag_log_callback;
            cbs.on_progress = diag_progress_callback;
            cbs.on_error = diag_error_callback;
            cbs.user = (__bridge void *)self;

            // ✅ Open
            NSLog(@"[SendFirmware] [Attempt %d] Opening device (ECID=0x%llx)...",
                  attempt, (unsigned long long)ecid);

            err = recore_open_with_ecid(&self->_recoreClient, ecid, &cbs);

            if (err != IRECV_E_SUCCESS || !self->_recoreClient) {
                NSLog(@"[SendFirmware] [Attempt %d] Open failed: %s",
                      attempt, irecv_strerror(err));

                if (attempt == maxRetries) {
                    break;
                }
                continue;
            }

            NSLog(@"[SendFirmware] [Attempt %d] Device opened successfully", attempt);

            // ✅ Send
            if ([fileType isEqualToString:@"FirstStage"] ||
                [fileType isEqualToString:@"iBSS"]) {

                NSLog(@"[SendFirmware] [Attempt %d] Sending FirstStage (iBSS): %@", attempt, fileName);
                err = recore_send_ibss(self->_recoreClient, pathCStr, 0, &cbs);

                // ChipId 0x8960 需要两次（保留你原逻辑）
                if (err == IRECV_E_SUCCESS) {
                    NSInteger chipId = [self getCurrentChipId];
                    if (chipId == 0x8960 || chipId == 35168) {
                        NSLog(@"[SendFirmware] [Attempt %d] ChipId 0x8960: Sending iBSS again...", attempt);
                        sleep(1);
                        err = recore_send_ibss(self->_recoreClient, pathCStr, 0, &cbs);
                    }
                }



            } else if ([fileType isEqualToString:@"SecondStage"] ||
                       [fileType isEqualToString:@"iBEC"]) {

                NSLog(@"[SendFirmware] [Attempt %d] Sending SecondStage (iBEC): %@", attempt, fileName);
                err = recore_send_ibec(self->_recoreClient, pathCStr, 0, &cbs);

            } else {
                NSLog(@"[SendFirmware] [Attempt %d] Sending file (%@): %@", attempt, fileType, fileName);
                err = recore_send_file(self->_recoreClient, pathCStr, 0, &cbs);
            }

            // ✅ Close
            recore_close(self->_recoreClient);
            self->_recoreClient = NULL;

            // ✅ 关键修复：只有 (进度100% 且 断开标志已出现) 才把 -6 当成功
            if (isDiagFile && err == IRECV_E_USB_UPLOAD) {  // -6
                NSLog(@"[SendFirmware] [Attempt %d] Diag returned -6, checking if expected...", attempt);

                // 给通知/回调一点时间（断开通知 + progress）
                usleep(1200 * 1000); // 1.2s

                if (self.diagSendReached100 && self.sawDisconnectAfterDiagSend) {
                    NSLog(@"[SendFirmware] [Attempt %d] ✅ Diag reached 100%% and disconnect observed, treating -6 as success", attempt);
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self showLogsWithMessage:@"✅ Diag sent to 100%, device rebooting into diagnostics..."];
                    });
                    success = YES;
                    err = IRECV_E_SUCCESS;
                    break;
                } else {
                    NSLog(@"[SendFirmware] [Attempt %d] ❌ Diag did NOT meet success conditions (reached100=%d, sawDisconnect=%d)",
                          attempt, self.diagSendReached100, self.sawDisconnectAfterDiagSend);
                    // 继续走失败逻辑，进入重试或最终失败
                }
            }

            if (err == IRECV_E_SUCCESS) {
                NSLog(@"[SendFirmware] [Attempt %d] ✅ Send succeeded!", attempt);
                success = YES;
                break;
            } else {
                NSLog(@"[SendFirmware] [Attempt %d] ❌ Send failed: %s",
                      attempt, irecv_strerror(err));
            }
        }

        // ✅ 退出“发送Diags窗口”
        if (isDiagFile) {
            self.isSendingDiags = NO;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (success) {
                [self showLogsWithMessage:[NSString stringWithFormat:@"✅ %@ sent successfully", fileType]];
                if (completion) completion(YES);
            } else {
                [self showLogsWithMessage:[NSString stringWithFormat:@"❌ Failed to send %@ after %d attempts: %s",
                                           fileType, maxRetries, irecv_strerror(err)]];
                if (completion) completion(NO);
            }
        });
    });
}



// ✅ 重命名原有方法以保持一致性
- (void)flowStep4_WaitAfterFirstStage:(void(^)(BOOL))completion {
    [self showLogsWithMessage:@"⏳ Step 4/8: Waiting for FirstStage to load..."];
    
    // ✅ 对于 A10 设备，iBSS 加载后 USB 模式不变，直接等待 3 秒即可
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        [self showLogsWithMessage:@"✅ FirstStage wait completed"];
        if (completion) completion(YES);
    });
}


// ✅ Step 4.5: 为 A10/A11 设备设置 boot-args (在发送 Diags 之前)
- (void)flowStep4_5_SetBootArgs:(BOOL)enableUSB completion:(void(^)(BOOL))completion {
    NSInteger chipId = [self getCurrentChipId];

    // 只对 A10/A11 走这条逻辑
    BOOL isA10A11 = (chipId == 0x8010 || chipId == 32784 ||
                     chipId == 0x8015 || chipId == 32789);

    if (!isA10A11) {
        if (completion) completion(YES);
        return;
    }

    self.currentFlowStep = 4; // 你也可以用 4.5 的语义，但 currentFlowStep 是 int 就用 4
    [self showLogsWithMessage:@"⚙️ Setting boot-args..."];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        uint64_t ecid = [self getDeviceECID];
        if (ecid == 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self showLogsWithMessage:@"❌ ECID is 0 (invalid)"];
                if (completion) completion(NO);
            });
            return;
        }

        // 1) 等设备能 open（避免还没枚举回来就 open 失败）
        const int TIMEOUT_SECONDS = 30;
        const double INTERVAL = 0.5;
        const int MAX_TRIES = (int)(TIMEOUT_SECONDS / INTERVAL);

        irecv_client_t client = NULL;
        irecv_error_t err = IRECV_E_UNKNOWN_ERROR;

        for (int i = 1; i <= MAX_TRIES; i++) {
            usleep((useconds_t)(INTERVAL * 1000000));

            err = recore_open_with_ecid(&client, ecid, NULL);
            if (err == IRECV_E_SUCCESS && client) {
                // 稳定一下
                usleep(800000);
                break;
            }
        }

        if (!client) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self showLogsWithMessage:@"❌ Failed to open device for boot-args (device not ready)"];
                if (completion) completion(NO);
            });
            return;
        }

        // 2) setenv/clearenv
        if (enableUSB) {
            err = recore_send_command(client, "setenv boot-args usbserial=enabled", NULL);
        } else {
            err = recore_send_command(client, "clearenv boot-args", NULL);
        }

        if (err != IRECV_E_SUCCESS) {
            recore_close(client);
            dispatch_async(dispatch_get_main_queue(), ^{
                [self showLogsWithMessage:@"❌ Failed to set boot-args"];
                if (completion) completion(NO);
            });
            return;
        }

        // 3) saveenv
        err = recore_send_command(client, "saveenv", NULL);
        if (err != IRECV_E_SUCCESS) {
            recore_close(client);
            dispatch_async(dispatch_get_main_queue(), ^{
                [self showLogsWithMessage:@"❌ Failed to save boot-args"];
                if (completion) completion(NO);
            });
            return;
        }

        // ✅ 关键：这里发 go（你已经删了 Step3 的 go，就必须在这里推进状态机）
        err = recore_send_command(client, "go", NULL);
        // go 很常见会导致断开/返回非 success（因为设备立刻跳走），所以不要把它当致命
        // 只要命令发出后设备断开重连即可
        recore_close(client);
        client = NULL;

        dispatch_async(dispatch_get_main_queue(), ^{
            [self showLogsWithMessage:@"✅ Boot-args configured"];
            [self showLogsWithMessage:@"⏳ Waiting for device to restart..."];
        });

        // 4) 等设备断开 + 再次可 open（进入下一阶段）
        //    这里简单等“能 open”为准（你也可以更精细按 PID 判断）
        BOOL ready = NO;
        for (int i = 1; i <= MAX_TRIES; i++) {
            usleep((useconds_t)(INTERVAL * 1000000));
            irecv_client_t t = NULL;
            irecv_error_t te = recore_open_with_ecid(&t, ecid, NULL);
            if (te == IRECV_E_SUCCESS && t) {
                recore_close(t);
                ready = YES;
                break;
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (!ready) {
                [self showLogsWithMessage:@"❌ Device did not come back after boot-args/go"];
            } else {
                [self showLogsWithMessage:@"✅ Device ready"];
            }
            if (completion) completion(ready);
        });
    });
}



// ✅ 重命名并增加等待时间：flowStep6_WaitAfteriBEC → flowStep6_WaitForDiagBoot
- (void)flowStep6_WaitForDiagBoot:(void(^)(BOOL))completion {
    self.currentFlowStep = 6;
    [self showLogsWithMessage:@"📍 Step 6/8: Waiting for Diag to boot..."];
    
    // ✅ Diag 启动需要更长时间（10秒而不是5秒）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC),
                  dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self showLogsWithMessage:@"✅ Diag should be ready\n"];
        completion(YES);
    });
}

- (NSInteger)getCurrentChipId {
    id cpidObj = self.detectedCPID;
    if (!cpidObj) {
        NSLog(@"[ChipId] detectedCPID is nil");
        return 0;
    }

    NSString *str = nil;

    if ([cpidObj isKindOfClass:[NSNumber class]]) {
        str = [(NSNumber *)cpidObj stringValue];
        NSLog(@"[ChipId] detectedCPID NSNumber: %@", str);
    } else if ([cpidObj isKindOfClass:[NSString class]]) {
        str = (NSString *)cpidObj;
        NSLog(@"[ChipId] detectedCPID NSString: %@", str);
    } else {
        NSLog(@"[ChipId] detectedCPID unknown type: %@", [cpidObj class]);
        return 0;
    }

    // 清理字符串
    NSString *cleanStr =
        [[str stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
         stringByReplacingOccurrencesOfString:@"0x"
         withString:@""];

    // 按 16 进制解析
    NSInteger chipId = (NSInteger)strtol(cleanStr.UTF8String, NULL, 16);

    // 打印最终结果
    NSLog(@"[ChipId] parsed string: %@ -> dec: %ld, hex: 0x%lX",
          cleanStr,
          (long)chipId,
          (long)chipId);

    return chipId;
}


#pragma mark - Gaster Actions

- (IBAction)GasterOnRun:(id)sender {
    if (self.currentToken) return;

    if (![self validateForAction]) return;

    if (![self isDeviceLocked]) {
        NSString *msg =
        [[LanguageManager sharedManager] localizedStringForKeys:@"PleaseSelectDeviceTitle"
                                                      inModule:@"Flasher"
                                                  defaultValue:@"Please Select Device"];
        [self showLogsWithMessage:msg];
        return;
    }

    if (!self.parentTabsController) {
        [self showLogsWithMessage:@"[ER] parentTabsController is nil (setupParentTabsController failed)"];
        return;
    }

    NSArray<NSString *> *args = [self parseArgs:self.argsField.stringValue];
    if (args.count == 0) {
        // 你验证过 --help 在 gaster 上是 exit=1 且无输出，所以默认 pwn
        args = @[@"pwn"];
        self.argsField.stringValue = @"pwn";
    }

    NSString *lockedDeviceID = [self getLockedDeviceID];
    if (lockedDeviceID.length == 0) {
        [self showLogsWithMessage:@"[ER] lockedDeviceID is empty"];
        return;
    }

    // UI 状态
    self.runButton.enabled = NO;
    self.cancelButton.enabled = YES;

    // 任务标题也用本地化（与固件流程一致：关键节点本地化）
    NSString *taskTitle =
    [[LanguageManager sharedManager] localizedStringForKeys:@"GasterTaskRunning"
                                                  inModule:@"Gaster"
                                              defaultValue:@"Gaster Running"];

    __weak typeof(self) weakSelf = self;

    [self.parentTabsController lockDeviceForExclusiveTask:lockedDeviceID
                                               deviceInfo:@{@"type": self.currentDeviceType ?: @"unknown",
                                                            @"mode": self.currentDeviceMode ?: @"unknown"}
                                                operation:@"gaster"
                                               sourceName:@"DiagController"
                                          taskDescription:taskTitle
                                          allowUserCancel:YES
                                          completionBlock:^(BOOL success, NSError *error) {
        // completionBlock 在你架构里属于“任务中心的回调”，注销任务不靠它。
        (void)success; (void)error;
    } callback:^(BOOL registered, NSString *errorMessage) {

        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;

        if (!registered) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.runButton.enabled = YES;
                self.cancelButton.enabled = NO;
                [self showLogsWithMessage:[NSString stringWithFormat:@"[ER] %@", errorMessage ?: @"register task failed"]];
            });
            return;
        }

        // 清理去重状态（每次运行从干净状态开始）
        self.lastGasterLogLine = nil;
        self.lastGasterLogTime = nil;

        // 注册成功后启动 gaster（给一个超时避免一直等）
        [self startGasterWithArguments:args timeout:60];
    }];
}

- (IBAction)onCancel:(id)sender {
    if (!self.currentToken && !self.isDiagFlowRunning) return;
    
    // 取消 Gaster
    if (self.currentToken) {
        [self.currentToken cancel];
        self.currentToken = nil;
        [self showLogsWithMessage:@"[WAR] gaster cancelled by user"];
    }
    
    // 取消诊断流程
    if (self.isDiagFlowRunning) {
        self.isDiagFlowRunning = NO;
        [self showLogsWithMessage:@"[WAR] diagnostics flow cancelled by user"];
    }
    
    // 解锁设备，恢复 UI
    [self.parentTabsController unlockDeviceForSource:@"DiagController"
                                          withReason:@"cancelled by user"];
    
    self.runButton.enabled = YES;
    self.cancelButton.enabled = NO;
}

#pragma mark - Helpers

- (NSArray<NSString *> *)parseArgs:(NSString *)text {
    NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSArray<NSString *> *parts = [text componentsSeparatedByCharactersInSet:ws];
    NSMutableArray<NSString *> *args = [NSMutableArray array];
    for (NSString *p in parts) {
        if (p.length > 0) [args addObject:p];
    }
    return args;
}

#pragma mark - ✅ iRecovery/recore Open Retry Helpers

// 说明：recore_open_with_ecid 在设备重枚举窗口里很容易返回 -3（unable to connect）
// 这里做“重试 + 超时 + 可取消”，避免 Step5 直接撞空。
- (irecv_error_t)recoreOpenWithRetry:(uint64_t)ecid
                           callbacks:(imfc_callbacks_t *)cbs
                             timeout:(NSTimeInterval)timeoutSeconds
                        pollInterval:(NSTimeInterval)pollSeconds
{
    // 防御：避免 poll=0 导致 busy loop
    if (pollSeconds < 0.05) pollSeconds = 0.05;
    if (timeoutSeconds < pollSeconds) timeoutSeconds = pollSeconds;

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeoutSeconds];
    irecv_error_t lastErr = IRECV_E_UNABLE_TO_CONNECT;

    while (self.isDiagFlowRunning && [[NSDate date] compare:deadline] == NSOrderedAscending) {
        // 如果上一次 client 没关干净，先关掉
        if (self.recoreClient) {
            recore_close(self.recoreClient);
            self.recoreClient = NULL;
        }

        irecv_client_t client = NULL;
        irecv_error_t err = recore_open_with_ecid(&client, ecid, cbs);

        if (err == IRECV_E_SUCCESS && client) {
            self.recoreClient = client;
            return IRECV_E_SUCCESS;
        }

        lastErr = err;

        // 关键：给 USB 枚举/恢复一些时间
        usleep((useconds_t)(pollSeconds * 1000.0 * 1000.0));
    }

    return lastErr;
}

// 用于“探测设备是否已经可连”：open 成功就立刻 close
- (BOOL)probeDeviceConnectableWithECID:(uint64_t)ecid
                            callbacks:(imfc_callbacks_t *)cbs
                              timeout:(NSTimeInterval)timeoutSeconds
                         pollInterval:(NSTimeInterval)pollSeconds
                          lastErrorOut:(irecv_error_t *)outErr
{
    irecv_error_t err = [self recoreOpenWithRetry:ecid
                                       callbacks:cbs
                                         timeout:timeoutSeconds
                                    pollInterval:pollSeconds];

    if (outErr) *outErr = err;

    if (err == IRECV_E_SUCCESS) {
        // 这里只是探测，探测成功立即关闭，避免占用句柄影响后续步骤
        if (self.recoreClient) {
            recore_close(self.recoreClient);
            self.recoreClient = NULL;
        }
        return YES;
    }
    return NO;
}


#pragma mark - ✅ BootChian路径设置

- (void)setupBootChianPaths {
    
    // 获取最终文件路径
    NSString *mfcDataPath = [DatalogsSettings mfcDataDirectory];
    NSString *bootChianDirectory = [mfcDataPath stringByAppendingPathComponent:@"BootChian"];
    
    // 确保目录存在
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSError *dirError = nil;
    if (![fileManager fileExistsAtPath:bootChianDirectory]) {
        if (![fileManager createDirectoryAtPath:bootChianDirectory
                    withIntermediateDirectories:YES attributes:nil error:&dirError]) {
            NSLog(@"[ERROR] 创建BootChian目录失败: %@", dirError.localizedDescription);
            return;
        }
    }
        
    if (bootChianDirectory && [[NSFileManager defaultManager] fileExistsAtPath:bootChianDirectory]) {
        self.firmwareBasePath = bootChianDirectory;
    }
    
    NSLog(@"BootChain目录: %@", self.firmwareBasePath);
}



#pragma mark - ✅ 流程步骤实现（基于 recore_helpers.c）

- (void)flowStep1_GasterPwn:(void(^)(BOOL))completion {
    self.currentFlowStep = 1;
    [self showLogsWithMessage:@"📍 Step 1/8: Running Gaster pwn..."];
    
    // 复用现有的 Gaster 实现
    NSString *lockedDeviceID = [self getLockedDeviceID];
    NSString *taskTitle = @"Gaster PWN";
    
    __weak typeof(self) weakSelf = self;
    
    [self.parentTabsController lockDeviceForExclusiveTask:lockedDeviceID
                                               deviceInfo:@{@"type": self.currentDeviceType ?: @"unknown"}
                                                operation:@"gaster"
                                               sourceName:@"DiagController"
                                          taskDescription:taskTitle
                                          allowUserCancel:NO
                                          completionBlock:^(BOOL success, NSError *error) {}
                                                 callback:^(BOOL registered, NSString *errorMessage) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || !registered) {
            completion(NO);
            return;
        }
        
        self.currentToken = [[GasterRunner shared]
            runAsyncWithArguments:@[@"pwn"]
            timeout:60
            outputHandler:^(GasterStream stream, NSString *line) {
                __strong typeof(weakSelf) self = weakSelf;
                if (!self) return;
                NSString *mapped = [self gasterDisplayLineFromRaw:line];
                if (![self shouldEmitGasterLogLine:mapped]) return;
                [self showLogsWithMessage:mapped];
            }
            completion:^(GasterResult *result, NSError *error) {
                __strong typeof(weakSelf) self = weakSelf;
                if (!self) {
                    completion(NO);
                    return;
                }
                
                self.currentToken = nil;
                [self.parentTabsController unlockDeviceForSource:@"DiagController" withReason:@"gaster done"];
                
                BOOL ok = (!error && result.exitCode == 0);
                [self showLogsWithMessage:ok ? @"[SUC]Gaster pwn succeeded\n" : @"[ER]Gaster pwn failed\n"];
                completion(ok);
            }];
    }];
}

- (void)flowStep2_WaitForRecovery:(void(^)(BOOL))completion {
    self.currentFlowStep = 2;
    [self showLogsWithMessage:@"⏳ Waiting for Recovery mode..."];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        uint64_t ecid = [self getDeviceECID];

        imfc_callbacks_t cbs;
        memset(&cbs, 0, sizeof(cbs));
        cbs.on_log = diag_log_callback;
        cbs.on_progress = diag_progress_callback;
        cbs.on_error = diag_error_callback;
        cbs.user = (__bridge void *)self;

        // ✅ 增加等待时间到 30 秒
        NSLog(@"[Recovery] Probing device (ECID=0x%llx, timeout=30s)...",
              (unsigned long long)ecid);
        
        irecv_error_t lastErr = IRECV_E_UNABLE_TO_CONNECT;
        BOOL ok = [self probeDeviceConnectableWithECID:ecid
                                            callbacks:&cbs
                                              timeout:30.0
                                         pollInterval:0.25
                                          lastErrorOut:&lastErr];

        if (!ok) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!self.isDiagFlowRunning) {
                    [self showLogsWithMessage:@"[WAR] Flow cancelled"];
                    completion(NO);
                    return;
                }
                
                [self showLogsWithMessage:[NSString stringWithFormat:@"❌ Recovery not ready: %s",
                                           irecv_strerror(lastErr)]];
                completion(NO);
            });
            return;
        }

        // ✅ 额外等待确保设备稳定
        NSLog(@"[Recovery] Device connectable, waiting 2s for stability...");
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showLogsWithMessage:@"✅ Recovery ready, stabilizing..."];
        });
        
        sleep(2);

        dispatch_async(dispatch_get_main_queue(), ^{
            if (!self.isDiagFlowRunning) {
                [self showLogsWithMessage:@"[WAR] Flow cancelled"];
                completion(NO);
                return;
            }

            [self showLogsWithMessage:@"✅ Recovery ready"];
            NSLog(@"[Recovery] Device ready to receive firmware");
            completion(YES);
        });
    });
}


- (void)flowStep3_SendiBSS:(NSString *)path completion:(void(^)(BOOL))completion {
    self.currentFlowStep = 3;
    [self showLogsWithMessage:@"Sending iBSS..."];
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        uint64_t ecid = [self getDeviceECID];
        
        imfc_callbacks_t cbs;
        memset(&cbs, 0, sizeof(cbs));
        cbs.on_log = diag_log_callback;
        cbs.on_progress = diag_progress_callback;
        cbs.on_error = diag_error_callback;
        cbs.user = (__bridge void *)self;
        
        // 1) open
        irecv_error_t err = recore_open_with_ecid(&self->_recoreClient, ecid, &cbs);
        if (err != IRECV_E_SUCCESS) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self showLogsWithMessage:[NSString stringWithFormat:@"❌ Open: %s\n", irecv_strerror(err)]];
                completion(NO);
            });
            return;
        }
        
        // 2) send ibss
        // ✅ 关键：不要用 IRECV_SEND_OPT_DFU_NOTIFY_FINISH
        // 让流程更接近 diag_script 的“顺滑接管”
        err = recore_send_ibss(self->_recoreClient, [path UTF8String], 0 /* <- 改这里 */, &cbs);
        
        // 3) close
        recore_close(self->_recoreClient);
        self->_recoreClient = NULL;
        
        BOOL ok = (err == IRECV_E_SUCCESS);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showLogsWithMessage:ok ? @"✅ iBSS sent\n" : @"❌ iBSS failed\n"];
            completion(ok);
        });
    });
}


- (void)flowStep4_WaitAfteriBSS:(void(^)(BOOL))completion {
    self.currentFlowStep = 4;
    [self showLogsWithMessage:@"Waiting after iBSS..."];

    // ✅ 改为“短暂缓冲”，不要在这里用 recore_open 探测
    // 因为 iBSS 阶段并不保证能被 recore_open_with_ecid 打开
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!self.isDiagFlowRunning) {
            [self showLogsWithMessage:@"[WAR] flow cancelled\n"];
            completion(NO);
            return;
        }
        [self showLogsWithMessage:@"✅ Continue after iBSS\n"];
        completion(YES);
    });
}


- (void)flowStep5_SendiBEC:(NSString *)path completion:(void(^)(BOOL))completion {
    self.currentFlowStep = 5;
    [self showLogsWithMessage:@"Sending iBEC..."];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        uint64_t ecid = [self getDeviceECID];
        if (ecid == 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self showLogsWithMessage:@"❌ Open: ECID is 0 (invalid)\n"];
                completion(NO);
            });
            return;
        }

        imfc_callbacks_t cbs;
        memset(&cbs, 0, sizeof(cbs));
        cbs.on_log = diag_log_callback;
        cbs.on_progress = diag_progress_callback;
        cbs.on_error = diag_error_callback;
        cbs.user = (__bridge void *)self;

        irecv_error_t err = recore_open_with_ecid(&self->_recoreClient, ecid, &cbs);
        if (err != IRECV_E_SUCCESS) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self showLogsWithMessage:[NSString stringWithFormat:@"❌ Open: %s\n", irecv_strerror(err)]];
                completion(NO);
            });
            return;
        }

        err = recore_send_ibec(self->_recoreClient, [path UTF8String], 0, &cbs);

        recore_close(self->_recoreClient);
        self->_recoreClient = NULL;

        BOOL ok = (err == IRECV_E_SUCCESS);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showLogsWithMessage:ok ? @"✅ iBEC sent\n" : @"❌ iBEC failed\n"];
            completion(ok);
        });
    });
}


- (void)flowStep6_WaitAfteriBEC:(void(^)(BOOL))completion {
    self.currentFlowStep = 6;
    [self showLogsWithMessage:@"Waiting after iBEC..."];
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                  dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSLog(@"✅ Ready");
        completion(YES);
    });
}

// 启动 Diags (boot-args + go)
- (void)flowStep7_StartDiags:(BOOL)enableUSB completion:(void(^)(BOOL))completion {
    self.currentFlowStep = 7;
    [self showLogsWithMessage:@"🚀 Starting diagnostics..."];
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        uint64_t ecid = [self getDeviceECID];
        
        if (ecid == 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self showLogsWithMessage:@"❌ ECID is 0 (invalid)"];
                if (completion) completion(NO);
            });
            return;
        }
        
        irecv_client_t client = NULL;
        irecv_error_t err;
        
        // ✅ 打开设备
        err = recore_open_with_ecid(&client, ecid, NULL);
        if (err != IRECV_E_SUCCESS || !client) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self showLogsWithMessage:@"❌ Failed to open device"];
                if (completion) completion(NO);
            });
            return;
        }
        
        // ✅ 获取 ChipId 判断是否需要设置 boot-args
        NSInteger chipId = [self getCurrentChipId];
        BOOL isA10A11 = (chipId == 0x8010 || chipId == 32784 ||
                        chipId == 0x8015 || chipId == 32789);
        
        // ✅ 如果不是 A10/A11，需要在这里设置 boot-args
        if (!isA10A11) {
            NSLog(@"[StartDiags] Setting boot-args for ChipId 0x%lX", (long)chipId);
            
            // 对于其他芯片，使用原来的方式
            if (enableUSB) {
                recore_send_command(client, "setenv boot-args usbserial=enabled", NULL);
                recore_send_command(client, "saveenv", NULL);
            } else {
                recore_send_command(client, "clearenv boot-args", NULL);
                recore_send_command(client, "clearenv 1", NULL);
            }
        } else {
            NSLog(@"[StartDiags] ChipId 0x%lX (A10/A11): boot-args already set in Step 4.5", (long)chipId);
        }
        
        // ✅ 发送 go 命令启动 Diags
        NSLog(@"[StartDiags] Sending 'go' command...");
        err = recore_send_command(client, "go", NULL);
        
        recore_close(client);
        
        BOOL success = (err == IRECV_E_SUCCESS);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (success) {
                [self showLogsWithMessage:@"✅ Diagnostics started"];
                if (completion) completion(YES);
            } else {
                NSLog(@"[StartDiags] Failed to send 'go': %s", irecv_strerror(err));
                [self showLogsWithMessage:@"❌ Failed to start diagnostics"];
                if (completion) completion(NO);
            }
        });
    });
}

- (void)flowStep8_ReadSysCFG:(void(^)(BOOL))completion {
    self.currentFlowStep = 8;
    [self showLogsWithMessage:@"Reading SysCFG..."];
    
    // 等待设备启动诊断模式
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                  dispatch_get_main_queue(), ^{
        [self startSysCFGSessionWithSelectAll:YES];
        completion(YES);
    });
}

- (void)finishDiagnosticsFlow:(BOOL)success error:(NSString *)errorMsg {
    NSLog(@"[DiagController] 🏁 finishDiagnosticsFlow: %@ %@",
          success ? @"✅ SUCCESS" : @"❌ FAILED",
          errorMsg ?: @"");
    
    // ✅ 关键：流程结束后解锁设备，恢复 UI
    [self.parentTabsController unlockDeviceForSource:@"DiagController"
                                          withReason:success ? @"diagnostics completed" : @"diagnostics failed"];
    
    self.isDiagFlowRunning = NO;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        // 恢复 UI 状态
        self.runButton.enabled = YES;
        self.cancelButton.enabled = NO;
        
        // 显示结果

        if (success) {
            [self showLogsWithMessage:@"[SUC]Smart Diagnostics Completed!"];
            [[NSSound soundNamed:@"Glass"] play];
        } else {
            [self showLogsWithMessage:[NSString stringWithFormat:@"❌ Failed: %@", errorMsg ?: @"Unknown error"]];
            [[NSSound soundNamed:@"Basso"] play];
        }
    });
}


#pragma mark -  Diags CDC Serial 端口连接
- (IBAction)connectSerial:(id)sender {

    // ===== 已连接 → 执行断开 =====
    if (self.serialConnected) {
        [self disconnectSerial:nil];
        return;
    }

    // ===== 未连接 → 执行连接 =====
    NSString *path = (NSString *)self.portPopUpButton.selectedItem.representedObject;
    if (path.length == 0) {
        [self showLogsWithMessage:@"[ER] No serial port selected"];
        return;
    }

    NSInteger baudUI = self.speedPopUpButton
        ? self.speedPopUpButton.selectedItem.title.integerValue
        : 115200;
    speed_t baud = [self speedTFromInteger:baudUI];

    // ===== 启动连接动画 =====
    self.progressBar.hidden = NO;
    self.progressBar.style = NSProgressIndicatorStyleBar;
    self.progressBar.indeterminate = YES;
    [self.progressBar startAnimation:nil];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{

        BOOL ok = [self openSerialPath:path baud:baud];

        dispatch_async(dispatch_get_main_queue(), ^{

            // ===== 停止动画 =====
            [self.progressBar stopAnimation:nil];
            self.progressBar.indeterminate = NO;
            self.progressBar.doubleValue = 0.0;

            self.serialConnected = ok;

            if (ok) {
                [self showLogsWithMessage:@"[SUC] DCDC Serial established, Ready to read data"];
            } else {
                [self showLogsWithMessage:@"[ER] Serial connect failed"];
            }

            // ✅ 统一更新 UI
            [self updateSerialUI];
        });
    });
}

// 执行断开接口
- (IBAction)disconnectSerial:(id)sender {
    
    // ===== 切回 SysCFG =====
    self.consoleContentView.hidden = YES;
    self.toolsContentView.hidden = YES;
    self.syscfgContentView.hidden = NO;
    self.consoleVisible = NO;

    // 标题显示为 Console（表示“可以切到 Console”）
    self.onConsoleToggleButton.title = @"Console";

    // ✅ 切到 Console：恢复 terminal 图标（leading）
    self.onConsoleToggleButton.image = [NSImage imageNamed:@"terminal"];
    self.onConsoleToggleButton.imagePosition = NSImageLeft;
    
    // ✅ 自动清除读取的数据 Clear All
    [self onClearAll:nil];

    if (!self.serialConnected) return;

    [self closeSerialPort];
    self.serialConnected = NO;

    [self showLogsWithMessage:@"[WAR] Serial disconnected"];

    // ✅ 统一更新 UI
    [self updateSerialUI];
}

// 按照条件更新按钮状态
- (void)updateSerialUI {
    
    // ✅ 使用本地化字符串
    LanguageManager *lm = [LanguageManager sharedManager];
    
    self.syscfgKeyDisplayNames = @{
        @"Batt":  [lm localizedStringForKeys:@"SysCFG_Battery" inModule:@"Diag" defaultValue:@"Battery"],
        @"BMac":  [lm localizedStringForKeys:@"SysCFG_BluetoothMAC" inModule:@"Diag" defaultValue:@"Bluetooth MAC"],
        @"BCMS":  [lm localizedStringForKeys:@"SysCFG_BCMS" inModule:@"Diag" defaultValue:@"Back CAM SN"],
        @"DClr":  [lm localizedStringForKeys:@"SysCFG_DeviceColor" inModule:@"Diag" defaultValue:@"Device Color"],
        @"CLHS":  [lm localizedStringForKeys:@"SysCFG_CLHS" inModule:@"Diag" defaultValue:@"Housing Color"],
        @"EMac":  [lm localizedStringForKeys:@"SysCFG_EthernetMAC" inModule:@"Diag" defaultValue:@"Ethernet MAC"],
        @"FCMS":  [lm localizedStringForKeys:@"SysCFG_FCMS" inModule:@"Diag" defaultValue:@"Front  CAM SN"],
        @"LCM#":  [lm localizedStringForKeys:@"SysCFG_LCMNumber" inModule:@"Diag" defaultValue:@"LCD SN"],
        @"SrNm":  [lm localizedStringForKeys:@"SysCFG_SerialNumber" inModule:@"Diag" defaultValue:@"Serial Number"],
        @"MLB#":  [lm localizedStringForKeys:@"SysCFG_MLBNumber" inModule:@"Diag" defaultValue:@"Main Logicboard SN"],
        @"RMd#":  [lm localizedStringForKeys:@"SysCFG_RegionalModel" inModule:@"Diag" defaultValue:@"Regional Model"],
        @"Mod#":  [lm localizedStringForKeys:@"SysCFG_ModelNumber" inModule:@"Diag" defaultValue:@"Model Number"],
        @"MtSN":  [lm localizedStringForKeys:@"SysCFG_MtSN" inModule:@"Diag" defaultValue:@"Multitouch SN"],
        @"NvSn":  [lm localizedStringForKeys:@"SysCFG_NvSn" inModule:@"Diag" defaultValue:@"SandDollar SN"],
        @"NSrN":  [lm localizedStringForKeys:@"SysCFG_NSrN" inModule:@"Diag" defaultValue:@"Touch-ID SN"],
        @"Regn":  [lm localizedStringForKeys:@"SysCFG_Region" inModule:@"Diag" defaultValue:@"Region"],
        @"WMac":  [lm localizedStringForKeys:@"SysCFG_WiFiMAC" inModule:@"Diag" defaultValue:@"WiFi MAC"],
    };

    self.connectSerialButton.title =  self.serialConnected ? @"Disconnect" : @"Connect";

    if (self.serialConnected) {
        [self updateUIForState:DiagStateModemConnected];
    }
}

#pragma mark - SysCFG Display Name Helper

/**
 * 获取 syscfg key 的友好显示名称
 * @param key syscfg 原始 key（如 "Regn"）
 * @return 显示名称（如 "Region"），如果没有映射则返回原始 key
 */
- (NSString *)displayNameForSyscfgKey:(NSString *)key {
    if (!key || key.length == 0) return @"";
    
    // 从映射表中查找
    NSString *displayName = self.syscfgKeyDisplayNames[key];
    
    // 如果没有映射，返回原始 key
    return displayName ?: key;
}


- (BOOL)openSerialPath:(NSString *)path baud:(speed_t)baud {
    if (path.length == 0) return NO;

    // 如果已经打开了，先关
    [self closeSerialPort];

    self.serialPath = path;

    int fd = open(path.fileSystemRepresentation, O_RDWR | O_NOCTTY | O_NONBLOCK);
    if (fd < 0) {
        [self showLogsWithMessage:[NSString stringWithFormat:@"[ERR] open %@ failed: %d (%s)", path, errno, strerror(errno)]];
        return NO;
    }

    // 配置 termios
    struct termios tio;
    if (tcgetattr(fd, &tio) != 0) {
        [self showLogsWithMessage:[NSString stringWithFormat:@"[ERR] tcgetattr %@ failed: %d (%s)", path, errno, strerror(errno)]];
        close(fd);
        return NO;
    }

    cfmakeraw(&tio);
    tio.c_cflag |= (CLOCAL | CREAD);
    tio.c_cflag &= ~PARENB;
    tio.c_cflag &= ~CSTOPB;
    tio.c_cflag &= ~CSIZE;
    tio.c_cflag |= CS8;

    tio.c_iflag &= ~(IXON | IXOFF | IXANY);
#ifdef CRTSCTS
    tio.c_cflag &= ~CRTSCTS;
#endif

    if (cfsetispeed(&tio, baud) != 0 || cfsetospeed(&tio, baud) != 0) {
        [self showLogsWithMessage:[NSString stringWithFormat:@"[ERR] set speed %@ failed: %d (%s)", path, errno, strerror(errno)]];
        close(fd);
        return NO;
    }

    tio.c_cc[VMIN]  = 0;
    tio.c_cc[VTIME] = 1;

    if (tcsetattr(fd, TCSANOW, &tio) != 0) {
        [self showLogsWithMessage:[NSString stringWithFormat:@"[ERR] tcsetattr %@ failed: %d (%s)", path, errno, strerror(errno)]];
        close(fd);
        return NO;
    }

    self.serialFD = fd;
    [self.serialLineBuffer setLength:0];

    dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)self.serialFD, 0, self.serialQueue);
    self.serialReadSource = src;

    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(src, ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;

        uint8_t buf[4096];
        ssize_t n = read(self.serialFD, buf, sizeof(buf));
        if (n <= 0) return;

        // ✅ 批量追加所有数据
        [self.serialLineBuffer appendBytes:buf length:(NSUInteger)n];

        // ✅ 循环提取完整行
        while (YES) {
            // ⚠️ 每次循环都重新获取指针（因为buffer可能被修改）
            const uint8_t *bytes = (const uint8_t *)self.serialLineBuffer.bytes;
            NSUInteger totalLength = self.serialLineBuffer.length;
            
            if (totalLength == 0) break;
            
            // 查找第一个换行符
            NSUInteger lineEndIndex = NSNotFound;
            for (NSUInteger i = 0; i < totalLength; i++) {
                if (bytes[i] == '\n' || bytes[i] == '\r') {
                    lineEndIndex = i;
                    break;
                }
            }
            
            // 没找到完整行，等待下次数据
            if (lineEndIndex == NSNotFound) {
                // 防止缓冲区溢出
                if (totalLength > 8192) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self showLogsWithMessage:@"[WAR] Serial buffer overflow, clearing..."];
                    });
                    [self.serialLineBuffer setLength:0];
                }
                break;
            }
            
            // ✅ 提取行内容（不含换行符）
            NSData *lineData = [NSData dataWithBytes:bytes length:lineEndIndex];
            
            // ✅ 计算要移除的字节数（包括换行符）
            NSUInteger bytesToRemove = lineEndIndex + 1;
            
            // 跳过连续的 \r\n
            while (bytesToRemove < totalLength &&
                   (bytes[bytesToRemove] == '\n' || bytes[bytesToRemove] == '\r')) {
                bytesToRemove++;
            }
            
            // ✅ 使用 replaceBytesInRange 安全移除（不会使指针失效）
            [self.serialLineBuffer replaceBytesInRange:NSMakeRange(0, bytesToRemove)
                                             withBytes:NULL
                                                length:0];
            
            // 解码并处理
            if (lineData.length > 0) {
                NSString *line = [[NSString alloc] initWithData:lineData encoding:NSUTF8StringEncoding];
                if (!line) {
                    line = [NSString stringWithFormat:@"<%lu bytes binary>", (unsigned long)lineData.length];
                }
                
                // 主线程处理
                dispatch_async(dispatch_get_main_queue(), ^{
                    BOOL filtered = [self shouldFilterSerialLine:line];
                    NSString *cleanLine = [self cleanSerialLineForDisplay:line];

                    // ✅ 统一处理参数名前缀（Console 和主日志都用）
                    NSString *displayLine = cleanLine;
                    
                    if (self.currentExpectedSyscfgKey.length > 0 && !filtered) {
                        // 检查是否是真正的数据响应（排除命令回显、提示符等）
                        BOOL isSyscfgData = (![cleanLine hasPrefix:@"syscfg"] &&      // 不是命令
                                            ![cleanLine containsString:@":-)"]);      // 不是提示符
                        
                        if (isSyscfgData && cleanLine.length > 0) {
                            // ✅ 获取友好的显示名称
                            NSString *displayName = [self displayNameForSyscfgKey:self.currentExpectedSyscfgKey];
                            
                            // ✅ 如果是 MAC 地址，进行转换
                            NSString *valueToDisplay = cleanLine;
                            if ([self isMACAddressKey:self.currentExpectedSyscfgKey]) {
                                NSString *macAddr = [self convertHexToMAC:cleanLine];
                                if (macAddr) {
                                    valueToDisplay = macAddr;
                                }
                            }
                            
                            displayLine = [NSString stringWithFormat:@"%@: %@", displayName, valueToDisplay];
                        }
                    }

                    // 1) Console：显示
                    if (!filtered) {
                        [self appendConsoleText:[NSString stringWithFormat:@"[RX] %@\n", displayLine]];
                    }

                    // 2) SysCFG：始终解析 raw（保持当前逻辑）
                    [self onSerialTextReceived:line];

                    // 3) 主日志：Console 打开时可不刷
                    if (!self.consoleVisible && !filtered) {
                        // ✅ 关键修改：使用带参数名的 displayLine
                        [self showLogsWithMessage:displayLine];
                    }
                });

            }
        }
    });

    dispatch_source_set_cancel_handler(src, ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;

        if (self.serialFD >= 0) {
            close(self.serialFD);
            self.serialFD = -1;
        }
    });

    dispatch_resume(src);
    //连接到当前的usbmodem端口
    NSString *deviceConnectUSBmodem = path.lastPathComponent;
    
    // 去掉常见串口前缀
    if ([deviceConnectUSBmodem hasPrefix:@"cu."]) {
        deviceConnectUSBmodem = [deviceConnectUSBmodem substringFromIndex:3];
    } else if ([deviceConnectUSBmodem hasPrefix:@"tty."]) {
        deviceConnectUSBmodem = [deviceConnectUSBmodem substringFromIndex:4];
    }
    
    [self showLogsWithMessage:[NSString stringWithFormat:@"Connecting to port %@", deviceConnectUSBmodem]];
    return YES;
}

- (BOOL)openSerialPath000:(NSString *)path baud:(speed_t)baud {
    if (path.length == 0) return NO;

    // 如果已经打开了，先关
    [self closeSerialPort];

    self.serialPath = path;

    int fd = open(path.fileSystemRepresentation, O_RDWR | O_NOCTTY | O_NONBLOCK);
    if (fd < 0) {
        [self showLogsWithMessage:[NSString stringWithFormat:@"[ERR] open %@ failed: %d (%s)", path, errno, strerror(errno)]];
        return NO;
    }

    // 配置 termios
    struct termios tio;
    if (tcgetattr(fd, &tio) != 0) {
        [self showLogsWithMessage:[NSString stringWithFormat:@"[ERR] tcgetattr %@ failed: %d (%s)", path, errno, strerror(errno)]];
        close(fd);
        return NO;
    }

    cfmakeraw(&tio);
    tio.c_cflag |= (CLOCAL | CREAD);
    tio.c_cflag &= ~PARENB;
    tio.c_cflag &= ~CSTOPB;
    tio.c_cflag &= ~CSIZE;
    tio.c_cflag |= CS8;

    tio.c_iflag &= ~(IXON | IXOFF | IXANY);
#ifdef CRTSCTS
    tio.c_cflag &= ~CRTSCTS;
#endif

    if (cfsetispeed(&tio, baud) != 0 || cfsetospeed(&tio, baud) != 0) {
        [self showLogsWithMessage:[NSString stringWithFormat:@"[ERR] set speed %@ failed: %d (%s)", path, errno, strerror(errno)]];
        close(fd);
        return NO;
    }

    tio.c_cc[VMIN]  = 0;
    tio.c_cc[VTIME] = 1;

    if (tcsetattr(fd, TCSANOW, &tio) != 0) {
        [self showLogsWithMessage:[NSString stringWithFormat:@"[ERR] tcsetattr %@ failed: %d (%s)", path, errno, strerror(errno)]];
        close(fd);
        return NO;
    }

    self.serialFD = fd;
    [self.serialLineBuffer setLength:0];

    dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)self.serialFD, 0, self.serialQueue);
    self.serialReadSource = src;

    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(src, ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;

        uint8_t buf[4096];
        ssize_t n = read(self.serialFD, buf, sizeof(buf));
        if (n <= 0) return;

        // ✅ 批量追加所有数据
        [self.serialLineBuffer appendBytes:buf length:(NSUInteger)n];

        // ✅ 循环提取完整行
        while (YES) {
            // ⚠️ 每次循环都重新获取指针（因为buffer可能被修改）
            const uint8_t *bytes = (const uint8_t *)self.serialLineBuffer.bytes;
            NSUInteger totalLength = self.serialLineBuffer.length;
            
            if (totalLength == 0) break;
            
            // 查找第一个换行符
            NSUInteger lineEndIndex = NSNotFound;
            for (NSUInteger i = 0; i < totalLength; i++) {
                if (bytes[i] == '\n' || bytes[i] == '\r') {
                    lineEndIndex = i;
                    break;
                }
            }
            
            // 没找到完整行，等待下次数据
            if (lineEndIndex == NSNotFound) {
                // 防止缓冲区溢出
                if (totalLength > 8192) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self showLogsWithMessage:@"[WAR] Serial buffer overflow, clearing..."];
                    });
                    [self.serialLineBuffer setLength:0];
                }
                break;
            }
            
            // ✅ 提取行内容（不含换行符）
            NSData *lineData = [NSData dataWithBytes:bytes length:lineEndIndex];
            
            // ✅ 计算要移除的字节数（包括换行符）
            NSUInteger bytesToRemove = lineEndIndex + 1;
            
            // 跳过连续的 \r\n
            while (bytesToRemove < totalLength &&
                   (bytes[bytesToRemove] == '\n' || bytes[bytesToRemove] == '\r')) {
                bytesToRemove++;
            }
            
            // ✅ 使用 replaceBytesInRange 安全移除（不会使指针失效）
            [self.serialLineBuffer replaceBytesInRange:NSMakeRange(0, bytesToRemove)
                                             withBytes:NULL
                                                length:0];
            
            // 解码并处理
            if (lineData.length > 0) {
                NSString *line = [[NSString alloc] initWithData:lineData encoding:NSUTF8StringEncoding];
                if (!line) {
                    line = [NSString stringWithFormat:@"<%lu bytes binary>", (unsigned long)lineData.length];
                }
                
                // 主线程处理
                /*
                dispatch_async(dispatch_get_main_queue(), ^{
                    // ✅ 过滤设备提示符行（ECID + :-））
                    if (![self shouldFilterSerialLine:line]) {
                        // ✅ 清理ECID前缀后再显示
                        NSString *cleanLine = [self cleanSerialLineForDisplay:line];
                        [self showLogsWithMessage:cleanLine];
                    }
                    // ⚠️ 即使过滤显示，仍需要解析（SysCFG需要这些行做分隔）
                    [self onSerialTextReceived:line];
                });*/
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    // ✅ 关键修改：备份模式下直接传递原始数据，跳过过滤
                    if (self.syscfgBackupInProgress) {
                        // 备份模式：直接收集原始数据，不过滤、不显示
                        [self onSerialTextReceived:line];
                        return;
                    }
                    
                    BOOL filtered = [self shouldFilterSerialLine:line];
                    NSString *cleanLine = [self cleanSerialLineForDisplay:line];

                    // 1) Console：显示（建议同样尊重过滤，避免 syscfg print 命令刷屏）
                    if (!filtered) {
                        NSString *displayLine = cleanLine;
                        
                        if (self.currentExpectedSyscfgKey.length > 0) {
                            // 检查是否是真正的数据响应（排除命令回显、提示符等）
                            BOOL isSyscfgData = (![cleanLine hasPrefix:@"syscfg"] &&      // 不是命令
                                                ![cleanLine containsString:@":-)"]);      // 不是提示符
                            
                            if (isSyscfgData && cleanLine.length > 0) {
                                // ✅ 使用友好的显示名称
                                NSString *displayName = [self displayNameForSyscfgKey:self.currentExpectedSyscfgKey];
                                displayLine = [NSString stringWithFormat:@"%@: %@", displayName, cleanLine];
                            }
                        }
                        
                        [self appendConsoleText:[NSString stringWithFormat:@"[RX] %@\n", displayLine]];
                    }

                    // 2) SysCFG：始终解析 raw（保持你当前逻辑）
                    [self onSerialTextReceived:line];

                    // 3) 主日志：Console 打开时可不刷
                    if (!self.consoleVisible && !filtered) {
                        [self showLogsWithMessage:cleanLine];
                    }
                });

            }
        }
    });

    dispatch_source_set_cancel_handler(src, ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;

        if (self.serialFD >= 0) {
            close(self.serialFD);
            self.serialFD = -1;
        }
    });

    dispatch_resume(src);
    //连接到当前的usbmodem端口
    NSString *deviceConnectUSBmodem = path.lastPathComponent;
    
    // 去掉常见串口前缀
    if ([deviceConnectUSBmodem hasPrefix:@"cu."]) {
        deviceConnectUSBmodem = [deviceConnectUSBmodem substringFromIndex:3];
    } else if ([deviceConnectUSBmodem hasPrefix:@"tty."]) {
        deviceConnectUSBmodem = [deviceConnectUSBmodem substringFromIndex:4];
    }
    
    [self showLogsWithMessage:[NSString stringWithFormat:@"Connecting to port %@", deviceConnectUSBmodem]];
    return YES;
}

- (void)onSerialTextReceived:(NSString *)text {
    if (!self.syscfgListening) return;

    // ✅ 调试：备份模式下打印接收的数据
    if (self.syscfgBackupInProgress) {
        static NSInteger lineCount = 0;
        if (lineCount < 10) {  // 只打印前10行
            NSLog(@"[BACKUP RX %ld] %@", (long)lineCount++, text);
        }
    }
    
    // 拼成连续流（保留换行，帮助 suffix 匹配）
    [self.syscfgStream appendString:text];
    [self.syscfgStream appendString:@"\n"];

    // ✅ 备份模式：只收集数据，不提取packet
    if (self.syscfgBackupInProgress) {
        return;  // 备份模式下直接返回，等超时后统一处理
    }
    
    // 尝试从 stream 中提取一个或多个 syscfg packet（仅非备份模式）
    [self extractSysCFGPacketsFromStream];
}

- (void)extractSysCFGPacketsFromStream {
    NSString *stream = self.syscfgStream;
    NSString *prefix = @"syscfg";
    NSString *suffix = self.syscfgSuffix ?: @"\n[";

    while (YES) {
        NSRange p = [stream rangeOfString:prefix];
        if (p.location == NSNotFound) break;

        NSRange s = [stream rangeOfString:suffix options:0 range:NSMakeRange(p.location, stream.length - p.location)];
        if (s.location == NSNotFound) break;

        NSUInteger end = s.location + s.length;
        NSString *packet = [stream substringWithRange:NSMakeRange(p.location, end - p.location)];

        // 消费掉已解析部分（保留后面的内容）
        NSString *remaining = [stream substringFromIndex:end];
        [self.syscfgStream setString:remaining];
        stream = self.syscfgStream;

        [self handleSysCFGPacket:packet];
    }

    // 防止无限增长
    if (self.syscfgStream.length > 20000) {
        [self.syscfgStream deleteCharactersInRange:NSMakeRange(0, self.syscfgStream.length - 2000)];
    }
}

- (void)handleSysCFGPacket:(NSString *)packet {
    // packet 是 prefix=syscfg 到 suffix=:-) 的一段文本
    NSArray<NSString *> *lines = [packet componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];

    NSString *key = nil;
    NSMutableArray<NSString *> *content = [NSMutableArray array];

    for (NSString *raw in lines) {
        NSString *line = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (line.length == 0) continue;

        // 忽略结尾标记行
        if ([line containsString:@"----"]) continue;

        // 识别命令行：syscfg print XXX
        if ([line hasPrefix:@"syscfg print "]) {
            key = [[line substringFromIndex:[@"syscfg print " length]]
                   stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            continue;
        }

        // 忽略带 ECID 的前缀噪声，比如：[000C7916:1031A526] :-) syscfg print MLB#
        // 如果里面包含 "syscfg print "，也能提取 key
        NSRange r = [line rangeOfString:@"syscfg print "];
        if (r.location != NSNotFound) {
            NSString *k = [[line substringFromIndex:(r.location + r.length)]
                           stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (k.length > 0) key = k;
            continue;
        }

        // 有些 value 行带 "Serial:" 前缀
        [content addObject:line];
    }

    if (key.length == 0) return;

    NSString *value = [self syscfgValueFromContentLines:content forKey:key];
    if (!value) value = @"";

    self.syscfgValues[key] = value;
    //[self showLogsWithMessage:[NSString stringWithFormat:@"[SUC] %@ = %@", key, value]];
    NSLog(@"[SUC] %@ = %@", key, value);

    // 填 UI
    [self applySyscfgValue:value forKey:key];
}


- (NSString *)syscfgValueFromContentLines:(NSArray<NSString *> *)content forKey:(NSString *)key {
    // content 里包含了 packet 中除命令行/:-) 之外的所有行
    // 对不同 key 做最小规则

    if (content.count == 0) return @"";

    // SrNm 的 value 是 "Serial: XXX"
    if ([key isEqualToString:@"SrNm"]) {
        for (NSString *line in content) {
            if ([line hasPrefix:@"Serial:"]) {
                NSString *v = [[line substringFromIndex:[@"Serial:" length]]
                               stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                return v ?: @"";
            }
        }
        // 没有 Serial: 就取第一行
        return content.firstObject ?: @"";
    }

    // 其它 key（MLB#, Mod#, Regn）看你日志就是“直接一行值”
    // 但可能 content 里会混入别的噪声，所以取“最像值”的那一行：最后一行通常最稳
    NSString *last = content.lastObject ?: @"";
    // 如果最后一行还是像 "[000C....]" 这种，往前找
    for (NSInteger i = (NSInteger)content.count - 1; i >= 0; i--) {
        NSString *line = content[i];
        if ([line hasPrefix:@"["]) continue;
        if ([line containsString:@"syscfg"]) continue;
        if (line.length == 0) continue;
        return line;
    }
    return last;
}

#pragma mark - ✅ 串口行过滤
- (BOOL)shouldFilterSerialLine:(NSString *)line {
    if (line.length == 0) return YES; // 空行过滤
    
    NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) return YES;
    
    // ✅ 1. 过滤syscfg命令行（用户发送的命令，不应该显示）
    if ([trimmed hasPrefix:@"syscfg "]) {
        NSLog(@"[FILTER] Filtering syscfg command: %@", trimmed);
        return YES;  // 过滤命令行
    }
    
    // ✅ 2. ANSI颜色代码过滤
    BOOL hasANSIStart = ([trimmed rangeOfString:@"[0;"].location != NSNotFound ||
                         [trimmed rangeOfString:@"[1;"].location != NSNotFound ||
                         [trimmed rangeOfString:@"[3"].location != NSNotFound ||
                         [trimmed rangeOfString:@"[4"].location != NSNotFound);
    
    BOOL hasANSIEnd = ([trimmed rangeOfString:@"[m"].location != NSNotFound ||
                       [trimmed rangeOfString:@"[0m"].location != NSNotFound);
    
    if (hasANSIStart && hasANSIEnd) {
        NSRange mRange = [trimmed rangeOfString:@"m"];
        if (mRange.location > 2) {
            unichar charBeforeM = [trimmed characterAtIndex:mRange.location - 1];
            if ((charBeforeM >= '0' && charBeforeM <= '9') || charBeforeM == ';') {
                NSLog(@"[FILTER] Filtering ANSI line: %@", trimmed);
                return YES;
            }
        }
    }
    
    // ✅ 3. 过滤ECID提示符行
    if ([trimmed containsString:@"["] &&
        [trimmed containsString:@"]"] &&
        [trimmed containsString:@":-)"]) {
        
        NSRange smileyRange = [trimmed rangeOfString:@"-----"];
        if (smileyRange.location != NSNotFound) {
            NSUInteger afterSmiley = smileyRange.location + smileyRange.length;
            NSString *afterContent = (afterSmiley < trimmed.length)
                ? [[trimmed substringFromIndex:afterSmiley] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
                : @"";
            
            if (afterContent.length > 0) {
                return NO; // 保留命令行
            }
        }
        
        NSLog(@"[FILTER] Filtering ECID prompt: %@", trimmed);
        return YES;
    }
    
    return NO; // 不过滤其他行
}


- (NSString *)cleanSerialLineForDisplay:(NSString *)line {
    if (line.length == 0) return line;
    
    NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    
    // ✅ 清理 "[ECID] :-) syscfg print XXX" → "syscfg print XXX"
    if ([trimmed containsString:@":-)"]) {
        NSRange smileyRange = [trimmed rangeOfString:@":-)"];
        if (smileyRange.location != NSNotFound) {
            NSUInteger afterSmiley = smileyRange.location + smileyRange.length;
            if (afterSmiley < trimmed.length) {
                NSString *afterContent = [[trimmed substringFromIndex:afterSmiley]
                                          stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if (afterContent.length > 0) {
                    return afterContent; // 返回清理后的内容
                }
            }
        }
    }
    
    return line; // 其他行原样返回
}

- (void)closeSerialPort {
    // ✅ 只 cancel source，fd 交给 cancel_handler 关闭，避免 double close
    dispatch_source_t src = self.serialReadSource;
    self.serialReadSource = nil;

    if (src) {
        dispatch_source_cancel(src);
    }

    [self.serialLineBuffer setLength:0];
}


- (speed_t)speedTFromInteger:(NSInteger)baud {
    switch (baud) {
        case 9600: return B9600;
        case 19200: return B19200;
        case 38400: return B38400;
        case 57600: return B57600;
        case 115200: return B115200;
#ifdef B230400
        case 230400: return B230400;
#endif
#ifdef B460800
        case 460800: return B460800;
#endif
#ifdef B921600
        case 921600: return B921600;
#endif
        default:
            return B115200; // 常用默认
    }
}


- (BOOL)serialWriteLine:(NSString *)line appendCRLF:(BOOL)crlf {
    if (line.length == 0) return NO;

    NSMutableData *d = [[line dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    if (crlf) {
        uint8_t tail[2] = {0x0D, 0x0A}; // \r\n
        [d appendBytes:tail length:2];
    } else {
        uint8_t tail[1] = {0x0A}; // \n
        [d appendBytes:tail length:1];
    }

    BOOL ok = [self serialWriteData:d];
    NSLog(@"[TX] %@ %@", ok ? @"OK" : @"FAIL", line);
    return ok;
}

- (BOOL)serialWriteData:(NSData *)data {
    if (self.serialFD < 0 || data.length == 0) return NO;

    const uint8_t *p = data.bytes;
    ssize_t left = (ssize_t)data.length;

    while (left > 0) {
        ssize_t n = write(self.serialFD, p, (size_t)left);
        if (n < 0) {
            if (errno == EINTR) continue;
            [self showLogsWithMessage:[NSString stringWithFormat:@"[ER] write failed: %d (%s)", errno, strerror(errno)]];
            return NO;
        }
        left -= n;
        p += n;
    }
    return YES;
}


#pragma mark - 统一的SysCFG Keys

// ✅ 统一 keys：selectAll=YES 返回全量；否则根据 checkbox 返回选中项
- (NSArray<NSString *> *)selectedSyscfgKeys:(BOOL)selectAll
{
    if (selectAll) {
        return @[
            @"Batt", @"BMac", @"BCMS",
            @"DClr", @"CLHS",
            @"EMac", @"FCMS", @"LCM#",
            @"SrNm", @"MLB#", @"RMd#",
            @"Mod#", @"MtSN", @"NvSn",
            @"NSrN", @"Regn", @"WMac",
        ];
    }

    NSMutableArray<NSString *> *keys = [NSMutableArray array];

    if (self.batteryCheckbox.state == NSControlStateValueOn) [keys addObject:@"Batt"];
    if (self.bmacCheckbox.state    == NSControlStateValueOn) [keys addObject:@"BMac"];
    if (self.bcmsCheckbox.state    == NSControlStateValueOn) [keys addObject:@"BCMS"];
    if (self.colorCheckbox.state   == NSControlStateValueOn) [keys addObject:@"DClr"];
    if (self.CLHSCheckbox.state    == NSControlStateValueOn) [keys addObject:@"CLHS"];
    if (self.emacCheckbox.state    == NSControlStateValueOn) [keys addObject:@"EMac"];
    if (self.fcmsCheckbox.state    == NSControlStateValueOn) [keys addObject:@"FCMS"];
    if (self.lcmCheckbox.state     == NSControlStateValueOn) [keys addObject:@"LCM#"];
    if (self.snCheckbox.state      == NSControlStateValueOn) [keys addObject:@"SrNm"];
    if (self.mlbCheckbox.state     == NSControlStateValueOn) [keys addObject:@"MLB#"];
    if (self.modeCheckbox.state    == NSControlStateValueOn) [keys addObject:@"RMd#"];
    if (self.modelCheckbox.state   == NSControlStateValueOn) [keys addObject:@"Mod#"];
    if (self.mtsnCheckbox.state    == NSControlStateValueOn) [keys addObject:@"MtSN"];
    if (self.nvsnCheckbox.state    == NSControlStateValueOn) [keys addObject:@"NvSn"];
    if (self.nsrnCheckbox.state    == NSControlStateValueOn) [keys addObject:@"NSrN"];
    if (self.regionCheckbox.state  == NSControlStateValueOn) [keys addObject:@"Regn"];
    if (self.wifiCheckbox.state    == NSControlStateValueOn) [keys addObject:@"WMac"];

    return keys;
}

- (void)applySyscfgValue:(NSString *)val forKey:(NSString *)key
{
    if (val == nil) val = @"";
    NSString *trim = [val stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    // 一些设备会回 [0;31mNot Found![m 这种 ANSI，先简单去掉
    trim = [self stringByStrippingANSIEscapes:trim];
    
    // ✅ 如果是 MAC 地址类型，尝试转换
    if ([self isMACAddressKey:key]) {
        NSString *macAddr = [self convertHexToMAC:trim];
        if (macAddr) {
            trim = macAddr; // 使用转换后的 MAC 地址
        }
    }

    if ([key isEqualToString:@"Batt"]) {
        self.batteryTextField.stringValue = trim;
    } else if ([key isEqualToString:@"BCMS"]) {
        self.bcmsTextField.stringValue = trim;
    } else if ([key isEqualToString:@"BMac"]) {
        self.bmacTextField.stringValue = trim;
    } else if ([key isEqualToString:@"DClr"]) {
        // 你的颜色是 NSPopUpButton：这里可以先把原始值显示到 colorTextField（如果你有）
        // 或者把 popup 选中项映射
        // 先简单：如果 trim 能映射到 popup 就选中，否则忽略
        NSInteger idx = [self.colorPopup indexOfItemWithTitle:trim];
        if (idx >= 0) [self.colorPopup selectItemAtIndex:idx];
        // 如果你想把原始值也显示在某个文本框（你有 colorTextField? 但类型是 NSPopUpButton）
        // self.colorTextField.title = trim;
    } else if ([key isEqualToString:@"CLHS"]) {
        self.CLHSTextField.stringValue = trim;
    } else if ([key isEqualToString:@"EMac"]) {
        self.emacTextField.stringValue = trim;
    } else if ([key isEqualToString:@"FCMS"]) {
        self.fcmsTextField.stringValue = trim;
    } else if ([key isEqualToString:@"LCM#"]) {
        self.lcmTextField.stringValue = trim;
    } else if ([key isEqualToString:@"SrNm"]) {
        self.snTextField.stringValue = trim;
    } else if ([key isEqualToString:@"MLB#"]) {
        self.mlbTextField.stringValue = trim;
    } else if ([key isEqualToString:@"Mod#"]) {
        self.modelTextField.stringValue = trim;
    } else if ([key isEqualToString:@"MtSN"]) {
        self.mtsnTextField.stringValue = trim;
    } else if ([key isEqualToString:@"NvSn"]) {
        self.nvsnTextField.stringValue = trim;
    } else if ([key isEqualToString:@"NSrN"]) {
        self.nsrnTextField.stringValue = trim;
    } else if ([key isEqualToString:@"Regn"]) {
        self.regionTextField.stringValue = trim;
    } else if ([key isEqualToString:@"RMd#"]) {
        // 你 UI 里“Mode”对应哪个 key，要看你定义
        // 你 readSysCFGAll 里用 RMd#，那就填到 modeTextField
        self.modeTextField.stringValue = trim;
    } else if ([key isEqualToString:@"WMac"]) {
        self.wifiTextField.stringValue = trim;
    } else {
        [self showLogsWithMessage:[NSString stringWithFormat:@"[SysCFG][Unmapped] %@ = %@", key, trim]];
    }
}

- (NSString *)stringByStrippingANSIEscapes:(NSString *)s
{
    if (s.length == 0) return s;
    // 超简版：去掉 ESC[
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"\\x1B\\[[0-9;]*[A-Za-z]" options:0 error:nil];
    return [re stringByReplacingMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:@""];
}

#pragma mark - ✅ SysCFG UI 初始化

- (void)setupSysCFGUI {
    // 设置颜色下拉菜单
    [self.colorPopup removeAllItems];
    [self.colorPopup addItemsWithTitles:@[
        @"Color",  // placeholder
        @"Black", @"White", @"Silver", @"Gold",
        @"Rose Gold", @"Red", @"Blue", @"Green"
    ]];
    
    // 设置所有复选框为未选中
    [self onDeselectAll:nil];
}


#pragma mark - SysCFG Session (Common)

/// ✅ 统一启动 SysCFG 读取 session（All/Selected 都走这里）
- (void)startSysCFGSessionWithSelectAll:(BOOL)selectAll
{
    if (self.serialFD < 0) {
        [self showLogsWithMessage:@"[ER] Serial not connected"];
        [self updateProgress:0.0];
        return;
    }

    NSArray<NSString *> *keys = [self selectedSyscfgKeys:selectAll];
    if (keys.count == 0) {
        NSLog(@"[DiagController] ⚠️ 未选择任何项，未读取 SysCFG");
        return;
    }

    // ✅ 开始 SysCFG：先给一个起步进度（承接 connectSerial 的 15%）
    [self updateProgress:20.0];

    self.syscfgListening = YES;
    [self.syscfgStream setString:@""];
    [self.syscfgValues removeAllObjects];

    self.syscfgSuffix = @"\n[";

    [self showLogsWithMessage:@"Session started (listening packets)..."];

    self.pendingSyscfgKeys = [keys mutableCopy];
    self.currentSyscfgKey = nil;

    // ✅ 进度条区间：20% ~ 95% 用于发送/读取过程
    const double startP = 20.0;
    const double endP   = 95.0;
    const double span   = (endP - startP);
    const NSInteger total = (NSInteger)keys.count;

    __block NSInteger idx = 0;
    __weak typeof(self) weakSelf = self;

    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(t,
                              dispatch_time(DISPATCH_TIME_NOW, 0),
                              (uint64_t)(0.12 * NSEC_PER_SEC),
                              (uint64_t)(0.02 * NSEC_PER_SEC));

    dispatch_source_set_event_handler(t, ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) { dispatch_source_cancel(t); return; }

        if (idx >= total) {
            dispatch_source_cancel(t);
            return;
        }

        NSString *k = keys[idx++];
        NSString *cmd = [NSString stringWithFormat:@"syscfg print %@", k];
        
        // ✅ 记录当前期待的 key
        self.currentExpectedSyscfgKey = k;
        
        [self serialWriteLine:cmd appendCRLF:YES];

        // ✅ 每发送一个 key 就推进进度（线性）
        double p = startP + (span * ((double)idx / (double)total));
        [self updateProgress:p];
    });

    dispatch_resume(t);

    // 超时：每条 0.12s + 额外 buffer
    NSTimeInterval timeout = 1.0 + keys.count * 0.12 + 2.0;
    [self stopSysCFGSessionAfter:timeout];

    // ✅ UI 回填：仍然放在你 stopSysCFGSessionAfter / packet 完成的收尾里做
}


- (void)stopSysCFGSessionAfter:(NSTimeInterval)seconds {
    if (self.syscfgTimeoutTimer) {
        dispatch_source_cancel(self.syscfgTimeoutTimer);
        self.syscfgTimeoutTimer = nil;
    }

    dispatch_queue_t q = dispatch_get_main_queue();
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    self.syscfgTimeoutTimer = t;

    dispatch_source_set_timer(t,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)),
                              DISPATCH_TIME_FOREVER,
                              (uint64_t)(0.05 * NSEC_PER_SEC));

    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(t, ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;

        [self endSysCFGSession];
    });

    dispatch_resume(t);
}

- (void)endSysCFGSession {
    if (!self.syscfgListening) return;
    self.syscfgListening = NO;

    if (self.syscfgTimeoutTimer) {
        dispatch_source_cancel(self.syscfgTimeoutTimer);
        self.syscfgTimeoutTimer = nil;
    }

    // ✅ 清除当前期待的 key
    self.currentExpectedSyscfgKey = nil;

    [self showLogsWithMessage:@"[SUC]System Configuration session ended"];
    // ✅ 会话结束：进度条拉满
    [self updateProgress:100.0];
}


#pragma mark - ✅ SysCFG 读取

// Read All：逻辑全选（不依赖 UI checkbox 当前状态）
- (IBAction)readSysCFGAll:(id)sender
{
    [self startSysCFGSessionWithSelectAll:YES];
}

// Read Selected：只读勾选项
- (IBAction)onReadSysCFG:(id)sender
{
    [self startSysCFGSessionWithSelectAll:NO];
}



#pragma mark - ✅ SysCFG 写入

// 单个参数写入
- (IBAction)onWriteSingleSysCFG:(id)sender {
    
    if (self.serialFD < 0) {
        [self showLogsWithMessage:@"[ER] Serial not connected"];
        return;
    }
    
    NSButton *btn = (NSButton *)sender;
    NSString *param = @"Unknown";
    NSString *value = @"";
    
    // 按钮及对应的 Syscfg add 参数和值
    if (btn == self.batteryWriteButton) {
        param = @"Batt";
        value = self.batteryTextField.stringValue;
    }
    else if (btn == self.bcmsWriteButton) {
        param = @"BCMS";
        value = self.bcmsTextField.stringValue;
    }
    else if (btn == self.bmacWriteButton) {
        param = @"BMac";
        value = self.bmacTextField.stringValue;
    }
    else if (btn == self.emacWriteButton) {
        param = @"EMac";
        value = self.emacTextField.stringValue;
    }
    else if (btn == self.CLHSWriteButton) {
        param = @"CLHS";
        value = self.CLHSTextField.stringValue;
    }
    else if (btn == self.fcmsWriteButton) {
        param = @"FCMS";
        value = self.fcmsTextField.stringValue;
    }
    else if (btn == self.lcmWriteButton) {
        param = @"LCM#";
        value = self.lcmTextField.stringValue;
    }
    else if (btn == self.modeWriteButton) {
        param = @"RMd#";
        value = self.modeTextField.stringValue;
    }
    else if (btn == self.modelWriteButton) {
        param = @"Mod#";
        value = self.modelTextField.stringValue;
    }
    else if (btn == self.mlbWriteButton) {
        param = @"MLB#";
        value = self.mlbTextField.stringValue;
    }
    else if (btn == self.mtsnWriteButton) {
        param = @"MtSN";
        value = self.mtsnTextField.stringValue;
    }
    else if (btn == self.nsrnWriteButton) {
        param = @"NSrN";
        value = self.nsrnTextField.stringValue;
    }
    else if (btn == self.nvsnWriteButton) {
        param = @"NvSn";
        value = self.nvsnTextField.stringValue;
    }
    else if (btn == self.regionWriteButton) {
        param = @"Regn";
        value = self.regionTextField.stringValue;
    }
    else if (btn == self.snWriteButton) {
        param = @"SrNm";
        value = self.snTextField.stringValue;
    }
    else if (btn == self.wifiWriteButton) {
        param = @"WMac";
        value = self.wifiTextField.stringValue;
    }
    else {
        // 未识别的按钮
        [self showLogsWithMessage:@"[ER] Unknown write button"];
        return;
    }
    
    // 去除首尾空格
    value = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    
    // 立即检查值是否为空（在任何处理之前）
    if (!value || value.length == 0) {
        [self showLogsWithMessage:[NSString stringWithFormat:@"[WAR] %@ value is empty, skipped", param]];
        NSBeep(); // 发出提示音
        return;
    }
    
    // 如果是 MAC 地址类型，转换回十六进制格式
    if ([self isMACAddressKey:param]) {
        NSString *hexFormat = [self convertMACToHex:value];
        if (hexFormat) {
            // 显示转换信息
            NSLog(@"[WAR] Converting %@ MAC: %@ → %@", param, value, hexFormat);
            value = hexFormat; // 使用转换后的十六进制格式
        } else {
            // 转换失败
            [self showLogsWithMessage:[NSString stringWithFormat:@"[ER] Invalid MAC format for %@: %@",
                param, value]];
            NSBeep(); // 发出提示音
            return;
        }
    }
    
    // 再次检查转换后的值（MAC 转换后理论上不会为空，但做双重保险）
    if (!value || value.length == 0) {
        [self showLogsWithMessage:[NSString stringWithFormat:@"[ER] %@ converted value is empty", param]];
        NSBeep();
        return;
    }
    
    // 显示写入信息
    [self showLogsWithMessage:[NSString stringWithFormat:@"[WAR] Writing %@ data...", param]];
    
    // 构建并发送命令
    NSString *cmd = [NSString stringWithFormat:@"syscfg add %@ %@", param, value];
    NSLog(@"[DiagController] 写入命令: %@", cmd);
    [self serialWriteLine:cmd appendCRLF:YES];
}



#pragma mark - 📖 SysCFG 单个参数读取

- (IBAction)onReadSingleSysCFG:(id)sender {
    if (self.serialFD < 0) {
        [self showLogsWithMessage:@"[ER] Serial not connected"];
        return;
    }
    
    NSButton *btn = (NSButton *)sender;
    NSString *param = nil;
    
    // ✅ 根据按钮确定参数名（syscfg key）
    if (btn == self.batteryReadButton) param = @"Batt";
    else if (btn == self.bcmsReadButton) param = @"BCMS";
    else if (btn == self.bmacReadButton) param = @"BMac";
    else if (btn == self.colorReadButton) param = @"DClr";
    else if (btn == self.CLHSReadButton) param = @"CLHS";
    else if (btn == self.emacReadButton) param = @"EMac";
    else if (btn == self.fcmsReadButton) param = @"FCMS";
    else if (btn == self.lcmReadButton) param = @"LCM#";
    else if (btn == self.modeReadButton) param = @"RMd#";
    else if (btn == self.modelReadButton) param = @"Mod#";
    else if (btn == self.mlbReadButton) param = @"MLB#";
    else if (btn == self.mtsnReadButton) param = @"MtSN";
    else if (btn == self.nsrnReadButton) param = @"NSrN";
    else if (btn == self.nvsnReadButton) param = @"NvSn";
    else if (btn == self.regionReadButton) param = @"Regn";
    else if (btn == self.snReadButton) param = @"SrNm";
    else if (btn == self.wifiReadButton) param = @"WMac";
    else {
        [self showLogsWithMessage:@"[ER] Unknown read button"];
        return;
    }
    
    if (!param || param.length == 0) {
        [self showLogsWithMessage:@"[ER] Invalid parameter"];
        return;
    }
    
    // ✅ 关键：启用监听模式
    self.syscfgListening = YES;
    [self.syscfgStream setString:@""];
    self.syscfgSuffix = @"\n[";
    
    // ✅ 设置当前期待的参数（用于接收数据时识别）
    self.currentExpectedSyscfgKey = param;
    
    // ✅ 发送读取命令（只需参数名，不需要值）
    NSString *cmd = [NSString stringWithFormat:@"syscfg print %@", param];
    [self serialWriteLine:cmd appendCRLF:YES];
    
    // ✅ 显示友好的日志信息
    NSString *displayName = [self displayNameForSyscfgKey:param];
    [self showLogsWithMessage:[NSString stringWithFormat:@"Reading %@ data...", displayName]];
    
    // ✅ 设置超时：1秒后自动停止监听
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (self.currentExpectedSyscfgKey && [self.currentExpectedSyscfgKey isEqualToString:param]) {
            self.syscfgListening = NO;
            self.currentExpectedSyscfgKey = nil;
        }
    });
}


#pragma mark - ✅ 单多选择后SysCFG 写入
- (IBAction)onWriteSelectedSysCFG:(id)sender
{
    if (self.serialFD < 0) {
        [self showLogsWithMessage:@"[ER] Serial not connected"];
        return;
    }

    [self showLogsWithMessage:@"\n[WAR] Writing selected system configuration..."];

    // value getter
    NSString* (^trimmed)(NSString *s) = ^NSString* (NSString *s) {
        NSString *v = s ?: @"";
        return [v stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    };

    // ✅ 同一张表：checkbox + key + 如何从 UI 取值
    NSArray<NSDictionary *> *items = @[
        @{@"chk": self.batteryCheckbox, @"key": @"Batt",
          @"get": ^NSString *{ return self.batteryTextField.stringValue; }},

        @{@"chk": self.bcmsCheckbox, @"key": @"BCMS",
          @"get": ^NSString *{ return self.bcmsTextField.stringValue; }},

        @{@"chk": self.bmacCheckbox, @"key": @"BMac",
          @"get": ^NSString *{ return self.bmacTextField.stringValue; }},

        // Color：popup
        @{@"chk": self.colorCheckbox, @"key": @"DClr",
          @"get": ^NSString *{ return self.colorPopup.selectedItem.title; }},

        @{@"chk": self.CLHSCheckbox, @"key": @"CLHS",
          @"get": ^NSString *{ return self.CLHSTextField.stringValue; }},

        @{@"chk": self.emacCheckbox, @"key": @"EMac",
          @"get": ^NSString *{ return self.emacTextField.stringValue; }},

        @{@"chk": self.fcmsCheckbox, @"key": @"FCMS",
          @"get": ^NSString *{ return self.fcmsTextField.stringValue; }},

        @{@"chk": self.lcmCheckbox, @"key": @"LCM#",
          @"get": ^NSString *{ return self.lcmTextField.stringValue; }},

        @{@"chk": self.modeCheckbox, @"key": @"RMd#",
          @"get": ^NSString *{ return self.modeTextField.stringValue; }},

        @{@"chk": self.modelCheckbox, @"key": @"Mod#",
          @"get": ^NSString *{ return self.modelTextField.stringValue; }},

        @{@"chk": self.mlbCheckbox, @"key": @"MLB#",
          @"get": ^NSString *{ return self.mlbTextField.stringValue; }},

        @{@"chk": self.mtsnCheckbox, @"key": @"MtSN",
          @"get": ^NSString *{ return self.mtsnTextField.stringValue; }},

        @{@"chk": self.nsrnCheckbox, @"key": @"NSrN",
          @"get": ^NSString *{ return self.nsrnTextField.stringValue; }},

        @{@"chk": self.nvsnCheckbox, @"key": @"NvSn",
          @"get": ^NSString *{ return self.nvsnTextField.stringValue; }},

        @{@"chk": self.regionCheckbox, @"key": @"Regn",
          @"get": ^NSString *{ return self.regionTextField.stringValue; }},

        @{@"chk": self.snCheckbox, @"key": @"SrNm",
          @"get": ^NSString *{ return self.snTextField.stringValue; }},

        @{@"chk": self.wifiCheckbox, @"key": @"WMac",
          @"get": ^NSString *{ return self.wifiTextField.stringValue; }},
    ];

    // ✅ 组装 jobs（只取勾选且非空）
    NSMutableArray<NSDictionary *> *jobs = [NSMutableArray array];

    for (NSDictionary *it in items) {
        NSButton *chk = it[@"chk"];
        if (chk.state != NSControlStateValueOn) continue;

        NSString *key = it[@"key"];
        NSString* (^get)(void) = it[@"get"];

        NSString *val = trimmed(get ? get() : @"");
        if (val.length == 0) {
            [self showLogsWithMessage:[NSString stringWithFormat:@"[WAR] Skip %@ (empty)", key]];
            continue;
        }

        // ✅ 保存原始值用于显示
        NSString *displayValue = val;

        // ✅ 如果是 MAC 地址类型，转换回十六进制格式
        if ([self isMACAddressKey:key]) {
            NSString *hexFormat = [self convertMACToHex:val];
            if (hexFormat) {
                // 显示转换信息
                NSLog(@"[DiagController] Converting %@ MAC: %@ → %@", key, val, hexFormat);
                val = hexFormat; // 使用转换后的十六进制格式
            } else {
                // 转换失败，跳过此项
                [self showLogsWithMessage:[NSString stringWithFormat:@"[WAR] Skip %@ (invalid MAC: %@)", key, val]];
                continue;
            }
        }

        [jobs addObject:@{@"key": key, @"value": val, @"display": displayValue}];
    }

    if (jobs.count == 0) {
        [self showLogsWithMessage:@"[WAR] No parameters selected (or values bad/empty)"];
        return;
    }

    // ✅ 显示将要写入的参数列表
    NSMutableArray *pretty = [NSMutableArray arrayWithCapacity:jobs.count];
    for (NSDictionary *j in jobs) {
        [pretty addObject:j[@"key"]];
    }
    [self showLogsWithMessage:[NSString stringWithFormat:@"[WAR] Will write %ld parameters: %@",
        (long)jobs.count, [pretty componentsJoinedByString:@", "]]];

    // ✅ 逐条发送，避免输出粘连
    __block NSInteger idx = 0;
    __block NSInteger totalCount = (NSInteger)jobs.count;
    __weak typeof(self) weakSelf = self;

    __block void (^sendNext)(void) = nil;
    __weak void (^weakSendNext)(void) = nil;

    sendNext = ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) {
            NSLog(@"[DiagController] ⚠️ self is nil in sendNext block");
            return;
        }

        if (idx >= totalCount) {
            [self showLogsWithMessage:@"[SUC] All selected parameters written\n"];
            return;
        }

        NSDictionary *j = jobs[idx];
        NSString *key = j[@"key"];
        NSString *val = j[@"value"];
        NSString *displayVal = j[@"display"];

        // ✅ 显示进度和当前写入的参数
        [self showLogsWithMessage:[NSString stringWithFormat:@"[WAR] [%ld/%ld] Writing %@: %@",
            (long)(idx + 1), (long)totalCount, key, displayVal]];

        // 构建命令
        NSString *cmd = [NSString stringWithFormat:@"syscfg add %@ %@", key, val];

        NSLog(@"[DiagController] [%ld/%ld] 发送命令: %@", (long)(idx + 1), (long)totalCount, cmd);
        [self serialWriteLine:cmd appendCRLF:YES];

        // ✅ 递增索引
        idx++;

        // ✅ 增加间隔时间到 0.3 秒，给设备更多处理时间
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            // ✅ 检查 weakSendNext 是否有效
            if (weakSendNext) {
                NSLog(@"[DiagController] Calling weakSendNext for next parameter...");
                weakSendNext();
            } else {
                NSLog(@"[DiagController] ⚠️ weakSendNext is nil, stopping");
            }
        });
    };

    weakSendNext = sendNext;
    
    // ✅ 启动第一次写入
    NSLog(@"[DiagController] Starting batch write for %ld parameters", (long)totalCount);
    sendNext();
}

#pragma mark - ✅ SysCFG 批量操作

- (IBAction)onClearAll:(id)sender {
    self.snTextField.stringValue = @"";
    self.modelTextField.stringValue = @"";
    self.modeTextField.stringValue = @"";
    self.regionTextField.stringValue = @"";
    [self.colorPopup selectItemAtIndex:0];
    self.wifiTextField.stringValue = @"";
    self.bmacTextField.stringValue = @"";
    self.CLHSTextField.stringValue = @"";
    self.emacTextField.stringValue = @"";
    self.mlbTextField.stringValue = @"";
    self.nvsnTextField.stringValue = @"";
    self.nsrnTextField.stringValue = @"";
    self.lcmTextField.stringValue = @"";
    self.batteryTextField.stringValue = @"";
    self.bcmsTextField.stringValue = @"";
    self.fcmsTextField.stringValue = @"";
    self.mtsnTextField.stringValue = @"";
}

#pragma mark - ✅ SysCFG 批量操作修复

- (IBAction)onSelectAll:(id)sender {
    // ✅ 修复：设置 NSButton 的状态
    self.snCheckbox.state = NSControlStateValueOn;
    self.modelCheckbox.state = NSControlStateValueOn;
    self.modeCheckbox.state = NSControlStateValueOn;
    self.regionCheckbox.state = NSControlStateValueOn;
    self.colorCheckbox.state = NSControlStateValueOn;
    self.wifiCheckbox.state = NSControlStateValueOn;
    self.bmacCheckbox.state = NSControlStateValueOn;
    self.CLHSCheckbox.state = NSControlStateValueOn;
    self.emacCheckbox.state = NSControlStateValueOn;
    self.mlbCheckbox.state = NSControlStateValueOn;
    self.nvsnCheckbox.state = NSControlStateValueOn;
    self.nsrnCheckbox.state = NSControlStateValueOn;
    self.lcmCheckbox.state = NSControlStateValueOn;
    self.batteryCheckbox.state = NSControlStateValueOn;
    self.bcmsCheckbox.state = NSControlStateValueOn;
    self.fcmsCheckbox.state = NSControlStateValueOn;
    self.mtsnCheckbox.state = NSControlStateValueOn;
}

- (IBAction)onDeselectAll:(id)sender {
    self.snCheckbox.state = NSControlStateValueOff;
    self.modelCheckbox.state = NSControlStateValueOff;
    self.modeCheckbox.state = NSControlStateValueOff;
    self.regionCheckbox.state = NSControlStateValueOff;
    self.colorCheckbox.state = NSControlStateValueOff;
    self.wifiCheckbox.state = NSControlStateValueOff;
    self.CLHSCheckbox.state = NSControlStateValueOff;
    self.bmacCheckbox.state = NSControlStateValueOff;
    self.emacCheckbox.state = NSControlStateValueOff;
    self.mlbCheckbox.state = NSControlStateValueOff;
    self.nvsnCheckbox.state = NSControlStateValueOff;
    self.nsrnCheckbox.state = NSControlStateValueOff;
    self.lcmCheckbox.state = NSControlStateValueOff;
    self.batteryCheckbox.state = NSControlStateValueOff;
    self.bcmsCheckbox.state = NSControlStateValueOff;
    self.fcmsCheckbox.state = NSControlStateValueOff;
    self.mtsnCheckbox.state = NSControlStateValueOff;
}


#pragma mark - 备份 SysCFG

/**
 * 备份 SysCFG 到文件
 * 流程：
 * 1. 发送 "syscfg list" 命令
 * 2. 等待并收集响应数据
 * 3. 解析 Key-Value 对
 * 4. 转换为 "syscfg add" 命令格式
 * 5. 保存到文件
 */
- (IBAction)backupSysCFG:(id)sender
{
    if (self.serialFD < 0) {
        [self showLogsWithMessage:@"[ER] Serial not connected"];
        [[NSSound soundNamed:@"Basso"] play];
        return;
    }
    
    [self showLogsWithMessage:@"📦 Starting SysCFG backup..."];
    
    // ✅ 启用监听模式
    self.syscfgListening = YES;
    self.syscfgBackupInProgress = YES;
    [self.syscfgStream setString:@""];
    
    // ✅ 发送 syscfg list 命令
    [self serialWriteLine:@"syscfg list" appendCRLF:YES];
    
    // ✅ 设置超时：20秒后自动处理
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || !self.syscfgBackupInProgress) return;
        
        [self processSysCFGBackupData];
    });
}

/**
 * 处理 syscfg list 返回的数据并保存
 */
- (void)processSysCFGBackupData {
    self.syscfgBackupInProgress = NO;
    self.syscfgListening = NO;
    
    NSString *rawData = self.syscfgStream;
    if (rawData.length == 0) {
        [self showLogsWithMessage:@"[ER] No data received from device"];
        [[NSSound soundNamed:@"Basso"] play];
        return;
    }
    
    // ✅ 解析数据：提取 "syscfg list" 命令行之后的内容
    // 格式示例：
    // [ECID] :-) syscfg list
    // Key: XXX
    // Value: YYY
    // ...
    // [ECID] :-)
    
    // 1) 找到 "syscfg list" 命令行
    NSRange listCmdRange = [rawData rangeOfString:@"syscfg list"];
    if (listCmdRange.location == NSNotFound) {
        [self showLogsWithMessage:@"[ER] Failed to find 'syscfg list' command in response"];
        NSLog(@"[DEBUG] Raw data length: %lu", (unsigned long)rawData.length);
        NSLog(@"[DEBUG] First 500 chars: %@", rawData.length > 500 ? [rawData substringToIndex:500] : rawData);
        [[NSSound soundNamed:@"Basso"] play];
        return;
    }
    
    // 2) 找到命令行的换行符（从 "syscfg list" 之后开始）
    NSRange afterCmd = NSMakeRange(listCmdRange.location + listCmdRange.length,
                                   rawData.length - listCmdRange.location - listCmdRange.length);
    NSRange firstNewline = [rawData rangeOfString:@"\n" options:0 range:afterCmd];
    if (firstNewline.location == NSNotFound) {
        [self showLogsWithMessage:@"[ER] Invalid response format"];
        [[NSSound soundNamed:@"Basso"] play];
        return;
    }
    
    // 3) 数据起始位置：第一个换行符之后
    NSUInteger dataStart = firstNewline.location + 1;
    
    // 4) 找到结束标记（新设备："\n:-)" 或旧设备："\n["）
    NSRange searchRange = NSMakeRange(dataStart, rawData.length - dataStart);
    NSRange endRange = [rawData rangeOfString:@"\n:-)" options:0 range:searchRange];
    
    if (endRange.location == NSNotFound) {
        // 尝试旧设备格式
        endRange = [rawData rangeOfString:@"\n[" options:0 range:searchRange];
        if (endRange.location == NSNotFound) {
            [self showLogsWithMessage:@"[ER] Failed to find end marker in response"];
            [[NSSound soundNamed:@"Basso"] play];
            return;
        }
    }
    
    // 5) 提取内容
    NSUInteger length = endRange.location - dataStart;
    NSString *content = [rawData substringWithRange:NSMakeRange(dataStart, length)];
    
    NSLog(@"[DEBUG] Extracted content length: %lu", (unsigned long)content.length);
    NSLog(@"[DEBUG] First 300 chars: %@", content.length > 300 ? [content substringToIndex:300] : content);
    
    // ✅ 清理 ANSI 转义码（颜色代码）
    // 示例：Key: FSCl \^[[0;31mNot Found!\^[[m
    content = [self stringByStrippingANSIEscapes:content];
    
    // ✅ 转换格式：Key: XXX\nValue: YYY → syscfg add XXX YYY
    NSString *processed = [content stringByReplacingOccurrencesOfString:@"Key: " withString:@"syscfg add "];
    processed = [processed stringByReplacingOccurrencesOfString:@"\nValue: " withString:@" "];
    
    // ✅ 过滤掉 "Not Found" 行、"----" 分隔线和空行
    NSMutableArray *lines = [NSMutableArray array];
    NSArray *allLines = [processed componentsSeparatedByString:@"\n"];
    for (NSString *line in allLines) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        
        // 跳过空行
        if (trimmed.length == 0) continue;
        
        // 跳过 "Not Found" 行
        if ([trimmed containsString:@"Not Found"]) continue;
        
        // 跳过分隔线
        if ([trimmed containsString:@"----"]) continue;
        
        // 跳过不是 "syscfg add" 开头的行（可能是其他噪音）
        if (![trimmed hasPrefix:@"syscfg add "]) continue;
        
        [lines addObject:trimmed];
    }
    
    NSString *backupContent = [lines componentsJoinedByString:@"\n"];
    
    NSLog(@"[DEBUG] Processed %lu valid lines", (unsigned long)lines.count);
    
    if (backupContent.length == 0) {
        [self showLogsWithMessage:@"[WAR] No SysCFG data to backup"];
        [[NSSound soundNamed:@"Basso"] play];
        return;
    }
    
    [self showLogsWithMessage:[NSString stringWithFormat:@"✅ Collected %lu SysCFG entries", (unsigned long)lines.count]];
    
    // ✅ 保存到文件
    [self saveSysCFGBackup:backupContent];
}

/**
 * 显示保存对话框并保存备份
 */
- (void)saveSysCFGBackup:(NSString *)content {
    NSSavePanel *savePanel = [NSSavePanel savePanel];
    savePanel.allowedFileTypes = @[@"txt"];
    
    // 生成默认文件名：设备型号_序列号_日期
    NSString *deviceModel = self.currentDeviceType ?: @"Device";
    NSString *serialNumber = self.snTextField.stringValue ?: @"Unknown";
    
    NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
    [dateFormatter setDateFormat:@"yyyyMMdd_HHmmss"];
    NSString *timestamp = [dateFormatter stringFromDate:[NSDate date]];
    
    NSString *defaultName = [NSString stringWithFormat:@"%@_%@_%@", deviceModel, serialNumber, timestamp];
    savePanel.nameFieldStringValue = defaultName;
    
    __weak typeof(self) weakSelf = self;
    [savePanel beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse result) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        
        if (result == NSModalResponseOK) {
            NSURL *fileURL = savePanel.URL;
            NSError *error = nil;
            
            BOOL success = [content writeToURL:fileURL
                                    atomically:YES
                                      encoding:NSUTF8StringEncoding
                                         error:&error];
            
            if (success) {
                [self showLogsWithMessage:[NSString stringWithFormat:@"✅ Backup saved: %@", fileURL.lastPathComponent]];
                [[NSSound soundNamed:@"Glass"] play];
            } else {
                [self showLogsWithMessage:[NSString stringWithFormat:@"[ER] Failed to save: %@", error.localizedDescription]];
                [[NSSound soundNamed:@"Basso"] play];
            }
        } else {
            [self showLogsWithMessage:@"[WAR] Backup cancelled"];
        }
    }];
}


#pragma mark - 恢复 SysCFG

/**
 * 从备份文件恢复 SysCFG
 * 流程：
 * 1. 选择备份文件
 * 2. 读取文件内容
 * 3. 逐行发送 "syscfg add" 命令
 */
- (IBAction)restoreSysCFG:(id)sender
{
    if (self.serialFD < 0) {
        [self showLogsWithMessage:@"[ER] Serial not connected"];
        [[NSSound soundNamed:@"Basso"] play];
        return;
    }
    
    // ✅ 打开文件选择对话框
    NSOpenPanel *openPanel = [NSOpenPanel openPanel];
    openPanel.allowsMultipleSelection = NO;
    openPanel.canChooseDirectories = NO;
    openPanel.canCreateDirectories = NO;
    openPanel.canChooseFiles = YES;
    openPanel.allowedFileTypes = @[@"txt"];
    openPanel.message = @"Select SysCFG backup file to restore";
    
    __weak typeof(self) weakSelf = self;
    [openPanel beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse result) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        
        if (result == NSModalResponseOK) {
            NSURL *fileURL = openPanel.URL;
            [self performSysCFGRestore:fileURL];
        } else {
            [self showLogsWithMessage:@"[WAR] Restore cancelled"];
        }
    }];
}

/**
 * 执行 SysCFG 恢复
 */
- (void)performSysCFGRestore:(NSURL *)fileURL {
    // ✅ 读取文件内容
    NSError *error = nil;
    NSString *content = [NSString stringWithContentsOfURL:fileURL
                                                 encoding:NSUTF8StringEncoding
                                                    error:&error];
    
    if (!content || error) {
        [self showLogsWithMessage:[NSString stringWithFormat:@"[ER] Failed to read file: %@", error.localizedDescription]];
        [[NSSound soundNamed:@"Basso"] play];
        return;
    }
    
    // ✅ 解析命令行
    NSArray *lines = [content componentsSeparatedByString:@"\n"];
    NSMutableArray *commands = [NSMutableArray array];
    
    for (NSString *line in lines) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length > 0 && [trimmed hasPrefix:@"syscfg add "]) {
            [commands addObject:trimmed];
        }
    }
    
    if (commands.count == 0) {
        [self showLogsWithMessage:@"[ER] No valid syscfg commands found in file"];
        [[NSSound soundNamed:@"Basso"] play];
        return;
    }
    
    [self showLogsWithMessage:[NSString stringWithFormat:@"📥 Restoring %lu SysCFG entries from %@...", (unsigned long)commands.count, fileURL.lastPathComponent]];
    
    // ✅ 确认对话框
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"⚠️ Restore SysCFG";
    alert.informativeText = [NSString stringWithFormat:@"This will restore %lu SysCFG entries.\n\nThis operation will overwrite existing values!\n\nContinue?", (unsigned long)commands.count];
    [alert addButtonWithTitle:@"Restore"];
    [alert addButtonWithTitle:@"Cancel"];
    alert.alertStyle = NSAlertStyleWarning;
    
    __weak typeof(self) weakSelf = self;
    [alert beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse returnCode) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        
        if (returnCode == NSAlertFirstButtonReturn) {
            // 用户确认恢复
            [self executeSysCFGRestoreCommands:commands];
        } else {
            [self showLogsWithMessage:@"[WAR] Restore cancelled by user"];
        }
    }];
}

/**
 * 逐条执行恢复命令
 */
- (void)executeSysCFGRestoreCommands:(NSArray<NSString *> *)commands {
    __block NSInteger idx = 0;
    __weak typeof(self) weakSelf = self;
    
    // ✅ 使用定时器逐条发送（避免命令堆积）
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, 0),
                              (uint64_t)(0.3 * NSEC_PER_SEC),  // 每300ms发送一条
                              (uint64_t)(0.05 * NSEC_PER_SEC));
    
    dispatch_source_set_event_handler(timer, ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) {
            dispatch_source_cancel(timer);
            return;
        }
        
        if (idx >= (NSInteger)commands.count) {
            dispatch_source_cancel(timer);
            [self showLogsWithMessage:@"✅ SysCFG restore completed"];
            [[NSSound soundNamed:@"Glass"] play];
            return;
        }
        
        NSString *cmd = commands[idx];
        [self serialWriteLine:cmd appendCRLF:YES];
        
        // 显示进度（每5条或最后一条）
        if ((idx + 1) % 5 == 0 || idx == commands.count - 1) {
            double progress = ((double)(idx + 1) / (double)commands.count) * 100.0;
            [self showLogsWithMessage:[NSString stringWithFormat:@"⏳ Restoring... %.0f%% (%ld/%lu)",
                                       progress, (long)(idx + 1), (unsigned long)commands.count]];
        }
        
        idx++;
    });
    
    dispatch_resume(timer);
}


#pragma mark - 获取Nand大小

/**
 * 获取 Nand 大小
 * 发送 "nandsize" 命令，设备返回十六进制值
 *
 * 转换示例：
 * 0x7735940 = 125,000,000
 * 125,000,000 × 1024 = 128,000,000,000 bytes
 * 128,000,000,000 / 1,000,000,000 ≈ 128GB
 */
- (IBAction)getNandsize:(id)sender
{
    if (self.serialFD < 0) {
        [self showLogsWithMessage:@"[ER] Serial not connected"];
        [[NSSound soundNamed:@"Basso"] play];
        return;
    }
    
    [self showLogsWithMessage:@"💾 Reading Nand size..."];
    
    // ✅ 启用监听模式
    self.syscfgListening = YES;
    self.syscfgNandsizeInProgress = YES;
    [self.syscfgStream setString:@""];
    
    // ✅ 设置当前期待的命令响应
    self.currentExpectedSyscfgKey = @"nandsize";
    
    // ✅ 发送 nandsize 命令
    [self serialWriteLine:@"nandsize" appendCRLF:YES];
    
    // ✅ 设置超时：5秒后自动处理
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || !self.syscfgNandsizeInProgress) return;
        
        [self processNandsizeResponse];
    });
}

/**
 * 处理 nandsize 命令的响应
 */
- (void)processNandsizeResponse {
    self.syscfgNandsizeInProgress = NO;
    self.syscfgListening = NO;
    self.currentExpectedSyscfgKey = nil;
    
    NSString *rawData = self.syscfgStream;
    if (rawData.length == 0) {
        [self showLogsWithMessage:@"[ER] No response from device"];
        [[NSSound soundNamed:@"Basso"] play];
        return;
    }
    
    // ✅ 查找十六进制值（格式: 0xXXXXXXX）
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"0x([0-9A-Fa-f]+)"
                                                                           options:0
                                                                             error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:rawData
                                                    options:0
                                                      range:NSMakeRange(0, rawData.length)];
    
    if (!match || match.numberOfRanges < 2) {
        [self showLogsWithMessage:@"[ER] Failed to parse nandsize response"];
        [[NSSound soundNamed:@"Basso"] play];
        return;
    }
    
    // ✅ 提取十六进制字符串并转换
    NSString *hexString = [rawData substringWithRange:[match rangeAtIndex:1]];
    unsigned long long hexValue = 0;
    
    NSScanner *scanner = [NSScanner scannerWithString:hexString];
    if (![scanner scanHexLongLong:&hexValue]) {
        [self showLogsWithMessage:@"[ER] Failed to convert hex value"];
        [[NSSound soundNamed:@"Basso"] play];
        return;
    }
    
    // ✅ 转换为 GB（十六进制值 × 1024 ÷ 1,000,000,000）
    double bytes = (double)hexValue * 1024.0;
    double gigabytes = bytes / 1000000000.0;
    
    // ✅ 显示结果
    [self showLogsWithMessage:[NSString stringWithFormat:@"💾 Nand Size: 0x%@ = %llu", hexString.uppercaseString, hexValue]];
    [self showLogsWithMessage:[NSString stringWithFormat:@"💾 Converted: %.2f GB (%.0f bytes)", gigabytes, bytes]];
    
    // ✅ 判断容量档位
    NSString *capacity = @"Unknown";
    if (gigabytes >= 512) capacity = @"512GB+";
    else if (gigabytes >= 256) capacity = @"256GB";
    else if (gigabytes >= 128) capacity = @"128GB";
    else if (gigabytes >= 64) capacity = @"64GB";
    else if (gigabytes >= 32) capacity = @"32GB";
    else if (gigabytes >= 16) capacity = @"16GB";
    
    [self showLogsWithMessage:[NSString stringWithFormat:@"✅ Capacity: %@", capacity]];
    [[NSSound soundNamed:@"Glass"] play];
}

#pragma mark - 重启设备

/**
 * 重启诊断模式设备
 * 发送 "reset" 命令
 */
- (IBAction)rebootDiagDevice:(id)sender
{
    if (self.serialFD < 0) {
        [self showLogsWithMessage:@"[ER] Serial not connected"];
        [[NSSound soundNamed:@"Basso"] play];
        return;
    }
    
    // ✅ 确认对话框
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"⚠️ Reboot Device";
    alert.informativeText = @"This will reboot the device immediately.\n\nAny unsaved changes will be lost!\n\nContinue?";
    [alert addButtonWithTitle:@"Reboot"];
    [alert addButtonWithTitle:@"Cancel"];
    alert.alertStyle = NSAlertStyleWarning;
    
    __weak typeof(self) weakSelf = self;
    [alert beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse returnCode) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        
        if (returnCode == NSAlertFirstButtonReturn) {
            // 用户确认重启
            [self performDeviceReboot];
        } else {
            [self showLogsWithMessage:@"[WAR] Reboot cancelled"];
        }
    }];
}

/**
 * 执行设备重启
 */
- (void)performDeviceReboot {
    [self showLogsWithMessage:@"Sending reboot command..."];
    
    BOOL success = [self serialWriteLine:@"reset" appendCRLF:YES];
    
    if (success) {
        [self showLogsWithMessage:@"✅ Reboot command sent"];
        [self showLogsWithMessage:@"[WAR] Device will reboot now..."];
        [[NSSound soundNamed:@"Glass"] play];
        
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            
            if (self.serialConnected) {
                [self showLogsWithMessage:@"[WAR] Disconnecting serial port..."];
                [self disconnectSerial:nil];
                
                // 添加用户提示
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    [self showLogsWithMessage:@"Device is rebooting..."];
                    [self showLogsWithMessage:@"Please wait 10-15 seconds"];
                    [self showLogsWithMessage:@"Then click 'Connect' to reconnect"];
                });
            }
        });
    } else {
        [self showLogsWithMessage:@"[ER] Failed to send reboot command"];
        [[NSSound soundNamed:@"Basso"] play];
    }
}


#pragma mark - ✅ Helper Methods

- (uint64_t)getDeviceECID {
    // 1) 首选 currentDeviceECID
    NSString *ecidStr = self.currentDeviceECID;

    // 2) fallback: 从全局锁定信息取（你工程里锁定信息里有 ecid）
    if (ecidStr.length == 0) {
        NSDictionary *locked = [self getLockedDeviceInfo];
        NSString *lockedECID = locked[@"ECID"];
        if (lockedECID.length > 0) ecidStr = lockedECID;
    }

    // 3) fallback: 如果 parentTabsController/deviceECID 有值也可用（按你项目结构可选）
    if (ecidStr.length == 0 && self.deviceECID.length > 0) {
        ecidStr = self.deviceECID;
    }

    // 4) 防御：还是没有就返回 0 并打日志（不要再触发 NSScanner nil）
    if (ecidStr.length == 0) {
        NSLog(@"[DiagController][ER] ECID string is empty (currentDeviceECID/locked ECID all empty)");
        return 0;
    }

    ecidStr = [ecidStr stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([ecidStr hasPrefix:@"0x"] || [ecidStr hasPrefix:@"0X"]) {
        ecidStr = [ecidStr substringFromIndex:2];
    }

    unsigned long long ecid = 0;
    NSScanner *scanner = [NSScanner scannerWithString:ecidStr];
    if (!scanner || ![scanner scanHexLongLong:&ecid] || ecid == 0) {
        NSLog(@"[DiagController][ER] Failed to parse ECID from string: %@", ecidStr);
        return 0;
    }
    return (uint64_t)ecid;
}

#pragma mark - Serial UI (Diags CDC Serial)

- (void)populateSerialPortPopUpButton {
   
    if (!self.portPopUpButton) return;

    [self.portPopUpButton removeAllItems];

    // 先找 Diags CDC Serial 对应的 /dev/cu.*
    // ls -1 /dev/cu.* /dev/tty.* | grep -E 'usbmodem|usbserial'
    // 你之前已经确认：Diags CDC Serial = 0x05AC:0x1222, locationID=0x02100000
    NSString *diagDeviceConnectedECID = nil;
    NSString *diagsCallout = [DeviceManager findCalloutForUSBDeviceWithVID:0x05AC
                                                                       PID:0x1222
                                                                      ECID:&diagDeviceConnectedECID];

    //找到usbmodem端口
    NSString *deviceConnectUSBmodem = diagsCallout.lastPathComponent;
    
    // 去掉常见串口前缀
    if ([deviceConnectUSBmodem hasPrefix:@"cu."]) {
        deviceConnectUSBmodem = [deviceConnectUSBmodem substringFromIndex:3];
    } else if ([deviceConnectUSBmodem hasPrefix:@"tty."]) {
        deviceConnectUSBmodem = [deviceConnectUSBmodem substringFromIndex:4];
    }

    if (diagsCallout.length > 0) {
        NSString *title = [NSString stringWithFormat:@"DCDCS (%@)", deviceConnectUSBmodem];
        
        // 成功找到设备
        NSLog(@"✅ 找到 Diags CDC Serial 设备:");
        NSLog(@"   串口路径: %@", diagsCallout);

        //保存当前的设备ECID
        self.diagDeviceConnectedECID = diagDeviceConnectedECID;
        
        [self.portPopUpButton addItemWithTitle:title];
        self.portPopUpButton.lastItem.representedObject = diagsCallout;
        [self.portPopUpButton selectItemAtIndex:0];

        if (!self.isRefreshingSerialPorts) {
            [self showLogsWithMessage:[NSString stringWithFormat:@"[WAR]Found device %@ at DCDCS Port %@", self.diagDeviceConnectedECID, deviceConnectUSBmodem]];
            [self updateUIForState:DiagStateReady];
        }
        
        // ✅ 发现端口后，更新设备状态
       // [self updateDeviceStatusOnSerialPortDiscovered:diagDeviceConnectedECID];
        
    } else {
        [self updateUIForState:DiagStateNotReady];
        [self.portPopUpButton addItemWithTitle:@"Diags CDC Serial (not found)"];
        self.portPopUpButton.lastItem.representedObject = @"";
        [self showLogsWithMessage:[NSString stringWithFormat:@"[WAR] DCDCS Port not found"]];
    }

    // 2) 可选：再把系统里其它 usbmodem/usbsrial 也列出来，方便手动切换
    NSArray<NSString *> *devNames = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:@"/dev" error:nil] ?: @[];
    NSMutableArray<NSString *> *others = [NSMutableArray array];

    for (NSString *name in devNames) {
        if ([name hasPrefix:@"cu.usbmodem"] || [name hasPrefix:@"cu.usbserial"]) {
            NSString *path = [@"/dev" stringByAppendingPathComponent:name];
            if (![path isEqualToString:diagsCallout]) [others addObject:path];
        }
    }
/*
    [others sortUsingSelector:@selector(compare:)];

    if (others.count > 0) {
        [self.portPopUpButton.menu addItem:[NSMenuItem separatorItem]];
        for (NSString *p in others) {
            NSString *t = [NSString stringWithFormat:@"Other  (%@)", p.lastPathComponent];
            [self.portPopUpButton addItemWithTitle:t];
            self.portPopUpButton.lastItem.representedObject = p;
        }
    }*/
}

#pragma mark - 设备状态更新

/**
 * 当发现 CDC Serial 端口时，更新设备状态到数据库
 * @param deviceECID 从 FindCalloutForUSBDevice 获取的设备 ECID
 */
- (void)updateDeviceStatusOnSerialPortDiscovered:(NSString *)deviceECID {
    if (!deviceECID || deviceECID.length == 0) {
        NSLog(@"[DiagController] ⚠️ 未获取到 ECID，跳过状态更新");
        return;
    }
    
    NSLog(@"[DiagController] 🔄 更新诊断模式设备状态，ECID=%@", deviceECID);
    
    // ✅ 直接创建 DeviceHistory 对象
    DeviceHistory *device = [[DeviceHistory alloc] init];
    device.deviceECID = deviceECID;
    device.deviceMode = @"Diag";
    device.IsConnected = 1;
    device.connectDate = [self currentTimestamp];
    
    // ✅ 直接调用 addOrUpdateDeviceHistorySqlite
    // 它会自动判断是插入还是更新
    [[DeviceDataManager sharedManager] addOrUpdateDeviceHistorySqlite:device];
    
    NSLog(@"[DiagController] ✅ 设备 ECID=%@ 状态已更新为诊断模式", deviceECID);
    
    // 显示成功消息
    [self showLogsWithMessage:[NSString stringWithFormat:
        @"Device (ECID: %@) entered Diagnostic mode", deviceECID]];
}

// 辅助方法：获取当前时间戳
- (NSString *)currentTimestamp {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    return [formatter stringFromDate:[NSDate date]];
}

// 刷新串口列表按钮事件
- (IBAction)refreshSerialPorts:(id)sender {
    if (!self.portPopUpButton) return;

    // 记录刷新前当前选中的串口路径（representedObject 存的是 /dev/cu.*）
    NSString *previousPath = (NSString *)self.portPopUpButton.selectedItem.representedObject;

    // ✅ 标记为刷新动作（抑制 populate 内日志）
    self.isRefreshingSerialPorts = YES;
    
    // ✅ 重新扫描并填充
    [self populateSerialPortPopUpButton];
    
    // ✅ 恢复标志位
    self.isRefreshingSerialPorts = NO;

    // ✅ 尝试恢复之前的选择（如果刷新后仍存在）
    if (previousPath.length > 0) {
        for (NSMenuItem *item in self.portPopUpButton.itemArray) {
            NSString *p = (NSString *)item.representedObject;
            if ([p isEqualToString:previousPath]) {
                [self.portPopUpButton selectItem:item];
                break;
            }
        }
    }

    // 日志提示
    [self showLogsWithMessage:@"[WAR] Serial ports refreshed"];
}



#pragma mark - Console 主题配置（static：统一背景/字体/颜色/Prompt）
// ✅ Console 背景色可调（通过滑块修改）
// 说明：保留“终端绿”基调，仅让 green 分量可调。
static NSString * const kConsoleBGGreenKey = @"ConsoleBGGreen";
static CGFloat gConsoleBGGreen = 0.65; // 默认值

static NSColor *ConsoleBGColor(void) {
    return [NSColor colorWithCalibratedRed:0.0 green:gConsoleBGGreen blue:0.45 alpha:1.0];
}

// 字体：深灰（不是纯黑）
static NSColor *ConsoleFGColor(void) {
    return [NSColor colorWithCalibratedWhite:1.0 alpha:1.0];
}

// ✅ Prompt（提示符）
static NSString *ConsolePrompt(void) {
    return @"~ % ";
}

// ✅ 终端字体（等宽）
static NSFont *ConsoleFont(void) {
    if (@available(macOS 10.15, *)) {
        return [NSFont monospacedSystemFontOfSize:11.5
                                           weight:NSFontWeightRegular];
    }
    return [NSFont userFixedPitchFontOfSize:11.5];
}


#pragma mark - Console 工具函数（统一输出/输入属性）

- (NSDictionary *)_consoleAttrs
{
    NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];

    // ✅ 固定行高：建议 “字体大小 + 2~3”
    // 11号字可先用 13（你可以微调 12.5 / 13 / 14）
    ps.minimumLineHeight = 14;
    ps.maximumLineHeight = 14;

    // ✅ 段前/段后不要额外空隙
    ps.paragraphSpacing = 1;
    ps.paragraphSpacingBefore = 1;
    ps.lineSpacing = 1;

    return @{
        NSForegroundColorAttributeName: ConsoleFGColor(),
        NSFontAttributeName: ConsoleFont(),
        NSParagraphStyleAttributeName: ps
    };
}

// ✅ 输入文本属性（行高更高）
- (NSDictionary *)_consoleInputAttrs
{
    NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
    
    ps.minimumLineHeight = 15;  // 输入行更高
    ps.maximumLineHeight = 15;
    
    ps.paragraphSpacing = 3;
    ps.paragraphSpacingBefore = 5;
    ps.lineSpacing = 5;

    return @{
        NSForegroundColorAttributeName: ConsoleFGColor(),
        NSFontAttributeName: ConsoleFont(),
        NSParagraphStyleAttributeName: ps
    };
}

#pragma mark - Console UI 初始化（创建 ScrollView + TextView）
- (void)setupConsoleUI
{
    NSLog(@"[DiagController] 开始加载Console UI部分");
    if (!self.consoleContentView) return;

    // 清空 consoleContentView 中旧的控件
    for (NSView *v in self.consoleContentView.subviews.copy) {
        [v removeFromSuperview];
    }

    self.consoleAutoScroll = YES;
    self.consoleHistory = [NSMutableArray array];

    // ✅ “真实终端”：historyIndex 初始指向末尾（草稿位置）
    self.consoleHistoryIndex = self.consoleHistory.count;
    self.consoleDraftInput = @"";

    // =========================
    // ScrollView
    // =========================
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:self.consoleContentView.bounds];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;

    scroll.hasVerticalScroller = YES;        // ✅ 需要垂直滚动条
    scroll.hasHorizontalScroller = YES;      // ✅ 真终端：需要横向滚动条（不折行）
    scroll.autohidesScrollers = YES;

    // overlay 风格（如果你希望“永远可见”，把这一行改成 Legacy，见下方备注）
    if (@available(macOS 10.7, *)) {
        scroll.scrollerStyle = NSScrollerStyleOverlay;
    }
    
    scroll.borderType = NSNoBorder;

    // （可选）背景统一，避免露底
    scroll.drawsBackground = YES;
    scroll.contentView.drawsBackground = YES;
    if (@available(macOS 10.14, *)) {
        scroll.backgroundColor = ConsoleBGColor();
        scroll.contentView.backgroundColor = ConsoleBGColor();
    }
    
    // 让滚动内容区域顶部留出安全边距（不改变现有约束结构）
    if (@available(macOS 10.10, *)) {
        scroll.automaticallyAdjustsContentInsets = NO;
        scroll.contentInsets = NSEdgeInsetsMake(6, 0, 0, 0);
    }

    // =========================
    // TextView (documentView)
    // =========================
    NSSize cs = scroll.contentSize;
    NSTextView *tv = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, cs.width, cs.height)];
    
    // ✅ 关键：只能跟随宽度，不能跟随高度
    // 否则 tv 高度永远等于可视高度 -> 永远不触发垂直滚动条
    tv.autoresizingMask = NSViewWidthSizable;

    // ✅ 编辑功能完全启用
    tv.editable = YES;
    tv.selectable = YES;
    
    // ✅ 启用撤销（支持 ⌘Z）
    tv.allowsUndo = YES;  // ← 改为 YES
    
    tv.richText = NO;
    tv.importsGraphics = NO;
    tv.usesRuler = NO;
    tv.usesFindBar = YES;

    if (@available(macOS 10.12, *)) {
        tv.automaticSpellingCorrectionEnabled = NO;
        tv.automaticQuoteSubstitutionEnabled = NO;
        tv.automaticDashSubstitutionEnabled  = NO;
        tv.automaticTextReplacementEnabled   = NO;
        tv.automaticLinkDetectionEnabled     = NO;
        tv.automaticDataDetectionEnabled     = NO;
    }

    tv.editable = YES;
    tv.selectable = YES;

    tv.font = ConsoleFont();

    tv.drawsBackground = YES;
    tv.backgroundColor = ConsoleBGColor();

    tv.textColor = ConsoleFGColor();
    tv.insertionPointColor = ConsoleFGColor();

    // ✅ 确保输入时用新颜色（不然可能仍沿用旧 typingAttributes）
    tv.typingAttributes = [self _consoleAttrs];


    // ✅ 真终端：不折行 + 横向滚动
    tv.horizontallyResizable = YES;
    tv.verticallyResizable = YES;

    tv.textContainer.widthTracksTextView = NO;
    tv.textContainer.heightTracksTextView = NO;
    tv.textContainer.containerSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);

    // ✅ 允许 documentView 随内容无限增高（触发垂直滚动条）
    tv.minSize = NSMakeSize(0.0, cs.height);
    tv.maxSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);

    // 终端内边距
    tv.textContainerInset = NSMakeSize(8, 10);
    tv.textContainer.lineFragmentPadding = 0;

    // ✅ 设置统一属性和 delegate
    tv.typingAttributes = [self _consoleAttrs];
    tv.delegate = self;

    // 组装
    scroll.documentView = tv;
    [self.consoleContentView addSubview:scroll];

    [NSLayoutConstraint activateConstraints:@[
        [scroll.leadingAnchor constraintEqualToAnchor:self.consoleContentView.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.consoleContentView.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:self.consoleContentView.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.consoleContentView.bottomAnchor],
    ]];

    _consoleScrollView = scroll;
    _consoleTextView = tv;

    [self _consoleResetPrompt];

    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_consoleTextView) {
            [self.view.window makeFirstResponder:self->_consoleTextView];
        }
    });
}

#pragma mark - Console Prompt（显示提示符，并更新输入范围）

- (void)_consoleResetPrompt
{
    if (!_consoleTextView) return;

    NSTextStorage *ts = _consoleTextView.textStorage;
    if (!ts) return;

    NSDictionary *outputAttrs = [self _consoleAttrs];    // 输出属性（紧凑）
    NSDictionary *inputAttrs = [self _consoleInputAttrs]; // ✅ 输入属性（高行距）

    // 如果上一行没有换行，先补一个换行（使用输出属性）
    if (_consoleTextView.string.length > 0 && ![_consoleTextView.string hasSuffix:@"\n"]) {
        [ts appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:outputAttrs]];
    }

    NSString *prompt = ConsolePrompt();
    NSUInteger promptStart = _consoleTextView.string.length;

    // ✅ prompt 使用输入属性（高行距）
    [ts appendAttributedString:[[NSAttributedString alloc] initWithString:prompt attributes:inputAttrs]];

    // 输入区从 prompt 后开始
    NSUInteger inputLoc = promptStart + prompt.length;
    self.consoleInputRange = NSMakeRange(inputLoc, 0);

    [_consoleTextView setSelectedRange:NSMakeRange(inputLoc, 0)];
    if (self.consoleAutoScroll) {
        [_consoleTextView scrollRangeToVisible:NSMakeRange(inputLoc, 0)];
    }

    [_consoleTextView setNeedsDisplay:YES];
    
    // ✅ 设置 typingAttributes 为输入属性
    _consoleTextView.typingAttributes = inputAttrs;
    
    // 归位：终端行为
    self.consoleHistoryIndex = self.consoleHistory.count;
    self.consoleDraftInput = @"";
}


#pragma mark - NSTextViewDelegate (终端行为总入口)

- (BOOL)textView:(NSTextView *)textView doCommandBySelector:(SEL)commandSelector
{
    if (textView != _consoleTextView) return NO;
    
    NSRange sel = textView.selectedRange;
    NSUInteger inputStart = self.consoleInputRange.location;
    NSString *all = textView.string ?: @"";
    BOOL isInInput = (sel.location >= inputStart);
    
    // ========== 只自定义终端特有的命令 ==========
    
    // 1. 回车：发送命令
    if (commandSelector == @selector(insertNewline:)) {
        if (isInInput) {
            [self _consoleSendCurrentLine];
            return YES;
        }
        return NO;
    }
    
    // 2. 上下箭头：历史命令（仅单行输入时）
    if (commandSelector == @selector(moveUp:) || commandSelector == @selector(moveDown:)) {
        if (!isInInput) return NO;
        if (sel.length > 0) return NO;
        
        // 多行输入时不拦截（让系统处理上下移动光标）
        if (inputStart <= all.length) {
            NSString *tail = [all substringFromIndex:inputStart] ?: @"";
            if ([tail rangeOfString:@"\n"].location != NSNotFound) return NO;
        }
        
        [self _consoleHistoryMove:(commandSelector == @selector(moveUp:) ? -1 : +1)];
        return YES;
    }
    
    // 3. Home：跳到 prompt 后
    if (commandSelector == @selector(moveToBeginningOfLine:) ||
        commandSelector == @selector(moveToLeftEndOfLine:)) {
        if (isInInput) {
            [textView setSelectedRange:NSMakeRange(inputStart, 0)];
            return YES;
        }
        return NO;
    }
    
    // 4. End：跳到行末
    if (commandSelector == @selector(moveToEndOfLine:) ||
        commandSelector == @selector(moveToRightEndOfLine:)) {
        if (isInInput) {
            [textView setSelectedRange:NSMakeRange(textView.string.length, 0)];
            return YES;
        }
        return NO;
    }
    
    // 5. 左箭头：不越过 prompt
    if (commandSelector == @selector(moveLeft:)) {
        if (isInInput && sel.location == inputStart && sel.length == 0) {
            return YES;  // 卡住
        }
        return NO;
    }
    
    // 6. Backspace：不删除 prompt
    if (commandSelector == @selector(deleteBackward:)) {
        if (isInInput && sel.length == 0 && sel.location == inputStart) {
            return YES;  // 禁止
        }
        if (sel.length > 0 && sel.location < inputStart) {
            [textView setSelectedRange:NSMakeRange(textView.string.length, 0)];
            return YES;
        }
        return NO;
    }
    
    return NO;
}


#pragma mark - NSTextViewDelegate 选择变化保护

- (void)textViewDidChangeSelection:(NSNotification *)notification
{
    NSTextView *tv = notification.object;
    if (tv != _consoleTextView) return;

    // ✅ 防止无限递归
    static BOOL isAdjustingSelection = NO;
    if (isAdjustingSelection) return;

    NSRange sel = tv.selectedRange;
    NSUInteger inputStart = self.consoleInputRange.location;

    // ✅ 有选区（正在高亮选择历史输出）：必须放行
    if (sel.length > 0) return;

    // ✅ 只有"插入点"才不允许停在 prompt 之前
    if (sel.location < inputStart) {
        isAdjustingSelection = YES;
        [tv setSelectedRange:NSMakeRange(inputStart, 0)];
        isAdjustingSelection = NO;
    }
}

- (void)textDidChange:(NSNotification *)notification
{
    NSTextView *tv = notification.object;
    if (tv != _consoleTextView) return;

    NSUInteger inputStart = self.consoleInputRange.location;
    NSUInteger end = tv.string.length;
    if (end >= inputStart) {
        self.consoleInputRange = NSMakeRange(inputStart, end - inputStart);
    }

    // ✅ 保证后续输入继续使用输入属性
    tv.typingAttributes = [self _consoleInputAttrs];
}

#pragma mark - 防止粘贴/拖拽把内容插到输出区
- (BOOL)textView:(NSTextView *)textView
shouldChangeTextInRange:(NSRange)affectedCharRange
 replacementString:(NSString *)replacementString
{
    if (textView != _consoleTextView) return YES;

    NSUInteger inputStart = self.consoleInputRange.location;

    if (affectedCharRange.location < inputStart) {
        NSBeep();
        return NO;
    }
    return YES;
}


- (NSRange)textView:(NSTextView *)textView
willChangeSelectionFromCharacterRange:(NSRange)oldRange
    toCharacterRange:(NSRange)newRange
{
    if (textView != _consoleTextView) return newRange;

    NSUInteger inputStart = self.consoleInputRange.location;

    // ✅ 正在“选择一段文本”：允许覆盖历史输出（复制需要这个）
    if (newRange.length > 0) {
        return newRange;
    }

    // ✅ 只是移动插入点：不允许插入点跑到 prompt 前
    if (newRange.location < inputStart) {
        return NSMakeRange(inputStart, 0);
    }

    return newRange;
}


#pragma mark - Console 命令历史 ↑↓

- (void)_consoleHistoryMove:(NSInteger)delta
{
    if (!_consoleTextView) return;
    if (self.consoleHistory.count == 0) return;

    NSString *all = _consoleTextView.string ?: @"";
    NSUInteger start = self.consoleInputRange.location;

    // 当前输入（草稿）
    NSString *currentInput = (start <= all.length) ? ([all substringFromIndex:start] ?: @"") : @"";

    // 第一次从“末尾位置”进入历史时，保存草稿
    if (self.consoleHistoryIndex == self.consoleHistory.count) {
        self.consoleDraftInput = currentInput ?: @"";
    }

    NSInteger newIndex = (NSInteger)self.consoleHistoryIndex + delta;
    if (newIndex < 0) newIndex = 0;
    if (newIndex > (NSInteger)self.consoleHistory.count) newIndex = (NSInteger)self.consoleHistory.count;
    self.consoleHistoryIndex = (NSUInteger)newIndex;

    NSString *target = @"";
    if (self.consoleHistoryIndex == self.consoleHistory.count) {
        target = self.consoleDraftInput ?: @"";
    } else {
        target = self.consoleHistory[self.consoleHistoryIndex] ?: @"";
    }

    // 替换输入区
    NSUInteger len = (_consoleTextView.string.length >= start) ? (_consoleTextView.string.length - start) : 0;
    if (len > 0) {
        [_consoleTextView.textStorage deleteCharactersInRange:NSMakeRange(start, len)];
    }

    if (target.length > 0) {
        NSDictionary *attrs = [self _consoleAttrs];
        [_consoleTextView.textStorage appendAttributedString:
         [[NSAttributedString alloc] initWithString:target attributes:attrs]];
    }

    self.consoleInputRange = NSMakeRange(start, target.length);
    [_consoleTextView setSelectedRange:NSMakeRange(_consoleTextView.string.length, 0)];
    [_consoleTextView scrollRangeToVisible:NSMakeRange(_consoleTextView.string.length, 0)];
}


#pragma mark - Console 发送命令（回车发送）

- (void)_consoleSendCurrentLine
{
    if (!_consoleTextView) return;

    NSString *all = _consoleTextView.string ?: @"";
    if (self.consoleInputRange.location > all.length) {
        [self _consoleResetPrompt];
        return;
    }

    NSString *cmd = [all substringFromIndex:self.consoleInputRange.location];
    cmd = [cmd stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    NSDictionary *attrs = [self _consoleAttrs];

    // 结束当前行（带属性，避免颜色乱）
    [_consoleTextView.textStorage appendAttributedString:
     [[NSAttributedString alloc] initWithString:@"\n" attributes:attrs]];

    if (cmd.length == 0) {
        [self _consoleResetPrompt];
        return;
    }

    // 命令历史（后续可做 ↑↓）
    [self.consoleHistory addObject:cmd];
    self.consoleHistoryIndex = self.consoleHistory.count;

    // 真正发送串口
    if (self.serialFD < 0) {
        [self appendConsoleText:@"[ER] Serial not connected"];
        [self _consoleResetPrompt];
        return;
    }
    
    [self serialWriteLine:cmd appendCRLF:YES];

    // 再显示一个 prompt
    [self _consoleResetPrompt];
}

#pragma mark - Console 追加输出（串口接收数据时调用）
- (void)appendConsoleText:(NSString *)text
{
    if (text.length == 0 || !_consoleTextView) return;

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || !self->_consoleTextView) return;

        NSDictionary *attrs = [self _consoleAttrs];
        NSString *all = self->_consoleTextView.string ?: @"";

        // 1. 保存当前输入
        NSString *currentInput = @"";
        if (self.consoleInputRange.location <= all.length) {
            currentInput = [all substringFromIndex:self.consoleInputRange.location] ?: @"";
        }

        // 2. 计算 prompt 的起始位置（inputStart 前面就是 prompt）
        NSString *promptStr = ConsolePrompt();
        NSUInteger promptStart = (self.consoleInputRange.location >= promptStr.length)
            ? (self.consoleInputRange.location - promptStr.length)
            : 0;

        // 3. 删除 prompt 和后面的所有内容
        if (promptStart < all.length) {
            [self->_consoleTextView.textStorage deleteCharactersInRange:
             NSMakeRange(promptStart, all.length - promptStart)];
        }

        // 4. 添加输出内容（确保以换行结尾）
        NSString *output = text;
        if (![output hasSuffix:@"\n"]) {
            output = [output stringByAppendingString:@"\n"];
        }
        
        [self->_consoleTextView.textStorage appendAttributedString:
         [[NSAttributedString alloc] initWithString:output attributes:attrs]];
        
        // 5. 重置 prompt（会自动添加 \n + > ）
        [self _consoleResetPrompt];
        
        // 6. 恢复用户输入
        if (currentInput.length > 0) {
            [self->_consoleTextView insertText:currentInput
                              replacementRange:self->_consoleTextView.selectedRange];
            self.consoleInputRange = NSMakeRange(self.consoleInputRange.location,
                                                 currentInput.length);
        }
    });
}


#pragma mark - Tools UI 初始化

- (IBAction)onToolToggle:(id)sender
{
    BOOL showingTools = !self.toolsContentView.hidden;

    if (showingTools) {
        // ===== 切回 SysCFG =====
        self.toolsContentView.hidden = YES;
        self.consoleContentView.hidden = YES;
        self.syscfgContentView.hidden = NO;

    } else {
        // ===== 切到 Tools =====
        self.syscfgContentView.hidden = YES;
        self.consoleContentView.hidden = YES;
        self.toolsContentView.hidden = NO;

        // 初始化 Tools UI（如果需要）
        if (!self.toolsUIInitialized) {
            [self setupToolUI];
            self.toolsUIInitialized = YES;
        }

        // ✅ 延迟设置焦点，确保视图布局完成
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                      dispatch_get_main_queue(), ^{
            NSWindow *window = self.view.window;
            if (!window || !self.forwardInputTextField) return;
            
            // 设置焦点到 Forward 输入框
            [window makeFirstResponder:self.forwardInputTextField];
        });
    }
}


/*
 * 支持Forward / Reverse转换
 * i.e.: 0xEE75324C 0x00004664 0x00000000 0x00000000 Converts To(→) 4C:32:75:EE:64:46
 * i.e.: 4C:32:75:EE:64:46 Converts To(→) 0xEE75324C 0x00004664 0x00000000 0x00000000
 */
#pragma mark - Tools UI

- (void)setupToolUI
{
    // Forward 区域
    self.forwardTitleLable.stringValue = @"Forward Conversion";
    self.forwardDescLable.stringValue =
        @"i.e.: 0xEE75324C 0x00004664 0x00000000 0x00000000 Converts To(→) 4C:32:75:EE:64:46";

    if ([self.forwardInputTextField respondsToSelector:@selector(setPlaceholderString:)]) {
        self.forwardInputTextField.placeholderString = @"Input: 0xEE75324C 0x00004664 ...";
    }
    self.forwardResultTextField.stringValue = @"";

    // Reverse 区域
    self.reverseTitleLable.stringValue = @"Reverse Conversion";
    self.reverseDescLable.stringValue =
        @"i.e.: 4C:32:75:EE:64:46 Converts To(→) 0xEE75324C 0x00004664 0x00000000 0x00000000";

    if ([self.reverseInputTextField respondsToSelector:@selector(setPlaceholderString:)]) {
        self.reverseInputTextField.placeholderString = @"Input: 4C:32:75:EE:64:46";
    }
    self.reverseResultTextField.stringValue = @"";

    // ✅ 确保输入框完全启用编辑功能
    self.forwardInputTextField.editable = YES;
    self.forwardInputTextField.selectable = YES;
    self.forwardInputTextField.enabled = YES;
    
    self.reverseInputTextField.editable = YES;
    self.reverseInputTextField.selectable = YES;
    self.reverseInputTextField.enabled = YES;
    
    // ✅ 结果框只读
    self.forwardResultTextField.editable = NO;
    self.forwardResultTextField.selectable = YES;
    
    self.reverseResultTextField.editable = NO;
    self.reverseResultTextField.selectable = YES;
    
    // ✅ 绑定 Enter 键
    self.forwardInputTextField.target = self;
    self.forwardInputTextField.action = @selector(doForward:);
    
    self.reverseInputTextField.target = self;
    self.reverseInputTextField.action = @selector(doReverse:);
}


#pragma mark - MAC Address Conversion Helpers

/**
 * 判断 syscfg key 是否是 MAC 地址类型
 */
- (BOOL)isMACAddressKey:(NSString *)key {
    static NSSet<NSString *> *macKeys = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        macKeys = [NSSet setWithArray:@[@"BMac", @"EMac", @"WMac"]];
    });
    return [macKeys containsObject:key];
}

/**
 * 将十六进制格式转换为标准 MAC 地址格式
 * @param hexString 输入格式: "0x90240FF4 0x0000E98D 0x00000000 0x00000000"
 * @return MAC 地址格式: "F4:0F:24:90:8D:E9" 或 nil（转换失败）
 */
- (NSString *)convertHexToMAC:(NSString *)hexString {
    if (!hexString || hexString.length == 0) return nil;
    
    // 提取 0xXXXXXXXX 格式的十六进制数
    NSArray<NSString *> *hex32 = [self _extractHex32Tokens:hexString];
    if (hex32.count < 2) return nil; // 至少需要 2 个 32 位数
    
    // 对每个 0xXXXXXXXX -> 4 bytes reversed
    NSMutableArray<NSString *> *chunks = [NSMutableArray array];
    for (NSString *h in hex32) {
        [chunks addObject:[self _reverseBytes32ToColonString:h]];
    }
    
    // 只取前两段（对应 8 bytes）
    NSArray<NSString *> *firstTwo = [chunks subarrayWithRange:NSMakeRange(0, MIN(2, chunks.count))];
    
    // 拼接并去掉冒号
    NSString *joined = [firstTwo componentsJoinedByString:@""];
    NSString *noColon = [[joined componentsSeparatedByCharactersInSet:
                         [NSCharacterSet characterSetWithCharactersInString:@":"]]
                         componentsJoinedByString:@""];
    
    // 去掉最后 4 个字符（2 bytes）
    if (noColon.length < 12) return nil;
    NSString *mac12 = [noColon substringToIndex:(noColon.length - 4)];
    
    // 按 2 字符插入冒号
    NSMutableArray<NSString *> *pairs = [NSMutableArray array];
    for (NSUInteger i = 0; i + 1 < mac12.length; i += 2) {
        [pairs addObject:[[mac12 substringWithRange:NSMakeRange(i, 2)] uppercaseString]];
    }
    
    return [pairs componentsJoinedByString:@":"];
}

/**
 * 将标准 MAC 地址格式转换为十六进制格式（反向转换）
 * @param macString 输入格式: "F4:0F:24:90:8D:E9" 或 "F40F24908DE9"
 * @return 十六进制格式: "0x90240FF4 0x0000E98D 0x00000000 0x00000000" 或 nil（转换失败）
 */
- (NSString *)convertMACToHex:(NSString *)macString {
    if (!macString || macString.length == 0) return nil;
    
    // 解析 MAC 地址为 6 字节数组
    uint8_t mac[6] = {0};
    if (![self _parseMAC6:macString bytes:mac]) {
        return nil;
    }
    
    // MAC 地址: F4:0F:24:90:8D:E9
    // 索引:     [0][1][2][3][4][5]
    
    // 扩展为 8 字节: F4:0F:24:90:8D:E9:00:00
    // 分成两个 4 字节块，每个块需要字节反转（小端序）
    
    // 第一个块: F4:0F:24:90 -> 反转 -> 90:24:0F:F4 -> 0x90240FF4
    uint32_t part1 = ((uint32_t)mac[3] << 24) |
                     ((uint32_t)mac[2] << 16) |
                     ((uint32_t)mac[1] << 8)  |
                     (uint32_t)mac[0];
    
    // 第二个块: 8D:E9:00:00 -> 反转 -> 00:00:E9:8D -> 0x0000E98D
    uint32_t part2 = ((uint32_t)mac[5] << 8) |
                     (uint32_t)mac[4];
    
    // 后两个固定为 0
    uint32_t part3 = 0;
    uint32_t part4 = 0;
    
    return [NSString stringWithFormat:@"0x%08X 0x%08X 0x%08X 0x%08X",
            part1, part2, part3, part4];
}


// 工具：从任意字符串提取 0xXXXXXXXX 列表
- (NSArray<NSString *> *)_extractHex32Tokens:(NSString *)text
{
    if (text.length == 0) return @[];

    NSError *err = nil;
    NSRegularExpression *re =
        [NSRegularExpression regularExpressionWithPattern:@"0x([A-Fa-f0-9]{8})"
                                                  options:0
                                                    error:&err];
    if (err) return @[];

    NSMutableArray<NSString *> *out = [NSMutableArray array];
    [re enumerateMatchesInString:text options:0 range:NSMakeRange(0, text.length)
                      usingBlock:^(NSTextCheckingResult * _Nullable result, NSMatchingFlags flags, BOOL * _Nonnull stop) {
        if (!result || result.numberOfRanges < 2) return;
        NSRange r = [result rangeAtIndex:1];
        if (r.location == NSNotFound) return;
        NSString *hex = [text substringWithRange:r];
        if (hex.length == 8) [out addObject:hex];
    }];
    return out;
}

// 工具：把 "EE75324C" -> "4C:32:75:EE"
- (NSString *)_reverseBytes32ToColonString:(NSString *)hex8
{
    // hex8 必须 8 位
    NSString *b0 = [hex8 substringWithRange:NSMakeRange(0, 2)];
    NSString *b1 = [hex8 substringWithRange:NSMakeRange(2, 2)];
    NSString *b2 = [hex8 substringWithRange:NSMakeRange(4, 2)];
    NSString *b3 = [hex8 substringWithRange:NSMakeRange(6, 2)];
    return [[NSString stringWithFormat:@"%@:%@:%@:%@",
             b3.uppercaseString, b2.uppercaseString, b1.uppercaseString, b0.uppercaseString] copy];
}

- (IBAction)doForward:(id)sender
{
    NSString *input = self.forwardInputTextField.stringValue ?: @"";
    input = [input stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    NSArray<NSString *> *hex32 = [self _extractHex32Tokens:input];
    if (hex32.count == 0) {
        self.forwardResultTextField.stringValue = @"[ER] Invalid input. Expect: 0xXXXXXXXX ...";
        return;
    }

    // 对每个 0xXXXXXXXX -> 4 bytes reversed (AA:BB:CC:DD)
    NSMutableArray<NSString *> *chunks = [NSMutableArray array];
    for (NSString *h in hex32) {
        [chunks addObject:[self _reverseBytes32ToColonString:h]]; // e.g. 4C:32:75:EE
    }

    // 只取前两段（对应 8 bytes），再去掉最后 2 bytes => 6 bytes MAC
    NSArray<NSString *> *firstTwo = [chunks subarrayWithRange:NSMakeRange(0, MIN(2, chunks.count))];

    // 拼起来： "4C:32:75:EE" + "64:46:00:00" => "4C:32:75:EE64:46:00:00"（直接拼接）
    NSString *joined = [firstTwo componentsJoinedByString:@""]; // 关键：不加分隔符

    // 去掉冒号
    NSString *noColon = [[joined componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@":"]]
                         componentsJoinedByString:@""];

    // 去掉最后 4 个字符（2 bytes），等价“去掉 0000”
    if (noColon.length < 12) { // 至少要 6 bytes
        self.forwardResultTextField.stringValue = @"[ER] Not enough data to form MAC.";
        return;
    }
    NSString *mac12 = (noColon.length >= 4) ? [noColon substringToIndex:(noColon.length - 4)] : noColon;

    // 再按 2 字符插冒号： "4C3275EE6446" -> "4C:32:75:EE:64:46"
    NSMutableArray<NSString *> *pairs = [NSMutableArray array];
    for (NSUInteger i = 0; i + 1 < mac12.length; i += 2) {
        [pairs addObject:[[mac12 substringWithRange:NSMakeRange(i, 2)] uppercaseString]];
    }

    self.forwardResultTextField.stringValue = [pairs componentsJoinedByString:@":"];
}

#pragma mark - Tools Helpers

// 解析 MAC（允许 "4C:32:75:EE:64:46" / "4C3275EE6446" / 带空格）
- (BOOL)_parseMAC6:(NSString *)text bytes:(uint8_t *)outBytes
{
    if (!outBytes) return NO;

    NSString *s = [[text ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] uppercaseString];
    if (s.length == 0) return NO;

    NSCharacterSet *nonHex = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789ABCDEF"] invertedSet];
    s = [[s componentsSeparatedByCharactersInSet:nonHex] componentsJoinedByString:@""];

    if (s.length != 12) return NO;

    for (int i = 0; i < 6; i++) {
        NSString *pair = [s substringWithRange:NSMakeRange(i * 2, 2)];
        unsigned value = 0;
        NSScanner *scanner = [NSScanner scannerWithString:pair];
        if (![scanner scanHexInt:&value]) return NO;
        outBytes[i] = (uint8_t)(value & 0xFF);
    }
    return YES;
}

#pragma mark - Tools Actions

- (IBAction)doReverse:(id)sender
{
    uint8_t mac[6] = {0};
    NSString *input = self.reverseInputTextField.stringValue ?: @"";

    if (![self _parseMAC6:input bytes:mac]) {
        self.reverseResultTextField.stringValue = @"[ER] Invalid MAC. Expect: 4C:32:75:EE:64:46";
        return;
    }

    uint32_t part1 = ((uint32_t)mac[3] << 24) | ((uint32_t)mac[2] << 16) | ((uint32_t)mac[1] << 8) | (uint32_t)mac[0];
    uint32_t part2 = ((uint32_t)mac[5] << 8)  | (uint32_t)mac[4];
    uint32_t part3 = 0;
    uint32_t part4 = 0;

    self.reverseResultTextField.stringValue =
        [NSString stringWithFormat:@"0x%08X 0x%08X 0x%08X 0x%08X", part1, part2, part3, part4];
}




#pragma mark - 焦点变化监听与 LogChannel 通知

- (void)onTextFieldDidBeginEditing:(NSNotification *)notification {
    id object = notification.object;
    
    // 检查是否是我们关心的输入框
    BOOL isOurTextField = [self isOurInputField:object];
    
    if (!isOurTextField) {
        return;  // 不是我们的输入框，忽略
    }
    
    NSString *fieldName = [self inputFieldNameForObject:object];
    NSLog(@"[Focus] ✏️ 输入框获得焦点: %@", fieldName);
    
    // ✅ 发送通知禁用 LogChannel 键盘监听
    [self notifyLogChannelKeyboardMonitoring:NO source:fieldName];
}

- (void)onTextFieldDidEndEditing:(NSNotification *)notification {
    id object = notification.object;
    
    // 检查是否是我们关心的输入框
    BOOL isOurTextField = [self isOurInputField:object];
    
    if (!isOurTextField) {
        return;
    }
    
    NSString *fieldName = [self inputFieldNameForObject:object];
    NSLog(@"[Focus] 📝 输入框失去焦点: %@", fieldName);
    
    // ✅ 延迟检查焦点去向
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        NSWindow *window = self.view.window;
        if (!window) return;
        
        id firstResponder = window.firstResponder;
        NSTextView *logTV = (NSTextView *)self.deviceLogChannel.logScrollView.documentView;
        
        // 如果焦点转移到日志区，恢复键盘监听
        if (firstResponder == logTV || [firstResponder isKindOfClass:[NSTextView class]]) {
            NSLog(@"[Focus] 📋 焦点转移到日志区，恢复LogChannel监听");
            [self notifyLogChannelKeyboardMonitoring:YES source:@"LogArea"];
        }
    });
}

- (BOOL)isOurInputField:(id)object {
    // SysCFG 输入框
    if (object == self.batteryTextField || object == self.bcmsTextField ||
        object == self.bmacTextField || object == self.CLHSTextField ||
        object == self.emacTextField || object == self.fcmsTextField ||
        object == self.lcmTextField || object == self.modeTextField ||
        object == self.modelTextField || object == self.mlbTextField ||
        object == self.mtsnTextField || object == self.nsrnTextField ||
        object == self.nvsnTextField || object == self.regionTextField ||
        object == self.snTextField || object == self.wifiTextField) {
        return YES;
    }
    
    // Tools 输入框
    if (object == self.forwardInputTextField || object == self.reverseInputTextField) {
        return YES;
    }
    
    // Console 输入区（NSTextView）
    if (object == _consoleTextView) {
        return YES;
    }
    
    // 也检查是否是这些输入框的 field editor
    if ([object isKindOfClass:[NSTextView class]]) {
        NSTextView *tv = (NSTextView *)object;
        if ([tv isFieldEditor]) {
            // 检查 delegate 是否是我们的输入框
            id delegate = tv.delegate;
            return [self isOurInputField:delegate];
        }
    }
    
    return NO;
}

- (NSString *)inputFieldNameForObject:(id)object {
    // SysCFG
    if (object == self.batteryTextField) return @"Battery";
    if (object == self.bcmsTextField) return @"BCMS";
    if (object == self.bmacTextField) return @"BMac";
    if (object == self.CLHSTextField) return @"CLHS";
    if (object == self.emacTextField) return @"EMac";
    if (object == self.fcmsTextField) return @"FCMS";
    if (object == self.lcmTextField) return @"LCM";
    if (object == self.modeTextField) return @"Mode";
    if (object == self.modelTextField) return @"Model";
    if (object == self.mlbTextField) return @"MLB";
    if (object == self.mtsnTextField) return @"MTSN";
    if (object == self.nsrnTextField) return @"NSRN";
    if (object == self.nvsnTextField) return @"NVSN";
    if (object == self.regionTextField) return @"Region";
    if (object == self.snTextField) return @"SN";
    if (object == self.wifiTextField) return @"WiFi";
    
    // Tools
    if (object == self.forwardInputTextField) return @"ForwardInput";
    if (object == self.reverseInputTextField) return @"ReverseInput";
    
    // Console
    if (object == _consoleTextView) return @"ConsoleInput";
    
    // Field Editor
    if ([object isKindOfClass:[NSTextView class]]) {
        NSTextView *tv = (NSTextView *)object;
        if ([tv isFieldEditor]) {
            return [NSString stringWithFormat:@"FieldEditor(%@)", [self inputFieldNameForObject:tv.delegate]];
        }
    }
    
    return @"Unknown";
}

- (void)notifyLogChannelKeyboardMonitoring:(BOOL)enabled source:(NSString *)source {
    NSDictionary *userInfo = @{
        @"enabled": @(enabled),
        @"source": source ?: @"DiagController"
    };
    
    [[NSNotificationCenter defaultCenter] postNotificationName:@"LogChannelKeyboardMonitoringNotification"
                                                        object:self
                                                      userInfo:userInfo];
    
    NSLog(@"[Focus] 📢 发送通知给LogChannel: %@ (来源:%@)",
          enabled ? @"启用" : @"禁用", source);
}


// 销毁监听
- (void)dealloc {
    
    // 原有的清理代码...
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:DeviceManagerDidDisconnectWithContextNotification
                                                  object:nil];
}



@end
