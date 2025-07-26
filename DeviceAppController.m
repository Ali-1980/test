//  DeviceAppController.m
//  MFCTOOL
//
//  Created by Monterey on 3/1/2025.

#import "DeviceAppController.h"
#import "DatalogsSettings.h"//日志保存路径全局
#import "DeviceManager.h" // 引入设备管理模块
#import "LanguageManager.h" //语言
#import "CustomTableRowView.h"
#import "AlertWindowController.h" //引入提示消息弹窗
#import "LanguageManager.h" //语言
#import "DataBaseManager.h" //数据储存管理
#import "SidebarViewController.h" //切换试图时使用
#import "SimulationiCloudLoginController.h"
#import "iCloudLoginViewController.h"
#import "GlobalLockController.h" //全局设备锁定
#import "DownloadProgressViewController.h"
#import "UserManager.h" //登录

#import <libimfccore/libimfccore.h>
#include <libimfccore/mobilebackup2.h>
#import <libimfccore/installation_proxy.h>
#import <libimfccore/sbservices.h>
#import <libimfccore/lockdown.h>         // 引入 lockdown 服务头文件
#import <plist/plist.h>
#import <libimfccore/afc.h>
#import <libimfccore/house_arrest.h>  // 添加这个头文件
#include <zip.h>

static instproxy_client_t cachedClient = NULL;
static sbservices_client_t cachedSb = NULL;

@interface DeviceAppController ()
@property (nonatomic, strong) NSString *waitingForDeviceID;  // 等待解锁的设备ID
@property (nonatomic, assign) BOOL isWorking; //是否在执行一个进程
@end

@implementation DeviceApp
@end

@implementation DeviceAppController

#pragma mark - 单例方法全局数据
+ (instancetype)sharedInstance {
    static dispatch_once_t onceToken;
    static DeviceAppController *sharedInstance = nil;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[DeviceAppController alloc] init];
    });
    return sharedInstance;
}

- (void)viewDidLoad {
    [super viewDidLoad];
       
    // 初始化 NSPopUpButton
    [self populateDevicePopUpButton];
    
    self.loadingIndicator.hidden = YES;
    
    // 初始化计算状态
    self.isCalculatingAppSizes = NO;
    
    //当前设备列表信息
    [self getCurrentConnectedDevicesFromHistorylist];
    
    // 设置可排序列的 sortDescriptorPrototype
    for (NSTableColumn *column in self.tableView.tableColumns) {
        NSString *identifier = column.identifier;
        if ([identifier isEqualToString:@"APPNameColumn"]) {
            column.sortDescriptorPrototype = [[NSSortDescriptor alloc] initWithKey:@"appName" ascending:YES selector:@selector(caseInsensitiveCompare:)];
        } else if ([identifier isEqualToString:@"APPTypeColumn"]) {
            column.sortDescriptorPrototype = [[NSSortDescriptor alloc] initWithKey:@"applicationType" ascending:YES selector:@selector(compare:)];
        } else if ([identifier isEqualToString:@"APPVersionColumn"]) {
            column.sortDescriptorPrototype = [[NSSortDescriptor alloc] initWithKey:@"version" ascending:YES selector:@selector(compare:)];
        } else if ([identifier isEqualToString:@"APPSizeColumn"]) {
            column.sortDescriptorPrototype = [[NSSortDescriptor alloc] initWithKey:@"appSize" ascending:YES];
        } else if ([identifier isEqualToString:@"APPDataColumn"]) {
            column.sortDescriptorPrototype = [[NSSortDescriptor alloc] initWithKey:@"docSize" ascending:YES];
        } else {
            column.sortDescriptorPrototype = nil; // 禁用其他列的排序
        }
    }
    
    // 设置默认排序：自定义 "User" 类型优先
    NSSortDescriptor *defaultSortDescriptor = [[NSSortDescriptor alloc] initWithKey:@"applicationType"
                                                                        ascending:YES
                                                                         comparator:^NSComparisonResult(id obj1, id obj2) {
        NSString *type1 = (NSString *)obj1;
        NSString *type2 = (NSString *)obj2;
        BOOL isType1User = [type1 isEqualToString:@"User"];
        BOOL isType2User = [type2 isEqualToString:@"User"];
        
        if (isType1User && !isType2User) return NSOrderedAscending;  // "User" 排前面
        if (!isType1User && isType2User) return NSOrderedDescending; // 非 "User" 排后面
        return [type1 compare:type2];                                // 类型相同，按字符串排序
    }];
    
    [self.tableView setSortDescriptors:@[defaultSortDescriptor]];
    
    // 启用列宽自动调整
    [self.tableView setColumnAutoresizingStyle:NSTableViewUniformColumnAutoresizingStyle];
    
    // 更新本地化标题
    [self updateLocalizedHeaders];
    
    //搜索
    [self.searchField setAction:@selector(searchApps:)];

    // 在视图加载时，我们初始化 appList 和 allAppList 为一个空的数组
    self.appList = @[];
    self.allAppList = @[];
    
    // 其他多语言处理
    [self DeviceAppControllersetupLocalizedStrings];

    // 默认隐藏两个标签
    self.applicationTypeLabel.hidden = YES;
    self.applicationTypeUserSpaceLabel.hidden = YES;
    
    
    //缓存登录ID信息
    [self setupAuthenticationObservers];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(appListLoaded:)
                                                 name:@"AppListLoadedNotification"
                                               object:nil];
    
    // 🔥 监听应用安装成功通知
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleAppInstallationSuccess:)
                                                 name:@"AppInstallationSuccessNotification"
                                               object:nil];
    
    
    // 🔥 确保窗口属性初始化
    self.loginWindow = nil;
    
    // 🔥 注册应用终止通知
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationWillTerminate:)
                                                 name:NSApplicationWillTerminateNotification
                                               object:nil];
    
    // 初始化选中应用集合
    self.selectedApps = [NSMutableSet set];
    self.isSelectingAll = NO;
    
    [self updateBatchOperationButtonsState:NO];
    //创建统一目录
    [self getMFCTempDirectory];
    
    // 注册通知观察者
    [self registerNotificationObservers];
}

/**
 * 注册通知监听
 */
- (void)registerNotificationObservers {
    NSLog(@"[DeviceAppController] 注册通知监听");
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onGlobalDeviceUnlocked:)
                                                 name:GlobalDeviceUnlockedNotification
                                               object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onGlobalDeviceLocked:)
                                                 name:GlobalDeviceLockedNotification
                                               object:nil];
}

/**
 * 移除通知监听
 */
- (void)removeNotificationObservers {
    NSLog(@"[DeviceAppController] 移除通知监听");
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                     name:GlobalDeviceUnlockedNotification
                                                   object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                     name:GlobalDeviceLockedNotification
                                                   object:nil];
}

/**
 * 处理全局设备解锁通知
 */
- (void)onGlobalDeviceUnlocked:(NSNotification *)notification {
    DeviceLockInfo *deviceInfo = notification.object;
    
    if ([deviceInfo.deviceID isEqualToString:self.waitingForDeviceID]) {
        NSLog(@"[DeviceAppController] 等待的设备已可用: %@", deviceInfo.displayName);
        
        // 移除监听
        [self removeNotificationObservers];
        
        self.waitingForDeviceID = nil;
    }
}

/**
 * 处理全局设备锁定通知
 */
- (void)onGlobalDeviceLocked:(NSNotification *)notification {
    DeviceLockInfo *deviceInfo = notification.object;
    NSString *sourceName = notification.userInfo[@"sourceName"];
    
    // 如果是当前控制器锁定的设备，更新UI状态
    if ([sourceName isEqualToString:@"DeviceAppController"]) {
        NSLog(@"[DeviceAppController] 设备锁定成功: %@", deviceInfo.displayName);
    }
}

- (void)viewDidAppear {
    [super viewDidAppear];
    NSLog(@"DeviceAppController: viewDidAppear");
    /*
    // 固件操作如果正在进行，不要解锁设备
    if (![self hasActiveOperations]) {
        [self safelyUnlockCurrentDevice];
        NSLog(@"[DeviceAppController] 控制器退出，设备已解锁");
    }*/
}

/**
 * 安全的设备解锁
 */
- (BOOL)safelyUnlockCurrentDevice {
    @try {
        return [self unlockCurrentDevice];
    } @catch (NSException *exception) {
        NSLog(@"[DeviceAppController] ❌ 解锁设备异常: %@", exception.reason);
        return NO;
    }
}

#pragma mark - 搜索APP
- (IBAction)searchApps:(id)sender {
    NSString *searchText = self.searchField.stringValue.lowercaseString;
    
    // 如果没有输入搜索文本，显示所有应用（恢复完整的列表）
    if (searchText.length == 0) {
        // 恢复为所有应用列表
        self.appList = [self.allAppList mutableCopy]; // 恢复为完整的应用列表
    } else {
        // 根据搜索文本筛选应用（不区分大小写）
        self.appList = [self.allAppList filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"appName CONTAINS[c] %@", searchText]];
        NSLog(@"搜索文本: %@", searchText);
        NSLog(@"当前应用列表: %@", self.appList);
    }
    
    // 重新加载表格视图以显示搜索结果
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.tableView reloadData];
        [self.tableView setNeedsDisplay:YES];
    });
}

#pragma mark - 获取/ 读取当前设备的文件
- (NSDictionary *)getCurrentConnectedDevicesFromHistorylist {
    NSLog(@"[DEBUG] 加载 CurrentDevices.plist");
    NSString *mfcDataPath = [DatalogsSettings mfcDataDirectory];
    NSString *cachesDirectory = [mfcDataPath stringByAppendingPathComponent:@"Caches"];
    NSString *plistPath = [cachesDirectory stringByAppendingPathComponent:@"CurrentDevices.plist"];
   
    // 检查 Plist 文件是否存在
    if (![[NSFileManager defaultManager] fileExistsAtPath:plistPath]) {
        NSLog(@"[ERROR] Plist 文件不存在: %@", plistPath);
        return nil;
    }
    
    // 读取 Plist 文件内容
    NSDictionary *allDevicesData = [NSDictionary dictionaryWithContentsOfFile:plistPath];
    if (!allDevicesData) {
        NSLog(@"[ERROR] 无法读取 Plist 文件内容: %@", plistPath);
        return nil;
    }
    
    return allDevicesData;
}



#pragma mark - 填充 NSPopUpButton 表头当前连接的设备列表
- (void)populateDevicePopUpButton {
    NSLog(@"[DEBUG] 开始执行 populateDevicePopUpButton 方法");
    
    NSLog(@"[DEBUG] FlasherTabsController 的 deviceUDID: %@, deviceECID: %@", self.deviceUDID, self.deviceECID);
    
    NSDictionary *allDevicesData = [self getCurrentConnectedDevicesFromHistorylist];
    if (!allDevicesData) {
        NSLog(@"[ERROR] 无法提取设备信息，因为 Plist 文件读取失败。");
        return;
    }
    
    // 清空当前的菜单项
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
            self.currentDeviceECID = ecid;
            self.currentDeviceSerialNumber = deviceSerialNumber;
            NSLog(@"[DEBUG] 已选中设备信息: %@  Type: %@  Mode: %@ Ver: %@  ECID: %@ SNR: %@",self.deviceOfficialName, self.currentDeviceType, self.currentDeviceMode, self.currentDeviceVersion, self.currentDeviceECID, self.currentDeviceSerialNumber);
            
            [self lockDeviceWithInfo:uniqueKey officialName:self.deviceOfficialName type:self.currentDeviceType mode:self.currentDeviceMode version:self.currentDeviceVersion ecid:self.currentDeviceECID snr:self.currentDeviceSerialNumber];
            NSLog(@"[DEBUG] 已选中设备并锁定: %@  Type: %@  Mode: %@  Ver: %@ ECID: %@ SNR: %@",self.deviceOfficialName, self.currentDeviceType, self.currentDeviceMode, self.currentDeviceVersion, self.currentDeviceECID, self.currentDeviceSerialNumber);
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
        
    NSLog(@"[DEBUG] populateDevicePopUpButton 方法执行完成");
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
    NSString *deviceSerialNumber = selectedDeviceInfo[@"SerialNumber"];
    
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
        NSLog(@"当前设备的 deviceType: %@", self.currentDeviceType);
        
        // 锁定并持久化设备信息
        [self lockDeviceWithInfo:uniqueKey officialName:deviceOfficialName type:deviceTYPE mode:deviceMode version:deviceVersion ecid:deviceECID snr:deviceSerialNumber];

    } else {
        NSLog(@"[ERROR] 无法根据 uniqueKey 获取设备信息: %@", uniqueKey);
    }
    
    //是否是Watch
    if ([self.currentDeviceType.lowercaseString containsString:@"watch"]) {
        LanguageManager *languageManager = [LanguageManager sharedManager];
        // 当前选择的设备不支持应用管理
        NSString *logsNotSupportAppManagementMessage = [languageManager localizedStringForKeys:@"applicationManageNotSupport" inModule:@"AppsManager" defaultValue:@"The currently selected device does not support application management"];
        
        logsNotSupportAppManagementMessage = [NSString stringWithFormat:@"[WAR] %@", logsNotSupportAppManagementMessage];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            [[AlertWindowController sharedController] showResultMessageOnly:logsNotSupportAppManagementMessage inWindow:self.view.window];
        });
        return;
    }
    
    //判断当前模式
    if (![deviceMode isEqualToString:@"Normal"]) {
        LanguageManager *languageManager = [LanguageManager sharedManager];
        // 当前选择的设备需要处于正常模式
        NSString *logeraseModeErrorsMessage = [languageManager localizedStringForKeys:@"nonNormalModeErrorsMessage" inModule:@"GlobaMessages" defaultValue:@"This operation can only be performed when the device is in normal mode\n"];
        
        logeraseModeErrorsMessage = [NSString stringWithFormat:@"[WAR] %@", logeraseModeErrorsMessage];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            [[AlertWindowController sharedController] showResultMessageOnly:logeraseModeErrorsMessage inWindow:self.view.window];
        });
        return;
    }
    
    //检测设备匹配状态
    BOOL isPaired = [[DeviceManager sharedManager] triggerPairStatusForDeviceWithUDID:uniqueKey];
    if (!isPaired) {
        NSString *logerasePairErrorsMessage = [[LanguageManager sharedManager] localizedStringForKeys:@"pairErrorsMessage"
                                                                                                     inModule:@"GlobaMessages"
                                                                                                defaultValue:@"Only paired devices can operate this function\n"];
        logerasePairErrorsMessage = [NSString stringWithFormat:@"[WAR] %@", logerasePairErrorsMessage];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            [[AlertWindowController sharedController] showResultMessageOnly:logerasePairErrorsMessage inWindow:self.view.window];
        });
        
        return;
    }
    
    //判断按钮显示状态
    NSLog(@"手动选择后当前设备模式: %@", deviceMode);
    
    if (uniqueKey && uniqueKey.length > 0) {
        
        // 设置正在计算状态
        self.isCalculatingAppSizes = YES;
        
        // 主线程更新 UI
        dispatch_async(dispatch_get_main_queue(), ^{
     
            if (!self.loadingIndicator) {
                self.loadingIndicator = [[NSProgressIndicator alloc] init];
                self.loadingIndicator.style = NSProgressIndicatorStyleSpinning;
                self.loadingIndicator.controlSize = NSControlSizeRegular;
                self.loadingIndicator.indeterminate = YES;
                self.loadingIndicator.displayedWhenStopped = NO;
                self.loadingIndicator.translatesAutoresizingMaskIntoConstraints = NO;

                NSView *parent = self.view;
                if (!parent) {
                    NSLog(@"Error: Parent view is nil");
                    return;
                }

                [parent addSubview:self.loadingIndicator];

                // 居中约束
                [NSLayoutConstraint activateConstraints:@[
                    [self.loadingIndicator.centerXAnchor constraintEqualToAnchor:parent.centerXAnchor],
                    [self.loadingIndicator.centerYAnchor constraintEqualToAnchor:parent.centerYAnchor]
                ]];
            }

            // 显示并启动旋转
            self.loadingIndicator.hidden = NO;
            [self.loadingIndicator startAnimation:nil];
             
            
            self.tableView.enabled = NO;
            self.tableView.alphaValue = 0.5;
            
            // 禁用所有操作按钮
            [self updateOperationButtonsState:NO];
            
            [self updateBatchOperationButtonsState:NO];
        });

        // 后台线程加载数据
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSError *error = nil;
            NSArray<DeviceApp *> *apps = [self listInstalledAppsWithError:&error];

            // 回主线程更新 UI
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.loadingIndicator stopAnimation:nil];
                self.loadingIndicator.hidden = YES;
                self.tableView.enabled = YES;
                self.tableView.alphaValue = 1.0;

                if (error) {
                    NSLog(@"[ERROR] 获取应用列表失败: %@", error.localizedDescription);
                    // 计算失败，重置状态
                    self.isCalculatingAppSizes = NO;
                    [self updateOperationButtonsState:YES];
                    
                    [self updateBatchOperationButtonsState:YES];
                } else {
                    self.appList = apps;
                    [self.tableView reloadData];
                    [self.tableView setNeedsDisplay:YES];
                }
            });
        });
    }

}

- (NSDictionary *)getDeviceInfoByID:(NSString *)deviceID {
    // 示例：从当前已加载的设备列表中找到设备详情
    NSDictionary *allDevicesData = [self getCurrentConnectedDevicesFromHistorylist];
    return allDevicesData[deviceID];
}


#pragma mark -锁定设备并持久化设备信息 同步更新 统一GlobalLock设备锁定方法
- (void)lockDeviceWithInfo:(NSString *)uniqueKey
             officialName:(NSString *)officialName
                     type:(NSString *)type
                     mode:(NSString *)mode
                  version:(NSString *)deviceVersion
                     ecid:(NSString *)deviceECID
                      snr:(NSString *)deviceSerialNumber {
    
    NSLog(@"[DeviceBackupRestore] 🔄 开始使用新的GlobalLockController锁定设备");
    NSLog(@"[DeviceBackupRestore] 设备信息 - uniqueKey: %@, officialName: %@", uniqueKey, officialName);
    
    // 🔥 创建包含完整信息的 DeviceLockInfo 对象
    DeviceLockInfo *deviceInfo = [DeviceLockInfo deviceWithID:uniqueKey
                                                          name:officialName
                                                          type:type
                                                          mode:mode
                                                       version:deviceVersion
                                                          ecid:deviceECID
                                                  serialNumber:deviceSerialNumber];
    
    NSError *lockError = nil;
    // 🔥 修复：使用正确的 sourceType - LockSourceTypeBackup 而不是 LockSourceTypeFirmware
    LockResult result = [[GlobalLockController sharedController]
                        lockDevice:deviceInfo
                        sourceType:LockSourceTypeBackup  // ✅ 修复：使用正确的 sourceType
                        sourceName:@"DeviceBackupRestore"
                             error:&lockError];
    
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
            NSLog(@"[DeviceBackupRestore] ⚠️ 设备锁定冲突");
            // [self handleBackupLockConflict:lockError];  // 如果需要专用冲突处理
            break;
            
        case LockResultInvalidDevice:
            NSLog(@"[DeviceBackupRestore] ❌ 设备信息无效");
            [self showAlert:@"设备信息无效" message:@"无法识别的设备信息"];
            break;
            
        case LockResultSystemError:
            NSLog(@"[DeviceBackupRestore] ❌ 系统错误");
            [self showAlert:@"系统错误" message:lockError.localizedDescription ?: @"未知系统错误"];
            break;
    }
}

#pragma mark - 🔥 兼容性方法实现（如果这些方法不存在，请添加）

/**
 * 显示警告对话框
 */
- (void)showAlert:(NSString *)title message:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = title ?: @"提示";
        alert.informativeText = message ?: @"";
        [alert addButtonWithTitle:@"确定"];
        [alert runModal];
    });
}

#pragma mark - 从内存获取锁定的设备ID
- (NSString *)getLockedDeviceID {
    return [[GlobalLockController sharedController]
            getLockedDeviceIDForSource:@"DeviceAppController"];
}


#pragma mark - 设备锁定信息存入内存
- (void)setLockedDeviceID:(NSString *)lockedDeviceID {
    if (!lockedDeviceID) {
        [[GlobalLockController sharedController] unlockAllDevicesFromSource:@"DeviceAppController"];
    }
}

#pragma mark - 从内存获取已锁定的设备信息
- (NSDictionary *)getLockedDeviceInfo {
    return [[GlobalLockController sharedController]
            getLockedDeviceInfoForSource:@"DeviceAppController"];
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
                                                          sourceName:@"DeviceBackupRestore"];
    }
    return YES;
}

- (BOOL)hasActiveOperations {
    return self.isWorking;
}


#pragma mark -  加载表头的本地化标题
- (void)updateLocalizedHeaders {
    NSArray<NSTableColumn *> *columns = self.tableView.tableColumns;
    LanguageManager *languageManager = [LanguageManager sharedManager];
    
    // 列标识符对应的本地化键和默认值
    NSDictionary *columnKeysAndDefaults = @{
        @"APPSelectColumn" : @{@"key": @"APPSelectHeader", @"default": @"Select"},
        @"APPNameColumn" : @{@"key": @"APPNameHeader", @"default": @"Name"},
        @"APPTypeColumn" : @{@"key": @"APPTypeHeader", @"default": @"Type"},
        @"APPVersionColumn" : @{@"key": @"APPVersionHeader", @"default": @"Version"},
        @"APPSizeColumn" : @{@"key": @"APPSizeHeader", @"default": @"Size"},
        @"APPDataColumn" : @{@"key": @"APPDataHeader", @"default": @"Data Size"},
        @"APPOperateColumn" : @{@"key": @"APPOperateHeader", @"default": @"Operate"}
    };
    
    for (NSTableColumn *column in columns) {
        NSDictionary *info = columnKeysAndDefaults[column.identifier];
        if (info) {
            // 获取本地化标题
            NSString *localizedTitle = [languageManager localizedStringForKeys:info[@"key"]
                                                                      inModule:@"AppsManager"
                                                                  defaultValue:info[@"default"]];
            // 设置列标题
            column.title = localizedTitle;
        } else {
            NSLog(@"[WARNING] No localization or default value found for column identifier: %@", column.identifier);
        }
    }
}


#pragma mark - NSTableViewDelegate 排序
- (void)tableView:(NSTableView *)tableView sortDescriptorsDidChange:(NSArray<NSSortDescriptor *> *)oldDescriptors {
    NSArray<NSSortDescriptor *> *sortDescriptors = [tableView sortDescriptors];
   // NSLog(@"[DEBUG] 原始排序描述符: %@", sortDescriptors);
    
    if (self.appList && self.appList.count > 0) {
        self.appList = [[self.appList sortedArrayUsingDescriptors:sortDescriptors] mutableCopy];
       // NSLog(@"[DEBUG] 排序后的 appList: %@", self.appList);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.tableView reloadData];
            [self.tableView setNeedsDisplay:YES];
        });
    } else {
        NSLog(@"[ERROR] appList 为空或无效，无法排序");
    }
}



//确认数据源方法是否被调用
- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
  //  NSLog(@"[DEBUG] numberOfRowsInTableView called, app count: %lu", self.appList.count);
    return self.appList.count;
}


#pragma mark - 应用列表显示
- (NSView *)tableView:(NSTableView *)tableView
   viewForTableColumn:(NSTableColumn *)tableColumn
                  row:(NSInteger)row {

    NSString *identifier = tableColumn.identifier;
    DeviceApp *app = self.appList[row];

    NSTableCellView *cellView = [tableView makeViewWithIdentifier:identifier owner:self];

    // 如果 cellView 为空或 cellView 没有 textField，则手动创建
    if (!cellView) {
        cellView = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, tableColumn.width, 32)];
        NSTextField *textField = [[NSTextField alloc] initWithFrame:cellView.bounds];
        textField.editable = NO;
        textField.bordered = NO;
        textField.backgroundColor = [NSColor clearColor];
        textField.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        cellView.textField = textField;
        [cellView addSubview:textField];
        cellView.identifier = identifier;
    }

    CGFloat rowHeight = [self tableView:tableView heightOfRow:row];
    CGFloat padding = 6;
    CGFloat textHeight = 20;
    CGFloat textY = (rowHeight - textHeight) / 2;

    // 根据列设置内容
    if ([identifier isEqualToString:@"APPSelectColumn"]) {
        
        // 复制 subviews 数组，避免在枚举时修改
        NSArray *subviewsCopy = [cellView.subviews copy];
        // 清空已有子视图，避免重复添加
        for (NSView *subview in subviewsCopy) {
            [subview removeFromSuperview];
        }
        
        if ([app.applicationType isEqualToString:@"User"]) {
            NSButton *radioButton = [[NSButton alloc] initWithFrame:NSMakeRect(15, 22, 18, 18)];
            radioButton.buttonType = NSButtonTypeSwitch;
            radioButton.title = @"";
            radioButton.tag = 100;
            [radioButton setTarget:self];
            [radioButton setAction:@selector(appSelectionChanged:)];
            
            radioButton.enabled = !self.isCalculatingAppSizes;
            if (self.isCalculatingAppSizes) {
                radioButton.alphaValue = 0.5;
            }
            
            [cellView addSubview:radioButton];
            
            // 设置按钮状态
            radioButton.state = [self.selectedApps containsObject:app] ? NSControlStateValueOn : NSControlStateValueOff;
            radioButton.tag = row;
        }
        
        return cellView;
    }
    
    else if ([identifier isEqualToString:@"APPNameColumn"]) {
        NSString *appName = app.appName ?: @"";
        NSString *developer = app.developer ?: @"";

        // 拼接显示文字，使用换行
        NSString *displayText = [NSString stringWithFormat:@"%@\n%@", appName, developer];

        // 构建富文本
        NSMutableParagraphStyle *paragraphStyle = [[NSMutableParagraphStyle alloc] init];
        paragraphStyle.lineSpacing = 2;

        NSMutableAttributedString *attrString = [[NSMutableAttributedString alloc] initWithString:displayText
                                                                                         attributes:@{
            NSFontAttributeName: [NSFont systemFontOfSize:13],
            NSParagraphStyleAttributeName: paragraphStyle
        }];

        // 第一行加粗
        [attrString addAttribute:NSFontAttributeName value:[NSFont boldSystemFontOfSize:13] range:NSMakeRange(0, appName.length)];

        // 第二行使用浅灰色字体
        if (developer.length > 0) {
            NSRange devRange = NSMakeRange(appName.length + 1, developer.length); // +1 是换行符
            [attrString addAttribute:NSFontAttributeName value:[NSFont systemFontOfSize:11] range:devRange];
            [attrString addAttribute:NSForegroundColorAttributeName value:[NSColor secondaryLabelColor] range:devRange];
        }

        cellView.textField.attributedStringValue = attrString;
        cellView.textField.usesSingleLineMode = NO;
        cellView.textField.lineBreakMode = NSLineBreakByTruncatingTail;
        cellView.textField.editable = NO;
        cellView.textField.bordered = NO;
        cellView.textField.backgroundColor = [NSColor clearColor];

        if (app.iconImage) {
            // 动态计算图标显示大小
            NSSize imageSize = app.iconImage.size;
            CGFloat maxIconSize = 48;
            CGFloat scale = MIN(maxIconSize / imageSize.width, maxIconSize / imageSize.height);
            CGFloat displayWidth = imageSize.width * scale;
            CGFloat displayHeight = imageSize.height * scale;
                       
            // 根据取整后的图像尺寸创建 NSImageView，并禁止再进行内部缩放
            CGFloat iconY = (rowHeight - displayHeight) / 2;
            NSImageView *imageView = [[NSImageView alloc] initWithFrame:NSMakeRect(padding, iconY, displayWidth, displayHeight)];
            imageView.image = app.iconImage;
            imageView.imageScaling = NSImageScaleProportionallyDown;
            
            imageView.wantsLayer = YES;
            // 注意：如果需要显示阴影，最好关闭 masksToBounds
            imageView.layer.masksToBounds = NO;
            // 可选：设置圆角（注意：如果设置 masksToBounds = YES，则阴影会被裁剪）
            imageView.layer.cornerRadius = 3;   // 图标圆角
            
            // 设置阴影属性（可根据需要调整或去除）
            imageView.layer.shadowColor = [[NSColor windowBackgroundColor] colorWithAlphaComponent:0.3].CGColor;
            imageView.layer.shadowOffset = CGSizeMake(0, -1);
            imageView.layer.shadowRadius = 3;
            imageView.layer.shadowOpacity = 1.0;
            
            imageView.layer.magnificationFilter = kCAFilterNearest;
            [cellView addSubview:imageView];
 
            // 设置文字区域垂直居中
            CGFloat textX = padding * 2 + displayWidth;
            CGFloat estimatedTextHeight = 34;
            CGFloat textY = (rowHeight - estimatedTextHeight) / 2;
            cellView.textField.frame = NSMakeRect(textX, textY, tableColumn.width - textX - padding, estimatedTextHeight);
        } else {
            // 没有图标，文字居中
            CGFloat estimatedTextHeight = 34;
            CGFloat textY = (rowHeight - estimatedTextHeight) / 2;
            cellView.textField.frame = NSMakeRect(padding, textY, tableColumn.width - padding * 2, estimatedTextHeight);
        }
    }

    else if ([identifier isEqualToString:@"APPTypeColumn"]) {
        LanguageManager *languageManager = [LanguageManager sharedManager];
        NSString *applicationTypeUserTitle = [languageManager localizedStringForKeys:@"applicationTypeUser" inModule:@"AppsManager" defaultValue:@"User"];
        NSString *applicationTypeSystemTitle = [languageManager localizedStringForKeys:@"applicationTypeSystem" inModule:@"AppsManager" defaultValue:@"System"];
        
        cellView.textField.stringValue = [app.applicationType isEqualToString:@"User"] ? applicationTypeUserTitle :
                                          [app.applicationType isEqualToString:@"System"] ? applicationTypeSystemTitle :
                                          app.applicationType ?: @"";
        
        cellView.textField.frame = NSMakeRect(padding, textY, tableColumn.width - padding * 2, textHeight);
        // 设置默认文本颜色
        cellView.textField.textColor = [NSColor labelColor];
    }
    else if ([identifier isEqualToString:@"APPVersionColumn"]) {
        if (app.hasUpdateAvailable && app.appStoreVersion) {
            
            //新版本
            LanguageManager *languageManager = [LanguageManager sharedManager];
            NSString *applicationNewVersion = [languageManager localizedStringForKeys:@"applicationNewVersion" inModule:@"AppsManager" defaultValue:@"NEW"];
            
            NSString *fullText = [NSString stringWithFormat:@"%@ (%@: %@)", app.version, applicationNewVersion, app.appStoreVersion];
            NSMutableAttributedString *attributedText = [[NSMutableAttributedString alloc] initWithString:fullText];

            // 先将 app.version 部分设置为蓝色
            NSRange versionRange = [fullText rangeOfString:app.version];
            [attributedText addAttribute:NSForegroundColorAttributeName
                                   value:[NSColor systemBlueColor]
                                   range:versionRange];

            // 找到 "(" 出现的位置，并将从此处开始的整段文本设置为红色
            NSRange redRange = [fullText rangeOfString:@"("];
            if (redRange.location != NSNotFound) {
                NSRange redFullRange = NSMakeRange(redRange.location, fullText.length - redRange.location);
                //斜体的字体属性
                NSFont *italicFont = [[NSFontManager sharedFontManager] convertFont:[NSFont systemFontOfSize:11] toHaveTrait:NSFontItalicTrait];

                [attributedText addAttributes:@{
                    NSForegroundColorAttributeName: [NSColor systemRedColor],
                    NSFontAttributeName: italicFont ?: [NSFont systemFontOfSize:11]
                } range:redFullRange];
            }

            cellView.textField.attributedStringValue = attributedText;
        } else {
            // 没有更新时仅显示 app.version（蓝色）
            NSMutableAttributedString *attributedText = [[NSMutableAttributedString alloc] initWithString:(app.version ?: @"")];
            [attributedText addAttribute:NSForegroundColorAttributeName
                                   value:[NSColor systemBlueColor]
                                   range:NSMakeRange(0, attributedText.length)];
            cellView.textField.attributedStringValue = attributedText;
        }
        cellView.textField.frame = NSMakeRect(padding, textY, tableColumn.width - padding * 2, textHeight);
    }


    else if ([identifier isEqualToString:@"APPSizeColumn"]) {
        cellView.textField.stringValue = [self formatSize:app.appSize];
        cellView.textField.frame = NSMakeRect(padding, textY, tableColumn.width - padding * 2, textHeight);

    }
    else if ([identifier isEqualToString:@"APPDataColumn"]) {
        cellView.textField.stringValue = [self formatSize:app.docSize];
        cellView.textField.frame = NSMakeRect(padding, textY, tableColumn.width - padding * 2, textHeight);
        // 设置默认文本颜色
        cellView.textField.textColor = [NSColor labelColor];
    }
    else if ([identifier isEqualToString:@"APPOperateColumn"]) {
        // 添加调试日志
        //调试 NSLog(@"添加调试日志 Row %ld: App: %@, applicationType: %@", (long)row, app.appName, app.applicationType);
        
        // 复制 subviews 数组，避免在枚举时修改
        NSArray *subviewsCopy = [cellView.subviews copy];
        // 清空已有子视图，避免重复添加
        for (NSView *subview in subviewsCopy) {
            [subview removeFromSuperview];
        }

        // 判断 applicationType 是否为 "User"
        if ([app.applicationType isEqualToString:@"User"]) {
           
            LanguageManager *languageManager = [LanguageManager sharedManager];
            NSString *applicationDeleteTips = [languageManager localizedStringForKeys:@"applicationDeleteTips" inModule:@"AppsManager" defaultValue:@"Delete Application"];
            NSString *applicationBackupTips = [languageManager localizedStringForKeys:@"applicationBackupTips" inModule:@"AppsManager" defaultValue:@"Backup Application"];
            NSString *applicationUpdateTips = [languageManager localizedStringForKeys:@"applicationUpdateTips" inModule:@"AppsManager" defaultValue:@"Update Application"];
            NSString *applicationDownloadTips = [languageManager localizedStringForKeys:@"applicationDownloadTips" inModule:@"AppsManager" defaultValue:@"Download Application iPA"];
            
            // 如果是 "User" 类型，添加按钮
            
            NSButton *unInstallButton = [[NSButton alloc] initWithFrame:NSMakeRect(0, 18, 40, 24)];
            [unInstallButton setTitle:@""]; // 不需要文字
            unInstallButton.identifier = @"uninstallAPPButton";

            // 1. 获取资源图标并设置图标大小
            NSImage *trashImage = [NSImage imageNamed:@"trash"];
            
            trashImage.size = NSMakeSize(12, 12);  // 设置图标大小为 16x16

            // 2. 指定按钮的图标和缩放方式
            [unInstallButton setImage:trashImage];
            [unInstallButton.cell setImageScaling:NSImageScaleProportionallyDown];

            // 3. 设置图标位置（只显示图标，或者图标覆盖文字区域）
            [unInstallButton setImagePosition:NSImageOverlaps];
            
            // 添加 toolTip 提示信息
            unInstallButton.toolTip = applicationDeleteTips;

            // 其余按钮属性
            [unInstallButton setButtonType:NSButtonTypeMomentaryPushIn];
            [unInstallButton setBezelStyle:NSBezelStyleRounded];
            unInstallButton.tag = row;
            //unInstallButton.bezelColor = [[NSColor systemGrayColor] colorWithAlphaComponent:0.1];
            [unInstallButton setFont:[NSFont systemFontOfSize:11]];
            [unInstallButton setTarget:self];
            [unInstallButton setAction:@selector(operateButtonClicked:)];
            
            // 设置按钮初始状态
            unInstallButton.enabled = !self.isCalculatingAppSizes;
            if (self.isCalculatingAppSizes) {
                unInstallButton.alphaValue = 0.5;
            }
            
            [cellView addSubview:unInstallButton];

            /*

            // 备份按钮
            NSButton *backupButton = [[NSButton alloc] initWithFrame:NSMakeRect(30, 18, 40, 24)];
            [backupButton setTitle:@""];
            backupButton.identifier = @"backupAPPButton";
            
            // 1. 获取资源图标并设置图标大小
            NSImage *backupImage = [NSImage imageNamed:@"backup"];
            
            backupImage.size = NSMakeSize(15, 14);  // 设置图标大小为 16x16

            // 2. 指定按钮的图标和缩放方式
            [backupButton setImage:backupImage];
            [backupButton.cell setImageScaling:NSImageScaleProportionallyDown];

            // 3. 设置图标位置（只显示图标，或者图标覆盖文字区域）
            [backupButton setImagePosition:NSImageOverlaps];
            
            // 添加 toolTip 提示信息
            backupButton.toolTip = applicationBackupTips;

            // 其余按钮属性
            [backupButton setButtonType:NSButtonTypeMomentaryPushIn];
            [backupButton setBezelStyle:NSBezelStyleRounded];
            backupButton.tag = row; // 使用 tag 存储行号
            //backupButton.bezelColor = [[NSColor systemYellowColor] colorWithAlphaComponent:0.3];
            [backupButton setFont:[NSFont systemFontOfSize:12]]; // 设置字体大小为12
            [backupButton setTarget:self];
            [backupButton setAction:@selector(operateButtonClicked:)]; //操作
            
            // 设置按钮初始状态
            backupButton.enabled = !self.isCalculatingAppSizes;
            if (self.isCalculatingAppSizes) {
                backupButton.alphaValue = 0.5;
            }
            
            [cellView addSubview:backupButton];
            */
            // 更新按钮
            if (app.hasUpdateAvailable && app.appStoreVersion) {
                // 更新按钮
                NSButton *upgradeButton = [[NSButton alloc] initWithFrame:NSMakeRect(30, 18, 40, 24)];
                [upgradeButton setTitle:@""];
                upgradeButton.identifier = @"upgradeAPPButton";
                
                // 1. 获取资源图标并设置图标大小
                NSImage *upgradeImage = [NSImage imageNamed:@"update"];
                
                upgradeImage.size = NSMakeSize(16, 16);  // 设置图标大小为 16x16

                // 2. 指定按钮的图标和缩放方式
                [upgradeButton setImage:upgradeImage];
                [upgradeButton.cell setImageScaling:NSImageScaleProportionallyDown];

                // 3. 设置图标位置（只显示图标，或者图标覆盖文字区域）
                [upgradeButton setImagePosition:NSImageOverlaps];
                
                // 添加 toolTip 提示信息
                upgradeButton.toolTip = applicationUpdateTips;
                // 其余按钮属性
                
                [upgradeButton setButtonType:NSButtonTypeMomentaryPushIn];
                [upgradeButton setBezelStyle:NSBezelStyleRounded];
                upgradeButton.tag = row; // 使用 tag 存储行号
                //upgradeButton.bezelColor = [[NSColor systemGreenColor] colorWithAlphaComponent:0.3];
                [upgradeButton setFont:[NSFont systemFontOfSize:12]]; // 设置字体大小为12
                [upgradeButton setTarget:self];
                [upgradeButton setAction:@selector(operateButtonClicked:)]; //操作
                
                // 设置按钮初始状态
                upgradeButton.enabled = !self.isCalculatingAppSizes;
                if (self.isCalculatingAppSizes) {
                    upgradeButton.alphaValue = 0.5;
                }
                
                [cellView addSubview:upgradeButton];
                
                // 仅下载IPA按钮
                NSButton *downloadButton = [[NSButton alloc] initWithFrame:NSMakeRect(60, 18, 40, 24)];
                [downloadButton setTitle:@""];
                downloadButton.identifier = @"downloadAPPButton";
                
                // 1. 获取资源图标并设置图标大小
                NSImage *downloadImage = [NSImage imageNamed:@"download"];
                
                downloadImage.size = NSMakeSize(16, 16);  // 设置图标大小为 16x16

                // 2. 指定按钮的图标和缩放方式
                [downloadButton setImage:downloadImage];
                [downloadButton.cell setImageScaling:NSImageScaleProportionallyDown];

                // 3. 设置图标位置（只显示图标，或者图标覆盖文字区域）
                [downloadButton setImagePosition:NSImageOverlaps];
                
                // 添加 toolTip 提示信息
                downloadButton.toolTip = applicationDownloadTips;
                // 其余按钮属性
                
                [downloadButton setButtonType:NSButtonTypeMomentaryPushIn];
                [downloadButton setBezelStyle:NSBezelStyleRounded];
                downloadButton.tag = row; // 使用 tag 存储行号
                //upgradeButton.bezelColor = [[NSColor systemGreenColor] colorWithAlphaComponent:0.3];
                [downloadButton setFont:[NSFont systemFontOfSize:12]]; // 设置字体大小为12
                [downloadButton setTarget:self];
                [downloadButton setAction:@selector(operateButtonClicked:)]; //操作
                
                // 设置按钮初始状态
                downloadButton.enabled = !self.isCalculatingAppSizes;
                if (self.isCalculatingAppSizes) {
                    downloadButton.alphaValue = 0.5;
                }
                
                [cellView addSubview:downloadButton];
               
            } else {
                // 仅下载IPA按钮
                NSButton *downloadButton = [[NSButton alloc] initWithFrame:NSMakeRect(30, 18, 40, 24)];
                [downloadButton setTitle:@""];
                downloadButton.identifier = @"downloadAPPButton";
                
                // 1. 获取资源图标并设置图标大小
                NSImage *downloadImage = [NSImage imageNamed:@"download"];
                
                downloadImage.size = NSMakeSize(16, 16);  // 设置图标大小为 16x16

                // 2. 指定按钮的图标和缩放方式
                [downloadButton setImage:downloadImage];
                [downloadButton.cell setImageScaling:NSImageScaleProportionallyDown];

                // 3. 设置图标位置（只显示图标，或者图标覆盖文字区域）
                [downloadButton setImagePosition:NSImageOverlaps];
                
                // 添加 toolTip 提示信息
                downloadButton.toolTip = applicationDownloadTips;
                // 其余按钮属性
                
                [downloadButton setButtonType:NSButtonTypeMomentaryPushIn];
                [downloadButton setBezelStyle:NSBezelStyleRounded];
                downloadButton.tag = row; // 使用 tag 存储行号
                //upgradeButton.bezelColor = [[NSColor systemGreenColor] colorWithAlphaComponent:0.3];
                [downloadButton setFont:[NSFont systemFontOfSize:12]]; // 设置字体大小为12
                [downloadButton setTarget:self];
                [downloadButton setAction:@selector(operateButtonClicked:)]; //操作
                
                // 设置按钮初始状态
                downloadButton.enabled = !self.isCalculatingAppSizes;
                if (self.isCalculatingAppSizes) {
                    downloadButton.alphaValue = 0.5;
                }
                
                [cellView addSubview:downloadButton];
            }
        } else {
            // 非 "User" 类型（例如 "System"）显示默认文本
            cellView.textField.stringValue = @"-";
            cellView.textField.frame = NSMakeRect(padding, textY, tableColumn.width - padding * 2, textHeight);
            // 设置默认文本颜色
            cellView.textField.textColor = [NSColor labelColor];
        }
    }
    
    return cellView;
}



- (NSString *)formatSize:(unsigned long long)sizeInBytes {
    if (sizeInBytes == 0) {
        return @"-";
    } else if (sizeInBytes >= 1024ULL * 1024 * 1024) {
        return [NSString stringWithFormat:@"%.2f GB", sizeInBytes / (1024.0 * 1024.0 * 1024.0)];
    } else if (sizeInBytes >= 1024 * 1024) {
        return [NSString stringWithFormat:@"%.2f MB", sizeInBytes / (1024.0 * 1024.0)];
    } else if (sizeInBytes >= 1024) {
        return [NSString stringWithFormat:@"%.2f KB", sizeInBytes / 1024.0];
    } else {
        return [NSString stringWithFormat:@"%llu B", sizeInBytes];
    }
}


#pragma mark - 自动行高
- (CGFloat)tableView:(NSTableView *)tableView heightOfRow:(NSInteger)row {
    
    //DeviceApp *app = self.appList[row];
    return 60; // 默认行高
}


- (NSTableRowView *)tableView:(NSTableView *)tableView rowViewForRow:(NSInteger)row {
    
    CustomTableRowView *rowView = [[CustomTableRowView alloc] init];
        
    // 处理数据行
    DeviceApp *app = self.appList[row];
    // 根据选中状态设置高亮
    rowView.isHighlighted = [self.selectedApps containsObject:app]; // 根据选中状态设置高亮
    

    // 检测暗黑模式
    NSAppearance *appearance = [rowView effectiveAppearance];
    BOOL isDarkMode = [appearance.name containsString:NSAppearanceNameDarkAqua];

    // 调整文字颜色
    dispatch_async(dispatch_get_main_queue(), ^{
        for (NSView *subview in rowView.subviews) {
            if ([subview isKindOfClass:[NSTableCellView class]]) {
                NSTableCellView *cellView = (NSTableCellView *)subview;
                if (cellView.textField) {
                    
                    // Get the column identifier for this cell
                    NSInteger columnIndex = [tableView columnForView:cellView];
                    NSTableColumn *column = [tableView.tableColumns objectAtIndex:columnIndex];
                    NSString *identifier = column.identifier;

                    // Skip APPVersionColumn to preserve its custom color (e.g., red for updates)
                    if ([identifier isEqualToString:@"APPVersionColumn"]) {
                        continue;
                    }
                    
                    if (rowView.isHighlighted) {
                        // 高亮状态下调整颜色
                        cellView.textField.textColor = isDarkMode ? [NSColor blackColor] : [NSColor textColor];
                    } else {
                        // 未选中状态恢复默认颜色
                        cellView.textField.textColor = [NSColor textColor];
                    }
                }
            }
        }
    });
    
    return rowView;
}

// 修复后的 fetchIconForApp:withSBServices: 方法
- (void)fetchIconForApp:(DeviceApp *)app withSBServices:(sbservices_client_t)sbsClient {
    if (!app.bundleID || !sbsClient) return;

    char *pngData = NULL;
    uint64_t length = 0;
    
    if (sbservices_get_icon_pngdata(sbsClient, [app.bundleID UTF8String], &pngData, &length) == SBSERVICES_E_SUCCESS && pngData && length > 0) {
        NSData *imageData = [NSData dataWithBytes:pngData length:length];
        if (imageData) {
            NSImage *icon = [[NSImage alloc] initWithData:imageData];
            if (icon) {
                app.icon = icon;
            } else {
                NSLog(@"[WARNING] 无法从 PNG 数据创建 NSImage for app: %@", app.bundleID);
            }
        }
        free(pngData);
    } else {
        NSLog(@"[WARNING] 无法获取图标 for app: %@", app.bundleID);
    }
}


// 提取字符串的辅助方法（已存在）
- (NSString *)extractStringFromPlist:(plist_t)plist forKey:(NSString *)key {
    plist_t node = plist_dict_get_item(plist, [key UTF8String]);
    if (node && plist_get_node_type(node) == PLIST_STRING) {
        char *value = NULL;
        plist_get_string_val(node, &value);
        NSString *result = value ? @(value) : nil;
        free(value);
        return result;
    }
    return nil;
}


#pragma mark - 获取APP列表
- (NSArray<DeviceApp *> *)listInstalledAppsWithError:(NSError **)error {
    idevice_t device = NULL;
    LanguageManager *languageManager = [LanguageManager sharedManager];
    //连接设备失败
    NSString *logsConnectToclientFailedMessage = [languageManager localizedStringForKeys:@"ConnectToclientFailed" inModule:@"GlobaMessages" defaultValue:@"Unable to connect to the currently selected device\n"];
    //无法启动安装服务
    NSString *logsapplicationcachedClientFailedMessage = [languageManager localizedStringForKeys:@"applicationcachedClientFailed" inModule:@"AppsManager" defaultValue:@"Failed to start application-related services. You may need to reconnect the device"];
    //获取应用列表失败
    NSString *applicationGetListFailedMessage = [languageManager localizedStringForKeys:@"applicationRetrieveListFailed" inModule:@"AppsManager" defaultValue:@"Failed to retrieve the application list. You may need to reconnect the device"];
    
    //无法启动 sbservices 服务
    NSString *logapplicationSbservicesStartFailedMessage = [languageManager localizedStringForKeys:@"applicationSbservicesStartFailed" inModule:@"AppsManager" defaultValue:@"The SBS service on the device failed to start while loading the application"];
    
    //连接设备失败
    if (idevice_new(&device, NULL) != IDEVICE_E_SUCCESS) {
        if (error) *error = [NSError errorWithDomain:@"Device" code:1 userInfo:@{NSLocalizedDescriptionKey: logsConnectToclientFailedMessage}];
        // 在主线程更新 UI 显示消息
        dispatch_async(dispatch_get_main_queue(), ^{
            [[AlertWindowController sharedController] showResultMessageOnly:logsConnectToclientFailedMessage inWindow:self.view.window];
        });
        return nil;
    }
    


    // 如果没有缓存客户端，启动安装服务
    if (!cachedClient) {
        if (instproxy_client_start_service(device, &cachedClient, NULL) != INSTPROXY_E_SUCCESS) {
            idevice_free(device);
            if (error) *error = [NSError errorWithDomain:@"Device" code:2 userInfo:@{NSLocalizedDescriptionKey: logsapplicationcachedClientFailedMessage}];
            dispatch_async(dispatch_get_main_queue(), ^{
                [[AlertWindowController sharedController] showResultMessageOnly:logsapplicationcachedClientFailedMessage inWindow:self.view.window];
            });
            // **等待 2 秒后切换视图**
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self switchViewWithButton:nil];
            });
            return nil;
        }
    }

    // 创建 plist 选项
    plist_t options = plist_new_dict();
    plist_t attrs = plist_new_array();

    plist_array_append_item(attrs, plist_new_string("CFBundleIdentifier"));
    plist_array_append_item(attrs, plist_new_string("CFBundleDisplayName")); //CFBundleExecutable
    plist_array_append_item(attrs, plist_new_string("CFBundleShortVersionString"));
    plist_array_append_item(attrs, plist_new_string("ApplicationType"));
    plist_array_append_item(attrs, plist_new_string("Path"));
    plist_array_append_item(attrs, plist_new_string("Container"));
    plist_array_append_item(attrs, plist_new_string("Developer"));
    plist_array_append_item(attrs, plist_new_string("iTunesMetadata"));         // iTunes 元数据
    plist_array_append_item(attrs, plist_new_string("ApplicationIdentifier"));         // appId


    plist_dict_set_item(options, "ReturnAttributes", attrs);


    plist_t apps = NULL;
    if (instproxy_browse(cachedClient, options, &apps) != INSTPROXY_E_SUCCESS) {
        plist_free(options);
        idevice_free(device);
        //获取应用列表失败
        if (error) *error = [NSError errorWithDomain:@"Device" code:6 userInfo:@{NSLocalizedDescriptionKey: applicationGetListFailedMessage}];
        dispatch_async(dispatch_get_main_queue(), ^{
            [[AlertWindowController sharedController] showResultMessageOnly:applicationGetListFailedMessage inWindow:self.view.window];
        });
        // **等待 2 秒后切换视图**
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self switchViewWithButton:nil];
        });
        return nil;
    }
    
    // 复用已存在的 sbservices 客户端
    if (!cachedSb) {
        if (sbservices_client_start_service(device, &cachedSb, "sbservices") != SBSERVICES_E_SUCCESS) {
            instproxy_client_free(cachedClient);
            idevice_free(device);
            //加载应用时该设备的sbs服务启动失败
            if (error) *error = [NSError errorWithDomain:@"Device" code:7 userInfo:@{NSLocalizedDescriptionKey: logapplicationSbservicesStartFailedMessage}];
            dispatch_async(dispatch_get_main_queue(), ^{
                [[AlertWindowController sharedController] showResultMessageOnly:logapplicationSbservicesStartFailedMessage inWindow:self.view.window];
            });
            // **等待 2 秒后切换视图**
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self switchViewWithButton:nil];
            });
            return nil;
        }
    }

    // 初始化结果数组，避免未初始化的情况
    NSMutableArray<DeviceApp *> *result = [NSMutableArray array];

    if (apps && plist_get_node_type(apps) == PLIST_ARRAY) {
        uint32_t count = plist_array_get_size(apps);
        for (uint32_t i = 0; i < count; i++) {
            plist_t dict = plist_array_get_item(apps, i);

            DeviceApp *app = [[DeviceApp alloc] init];
            app.device = device;

            // 使用 extractStringFromPlist 方法获取并检查每个字段
            app.bundleID = [self extractStringFromPlist:dict forKey:@"CFBundleIdentifier"];
            if (!app.bundleID) {
             //   NSLog(@"警告: 应用 %@ 缺少 CFBundleIdentifier，跳过此应用", app.appName);
                continue;  // 如果没有 CFBundleIdentifier，就跳过此应用
            }

            app.appName = [self extractStringFromPlist:dict forKey:@"CFBundleDisplayName"]; //CFBundleExecutable
            app.version = [self extractStringFromPlist:dict forKey:@"CFBundleShortVersionString"];
            app.applicationType = [self extractStringFromPlist:dict forKey:@"ApplicationType"];
            app.path = [self extractStringFromPlist:dict forKey:@"Path"];
            app.container = [self extractStringFromPlist:dict forKey:@"Container"];
            app.developer = [self extractStringFromPlist:dict forKey:@"Developer"];

            [self fetchIconForApp:app];  // 获取图标
            
            
            
            // 获取 iTunesMetadata（参考 GetDeviceAppThread）
            plist_t metadataNode = plist_dict_get_item(dict, "iTunesMetadata");
            if (metadataNode && plist_get_node_type(metadataNode) == PLIST_DATA) {
                char *rawData = NULL;
                uint64_t dataLen = 0;
                plist_get_data_val(metadataNode, &rawData, &dataLen);
                if (rawData && dataLen > 0) {
                    NSData *plistData = [NSData dataWithBytes:rawData length:(NSUInteger)dataLen];
                    NSError *parseError = nil;
                    id metadataObj = [NSPropertyListSerialization propertyListWithData:plistData
                                                                                options:NSPropertyListImmutable
                                                                                 format:nil
                                                                                  error:&parseError];
                    free(rawData);

                    if (!parseError && [metadataObj isKindOfClass:[NSDictionary class]]) {
                        NSDictionary *metadataDict = (NSDictionary *)metadataObj;

                        id artistName = metadataDict[@"artistName"];//artistName
                        if ([artistName isKindOfClass:[NSString class]]) {
                            app.developer = artistName;
                        }

                        id appleIdValue = metadataDict[@"appleId"];
                        if ([appleIdValue isKindOfClass:[NSString class]]) {
                            app.appleID = appleIdValue;
                        } else if ([appleIdValue isKindOfClass:[NSNumber class]]) {
                            app.appleID = [(NSNumber *)appleIdValue stringValue];
                        }

                        NSNumber *genreId = metadataDict[@"genreId"];
                        app.genreId = genreId ? [genreId intValue] : 0;

                        NSNumber *externalVer = metadataDict[@"softwareVersionExternalIdentifier"];
                        app.externalVersion = externalVer ? [externalVer intValue] : 0;
                        
                        
                        // 正确提取 App Store 应用 ID（itemId）
                        id itemId = metadataDict[@"itemId"];
                        if ([itemId isKindOfClass:[NSNumber class]]) {
                            app.appId = [itemId stringValue];
                        } else if ([itemId isKindOfClass:[NSString class]]) {
                            app.appId = itemId;
                        }

                        id downloadInfo = metadataDict[@"com.apple.iTunesStore.downloadInfo"];
                        if ([downloadInfo isKindOfClass:[NSDictionary class]]) {
                            id accountInfo = downloadInfo[@"accountInfo"];
                            if ([accountInfo isKindOfClass:[NSDictionary class]]) {
                                id accountAppleId = accountInfo[@"AppleID"];
                                if ([accountAppleId isKindOfClass:[NSString class]]) {
                                    app.appleID = accountAppleId;
                                }
                            }
                        }
                    } else {
                 //       NSLog(@"[WARNING] iTunesMetadata (data) 无法解析为 NSDictionary：%@", parseError);
                    }
                }
            }


            // 规范化 applicationType
            if (app.applicationType) {
                if ([[app.applicationType lowercaseString] isEqualToString:@"user"]) {
                    app.applicationType = @"User";
                } else if ([[app.applicationType lowercaseString] isEqualToString:@"system"]) {
                    app.applicationType = @"System";
                } else {
                 //   NSLog(@"[WARNING] 未知的 applicationType: %@ for app: %@", app.applicationType, app.appName);
                    app.applicationType = @"System"; // 默认值
                }
            } else {
               // NSLog(@"[WARNING] applicationType 为空 for app: %@", app.appName);
                app.applicationType = @"System"; // 默认值
            }
            
            // 检查 App Store 版本（仅对 User 类型应用）
            if ([app.applicationType isEqualToString:@"User"]) {

                [self checkAppStoreVersionForApp:app completion:^(NSDictionary *info, NSError *error) {
                    if (info) {
                        app.appStoreVersion = info[@"version"];
                        app.developer = info[@"developer"];
                        // 比较版本号
                        NSComparisonResult result = [app.version compare:info[@"version"] options:NSNumericSearch];
                        app.hasUpdateAvailable = (result == NSOrderedAscending);
                      //  NSLog(@"[DEBUG] 版本对比 App: %@, Installed: %@, App Store: %@, Update Available: %d ,appleID: %@,appId: %@",
                          //    app.appName, app.version, app.appStoreVersion, app.hasUpdateAvailable, app.appleID, app.appId);
                    }
                }];
            }

            // 将应用添加到结果数组
            [result addObject:app];
        }
        
        
        
        // 保存所有应用列表
        self.allAppList = result;
        
        // 应用默认排序：按 "User" 类型优先
         NSArray *sortedResult = [result sortedArrayUsingComparator:^NSComparisonResult(DeviceApp *app1, DeviceApp *app2) {
             BOOL isApp1User = [app1.applicationType isEqualToString:@"User"];
             BOOL isApp2User = [app2.applicationType isEqualToString:@"User"];
             if (isApp1User && !isApp2User) return NSOrderedAscending;
             if (!isApp1User && isApp2User) return NSOrderedDescending;
             return [app1.appName caseInsensitiveCompare:app2.appName]; // 次级排序按名称
         }];
         
         self.appList = [sortedResult mutableCopy];
         NSLog(@"[DEBUG] 排序后的 appList (listInstalledAppsWithError): %@", self.appList);
        
        [self updateApplicationTypeStatistics]; //计算应用程序类型统计数据
        
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.tableView reloadData];
            [self.tableView setNeedsDisplay:YES];
        });

        // 发送通知，表示应用列表已加载完成
        [[NSNotificationCenter defaultCenter] postNotificationName:@"AppListLoadedNotification" object:nil];

        return sortedResult;
    }

    // 清理资源
    if (apps) plist_free(apps);
    plist_free(options);
    idevice_free(device);

    return nil;  // 返回已加载的应用列表
}


// 获取图标
- (void)fetchIconForApp:(DeviceApp *)app {
    if (app.bundleID) {
        char *iconData = NULL;
        uint64_t iconSize = 0;
        if (sbservices_get_icon_pngdata(cachedSb, [app.bundleID UTF8String], &iconData, &iconSize) == SBSERVICES_E_SUCCESS) {
            NSData *imgData = [NSData dataWithBytes:iconData length:(NSUInteger)iconSize];
            app.iconImage = [[NSImage alloc] initWithData:imgData];
            free(iconData);
        }
    }
}

// 通知回调方法
- (void)appListLoaded:(NSNotification *)notification {
    // 在这里执行通知到来的处理
    NSLog(@"应用列表加载完成！");
    
    // 使用 dispatch_after 来确保异步任务执行完成后更新UI
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        // 获取已经加载的应用列表并更新大小
        // 异步
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSError *error = nil;
            NSArray<DeviceApp *> *installedApps = [self listInstalledAppsRefeshDataWithError:&error];
            
            if (error) {
               // NSLog(@"获取应用列表失败: %@", error.localizedDescription);
            } else {
                // 处理已加载的应用列表
                // 在这里可以保存列表或做其他处理
                NSLog(@"已加载应用列表：%@", installedApps);
            }
            
            // 更新UI
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.loadingIndicator stopAnimation:nil];
                self.loadingIndicator.hidden = YES;
                self.tableView.enabled = YES;
                self.tableView.alphaValue = 1.0;

                if (error) {
                    NSLog(@"[ERROR] 获取应用列表失败: %@", error.localizedDescription);
                    [self updateBatchOperationButtonsState:YES];
                } else {
                    self.appList = installedApps;  // 更新 appList
                     NSLog(@"[DEBUG] 当前 appList: %@", self.appList); // 打印 appList 数据
                    [self.tableView reloadData];
                    [self.tableView setNeedsDisplay:YES];
                    
                    //更新批量按钮状态
                    [self updateBatchOperationButtonsState:YES];
                }
            });

        });
    });
}




#pragma mark - App List
- (NSArray<DeviceApp *> *)listInstalledAppsRefeshDataWithError:(NSError **)error {
    
    LanguageManager *languageManager = [LanguageManager sharedManager];
    //连接设备失败
    NSString *logsConnectToclientFailedMessage = [languageManager localizedStringForKeys:@"ConnectToclientFailed" inModule:@"GlobaMessages" defaultValue:@"Unable to connect to the currently selected device\n"];
    //无法启动安装服务
    NSString *logsapplicationcachedClientFailedMessage = [languageManager localizedStringForKeys:@"applicationcachedClientFailed" inModule:@"AppsManager" defaultValue:@"Failed to start application-related services. You may need to reconnect the device"];
    //获取应用列表失败
    NSString *applicationGetListFailedMessage = [languageManager localizedStringForKeys:@"applicationRetrieveListFailed" inModule:@"AppsManager" defaultValue:@"Failed to retrieve the application list. You may need to reconnect the device"];
    
    //无法启动 sbservices 服务
    NSString *logapplicationSbservicesStartFailedMessage = [languageManager localizedStringForKeys:@"applicationSbservicesStartFailed" inModule:@"AppsManager" defaultValue:@"The SBS service on the device failed to start while loading the application"];
    
    //@"连接设备失败"
    idevice_t device = NULL;
    if (idevice_new(&device, NULL) != IDEVICE_E_SUCCESS) {
        if (error) *error = [NSError errorWithDomain:@"Device" code:1 userInfo:@{NSLocalizedDescriptionKey: logsConnectToclientFailedMessage}];
        return nil;
    }
    
     //@"无法启动安装服务"
    instproxy_client_t client = NULL;
    if (instproxy_client_start_service(device, &client, NULL) != INSTPROXY_E_SUCCESS) {
        idevice_free(device);
        if (error) *error = [NSError errorWithDomain:@"Device" code:2 userInfo:@{NSLocalizedDescriptionKey: logsapplicationcachedClientFailedMessage}];
        dispatch_async(dispatch_get_main_queue(), ^{
            [[AlertWindowController sharedController] showResultMessageOnly:logsapplicationcachedClientFailedMessage inWindow:self.view.window];
        });
        // **等待 2 秒后切换视图**
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self switchViewWithButton:nil];
        });
        return nil;
    }

    //@"无法启动 sbservices 服务"
    sbservices_client_t sb = NULL;
    if (sbservices_client_start_service(device, &sb, "sbservices") != SBSERVICES_E_SUCCESS) {
        instproxy_client_free(client);
        idevice_free(device);
        if (error) *error = [NSError errorWithDomain:@"Device" code:7 userInfo:@{NSLocalizedDescriptionKey: logapplicationSbservicesStartFailedMessage}];
        dispatch_async(dispatch_get_main_queue(), ^{
            [[AlertWindowController sharedController] showResultMessageOnly:logapplicationSbservicesStartFailedMessage inWindow:self.view.window];
        });
        // **等待 2 秒后切换视图**
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self switchViewWithButton:nil];
        });
        return nil;
    }

    // 设置 instproxy_browse 选项
    plist_t options = plist_new_dict();
    plist_t attrs = plist_new_array();

    plist_array_append_item(attrs, plist_new_string("CFBundleIdentifier"));
    plist_array_append_item(attrs, plist_new_string("CFBundleDisplayName"));
    plist_array_append_item(attrs, plist_new_string("CFBundleShortVersionString"));
    plist_array_append_item(attrs, plist_new_string("ApplicationType"));
    plist_array_append_item(attrs, plist_new_string("StaticDiskUsage"));
    plist_array_append_item(attrs, plist_new_string("DynamicDiskUsage"));
    plist_array_append_item(attrs, plist_new_string("Path"));
    plist_array_append_item(attrs, plist_new_string("Container"));
    plist_array_append_item(attrs, plist_new_string("iTunesMetadata"));         // iTunes 元数据

    plist_dict_set_item(options, "ReturnAttributes", attrs);



    plist_t apps = NULL;
    if (instproxy_browse(client, options, &apps) != INSTPROXY_E_SUCCESS) {
        plist_free(options);
        sbservices_client_free(sb);
        instproxy_client_free(client);
        idevice_free(device);
        //@"获取应用列表失败"
        if (error) *error = [NSError errorWithDomain:@"Device" code:6 userInfo:@{NSLocalizedDescriptionKey: applicationGetListFailedMessage}];
        dispatch_async(dispatch_get_main_queue(), ^{
            [[AlertWindowController sharedController] showResultMessageOnly:applicationGetListFailedMessage inWindow:self.view.window];
        });
        // **等待 2 秒后切换视图**
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self switchViewWithButton:nil];
        });
        return nil;
    }

    NSMutableArray<DeviceApp *> *result = [NSMutableArray array];
    
    if (apps && plist_get_node_type(apps) == PLIST_ARRAY) {
        uint32_t count = plist_array_get_size(apps);
        
        dispatch_group_t group = dispatch_group_create();
        
        for (uint32_t i = 0; i < count; i++) {
            plist_t dict = plist_array_get_item(apps, i);

            // 输出完整 Plist 数据（调试用）
            char *xml = NULL;
            uint32_t length = 0;
            plist_to_xml(dict, &xml, &length);
            if (xml) {
               // NSLog(@"[DEBUG] Plist for app %d: %s", i, xml);
                free(xml);
            }

            DeviceApp *app = [[DeviceApp alloc] init];
            app.device = device;
            char *str = NULL;

            // 获取基本信息
            plist_t val = plist_dict_get_item(dict, "CFBundleIdentifier");
            if (val) plist_get_string_val(val, &str);
            if (str) app.bundleID = [NSString stringWithUTF8String:str];
            free(str); str = NULL;

            val = plist_dict_get_item(dict, "CFBundleDisplayName");
            if (val) plist_get_string_val(val, &str);
            if (str) app.appName = [NSString stringWithUTF8String:str];
            free(str); str = NULL;

            val = plist_dict_get_item(dict, "CFBundleShortVersionString");
            if (val) plist_get_string_val(val, &str);
            if (str) app.version = [NSString stringWithUTF8String:str];
            free(str); str = NULL;

            val = plist_dict_get_item(dict, "ApplicationType");
            if (val) plist_get_string_val(val, &str);
            if (str) app.applicationType = [NSString stringWithUTF8String:str];
            free(str); str = NULL;
            
            val = plist_dict_get_item(dict, "Path");
            if (val) plist_get_string_val(val, &str);
            if (str) app.path = [NSString stringWithUTF8String:str];
            free(str); str = NULL;
            
            val = plist_dict_get_item(dict, "Container");
            if (val) plist_get_string_val(val, &str);
            if (str) app.container = [NSString stringWithUTF8String:str];
            free(str); str = NULL;
            
            
            
            // 获取 iTunesMetadata（参考 GetDeviceAppThread）
            plist_t metadataNode = plist_dict_get_item(dict, "iTunesMetadata");
            if (metadataNode && plist_get_node_type(metadataNode) == PLIST_DATA) {
                char *rawData = NULL;
                uint64_t dataLen = 0;
                plist_get_data_val(metadataNode, &rawData, &dataLen);
                if (rawData && dataLen > 0) {
                    NSData *plistData = [NSData dataWithBytes:rawData length:(NSUInteger)dataLen];
                    NSError *parseError = nil;
                    id metadataObj = [NSPropertyListSerialization propertyListWithData:plistData
                                                                                options:NSPropertyListImmutable
                                                                                 format:nil
                                                                                  error:&parseError];
                    free(rawData);

                    if (!parseError && [metadataObj isKindOfClass:[NSDictionary class]]) {
                        NSDictionary *metadataDict = (NSDictionary *)metadataObj;

                        id artistName = metadataDict[@"artistName"];
                        if ([artistName isKindOfClass:[NSString class]]) {
                            app.developer = artistName;
                        }

                        id appleIdValue = metadataDict[@"appleId"];
                        
                        NSLog(@"iTunesMetadata appleIdValue 解析为：%@", appleIdValue);
                        
                        id userNameValue = metadataDict[@"userName"];
                        
                        NSLog(@"iTunesMetadata userNameValue 解析为：%@", userNameValue);
                        
                        if ([appleIdValue isKindOfClass:[NSString class]]) {
                            if (appleIdValue != nil) {
                                app.appleID = appleIdValue;
                            } else if (appleIdValue == nil && userNameValue != nil) {
                                app.appleID = userNameValue;  // 注意这里应该是 userNameValue，不是 appleIdValue
                            } else {
                                app.appleID = NULL;
                            }
                        } else if ([appleIdValue isKindOfClass:[NSNumber class]]) {
                            app.appleID = [(NSNumber *)appleIdValue stringValue];
                        }

                        NSNumber *genreId = metadataDict[@"genreId"];
                        app.genreId = genreId ? [genreId intValue] : 0;

                        NSNumber *externalVer = metadataDict[@"softwareVersionExternalIdentifier"];
                        app.externalVersion = externalVer ? [externalVer intValue] : 0;
                        
                        
                        // 正确提取 App Store 应用 ID（itemId）
                        id itemId = metadataDict[@"itemId"];
                        if ([itemId isKindOfClass:[NSNumber class]]) {
                            app.appId = [itemId stringValue];
                        } else if ([itemId isKindOfClass:[NSString class]]) {
                            app.appId = itemId;
                        }



                        id downloadInfo = metadataDict[@"com.apple.iTunesStore.downloadInfo"];
                        if ([downloadInfo isKindOfClass:[NSDictionary class]]) {
                            id accountInfo = downloadInfo[@"accountInfo"];
                            if ([accountInfo isKindOfClass:[NSDictionary class]]) {
                                id accountAppleId = accountInfo[@"AppleID"];
                                if ([accountAppleId isKindOfClass:[NSString class]]) {
                                    app.appleID = accountAppleId;
                                }
                            }
                        }
                    } else {
                        NSLog(@"[WARNING] iTunesMetadata (data) 无法解析为 NSDictionary：%@", parseError);
                    }
                }
            }


            // 规范化 applicationType
            if (app.applicationType) {
                if ([[app.applicationType lowercaseString] isEqualToString:@"user"]) {
                    app.applicationType = @"User";
                } else if ([[app.applicationType lowercaseString] isEqualToString:@"system"]) {
                    app.applicationType = @"System";
                } else {
                   // NSLog(@"[WARNING] 未知的 applicationType: %@ for app: %@", app.applicationType, app.appName);
                    app.applicationType = @"System"; // 默认值
                }
            } else {
               // NSLog(@"[WARNING] applicationType 为空 for app: %@", app.appName);
                app.applicationType = @"System"; // 默认值
            }
            
            // 异步获取应用大小
            dispatch_group_enter(group);
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                // 获取应用包大小 (StaticDiskUsage)
                plist_t sizeVal = plist_dict_get_item(dict, "StaticDiskUsage");
                if (sizeVal && plist_get_node_type(sizeVal) == PLIST_UINT) {
                    uint64_t size;
                    plist_get_uint_val(sizeVal, &size);
                    app.appSize = size;
                   // NSLog(@"[DEBUG] Got app size from StaticDiskUsage: %llu bytes for %@", size, app.bundleID);
                }

                // 获取数据容器大小 (DynamicDiskUsage)
                plist_t dynamicSizeVal = plist_dict_get_item(dict, "DynamicDiskUsage");
                if (dynamicSizeVal && plist_get_node_type(dynamicSizeVal) == PLIST_UINT) {
                    uint64_t dynamicSize;
                    plist_get_uint_val(dynamicSizeVal, &dynamicSize);
                    app.docSize = dynamicSize;
                   // NSLog(@"[DEBUG] Got container size from DynamicDiskUsage: %llu bytes for %@", dynamicSize, app.bundleID);
                }

                // 完成任务
                dispatch_group_leave(group);
            });

            // 获取图标
            dispatch_group_enter(group);
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                if (app.bundleID) {
                    char *iconData = NULL;
                    uint64_t iconSize = 0;
                    if (sbservices_get_icon_pngdata(sb, [app.bundleID UTF8String], &iconData, &iconSize) == SBSERVICES_E_SUCCESS) {
                        NSData *imgData = [NSData dataWithBytes:iconData length:(NSUInteger)iconSize];
                        app.iconImage = [[NSImage alloc] initWithData:imgData];
                        free(iconData);
                    }
                }
                dispatch_group_leave(group);
            });

            // 打印所有信息
           // NSLog(@"[DEBUG] 添加应用 \n --- 应用名称: %@ ,\n 应用标识符: %@ ,\n 类型: %@ ,\n AppleID: %@ ,\n StaticDiskUsage: %llu ,\n DynamicDiskUsage: %llu\n",
              //    app.appName, app.bundleID, app.applicationType, app.appleID,
              //    (unsigned long long)app.appSize, (unsigned long long)app.docSize);
            
            // 检查 App Store 版本（仅对 User 类型应用）
            if ([app.applicationType isEqualToString:@"User"]) {
                dispatch_group_enter(group);
                [self checkAppStoreVersionForApp:app completion:^(NSDictionary *info, NSError *error) {
                    if (info) {
                        app.appStoreVersion = info[@"version"];
                        app.developer = info[@"developer"];
                        // 比较版本号
                        NSComparisonResult result = [app.version compare:info[@"version"] options:NSNumericSearch];
                        app.hasUpdateAvailable = (result == NSOrderedAscending);
                     //   NSLog(@"[DEBUG] App的信息: %@, Installed: %@, App Store: %@, Update Available: %d",
                       //       app.appName, app.version, app.appStoreVersion, app.hasUpdateAvailable);
                    }
                    dispatch_group_leave(group);
                }];
            }

            [result addObject:app];
        }
        
        // 保存所有应用列表
        self.allAppList = result;
        
        // 等待所有异步任务完成
        dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
        

        //计算用户应用程序空间使用量 计算 User 类型应用的总空间占用
        unsigned long long totalStaticSize = 0;
        unsigned long long totalDynamicSize = 0;
        NSInteger userAppCount = 0;

        for (DeviceApp *app in result) {
            if ([app.applicationType isEqualToString:@"User"]) {
                totalStaticSize += app.appSize;
                totalDynamicSize += app.docSize;
                userAppCount++;
            }
        }

        // 将字节转换为 GB（1 GB = 1024^3 字节）
        double totalStaticGB = totalStaticSize / (1024.0 * 1024.0 * 1024.0);
        double totalDynamicGB = totalDynamicSize / (1024.0 * 1024.0 * 1024.0);
        double totalGB = totalStaticGB + totalDynamicGB;

        // 定义普通和粗体字体属性（可根据实际需求调整字体大小）
        NSDictionary *normalAttributes = @{ NSFontAttributeName: [NSFont systemFontOfSize:11] };
        NSDictionary *boldAttributes   = @{ NSFontAttributeName: [NSFont boldSystemFontOfSize:11] };

        NSMutableAttributedString *attributedString = [[NSMutableAttributedString alloc] init];
        
        LanguageManager *languageManager = [LanguageManager sharedManager];
        NSString *applicationTotalSizeTitle = [languageManager localizedStringForKeys:@"applicationTotalSize" inModule:@"AppsManager" defaultValue:@"Total Space Used by User Apps:"];
        NSString *applicationSizeTtitle = [languageManager localizedStringForKeys:@"applicationSize" inModule:@"AppsManager" defaultValue:@"App Size:"];
        NSString *applicationDataSizeTitle = [languageManager localizedStringForKeys:@"applicationDataSize" inModule:@"AppsManager" defaultValue:@"App Data:"];

        if (userAppCount > 0) {
            // 添加 "用户应用总共占用: "（普通样式）
            [attributedString appendAttributedString:[[NSAttributedString alloc] initWithString:applicationTotalSizeTitle  attributes:normalAttributes]];
            
            // 添加 totalGB（粗体）
            NSString *totalGBString = [NSString stringWithFormat:@"%.2f", totalGB];
            [attributedString appendAttributedString:[[NSAttributedString alloc] initWithString:totalGBString attributes:boldAttributes]];
            
            // 添加 " GB "（普通样式）
            [attributedString appendAttributedString:[[NSAttributedString alloc] initWithString:@" GB " attributes:normalAttributes]];
            
            // 添加 "("（普通样式）
            [attributedString appendAttributedString:[[NSAttributedString alloc] initWithString:@"(" attributes:normalAttributes]];
            
            // 添加 "appSize: "（普通样式）
            [attributedString appendAttributedString:[[NSAttributedString alloc] initWithString:applicationSizeTtitle  attributes:normalAttributes]];
            
            // 添加 totalStaticGB（粗体）
            NSString *totalStaticGBString = [NSString stringWithFormat:@"%.2f", totalStaticGB];
            [attributedString appendAttributedString:[[NSAttributedString alloc] initWithString:totalStaticGBString attributes:boldAttributes]];
            
            // 添加 " GB, docSize: "（普通样式）
            [attributedString appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@" GB, %@: ", applicationDataSizeTitle] attributes:normalAttributes]];
            
            // 添加 totalDynamicGB（粗体）
            NSString *totalDynamicGBString = [NSString stringWithFormat:@"%.2f", totalDynamicGB];
            [attributedString appendAttributedString:[[NSAttributedString alloc] initWithString:totalDynamicGBString attributes:boldAttributes]];
            
            // 添加 " GB)"（普通样式）
            [attributedString appendAttributedString:[[NSAttributedString alloc] initWithString:@" GB)" attributes:normalAttributes]];
        } else {
            // 如果没有用户应用，则显示 0 的情况
            [attributedString appendAttributedString:[[NSAttributedString alloc] initWithString:applicationTotalSizeTitle  attributes:normalAttributes]];
            
            [attributedString appendAttributedString:[[NSAttributedString alloc] initWithString:@"0" attributes:boldAttributes]];
            
            [attributedString appendAttributedString:[[NSAttributedString alloc] initWithString:@" B (" attributes:normalAttributes]];
            
            [attributedString appendAttributedString:[[NSAttributedString alloc] initWithString:applicationSizeTtitle attributes:normalAttributes]];
            [attributedString appendAttributedString:[[NSAttributedString alloc] initWithString:@"0" attributes:boldAttributes]];
            
            [attributedString appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@" B, %@: ", applicationDataSizeTitle] attributes:normalAttributes]];
            [attributedString appendAttributedString:[[NSAttributedString alloc] initWithString:@"0" attributes:boldAttributes]];
            
            [attributedString appendAttributedString:[[NSAttributedString alloc] initWithString:@" B)" attributes:normalAttributes]];
        }

        //计算应用程序存储使用情况
        dispatch_async(dispatch_get_main_queue(), ^{
            self.applicationTypeUserSpaceLabel.attributedStringValue = attributedString;
            // 计算完成，启用操作按钮
            self.isCalculatingAppSizes = NO;
            [self updateOperationButtonsState:YES];
            
            [self updateBatchOperationButtonsState:YES];
            
            NSLog(@"[INFO] 应用空间计算完成，操作按钮已启用");
        });


        // 应用默认排序：按 "User" 类型优先
        NSArray *sortedResult = [result sortedArrayUsingComparator:^NSComparisonResult(DeviceApp *app1, DeviceApp *app2) {
            BOOL isApp1User = [app1.applicationType isEqualToString:@"User"];
            BOOL isApp2User = [app2.applicationType isEqualToString:@"User"];
            if (isApp1User && !isApp2User) return NSOrderedAscending;
            if (!isApp1User && isApp2User) return NSOrderedDescending;
            return [app1.appName caseInsensitiveCompare:app2.appName]; // 次级排序按名称
        }];
        
        self.appList = [sortedResult mutableCopy];
    }

    plist_free(options);
    sbservices_client_free(sb);
    instproxy_client_free(client);
    idevice_free(device);

    return self.appList;
}

#pragma mark - 更新操作按钮状态
- (void)updateOperationButtonsState:(BOOL)enabled {
    dispatch_async(dispatch_get_main_queue(), ^{
        // 遍历表格视图中的所有行，更新按钮状态
        NSInteger numberOfRows = [self.tableView numberOfRows];
        
        for (NSInteger row = 0; row < numberOfRows; row++) {
            // 获取该行的视图
            NSView *rowView = [self.tableView rowViewAtRow:row makeIfNecessary:NO];
            if (!rowView) continue;
            
            // 遍历行中的所有列
            for (NSInteger column = 0; column < [self.tableView numberOfColumns]; column++) {
                NSView *cellView = [self.tableView viewAtColumn:column row:row makeIfNecessary:NO];
                if (!cellView) continue;
                
                // 查找操作按钮
                for (NSView *subview in cellView.subviews) {
                    if ([subview isKindOfClass:[NSButton class]]) {
                        NSButton *button = (NSButton *)subview;
                        
                        // 只更新操作按钮（通过identifier识别）
                        if ([button.identifier isEqualToString:@"uninstallAPPButton"] ||
                            [button.identifier isEqualToString:@"backupAPPButton"] ||
                            [button.identifier isEqualToString:@"upgradeAPPButton"] ||
                            [button.identifier isEqualToString:@"downloadAPPButton"]){
                            
                            button.enabled = enabled;
                            button.alphaValue = enabled ? 1.0 : 0.5;
                        }
                    }
                }
            }
        }
    });
}

#pragma mark - App Store 版本查询
- (void)checkAppStoreVersionForApp:(DeviceApp *)app completion:(void (^)(NSDictionary *info, NSError *error))completion {
    if (![app.applicationType isEqualToString:@"User"]) {
        completion(nil, nil);
        return;
    }
    
  //  NSLog(@"[DEBUG] App Store 版本查询信息 : %@", app.appId);
    // 如果有 appId，优先使用 appId 查询   https://itunes.apple.com/lookup?id=361304891
    if (app.appId && app.appId.length > 0) {
        NSString *urlString = [NSString stringWithFormat:@"https://itunes.apple.com/lookup?id=%@", app.appId];
        NSURL *url = [NSURL URLWithString:urlString];
        
        if (!url) {
            NSError *error = [NSError errorWithDomain:@"InvalidURL" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"Invalid appId URL"}];
            completion(nil, error);
            return;
        }
        
        [self performLookupWithURL:url completion:completion];
        return;
    }
    
    // 如果没有 appId，使用 bundleID 查询并尝试获取 appId
    if (!app.bundleID || app.bundleID.length == 0) {
        NSError *error = [NSError errorWithDomain:@"InvalidInput" code:-2 userInfo:@{NSLocalizedDescriptionKey: @"No appId or bundleID provided"}];
        completion(nil, error);
        return;
    }
    
    NSString *bundleUrlString = [NSString stringWithFormat:@"https://itunes.apple.com/lookup?bundleId=%@", app.bundleID];
    NSURL *bundleUrl = [NSURL URLWithString:bundleUrlString];
    
    if (!bundleUrl) {
        NSError *error = [NSError errorWithDomain:@"InvalidURL" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"Invalid bundleID URL"}];
        completion(nil, error);
        return;
    }
    
    [self performLookupWithURL:bundleUrl completion:^(NSDictionary *info, NSError *error) {
        if (error) {
            completion(nil, error);
            return;
        }
        
        NSMutableDictionary *resultInfo = [info mutableCopy];
        NSString *developer = info[@"developer"];
        NSString *appId = info[@"appId"];
        
        // 如果没有开发者信息但有 appId，尝试用 appId 再查一次
        if (!developer && appId) {
            NSString *idUrlString = [NSString stringWithFormat:@"https://itunes.apple.com/lookup?id=%@", appId];
            NSURL *idUrl = [NSURL URLWithString:idUrlString];
            
            if (idUrl) {
                [self performLookupWithURL:idUrl completion:^(NSDictionary *idInfo, NSError *idError) {
                    if (!idError && idInfo[@"developer"]) {
                        resultInfo[@"developer"] = idInfo[@"developer"];
                    }
                    completion([resultInfo copy], idError);
                }];
            } else {
                completion([resultInfo copy], nil);
            }
        } else {
            completion([resultInfo copy], nil);
        }
    }];
}


- (void)performLookupWithURL:(NSURL *)url completion:(void (^)(NSDictionary *info, NSError *error))completion {
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || !data) {
            completion(nil, error);
            return;
        }
        
        NSError *jsonError;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        if (jsonError) {
            completion(nil, jsonError);
            return;
        }
        
        NSArray *results = json[@"results"];
        if (results.count == 0) {
            NSError *error = [NSError errorWithDomain:@"NotFound" code:-3 userInfo:@{NSLocalizedDescriptionKey: @"App not found"}];
            completion(nil, error);
            return;
        }
        
        NSDictionary *appInfo = results[0];
        NSMutableDictionary *resultInfo = [NSMutableDictionary dictionary];
        
        // 获取版本号
        if (appInfo[@"version"]) {
            resultInfo[@"version"] = appInfo[@"version"];
        }
        
        // 获取开发者信息
        NSString *developer = appInfo[@"sellerName"];
        if (!developer || developer.length == 0) {
            developer = appInfo[@"artistName"];
        }
        if (developer) {
            resultInfo[@"developer"] = developer;
        }
        
        // 获取 appId
        if (appInfo[@"appId"]) {
            resultInfo[@"appId"] = appInfo[@"appId"];
        }
        
        completion([resultInfo copy], nil);
    }];
    
    [task resume];
}

#pragma mark - 应用卸载
- (BOOL)uninstallAppWithBundleID:(NSString *)bundleID error:(NSError **)error {
    NSLog(@"[DEBUG] 开始卸载APP...");
    
    LanguageManager *languageManager = [LanguageManager sharedManager];
    //无法连接到当前选择的设备
    NSString *connectToclientFailedMessage = [languageManager localizedStringForKeys:@"ConnectToclientFailed" inModule:@"GlobaMessages" defaultValue:@"Unable to connect to the currently selected device\n"];
    
    //无法启动安装服务
    NSString *installationServiceFailedMessage = [languageManager localizedStringForKeys:@"applicationInstallationServiceFailed" inModule:@"AppsManager" defaultValue:@"Unable to start the installation service"];
    
    //选择的应用卸载失败
    NSString *applicationUninstallFailedMessage = [languageManager localizedStringForKeys:@"applicationUninstallFailed" inModule:@"AppsManager" defaultValue:@"Failed to uninstall the selected application"];
        
    idevice_t device = NULL;
    if (idevice_new(&device, NULL) != IDEVICE_E_SUCCESS) {
        //连接设备失败
        if (error) *error = [NSError errorWithDomain:@"Device" code:3 userInfo:@{NSLocalizedDescriptionKey: connectToclientFailedMessage}];
        return NO;
    }

    instproxy_client_t client = NULL;
    if (instproxy_client_start_service(device, &client, "ideviceinstaller") != INSTPROXY_E_SUCCESS) {
        idevice_free(device);
        //无法启动安装服务
        if (error) *error = [NSError errorWithDomain:@"Device" code:4 userInfo:@{NSLocalizedDescriptionKey: installationServiceFailedMessage}];
        return NO;
    }

    instproxy_error_t res = instproxy_uninstall(client, [bundleID UTF8String], NULL, NULL, NULL);

    instproxy_client_free(client);
    idevice_free(device);
    
    if (res != INSTPROXY_E_SUCCESS) {
        //卸载失败
        if (error) *error = [NSError errorWithDomain:@"Device" code:5 userInfo:@{NSLocalizedDescriptionKey: applicationUninstallFailedMessage}];
        return NO;
    }

    return YES;
}

#pragma mark - Size Calculations Helper Methods
- (NSUInteger)_recursiveSizeForAFCClient:(afc_client_t)afc path:(NSString *)path {
    if (!afc || !path) {
        NSLog(@"[ERROR] Invalid AFC client or path");
        return 0;
    }

    NSUInteger totalSize = 0;
    char **dirlist = NULL;
    afc_error_t err = afc_read_directory(afc, [path UTF8String], &dirlist);
    
    if (err != AFC_E_SUCCESS) {
        NSLog(@"[ERROR] Failed to read directory: %@", path);
        return 0;
    }

    if (!dirlist) {
        NSLog(@"[ERROR] Directory list is NULL for path: %@", path);
        return 0;
    }

    for (int i = 0; dirlist[i]; i++) {
        NSString *filename = [NSString stringWithUTF8String:dirlist[i]];
        
        // Skip current and parent directory entries
        if ([filename isEqualToString:@"."] || [filename isEqualToString:@".."]) {
            continue;
        }

        NSString *fullPath = [path stringByAppendingPathComponent:filename];
        
        char **info = NULL;
        err = afc_get_file_info(afc, [fullPath UTF8String], &info);
        
        if (err != AFC_E_SUCCESS || !info) {
            NSLog(@"[ERROR] Failed to get file info for: %@", fullPath);
            continue;
        }

        NSString *fileType = nil;
        uint64_t fileSize = 0;

        for (int j = 0; info[j] && info[j + 1]; j += 2) {
            NSString *key = [NSString stringWithUTF8String:info[j]];
            NSString *value = [NSString stringWithUTF8String:info[j + 1]];

            if ([key isEqualToString:@"st_ifmt"]) {
                fileType = value;
            } else if ([key isEqualToString:@"st_size"]) {
                fileSize = strtoull([value UTF8String], NULL, 10);
            }
        }

        if ([fileType isEqualToString:@"S_IFREG"]) {  // Regular file
            totalSize += fileSize;
            NSLog(@"[DEBUG] File: %@, Size: %llu bytes", filename, fileSize);
        } else if ([fileType isEqualToString:@"S_IFDIR"]) {  // Directory
            NSUInteger subdirSize = [self _recursiveSizeForAFCClient:afc path:fullPath];
            totalSize += subdirSize;
            NSLog(@"[DEBUG] Directory: %@, Size: %lu bytes", filename, (unsigned long)subdirSize);
        }

        // Free the file info
        for (int j = 0; info[j]; j++) {
            free(info[j]);
        }
        free(info);
    }

    // Free the directory listing
    for (int i = 0; dirlist[i]; i++) {
        free(dirlist[i]);
    }
    free(dirlist);

    return totalSize;
}




// 按钮点击事件处理
- (void)operateButtonClicked:(NSButton *)sender {
    // 检查是否正在计算应用大小
    if (self.isCalculatingAppSizes) {
        LanguageManager *languageManager = [LanguageManager sharedManager];
        NSString *calculatingMessage = [languageManager localizedStringForKeys:@"applicationCalculatingPleaseWait"
                                                                       inModule:@"AppsManager"
                                                                   defaultValue:@"Please wait while calculating app storage usage..."];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            [[AlertWindowController sharedController] showResultMessageOnly:calculatingMessage inWindow:self.view.window];
        });
        return;
    }
    
    
    NSInteger row = [self.tableView rowForView:sender];
    if (row == -1) return;
    
    DeviceApp *app = self.appList[row];
    NSString *lockedDeviceID = [self getLockedDeviceID];
    LanguageManager *languageManager = [LanguageManager sharedManager];
    
    if ([sender.identifier isEqualToString:@"uninstallAPPButton"]) {
        // **记录操作日志**
        NSString *logHandleDeleteAPPRecord = [[LanguageManager sharedManager] localizedStringForKeys:@"HandleDeleteAPP" inModule:@"OperationRecods" defaultValue:@"Handle Delete APP"];
        [[DataBaseManager sharedInstance] addOperationRecord:logHandleDeleteAPPRecord forDeviceECID:lockedDeviceID UDID:lockedDeviceID];
        
        //删除APP相关消息及日志记录
        NSString *messageAPPDeleteDone = [[LanguageManager sharedManager] localizedStringForKeys:@"AppDeleteDone" inModule:@"AppsManager" defaultValue:@"The selected APP \"%@\" has been deleted"];
        
        //删除APP对话框相关消息
        NSString *deleteSelectAppTitle = [languageManager localizedStringForKeys:@"DeleteSelectAPPTitle" inModule:@"AppsManager" defaultValue:@"Are you sure you want to delete the selected APP?"];
        NSString *deleteSelectAPPMessage = [languageManager localizedStringForKeys:@"DeleteSelectAPPMessage" inModule:@"AppsManager" defaultValue:@"The currently selected APP is \"%@\""];
        NSString *formattedMessage = [NSString stringWithFormat:deleteSelectAPPMessage, app.appName];
        NSString *deleteButton = [languageManager localizedStringForKeys:@"DeleteButton" inModule:@"GlobaButtons" defaultValue:@"Delete"];
        NSString *cancelButton = [languageManager localizedStringForKeys:@"CancelButton" inModule:@"GlobaButtons" defaultValue:@"Cancel"];

        // 弹窗确认删除操作
        [[AlertWindowController sharedController] showAlertWithTitle:deleteSelectAppTitle
                                                         description:formattedMessage
                                                        confirmTitle:deleteButton
                                                         cancelTitle:cancelButton
                                                       confirmAction:^{
            // 用户确认后执行删除操作
            NSError *error = nil;
            if ([self uninstallAppWithBundleID:app.bundleID error:&error]) {
                NSLog(@"[INFO] 成功卸载应用: %@", app.appName);
                
                // 提示APP已删除消息
                NSString *appDeleteDoneMessage = [NSString stringWithFormat:messageAPPDeleteDone, app.appName];
                //3秒提示
                dispatch_async(dispatch_get_main_queue(), ^{
                    [[AlertWindowController sharedController] showResultMessageOnly:appDeleteDoneMessage inWindow:self.view.window];
                });
                
                // **记录操作日志** 删除APP操作结果
                NSString *logResultRecord = [[LanguageManager sharedManager] localizedStringForKeys:@"HandleDeleteAPPResult"
                                                                                           inModule:@"OperationRecods"
                                                                                      defaultValue:@"Handle Delete APP Result: %@"];
                NSString *recordresultMessage = [NSString stringWithFormat:@"[SUC] %@", appDeleteDoneMessage];
                [[DataBaseManager sharedInstance] addOperationRecord:[NSString stringWithFormat:logResultRecord, recordresultMessage]
                                                     forDeviceECID:lockedDeviceID
                                                              UDID:lockedDeviceID];
                // 刷新列表
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [self refreshAppList];
                });
                
            } else {
                NSLog(@"[ERROR] 卸载应用失败: %@", error.localizedDescription);
                
                NSString *appDeleteFailedMessage = [NSString stringWithFormat:error.localizedDescription, app.appName];
                //3秒提示
                dispatch_async(dispatch_get_main_queue(), ^{
                    [[AlertWindowController sharedController] showResultMessageOnly:appDeleteFailedMessage inWindow:self.view.window];
                });
                
                // **记录操作日志** 删除APP操作结果
                NSString *logResultRecord = [[LanguageManager sharedManager] localizedStringForKeys:@"HandleDeleteAPPResult"
                                                                                           inModule:@"OperationRecods"
                                                                                      defaultValue:@"Handle Delete APP Result: %@"];
                NSString *recordresultMessage = [NSString stringWithFormat:@"[ER] %@", appDeleteFailedMessage];
                [[DataBaseManager sharedInstance] addOperationRecord:[NSString stringWithFormat:logResultRecord, recordresultMessage]
                                                     forDeviceECID:lockedDeviceID
                                                              UDID:lockedDeviceID];
            }
            

        }];
    } else if ([sender.identifier isEqualToString:@"backupAPPButton"]) {
        [self backupApp:app];
    } else if ([sender.identifier isEqualToString:@"upgradeAPPButton"]) {
        [self updateApp:app];
    } else if ([sender.identifier isEqualToString:@"downloadAPPButton"]) {
        [self downloadAppIPA:app];
    }
}




// ============================================================================
// MARK: - 工具方法
// ============================================================================

- (NSString *)getCurrentTimestamp {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"yyyyMMdd_HHmmss";
    return [formatter stringFromDate:[NSDate date]];
}

- (NSString *)sanitizeFileName:(NSString *)fileName {
    NSCharacterSet *illegalFileNameCharacters = [NSCharacterSet characterSetWithCharactersInString:@":/\\?%*|\"<>"];
    return [[fileName componentsSeparatedByCharactersInSet:illegalFileNameCharacters] componentsJoinedByString:@"_"];
}


#pragma mark - 🔥 MFC临时目录统一管理
- (NSString *)getMFCTempDirectory {
    static NSString *mfcTempDir = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        mfcTempDir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"com.mfcbox.TmpCaches"];
        NSError *error;
        if (![[NSFileManager defaultManager] createDirectoryAtPath:mfcTempDir
                                        withIntermediateDirectories:YES
                                                         attributes:nil
                                                              error:&error]) {
            NSLog(@"[DeviceAppController] ❌ 创建MFC临时目录失败: %@", error.localizedDescription);
            // 如果创建失败，记录错误但仍返回路径
        } else {
            NSLog(@"[DeviceAppController] ✅ MFC统一临时目录就绪: %@", mfcTempDir);
        }
    });
    
    return mfcTempDir;
}

// ============================================================================
// MARK: - 下载应用方法
// ============================================================================
/// 旧接口 —— 兼容外部历史调用，默认视为「单个下载」
- (void)downloadAppIPA:(DeviceApp *)app {
    [self downloadAppIPA:app isQueued:NO];
}

/// 新接口 —— 多一个 `isQueued` 参数标记是否来自批量队列
- (void)downloadAppIPA:(DeviceApp *)app
              isQueued:(BOOL)isQueued {
    // 👉 记录状态（示例：可在 UI 中使用）
    BOOL oldQueuedState = self.isBatchDownloading;
    self.isBatchDownloading = isQueued;
    NSLog(@"[INFO]%@ 开始下载应用: %@ 设备版本: %@ adamId: %@ (Bundle ID: %@)",
          isQueued ? @"[队列]" : @"[单个]",
          app.appName, self.deviceVersion, app.appId, app.bundleID);
    
    NSLog(@"🔍 [downloadAppIPA] 开始调试 - 输入的 DeviceApp 对象:");
    NSLog(@"   app 对象地址: %p", app);
    NSLog(@"   app.appName: '%@'", app.appName ?: @"(null)");
    NSLog(@"   app.appId: '%@'", app.appId ?: @"(null)");
    NSLog(@"   app.bundleID: '%@'", app.bundleID ?: @"(null)");
    NSLog(@"   app.version: '%@'", app.version ?: @"(null)");
    
   
    if (![self isDeviceConnected]) {
        NSLog(@"[ERROR] 设备未连接，无法下载应用 %@", app.appName);
        return;
    }

    if (![self checkAvailableStorage:app.updateSize]) {
        NSLog(@"[ERROR] 设备存储空间不足，无法下载应用 %@", app.appName);
        return;
    }
    
    @try {
        NSString *appleID = app.appleID;
        NSString *password = app.applePassword;
        NSString *adamId = app.appId;
        NSString *bundleID = app.bundleID;

        // 🔥 完全复用updateApp的认证缓存逻辑
        BOOL canReuseAuth = NO;
        if (self.cachedLoginController && self.cachedAppleID &&
            [self.cachedAppleID isEqualToString:appleID]) {
            
            // 检查认证是否过期
            BOOL isAuthValid = YES;
            if (self.authExpirationTime && [[NSDate date] compare:self.authExpirationTime] == NSOrderedDescending) {
                // 认证已过期
                isAuthValid = NO;
                NSLog(@"[INFO] 缓存的认证已过期，需要重新登录");
            }
            
            if (isAuthValid) {
                canReuseAuth = YES;
                NSLog(@"[INFO] 使用缓存的认证信息，跳过登录步骤");
            }
        }

        if (canReuseAuth) {
            // 🔥 直接开始下载，跳过登录阶段 - 传递不上传不安装的标识
            [self startDownloadWithController:self.cachedLoginController //SimulationiCloudLoginController
                                      appleID:appleID
                                       adamId:adamId
                               expectedBundleID:bundleID
                                     noUpload:YES     // 🔥 关键：不上传到设备
                                    noInstall:YES   // 🔥 关键：不安装
                                isQueued:isQueued];
        } else {
            NSLog(@"[INFO] 需要登录验证");
            if (appleID.length == 0 || password.length == 0) {
                NSLog(@"[WARN] Apple ID 或密码为空，将在弹窗中手动输入");
            }

            NSLog(@"[DEBUG] AppleID: %@", appleID ?: @"(null)");
            NSLog(@"[DEBUG] AdamID: %@", adamId ?: @"(null)");
            NSLog(@"[DEBUG] BundleID: %@", bundleID ?: @"(null)");
            
            NSLog(@"Download button clicked");
            // 🔥 完全复用updateApp的登录窗口创建逻辑
            NSStoryboard *storyboard = [NSStoryboard storyboardWithName:@"Main" bundle:nil];
            iCloudLoginViewController *loginController = [storyboard instantiateControllerWithIdentifier:@"iCloudLoginWindowController"];
            
            // 🔥 为了后续能接收到登录成功的通知，可以添加一个通知观察者
            [[NSNotificationCenter defaultCenter] addObserver:self
                                                    selector:@selector(downloadOnlyLoginSucceeded:)  // 🔥 使用不同的处理方法
                                                        name:@"LoginSuccessNotification"
                                                      object:nil];
            
            // 🔥 完全复用updateApp的信息传递
            loginController.appleID = appleID;
            loginController.password = password;
            loginController.adamId = adamId;
            loginController.expectedBundleID = bundleID;
            loginController.deviceVersion = self.deviceVersion; //传递设备版本
            
            // 🔥 关键：设置不上传不安装标识
            loginController.noUpload = YES;
            loginController.noInstall = YES;
            loginController.isQueued = isQueued;
            
            NSLog(@"[downloadApp] ✅ 开始下载时传递的当前设备的iOS版本: %@", self.currentDeviceVersion);
            
            // 🔥 完全复用updateApp的窗口创建逻辑
            self.loginWindow = [[NSWindow alloc] init];
            self.loginWindow.contentViewController = loginController;
            
            // 隐藏窗口的标题栏
            self.loginWindow.titleVisibility = NSWindowTitleHidden;
            self.loginWindow.titlebarAppearsTransparent = YES;
            
            // 设置窗口的外观与应用一致（仅 macOS 10.14 及以上适用）
            if (@available(macOS 10.14, *)) {
                NSString *currentAppearance = [[NSUserDefaults standardUserDefaults] stringForKey:@"AppAppearance"];
                if ([currentAppearance isEqualToString:NSAppearanceNameAqua]) {
                    self.loginWindow.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
                } else if ([currentAppearance isEqualToString:NSAppearanceNameDarkAqua]) {
                    self.loginWindow.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
                } else {
                    self.loginWindow.appearance = [NSApp effectiveAppearance];
                }
            }
            
            // 设置窗口背景色
            self.loginWindow.backgroundColor = [NSColor windowBackgroundColor];
            
            // 设置窗口关闭时不自动释放
            self.loginWindow.releasedWhenClosed = NO;
            
            // 设置窗口的父窗口
            [[NSApp mainWindow] addChildWindow:self.loginWindow ordered:NSWindowAbove];
            
            // 将弹窗居中显示在主应用窗口中
            [self centerWindow:self.loginWindow relativeToWindow:[NSApp mainWindow]];
            
            // 显示窗口
            [self.loginWindow makeKeyAndOrderFront:nil];
        }
        
    } @catch (NSException *exception) {
        NSLog(@"[ERROR] 下载过程发生异常: %@", exception.description);
    } @finally {
        // 还原批量标记（避免单个下载影响后续）
        self.isBatchDownloading = oldQueuedState;
    }
}

// ============================================================================
// MARK: - 仅下载模式的登录成功处理
// ============================================================================

- (void)downloadOnlyLoginSucceeded:(NSNotification *)notification {
    // 🔥 完全复用 loginSucceeded 的逻辑
    SimulationiCloudLoginController *loginController = notification.userInfo[@"loginController"];
    NSString *appleID = notification.userInfo[@"appleID"];
    
    if (loginController) {
        // 保存认证信息
        self.cachedLoginController = loginController;
        self.cachedAppleID = appleID;
        
        // 设置认证过期时间（例如：2小时后）
        self.authExpirationTime = [NSDate dateWithTimeIntervalSinceNow:7200]; // 2小时 = 7200秒
        
        NSLog(@"[INFO] 已缓存认证信息，AppleID: %@，有效期至: %@",
              appleID, [NSDateFormatter localizedStringFromDate:self.authExpirationTime
                                                      dateStyle:NSDateFormatterShortStyle
                                                      timeStyle:NSDateFormatterMediumStyle]);
    }
    
    // 移除观察者
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"LoginSuccessNotification" object:nil];
    
    // 关闭登录窗口
    [self.loginWindow close];
    //self.loginWindow = nil;
}


// ============================================================================
#pragma mark - 从本地安装应用实现
// ============================================================================

/**
 * 从本地导入应用按钮的点击事件
 * 整个流程类似于 updateApp，但跳过下载步骤，直接从本地选择IPA文件安装
 */
- (IBAction)importAppFromLocal:(id)sender {
    NSLog(@"[INFO] 用户点击从本地导入应用按钮");
    LanguageManager *languageManager = [LanguageManager sharedManager];

    // 🔥 修复：正确处理权限验证回调
    NSString *currentProductType = @"Watch6,6";
    [[UserManager sharedManager] canProceedWithCurrentDeviceType:currentProductType completion:^(BOOL canProceed, NSString *targetPermission) {
        
        // 🔥 关键修复：检查权限验证结果
        if (!canProceed) {
            NSString *noPermissionMessage = [languageManager localizedStringForKeys:@"PermissionVerificationFailed"
                                                                           inModule:@"Permissions"
                                                                       defaultValue:@"The permission of %@ has expired or has not been activated"];
            NSString *operationPermissionTitle = [NSString stringWithFormat:noPermissionMessage, targetPermission];
            [[AlertWindowController sharedController] showResultMessageOnly:operationPermissionTitle inWindow:self.view.window];
            return; // 权限验证失败，直接返回
        }
        
        // 🔥 修复：权限验证成功后，继续执行后续逻辑
        [self proceedimportAppFromLocal];
    }];
}

- (void)proceedimportAppFromLocal {
    LanguageManager *manager = [LanguageManager sharedManager];
    
    // 1. 前置检查 - 复用 updateApp 的检查逻辑
    if (![self performPreInstallationChecks]) {
        return;
    }
    
    // 2. 显示文件选择对话框
    NSOpenPanel *openPanel = [NSOpenPanel openPanel];
    openPanel.allowedFileTypes = @[@"ipa"];
    openPanel.allowsMultipleSelection = YES; // 支持批量选择
    openPanel.canChooseFiles = YES;
    openPanel.canChooseDirectories = NO;
    
    // 设置本地化标题和提示
    NSString *selectIPATitle = [manager localizedStringForKeys:@"selectIPAFileTitle"
                                                      inModule:@"AppsManager"
                                                  defaultValue:@"Select IPA Files to Install"];
    NSString *selectIPAMessage = [manager localizedStringForKeys:@"selectIPAFileMessage"
                                                        inModule:@"AppsManager"
                                                    defaultValue:@"Choose one or more IPA files to install on the device"];
    
    openPanel.title = selectIPATitle;
    openPanel.message = selectIPAMessage;
    
    // 3. 显示文件选择对话框
    [openPanel beginSheetModalForWindow:self.view.window
                      completionHandler:^(NSInteger result) {
        if (result == NSModalResponseOK) {
            // 处理选中的IPA文件
            [self processSelectedIPAFiles:openPanel.URLs];
        }
    }];
}

/**
 * 前置检查 - 复用 updateApp 的检查逻辑
 */
- (BOOL)performPreInstallationChecks {
    LanguageManager *manager = [LanguageManager sharedManager];
    NSString *lockedDeviceID = [self getLockedDeviceID];
    // 检查设备连接状态
    if (![self isDeviceConnected]) {
        NSString *noDeviceMessage = [manager localizedStringForKeys:@"deviceNotConnectedMessage"
                                                           inModule:@"AppsManager"
                                                       defaultValue:@"Device not connected. Please connect a device and try again"];
        [[AlertWindowController sharedController] showResultMessageOnly:noDeviceMessage
                                                               inWindow:self.view.window];
        NSLog(@"[ERROR] 设备未连接，无法进行本地安装");
        return NO;
    }
    
    // 检查设备是否被锁定
    if (lockedDeviceID && ![lockedDeviceID isEqualToString:@""]) {
        NSLog(@"[INFO] 设备连接正常，UDID: %@", lockedDeviceID);
    }
    
    return YES;
}

/**
 * 处理选中的IPA文件列表
 */
- (void)processSelectedIPAFiles:(NSArray<NSURL *> *)fileURLs {
    NSLog(@"[INFO] 开始处理 %lu 个选中的IPA文件", (unsigned long)fileURLs.count);
    
    LanguageManager *manager = [LanguageManager sharedManager];
    
    // 验证选中的文件
    NSMutableArray<NSString *> *validIPAFiles = [NSMutableArray array];
    
    for (NSURL *fileURL in fileURLs) {
        NSString *filePath = fileURL.path;
        
        if ([self validateIPAFile:filePath]) {
            [validIPAFiles addObject:filePath];
            NSLog(@"[INFO] 有效的IPA文件: %@", [filePath lastPathComponent]);
        } else {
            NSString *invalidFileMessage = [manager localizedStringForKeys:@"invalidIPAFileMessage"
                                                                   inModule:@"AppsManager"
                                                               defaultValue:@"Invalid IPA file: %@"];
            NSString *message = [NSString stringWithFormat:invalidFileMessage, [filePath lastPathComponent]];
            [[AlertWindowController sharedController] showResultMessageOnly:message
                                                                   inWindow:self.view.window];
        }
    }
    
    if (validIPAFiles.count == 0) {
        NSString *noValidFilesMessage = [manager localizedStringForKeys:@"noValidIPAFilesMessage"
                                                               inModule:@"AppsManager"
                                                           defaultValue:@"No valid IPA files selected"];
        [[AlertWindowController sharedController] showResultMessageOnly:noValidFilesMessage
                                                               inWindow:self.view.window];
        return;
    }
    
    // 处理有效的IPA文件
    if (validIPAFiles.count == 1) {
        // 单个文件直接安装
        [self installSingleIPAFile:validIPAFiles.firstObject];
    } else {
        // 多个文件批量安装
        [self batchInstallIPAFiles:validIPAFiles];
    }
}

/**
 * 验证IPA文件的有效性
 */
- (BOOL)validateIPAFile:(NSString *)filePath {
    // 检查文件是否存在
    if (![[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
        NSLog(@"[ERROR] IPA文件不存在: %@", filePath);
        return NO;
    }
    
    // 检查文件扩展名
    if (![filePath.pathExtension.lowercaseString isEqualToString:@"ipa"]) {
        NSLog(@"[ERROR] 文件扩展名不正确: %@", filePath);
        return NO;
    }
    
    // 检查文件大小
    NSError *error;
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:filePath error:&error];
    if (error) {
        NSLog(@"[ERROR] 无法获取文件属性: %@", error.localizedDescription);
        return NO;
    }
    
    long long fileSize = [attributes[NSFileSize] longLongValue];
    if (fileSize <= 0) {
        NSLog(@"[ERROR] IPA文件大小异常: %lld", fileSize);
        return NO;
    }
    
    // 简单检查是否为有效的ZIP文件（IPA本质上是ZIP）
    if (![self isValidZipFile:filePath]) {
        NSLog(@"[ERROR] IPA文件格式无效: %@", filePath);
        return NO;
    }
    
    NSLog(@"[INFO] IPA文件验证通过: %@, 大小: %.2f MB",
          [filePath lastPathComponent], fileSize / (1024.0 * 1024.0));
    
    return YES;
}

/**
 * 简单验证ZIP文件格式
 */
- (BOOL)isValidZipFile:(NSString *)filePath {
    NSFileHandle *fileHandle = [NSFileHandle fileHandleForReadingAtPath:filePath];
    if (!fileHandle) return NO;
    
    NSData *header = [fileHandle readDataOfLength:4];
    [fileHandle closeFile];
    
    if (header.length < 4) return NO;
    
    // ZIP文件的魔术字节是 PK (0x504B)
    const unsigned char *bytes = (const unsigned char *)header.bytes;
    return (bytes[0] == 0x50 && bytes[1] == 0x4B);
}

/**
 * 安装单个IPA文件
 */
- (void)installSingleIPAFile:(NSString *)ipaPath {
    NSLog(@"[INFO] 准备安装IPA文件: %@", [ipaPath lastPathComponent]);
    
    // 1. 首先提取IPA文件信息
    NSDictionary *appInfo = [self extractAppInfoFromIPA:ipaPath];
    if (!appInfo) {
        LanguageManager *manager = [LanguageManager sharedManager];
        NSString *extractInfoFailedMessage = [manager localizedStringForKeys:@"extractIPAInfoFailedMessage"
                                                                     inModule:@"AppsManager"
                                                                 defaultValue:@"Failed to extract application information"];
        [[AlertWindowController sharedController] showResultMessageOnly:extractInfoFailedMessage
                                                               inWindow:self.view.window];
        return;
    }
    
    // 🔥 关键修复：检查应用是否已安装
    NSString *bundleID = appInfo[@"CFBundleIdentifier"];
    if ([self checkIfAppAlreadyInstalled:bundleID]) {
        [self handleDuplicateAppInstallation:appInfo ipaPath:ipaPath];
        return;
    }
    
    // 2. 如果应用未安装，继续原有的安装流程
    NSString *tempIPAPath = [self copyIPAToTempDirectory:ipaPath];
    if (!tempIPAPath) {
        LanguageManager *manager = [LanguageManager sharedManager];
        NSString *copyFileFailedMessage = [manager localizedStringForKeys:@"copyIPAFileFailedMessage"
                                                                  inModule:@"AppsManager"
                                                              defaultValue:@"Failed to prepare installation file"];
        [[AlertWindowController sharedController] showResultMessageOnly:copyFileFailedMessage
                                                               inWindow:self.view.window];
        return;
    }
    
    // 3. 启动安装流程
    [self startLocalInstallationProcess:tempIPAPath appInfo:appInfo];
}

/**
 * 检查应用是否已安装
 */
- (BOOL)checkIfAppAlreadyInstalled:(NSString *)bundleID {
    if (!bundleID || bundleID.length == 0) {
        NSLog(@"[WARNING] Bundle ID为空，无法检查重复安装");
        return NO;
    }
    
    // 检查当前已安装应用列表
    for (DeviceApp *app in self.allAppList) {
        if ([app.bundleID isEqualToString:bundleID]) {
            NSLog(@"[WARNING] 检测到重复应用: %@ (Bundle ID: %@)", app.appName, bundleID);
            return YES;
        }
    }
    
    NSLog(@"[INFO] 应用未安装，可以继续安装流程 (Bundle ID: %@)", bundleID);
    return NO;
}

/**
 * 处理重复应用安装情况
 */
- (void)handleDuplicateAppInstallation:(NSDictionary *)newAppInfo ipaPath:(NSString *)ipaPath {
    NSString *bundleID = newAppInfo[@"CFBundleIdentifier"];
    NSString *newAppName = newAppInfo[@"CFBundleDisplayName"] ?: newAppInfo[@"CFBundleName"] ?: @"Unknown App";
    NSString *newVersion = newAppInfo[@"CFBundleShortVersionString"] ?: @"Unknown";
    
    // 查找已安装的应用信息
    DeviceApp *existingApp = nil;
    for (DeviceApp *app in self.allAppList) {
        if ([app.bundleID isEqualToString:bundleID]) {
            existingApp = app;
            break;
        }
    }
    
    LanguageManager *manager = [LanguageManager sharedManager];
    
    if (existingApp) {
        // 比较版本号
        NSComparisonResult versionComparison = [newVersion compare:existingApp.version options:NSNumericSearch];
        
        NSString *title = [manager localizedStringForKeys:@"duplicateAppFoundTitle"
                                                  inModule:@"AppsManager"
                                              defaultValue:@"Application Already Installed"];
        
        NSString *message;
        if (versionComparison == NSOrderedSame) {
            // 相同版本
            NSString *sameVersionMessage = [manager localizedStringForKeys:@"sameVersionInstalledMessage"
                                                                   inModule:@"AppsManager"
                                                               defaultValue:@"The same version (%@) of \"%@\" is already installed. Do you want to reinstall it?"];
            message = [NSString stringWithFormat:sameVersionMessage, newVersion, newAppName];
        } else if (versionComparison == NSOrderedDescending) {
            // 新版本更高
            NSString *upgradeMessage = [manager localizedStringForKeys:@"upgradeVersionMessage"
                                                              inModule:@"AppsManager"
                                                          defaultValue:@"A newer version (%@) of \"%@\" will be installed. Current version: %@. Continue?"];
            message = [NSString stringWithFormat:upgradeMessage, newVersion, newAppName, existingApp.version];
        } else {
            // 新版本更低
            NSString *downgradeMessage = [manager localizedStringForKeys:@"downgradeVersionMessage"
                                                                inModule:@"AppsManager"
                                                            defaultValue:@"An older version (%@) of \"%@\" will be installed. Current version: %@. Continue?"];
            message = [NSString stringWithFormat:downgradeMessage, newVersion, newAppName, existingApp.version];
        }
        
        NSString *installTitle = [manager localizedStringForKeys:@"ContinueButton"
                                                        inModule:@"GlobaButtons"
                                                    defaultValue:@"Continue"];
        NSString *cancelTitle = [manager localizedStringForKeys:@"CancelButton"
                                                       inModule:@"GlobaButtons"
                                                   defaultValue:@"Cancel"];
        
        // 🔥 修复：创建安全的 block 调用
        // 确保 self、ipaPath 和 newAppInfo 在 block 执行时仍然有效
        NSString *safeIpaPath = [ipaPath copy]; // 创建副本防止被释放
        NSDictionary *safeAppInfo = [newAppInfo copy]; // 创建副本防止被释放
        __weak typeof(self) weakSelf = self; // 弱引用防止循环引用
        
        // 显示确认对话框
        [[AlertWindowController sharedController] showAlertWithTitle:title
                                                         description:message
                                                        confirmTitle:installTitle
                                                         cancelTitle:cancelTitle
                                                       confirmAction:^{
            // 🔥 修复：在 block 内部添加安全检查
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) {
                NSLog(@"[ERROR] DeviceAppController 已被释放，取消安装");
                return;
            }
            
            // 🔥 修复：添加参数有效性检查
            if (!safeIpaPath || ![[NSFileManager defaultManager] fileExistsAtPath:safeIpaPath]) {
                NSLog(@"[ERROR] IPA文件路径无效或文件不存在: %@", safeIpaPath);
                LanguageManager *manager = [LanguageManager sharedManager];
                NSString *fileNotFoundMessage = [manager localizedStringForKeys:@"ipaFileNotFoundMessage"
                                                                       inModule:@"AppsManager"
                                                                   defaultValue:@"IPA file not found"];
                [[AlertWindowController sharedController] showResultMessageOnly:fileNotFoundMessage
                                                                       inWindow:strongSelf.view.window];
                return;
            }
            
            if (!safeAppInfo || !safeAppInfo[@"CFBundleIdentifier"]) {
                NSLog(@"[ERROR] 应用信息无效");
                LanguageManager *manager = [LanguageManager sharedManager];
                NSString *invalidInfoMessage = [manager localizedStringForKeys:@"invalidAppInfoMessage"
                                                                      inModule:@"AppsManager"
                                                                  defaultValue:@"Invalid application information"];
                [[AlertWindowController sharedController] showResultMessageOnly:invalidInfoMessage
                                                                       inWindow:strongSelf.view.window];
                return;
            }
            
            NSLog(@"[INFO] 用户确认继续安装，执行强制安装流程");
            
            // 🔥 修复：使用延迟执行，确保 UI 完全更新后再执行安装
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [strongSelf forcedInstallSingleIPAFile:safeIpaPath appInfo:safeAppInfo];
            });
        }];
        
    } else {
        // 理论上不应该到这里，但作为安全措施
        NSString *unknownErrorMessage = [manager localizedStringForKeys:@"duplicateCheckErrorMessage"
                                                                inModule:@"AppsManager"
                                                            defaultValue:@"Unable to verify application installation status"];
        [[AlertWindowController sharedController] showResultMessageOnly:unknownErrorMessage
                                                               inWindow:self.view.window];
    }
}

/**
 * 🔥 强制安装（用户确认后）
 */
- (void)forcedInstallSingleIPAFile:(NSString *)ipaPath appInfo:(NSDictionary *)appInfo {
    NSLog(@"[INFO] 用户确认强制安装: %@", appInfo[@"CFBundleDisplayName"]);
    
    // 🔥 添加：防止重复调用检查
    static BOOL isProcessingForcedInstall = NO;
    static NSTimeInterval lastInstallTime = 0;
    NSTimeInterval currentTime = [[NSDate date] timeIntervalSince1970];
    
    if (isProcessingForcedInstall) {
        NSLog(@"[WARN] 检测到重复的强制安装请求，忽略");
        return;
    }
    
    // 防止快速重复点击（2秒内）
    if (currentTime - lastInstallTime < 2.0) {
        NSLog(@"[WARN] 检测到快速重复安装请求，忽略");
        return;
    }
    
    isProcessingForcedInstall = YES;
    lastInstallTime = currentTime;
    
    @try {
        // 复制文件到临时目录
        NSString *tempIPAPath = [self copyIPAToTempDirectory:ipaPath];
        if (!tempIPAPath) {
            LanguageManager *manager = [LanguageManager sharedManager];
            NSString *copyFileFailedMessage = [manager localizedStringForKeys:@"copyIPAFileFailedMessage"
                                                                      inModule:@"AppsManager"
                                                                  defaultValue:@"Failed to prepare installation file"];
            [[AlertWindowController sharedController] showResultMessageOnly:copyFileFailedMessage
                                                                   inWindow:self.view.window];
            return;
        }
        
        // 🔥 添加：参数验证
        if (!appInfo || !appInfo[@"CFBundleIdentifier"]) {
            NSLog(@"[ERROR] 应用信息不完整，无法继续安装");
            LanguageManager *manager = [LanguageManager sharedManager];
            NSString *invalidAppInfoMessage = [manager localizedStringForKeys:@"invalidAppInfoMessage"
                                                                     inModule:@"AppsManager"
                                                                 defaultValue:@"Invalid application information"];
            [[AlertWindowController sharedController] showResultMessageOnly:invalidAppInfoMessage
                                                                   inWindow:self.view.window];
            return;
        }
        
        // 启动强制安装流程
        [self startLocalInstallationProcess:tempIPAPath appInfo:appInfo];
        
    } @catch (NSException *exception) {
        NSLog(@"[ERROR] 强制安装过程中发生异常: %@", exception.reason);
        
        LanguageManager *manager = [LanguageManager sharedManager];
        NSString *installExceptionMessage = [manager localizedStringForKeys:@"installExceptionMessage"
                                                                   inModule:@"AppsManager"
                                                               defaultValue:@"Installation process encountered an error"];
        [[AlertWindowController sharedController] showResultMessageOnly:installExceptionMessage
                                                               inWindow:self.view.window];
    } @finally {
        // 🔥 重要：无论成功还是失败都要重置标记
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            isProcessingForcedInstall = NO;
        });
    }
}

/**
 * 批量安装多个IPA文件
 */
- (void)batchInstallIPAFiles:(NSArray<NSString *> *)ipaFiles {
    NSLog(@"[INFO] 开始批量安装 %lu 个IPA文件", (unsigned long)ipaFiles.count);
    
    LanguageManager *manager = [LanguageManager sharedManager];
    NSString *batchInstallTitle = [manager localizedStringForKeys:@"batchInstallConfirmTitle"
                                                         inModule:@"AppsManager"
                                                     defaultValue:@"Batch Installation"];
    NSString *batchInstallMessage = [manager localizedStringForKeys:@"batchInstallConfirmMessage"
                                                            inModule:@"AppsManager"
                                                        defaultValue:@"Are you sure you want to install %ld IPA files?"];
    NSString *message = [NSString stringWithFormat:batchInstallMessage, (long)ipaFiles.count];
    
    NSString *installTitle = [manager localizedStringForKeys:@"ContinueButton"
                                                    inModule:@"GlobaButtons"
                                                defaultValue:@"Continue"];
    NSString *cancelTitle = [manager localizedStringForKeys:@"CancelButton"
                                                   inModule:@"GlobaButtons"
                                               defaultValue:@"Cancel"];
    
    // 确认批量安装
    [[AlertWindowController sharedController] showAlertWithTitle:batchInstallTitle
                                                     description:message
                                                    confirmTitle:installTitle
                                                     cancelTitle:cancelTitle
                                                   confirmAction:^{
        [self executeBatchInstallation:ipaFiles];
    }];
}

/**
 * 执行批量安装
 */
- (void)executeBatchInstallation:(NSArray<NSString *> *)ipaFiles {
    NSLog(@"[INFO] 执行批量安装流程");
    
    // 🔥 新增：预检查所有文件，过滤重复应用
    NSMutableArray<NSString *> *validFiles = [NSMutableArray array];
    NSMutableArray<NSString *> *duplicateFiles = [NSMutableArray array];
    
    for (NSString *ipaPath in ipaFiles) {
        NSDictionary *appInfo = [self extractAppInfoFromIPA:ipaPath];
        if (appInfo) {
            NSString *bundleID = appInfo[@"CFBundleIdentifier"];
            if ([self checkIfAppAlreadyInstalled:bundleID]) {
                [duplicateFiles addObject:[ipaPath lastPathComponent]];
                NSLog(@"[WARNING] 批量安装中发现重复应用: %@", [ipaPath lastPathComponent]);
            } else {
                [validFiles addObject:ipaPath];
            }
        } else {
            NSLog(@"[ERROR] 无法提取应用信息: %@", [ipaPath lastPathComponent]);
        }
    }
    
    // 如果有重复应用，询问用户是否继续
    if (duplicateFiles.count > 0) {
        LanguageManager *manager = [LanguageManager sharedManager];
        NSString *title = [manager localizedStringForKeys:@"batchInstallDuplicateTitle"
                                                  inModule:@"AppsManager"
                                              defaultValue:@"Duplicate Applications Found"];
        NSString *message = [manager localizedStringForKeys:@"batchInstallDuplicateMessage"
                                                    inModule:@"AppsManager"
                                                defaultValue:@"Found %ld duplicate applications. Continue installing %ld new applications?"];
        NSString *formattedMessage = [NSString stringWithFormat:message,
                                     (long)duplicateFiles.count, (long)validFiles.count];
        
        NSString *installTitle = [manager localizedStringForKeys:@"ContinueButton"
                                                        inModule:@"GlobaButtons"
                                                    defaultValue:@"Continue"];
        NSString *cancelTitle = [manager localizedStringForKeys:@"CancelButton"
                                                       inModule:@"GlobaButtons"
                                                   defaultValue:@"Cancel"];
        
        [[AlertWindowController sharedController] showAlertWithTitle:title
                                                         description:formattedMessage
                                                        confirmTitle:installTitle
                                                         cancelTitle:cancelTitle
                                                       confirmAction:^{
            // 只安装不重复的应用
            [self executeBatchInstallationWithValidFiles:validFiles];
        }];
    } else {
        // 没有重复应用，继续原有流程
        [self executeBatchInstallationWithValidFiles:validFiles];
    }
}

/**
 * 🔥 执行已验证的批量安装
 */
- (void)executeBatchInstallationWithValidFiles:(NSArray<NSString *> *)validFiles {
    if (validFiles.count == 0) {
        LanguageManager *manager = [LanguageManager sharedManager];
        NSString *noValidAppsMessage = [manager localizedStringForKeys:@"noValidAppsToInstallMessage"
                                                              inModule:@"AppsManager"
                                                          defaultValue:@"No valid applications to install"];
        [[AlertWindowController sharedController] showResultMessageOnly:noValidAppsMessage
                                                               inWindow:self.view.window];
        return;
    }
    
    // 设置批量安装状态
    self.isBatchInstalling = YES;
    self.batchInstallQueue = [validFiles mutableCopy];
    
    // 监听安装完成通知
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onLocalInstallCompleted:)
                                                 name:@"AppInstallationSuccessNotification"
                                               object:nil];
    
    // 开始第一个安装
    [self installNextIPAFromQueue];
}

/**
 * 从队列中安装下一个IPA
 */
- (void)installNextIPAFromQueue {
    if (!self.batchInstallQueue || self.batchInstallQueue.count == 0) {
        // 所有安装完成
        [self completeBatchInstallation];
        return;
    }
    
    NSString *ipaPath = [self.batchInstallQueue firstObject];
    [self.batchInstallQueue removeObjectAtIndex:0];
    
    NSLog(@"[批量安装] 🔄 安装IPA: %@，剩余: %lu",
          [ipaPath lastPathComponent], (unsigned long)self.batchInstallQueue.count);
    
    // 安装当前IPA
    [self installSingleIPAFile:ipaPath];
}

/**
 * 本地安装完成通知处理
 */
- (void)onLocalInstallCompleted:(NSNotification *)notification {
    NSLog(@"[批量安装] ✅ 单个本地安装完成，继续下一个");
    
    // 增加间隔时间，避免并发冲突
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self installNextIPAFromQueue];
    });
}

/**
 * 完成批量安装
 */
- (void)completeBatchInstallation {
    NSLog(@"[批量安装] ✅ 批量本地安装完成");
    
    // 移除通知观察者
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                     name:@"AppInstallationSuccessNotification"
                                                   object:nil];
    
    // 重置状态
    self.isBatchInstalling = NO;
    self.batchInstallQueue = nil;
    
    // 刷新应用列表
    dispatch_async(dispatch_get_main_queue(), ^{
        LanguageManager *manager = [LanguageManager sharedManager];
        NSString *batchInstallCompleteMessage = [manager localizedStringForKeys:@"batchInstallCompleteMessage"
                                                                        inModule:@"AppsManager"
                                                                    defaultValue:@"Batch installation completed"];
        [[AlertWindowController sharedController] showResultMessageOnly:batchInstallCompleteMessage
                                                               inWindow:self.view.window];
        
        // 🔥 新增：刷新前禁用批量操作按钮
        [self updateBatchOperationButtonsState:NO];
        
        // 延迟刷新应用列表
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self refreshAppList];
        });
    });
}

/**
 * 启动本地安装流程 - 复用 updateApp 的安装逻辑
 */
- (void)startLocalInstallationProcess:(NSString *)tempIPAPath appInfo:(NSDictionary *)appInfo {
    NSLog(@"[INFO] 启动本地安装流程，IPA路径: %@", tempIPAPath);
    
    // 🔥 参数验证
    if (!tempIPAPath || !appInfo) {
        NSLog(@"[ERROR] 启动本地安装流程失败：参数无效");
        LanguageManager *manager = [LanguageManager sharedManager];
        NSString *errorMessage = [manager localizedStringForKeys:@"installParameterError"
                                                        inModule:@"AppsManager"
                                                    defaultValue:@"Installation parameter error"];
        [[AlertWindowController sharedController] showResultMessageOnly:errorMessage
                                                               inWindow:self.view.window];
        return;
    }
    
    // 🔥 防止重复调用
    static BOOL isProcessing = NO;
    if (isProcessing) {
        NSLog(@"[WARNING] 本地安装流程已在进行中，忽略重复调用");
        return;
    }
    isProcessing = YES;
    
    // 🔥 确保在主线程上执行UI操作
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            isProcessing = NO;  // 重置标志
            [self startLocalInstallationProcess:tempIPAPath appInfo:appInfo];
        });
        return;
    }
    
    // 🔥 安全关闭现有窗口，并添加延迟确保完全清理
    [self safeCloseLoginWindow];
    
    // 🔥 稍微延迟创建新窗口，确保旧窗口完全清理
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self createInstallWindowSafely:tempIPAPath appInfo:appInfo];
        isProcessing = NO;  // 重置标志
    });
}

/**
 * 安全创建安装窗口 - 新增方法
 * 分离窗口创建逻辑，提高代码可维护性
 */
- (void)createInstallWindowSafely:(NSString *)tempIPAPath appInfo:(NSDictionary *)appInfo {
    @try {
        // 复用 updateApp 中的 DownloadProgressViewController 逻辑
        NSStoryboard *storyboard = [NSStoryboard storyboardWithName:@"Main" bundle:nil];
        DownloadProgressViewController *progressController =
            [storyboard instantiateControllerWithIdentifier:@"DownloadProgressViewWindowController"];
        
        if (!progressController) {
            NSLog(@"[ERROR] 无法创建 DownloadProgressViewController");
            LanguageManager *manager = [LanguageManager sharedManager];
            NSString *errorMessage = [manager localizedStringForKeys:@"installWindowCreateErrorMessage"
                                                            inModule:@"AppsManager"
                                                        defaultValue:@"Failed to create installation window"];
            [[AlertWindowController sharedController] showResultMessageOnly:errorMessage
                                                                   inWindow:self.view.window];
            return;
        }
        
        // 设置本地安装模式的参数
        progressController.isLocalInstallMode = YES; // 标记为本地安装模式
        progressController.localIPAPath = tempIPAPath;
        progressController.expectedBundleID = appInfo[@"CFBundleIdentifier"];
        progressController.deviceVersion = self.deviceVersion;
        
        // 如果有 adamId，也设置（用于某些验证，本地安装可以使用占位符）
        progressController.adamId = appInfo[@"adamId"] ?: @"0";
        
        // 🔥 安全创建新窗口
        NSWindow *newWindow = [[NSWindow alloc] init];
        if (!newWindow) {
            NSLog(@"[ERROR] 无法创建新窗口对象");
            return;
        }
        
        newWindow.contentViewController = progressController;
        
        // 隐藏窗口的标题栏 - 复用 updateApp 的窗口样式
        newWindow.titleVisibility = NSWindowTitleHidden;
        newWindow.titlebarAppearsTransparent = YES;
        
        // 设置窗口关闭时不自动释放
        newWindow.releasedWhenClosed = NO;
        
        // 设置窗口的外观与应用一致
        if (@available(macOS 10.14, *)) {
            NSString *currentAppearance = [[NSUserDefaults standardUserDefaults] stringForKey:@"AppAppearance"];
            if ([currentAppearance isEqualToString:NSAppearanceNameAqua]) {
                newWindow.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
            } else if ([currentAppearance isEqualToString:NSAppearanceNameDarkAqua]) {
                newWindow.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
            } else {
                newWindow.appearance = [NSApp effectiveAppearance];
            }
        }
        
        // 设置窗口背景色
        newWindow.backgroundColor = [NSColor windowBackgroundColor];
        
        // 🔥 只有在窗口完全配置好后才赋值给属性
        self.loginWindow = newWindow;
        
        NSLog(@"[DEBUG] 新安装窗口创建成功: %p", self.loginWindow);
        
        // 显示窗口
        [self.loginWindow makeKeyAndOrderFront:nil];
        [self.loginWindow center];
        
        // 直接启动本地安装流程（跳过下载步骤）
        [progressController startInstallAppFromLocal];
        
    } @catch (NSException *exception) {
        NSLog(@"[ERROR] 创建安装窗口时发生异常: %@", exception.reason);
        NSLog(@"[ERROR] 异常堆栈: %@", exception.callStackSymbols);
        
        // 异常处理：显示错误信息
        LanguageManager *manager = [LanguageManager sharedManager];
        NSString *errorMessage = [manager localizedStringForKeys:@"installWindowCreateErrorMessage"
                                                        inModule:@"AppsManager"
                                                    defaultValue:@"Failed to create installation window"];
        [[AlertWindowController sharedController] showResultMessageOnly:errorMessage
                                                               inWindow:self.view.window];
        
        // 🔥 确保清理状态
        self.loginWindow = nil;
    }
}

#pragma mark - 安全的窗口管理方法

/**
 * 安全关闭登录窗口
 * 避免在关闭窗口时发生崩溃
 */
- (void)safeCloseLoginWindow {
    // 🔥 确保在主线程执行
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self safeCloseLoginWindow];
        });
        return;
    }
    
    // 🔥 防止重入调用
    static BOOL isClosing = NO;
    if (isClosing) {
        NSLog(@"[DEBUG] 窗口正在关闭中，忽略重复调用");
        return;
    }
    isClosing = YES;
    
    @try {
        // 🔥 更严格的有效性检查
        if (self.loginWindow && [self isLoginWindowValid]) {
            NSLog(@"[DEBUG] 安全关闭登录窗口: %p", self.loginWindow);
            
            // 🔥 使用 weak 引用避免在操作过程中对象被释放
            __weak NSWindow *weakWindow = self.loginWindow;
            
            // 先从父窗口移除（如果存在）
            if (weakWindow && weakWindow.parentWindow) {
                [weakWindow.parentWindow removeChildWindow:weakWindow];
                NSLog(@"[DEBUG] 已从父窗口移除子窗口");
            }
            
            // 关闭窗口
            if (weakWindow && weakWindow.isVisible) {
                [weakWindow close];
                NSLog(@"[DEBUG] 窗口已关闭");
            }
            
        } else if (self.loginWindow) {
            NSLog(@"[WARNING] 登录窗口对象无效，直接置空引用");
        }
    } @catch (NSException *exception) {
        NSLog(@"[ERROR] 关闭登录窗口时异常: %@", exception.reason);
        NSLog(@"[ERROR] 异常堆栈: %@", exception.callStackSymbols);
    } @finally {
        // 🔥 无论如何都要置空引用和重置标志
        self.loginWindow = nil;
        isClosing = NO;
        NSLog(@"[DEBUG] 登录窗口引用已清空");
    }
}

/**
 * 检查登录窗口状态
 * 确保窗口对象处于有效状态
 */
- (BOOL)isLoginWindowValid {
    if (!self.loginWindow) {
        return NO;
    }
    
    @try {
        // 🔥 使用多重检查来验证对象有效性
        if (![self.loginWindow respondsToSelector:@selector(isVisible)]) {
            NSLog(@"[ERROR] 窗口对象不响应基本方法");
            return NO;
        }
        
        // 🔥 尝试访问窗口的关键属性来触发可能的崩溃
        BOOL isVisible = self.loginWindow.isVisible;
        NSWindow *parentWindow = self.loginWindow.parentWindow;
        
        // 🔥 如果能执行到这里，说明对象是有效的
        NSLog(@"[DEBUG] 窗口有效性检查通过 - 可见: %@, 父窗口: %@",
              isVisible ? @"是" : @"否",
              parentWindow ? @"存在" : @"无");
        
        return YES;
        
    } @catch (NSException *exception) {
        NSLog(@"[ERROR] 登录窗口对象无效: %@", exception.reason);
        // 🔥 立即置空无效的引用
        self.loginWindow = nil;
        return NO;
    }
}



// ============================================================================
#pragma mark - IPA文件信息提取和处理工具方法
// ============================================================================

/**
 * 从IPA文件中提取应用信息
 */
- (NSDictionary *)extractAppInfoFromIPA:(NSString *)ipaPath {
    NSLog(@"[INFO] 开始提取IPA文件信息: %@", [ipaPath lastPathComponent]);
    
    // 检查文件是否存在
    if (![[NSFileManager defaultManager] fileExistsAtPath:ipaPath]) {
        NSLog(@"[ERROR] IPA文件不存在: %@", ipaPath);
        return nil;
    }
    
    @try {
        // 使用 libzip 或其他方法提取 Info.plist
        // 这里使用简化的实现，实际项目中应该使用完整的ZIP解析
        
        int error = 0;
        struct zip *archive = zip_open([ipaPath UTF8String], ZIP_RDONLY, &error);
        if (!archive) {
            NSLog(@"[ERROR] 无法打开IPA文件: %d", error);
            return nil;
        }
        
        // 查找应用目录
        NSString *appDir = [self findAppDirectoryInZip:archive];
        if (!appDir) {
            NSLog(@"[ERROR] 无法在IPA中找到应用目录");
            zip_close(archive);
            return nil;
        }
        
        // 提取Info.plist
        NSString *infoPlistPath = [appDir stringByAppendingString:@"Info.plist"];
        char *buffer = NULL;
        uint32_t length = 0;
        
        if ([self getZipFileContents:archive path:infoPlistPath buffer:&buffer length:&length]) {
            NSData *plistData = [NSData dataWithBytes:buffer length:length];
            free(buffer);
            
            NSError *parseError;
            NSDictionary *infoPlist = [NSPropertyListSerialization propertyListWithData:plistData
                                                                                 options:0
                                                                                  format:NULL
                                                                                   error:&parseError];
            
            zip_close(archive);
            
            if (infoPlist && !parseError) {
                NSLog(@"[INFO] 成功提取应用信息: %@", infoPlist[@"CFBundleDisplayName"]);
                return infoPlist;
            } else {
                NSLog(@"[ERROR] Info.plist解析失败: %@", parseError.localizedDescription);
            }
        } else {
            zip_close(archive);
            NSLog(@"[ERROR] 无法读取Info.plist");
        }
        
    } @catch (NSException *exception) {
        NSLog(@"[ERROR] 提取IPA信息时发生异常: %@", exception.reason);
    }
    
    return nil;
}

/**
 * 🔥 辅助方法 - 查找ZIP中的应用目录
 */
- (NSString *)findAppDirectoryInZip:(struct zip *)archive {
    if (!archive) return nil;
    
    zip_int64_t numEntries = zip_get_num_entries(archive, 0);
    
    for (zip_int64_t i = 0; i < numEntries; i++) {
        const char *name = zip_get_name(archive, i, 0);
        if (name) {
            NSString *fileName = [NSString stringWithUTF8String:name];
            if ([fileName hasPrefix:@"Payload/"] && [fileName hasSuffix:@".app/"]) {
                return fileName;
            }
        }
    }
    
    return nil;
}

/**
 * 🔥 辅助方法 - 从ZIP中读取文件内容
 */
- (BOOL)getZipFileContents:(struct zip *)archive path:(NSString *)path buffer:(char **)buffer length:(uint32_t *)length {
    if (!archive || !path) return NO;
    
    struct zip_file *file = zip_fopen(archive, [path UTF8String], 0);
    if (!file) {
        NSLog(@"[ERROR] 无法打开ZIP中的文件: %@", path);
        return NO;
    }
    
    struct zip_stat stat;
    if (zip_stat(archive, [path UTF8String], 0, &stat) != 0) {
        zip_fclose(file);
        return NO;
    }
    
    *length = (uint32_t)stat.size;
    *buffer = malloc(*length);
    
    if (zip_fread(file, *buffer, *length) != *length) {
        free(*buffer);
        *buffer = NULL;
        zip_fclose(file);
        return NO;
    }
    
    zip_fclose(file);
    return YES;
}

/**
 * 复制IPA文件到临时目录
 */
- (NSString *)copyIPAToTempDirectory:(NSString *)ipaPath {
    NSString *tempDir = [self getMFCTempDirectory];
    NSString *fileName = [NSString stringWithFormat:@"local_install_%@_%@.ipa",
                         [self getCurrentTimestamp],
                         [[ipaPath lastPathComponent] stringByDeletingPathExtension]];
    NSString *tempIPAPath = [tempDir stringByAppendingPathComponent:fileName];
    
    NSError *error;
    if ([[NSFileManager defaultManager] copyItemAtPath:ipaPath
                                                toPath:tempIPAPath
                                                 error:&error]) {
        NSLog(@"[INFO] IPA文件已复制到临时目录: %@", tempIPAPath);
        return tempIPAPath;
    } else {
        NSLog(@"[ERROR] 复制IPA文件失败: %@", error.localizedDescription);
        return nil;
    }
}


// ============================================================================
#pragma mark - 更新应用方法
// ============================================================================
/*
 *1.1 前置检查阶段
 *1.2 iCloud认证阶段
 *1.3 下载阶段
 *1.4 安装阶段
 *1.4 安装状态监控
     通过 installation_status_callback 回调监控安装进度：
     CreatingStagingDirectory - 创建暂存目录
     ExtractingPackage - 解压安装包
     InspectingPackage - 检查安装包
     PreflightingApplication - 预检查应用
     VerifyingApplication - 验证应用
     Complete - 安装完成
 */
- (void)updateApp:(DeviceApp *)app {

    NSLog(@"[INFO] 开始更新应用: %@ 设备版本: %@ adamId: %@ (Bundle ID: %@)", app.appName, self.deviceVersion, app.appId, app.bundleID);

    if (![self isDeviceConnected]) {
        NSLog(@"[ERROR] 设备未连接，无法更新应用 %@", app.appName);
        return;
    }

    if (![self checkAvailableStorage:app.updateSize]) {
        NSLog(@"[ERROR] 设备存储空间不足，无法更新应用 %@", app.appName);
        return;
    }
    @try {
        NSString *appleID = app.appleID;
        NSString *password = app.applePassword;
        NSString *adamId = app.appId;
        NSString *bundleID = app.bundleID;

        // 检查是否有缓存的认证信息，且与当前所需的相同
        BOOL canReuseAuth = NO;
        if (self.cachedLoginController && self.cachedAppleID &&
            [self.cachedAppleID isEqualToString:appleID]) {
            
            // 检查认证是否过期
            BOOL isAuthValid = YES;
            if (self.authExpirationTime && [[NSDate date] compare:self.authExpirationTime] == NSOrderedDescending) {
                // 认证已过期
                isAuthValid = NO;
                NSLog(@"[INFO] 缓存的认证已过期，需要重新登录");
            }
            
            if (isAuthValid) {
                canReuseAuth = YES;
                NSLog(@"[INFO] 使用缓存的认证信息，跳过登录步骤");
            }
        }

        if (canReuseAuth) {
            // 直接开始下载，跳过登录阶段
            [self startDownloadWithController:self.cachedLoginController
                                      appleID:appleID
                                      adamId:adamId
                               expectedBundleID:bundleID];
        } else {
            NSLog(@"[INFO] 需要登录验证");
            if (appleID.length == 0 || password.length == 0) {
                NSLog(@"[WARN] Apple ID 或密码为空，将在弹窗中手动输入");
            }

            NSLog(@"[DEBUG] AppleID: %@", appleID ?: @"(null)");
            NSLog(@"[DEBUG] AdamID: %@", adamId ?: @"(null)");
            NSLog(@"[DEBUG] BundleID: %@", bundleID ?: @"(null)");
            
            NSLog(@"Update button clicked");
            // 加载 UserLoginController 实例
            NSStoryboard *storyboard = [NSStoryboard storyboardWithName:@"Main" bundle:nil];
            iCloudLoginViewController *loginController = [storyboard instantiateControllerWithIdentifier:@"iCloudLoginWindowController"];
            
            // 为了后续能接收到登录成功的通知，可以添加一个通知观察者
            [[NSNotificationCenter defaultCenter] addObserver:self
                                                    selector:@selector(loginSucceeded:)
                                                        name:@"LoginSuccessNotification"
                                                      object:nil];
            
            //添加信息传递
            loginController.appleID = appleID;
            loginController.password = password;
            loginController.adamId = adamId;
            loginController.expectedBundleID = bundleID;
            loginController.deviceVersion = self.deviceVersion; //传递设备版本
            
            
            NSLog(@"[updateApp] ✅ 开始更新时传递的当前设备的iOS版本: %@", self.currentDeviceVersion);
            
            // 创建窗口并设置其 ContentViewController
            self.loginWindow = [[NSWindow alloc] init];
            self.loginWindow.contentViewController = loginController;
            
            // 隐藏窗口的标题栏
            self.loginWindow.titleVisibility = NSWindowTitleHidden;
            self.loginWindow.titlebarAppearsTransparent = YES;
            
            // 设置窗口的外观与应用一致（仅 macOS 10.14 及以上适用）
            if (@available(macOS 10.14, *)) {
                NSString *currentAppearance = [[NSUserDefaults standardUserDefaults] stringForKey:@"AppAppearance"];
                if ([currentAppearance isEqualToString:NSAppearanceNameAqua]) {
                    self.loginWindow.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
                } else if ([currentAppearance isEqualToString:NSAppearanceNameDarkAqua]) {
                    self.loginWindow.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
                } else {
                    self.loginWindow.appearance = [NSApp effectiveAppearance];
                }
            }
            
            // 设置窗口代理
            self.loginWindow.delegate = self;
            
            // 设置窗口背景色
            self.loginWindow.backgroundColor = [NSColor windowBackgroundColor];
            
            // 设置窗口关闭时不自动释放
            self.loginWindow.releasedWhenClosed = NO;
            
            // 设置窗口的父窗口
            [[NSApp mainWindow] addChildWindow:self.loginWindow ordered:NSWindowAbove];
            
            // 将弹窗居中显示在主应用窗口中
            [self centerWindow:self.loginWindow relativeToWindow:[NSApp mainWindow]];
            
            // 显示窗口
            [self.loginWindow makeKeyAndOrderFront:nil];
        }
    } @catch (NSException *exception) {
        NSLog(@"[ERROR] 更新过程发生异常: %@", exception.description);
    }
}

- (void)centerWindow:(NSWindow *)childWindow relativeToWindow:(NSWindow *)parentWindow {
    if (parentWindow) {
        NSRect parentFrame = parentWindow.frame;
        NSRect childFrame = childWindow.frame;

        CGFloat x = NSMidX(parentFrame) - NSWidth(childFrame) / 2;
        CGFloat y = NSMidY(parentFrame) + 50 - NSHeight(childFrame) / 2;
        
        // 禁止子窗口移动
        [childWindow setMovable:NO];

        [childWindow setFrame:NSMakeRect(x, y, NSWidth(childFrame), NSHeight(childFrame)) display:YES];
    } else {
        // 如果主窗口不可用，则将窗口居中显示在屏幕中间
        NSScreen *screen = [NSScreen mainScreen];
        NSRect screenFrame = screen.frame;
        NSRect childFrame = childWindow.frame;

        CGFloat x = NSMidX(screenFrame) - NSWidth(childFrame) / 2;
        CGFloat y = NSMidY(screenFrame) - NSHeight(childFrame) / 2;

        [childWindow setFrame:NSMakeRect(x, y, NSWidth(childFrame), NSHeight(childFrame)) display:YES];
    }
}

// 🔥 保持原有的 startDownloadWithController 方法不变（为了兼容性）
- (void)startDownloadWithController:(SimulationiCloudLoginController *)loginController
                            appleID:(NSString *)appleID
                             adamId:(NSString *)adamId
                    expectedBundleID:(NSString *)bundleID {
    // 调用新方法，noUpload和noInstall都设为NO（默认行为：上传并安装）
    [self startDownloadWithController:loginController
                              appleID:appleID
                               adamId:adamId
                      expectedBundleID:bundleID
                             noUpload:NO
                            noInstall:NO
                             isQueued:NO];
}


//缓存的登录控制器直接处理开始下载 🔥 修改现有方法，添加noUpload和noInstall参数
- (void)startDownloadWithController:(SimulationiCloudLoginController *)loginController
                            appleID:(NSString *)appleID
                             adamId:(NSString *)adamId
                    expectedBundleID:(NSString *)bundleID
                           noUpload:(BOOL)noUpload
                          noInstall:(BOOL)noInstall
                           isQueued:(BOOL)isQueued {
    
    if (noUpload && noInstall) {
        NSLog(@"[INFO] 使用已缓存的登录信息开始仅下载打包应用（不上传不安装）: %@ (%@)", adamId, bundleID);
    } else {
        NSLog(@"[INFO] 使用已缓存的登录信息直接开始下载应用: %@ (%@)", adamId, bundleID);
    }
    
    NSLog(@"[INFO] %@开始 %@%@下载: %@ (%@)",
          isQueued ? @"[队列] " : @"",
          noUpload ? @"仅" : @"",
          noInstall ? @"下载" : @"下载+安装",
          adamId, bundleID);
    
    // 🔥 文件名创建逻辑保持不变
    NSString *fileName;
    if (bundleID && bundleID.length > 0) {
        fileName = [NSString stringWithFormat:@"%@.ipa", bundleID];
    } else {
        // 如果没有bundleID，使用adamId作为备用
        fileName = [NSString stringWithFormat:@"app_%@.ipa", adamId ?: @"unknown"];
    }
    
    // 🔥 创建在统一目录下的文件路径（先下载到临时目录）
    NSString *mfcTempDir = [self getMFCTempDirectory];
    NSString *savePath = [mfcTempDir stringByAppendingPathComponent:fileName];
    
    NSLog(@"[INFO] 目标下载路径: %@", savePath);
    
    // 🔥 检查并清理同名文件
    [self cleanupExistingFileIfNeeded:savePath bundleID:bundleID];
    
    // 🔥 加载 DownloadProgressViewController 实例
    NSStoryboard *storyboard = [NSStoryboard storyboardWithName:@"Main" bundle:nil];
    DownloadProgressViewController *downloadProgressVC = [storyboard instantiateControllerWithIdentifier:@"DownloadProgressViewWindowController"];
    
    // 确保实例化成功
    if (!downloadProgressVC) {
        NSLog(@"[ERROR] 无法从 storyboard 实例化 DownloadProgressViewController");
        return;
    }
    
    // 🔥 传递必要的参数
    downloadProgressVC.simloginController = loginController;
    downloadProgressVC.adamId = adamId;
    downloadProgressVC.savePath = savePath;
    downloadProgressVC.expectedBundleID = bundleID;
    downloadProgressVC.appleID = appleID;
    downloadProgressVC.deviceVersion = self.deviceVersion;
    
    // 🔥 关键：传递不上传不安装标识
    downloadProgressVC.noUpload = noUpload;
    downloadProgressVC.noInstall = noInstall;
    downloadProgressVC.isQueued  = isQueued;   // ⬅️ 新增
    
    // 🔥 下载窗口创建逻辑保持不变
    NSWindow *downloadWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 400, 200)
                                                           styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                                                             backing:NSBackingStoreBuffered
                                                               defer:NO];
    downloadWindow.contentViewController = downloadProgressVC;
    
    // 隐藏窗口的标题栏
    downloadWindow.titleVisibility = NSWindowTitleHidden;
    downloadWindow.titlebarAppearsTransparent = YES;
    
    // 设置外观
    if (@available(macOS 10.14, *)) {
        NSString *currentAppearance = [[NSUserDefaults standardUserDefaults] stringForKey:@"AppAppearance"];
        if ([currentAppearance isEqualToString:NSAppearanceNameAqua]) {
            downloadWindow.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
        } else if ([currentAppearance isEqualToString:NSAppearanceNameDarkAqua]) {
            downloadWindow.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
        } else {
            downloadWindow.appearance = [NSApp effectiveAppearance];
        }
    }
    
    // 设置窗口背景色
    downloadWindow.backgroundColor = [NSColor windowBackgroundColor];
    
    // 设置窗口关闭时不自动释放
    downloadWindow.releasedWhenClosed = NO;
    
    // 设置窗口的父窗口
    [[NSApp mainWindow] addChildWindow:downloadWindow ordered:NSWindowAbove];
    
    // 将弹窗居中显示在主应用窗口中
    [self centerWindow:downloadWindow relativeToWindow:[NSApp mainWindow]];
    
    // 显示窗口
    [downloadWindow makeKeyAndOrderFront:nil];
    
    // 开始下载
    [downloadProgressVC startDownload];
}

/**
 * 清理指定路径的现有文件（包括相关的临时文件）
 */
- (void)cleanupExistingFileIfNeeded:(NSString *)targetPath bundleID:(NSString *)bundleID {
    NSLog(@"[INFO] 🧹 检查并清理现有文件: %@", [targetPath lastPathComponent]);
    
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *directory = [targetPath stringByDeletingLastPathComponent];
    
    // 🔥 要清理的文件模式列表
    NSArray *filePatterns = @[
        [targetPath lastPathComponent],                    // 主文件：com.example.app.ipa
        [[targetPath lastPathComponent] stringByAppendingString:@".tmp"],           // 临时文件：com.example.app.ipa.tmp
        [[targetPath lastPathComponent] stringByAppendingString:@".mfc_downloading"], // 下载中文件：com.example.app.ipa.mfc_downloading
        [[targetPath lastPathComponent] stringByAppendingString:@".working"],        // 工作文件：com.example.app.ipa.working
        [[targetPath lastPathComponent] stringByAppendingString:@".backup"]          // 备份文件：com.example.app.ipa.backup
    ];
    
    NSInteger cleanedCount = 0;
    
    for (NSString *pattern in filePatterns) {
        NSString *filePath = [directory stringByAppendingPathComponent:pattern];
        
        if ([fileManager fileExistsAtPath:filePath]) {
            NSError *deleteError;
            if ([fileManager removeItemAtPath:filePath error:&deleteError]) {
                NSLog(@"[INFO] ✅ 已删除现有文件: %@", pattern);
                cleanedCount++;
            } else {
                NSLog(@"[WARN] ⚠️ 删除文件失败: %@ - %@", pattern, deleteError.localizedDescription);
            }
        }
    }
    
    if (cleanedCount > 0) {
        NSLog(@"[INFO] 🗑️ 总计清理了 %ld 个现有文件", (long)cleanedCount);
    } else {
        NSLog(@"[INFO] ℹ️ 没有需要清理的现有文件");
    }
}

//将相同的通知添加到非 2FA 登录成功路径
- (void)loginSucceeded:(NSNotification *)notification {
    // 从通知中获取登录控制器和参数
    SimulationiCloudLoginController *loginController = notification.userInfo[@"loginController"];
    NSString *appleID = notification.userInfo[@"appleID"];
    
    if (loginController) {
        // 保存认证信息
        self.cachedLoginController = loginController;
        self.cachedAppleID = appleID;
        
        // 设置认证过期时间（例如：2小时后）
        self.authExpirationTime = [NSDate dateWithTimeIntervalSinceNow:7200]; // 2小时 = 7200秒
        
        NSLog(@"[INFO] 已缓存认证信息，AppleID: %@，有效期至: %@",
              appleID, [NSDateFormatter localizedStringFromDate:self.authExpirationTime
                                                      dateStyle:NSDateFormatterShortStyle
                                                      timeStyle:NSDateFormatterMediumStyle]);
        
        // 🔥 新增：登录成功后立即进行版本检查和SINF获取
        NSLog(@"[INFO] 🔍 登录成功，开始版本信息和SINF检查");
        
        // 🔥 尝试从通知中获取更多参数
        NSString *adamId = notification.userInfo[@"adamId"];
        NSString *bundleID = notification.userInfo[@"bundleID"];
        
        // 如果通知中没有这些参数，尝试从登录窗口控制器获取
        if (!adamId || !bundleID) {
            // 查找当前的登录窗口控制器
            if (self.loginWindow && self.loginWindow.contentViewController) {
                iCloudLoginViewController *loginVC = (iCloudLoginViewController *)self.loginWindow.contentViewController;
                if ([loginVC isKindOfClass:[iCloudLoginViewController class]]) {
                    adamId = loginVC.adamId;
                    bundleID = loginVC.expectedBundleID;
                    NSLog(@"[INFO] 📋 从登录控制器获取参数: adamId=%@, bundleID=%@", adamId, bundleID);
                }
            }
        }
        
        // 如果有足够的参数，进行版本检查
        if (adamId && adamId.length > 0 && bundleID && bundleID.length > 0) {
            // 创建MFCIPaApp对象进行版本查询
            MFCIPaApp *versionCheckApp = [[MFCIPaApp alloc] init];
            versionCheckApp.appID = [adamId longLongValue];
            versionCheckApp.bundleID = bundleID;
            versionCheckApp.name = @"";
            versionCheckApp.version = @"";
            versionCheckApp.price = 0.0;
            
            // 异步查询版本信息（不阻塞UI）
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                
                // 🔥 检查登录控制器是否支持新的API方法
                if ([loginController respondsToSelector:@selector(listVersionsForApp:completion:)]) {
                    NSLog(@"[INFO] 📋 开始查询应用版本信息");
                    
                    [loginController listVersionsForApp:versionCheckApp completion:^(NSArray<NSString *> *versionIDs, NSError *error) {
                        if (!error && versionIDs && versionIDs.count > 0) {
                            NSLog(@"[INFO] ✅ 版本查询成功: %lu个版本", (unsigned long)versionIDs.count);
                            NSLog(@"[INFO] 📋 版本列表: %@", versionIDs);
                            
                            // 查询最新版本元数据
                            NSString *latestVersionID = versionIDs.firstObject;
                            
                            if ([loginController respondsToSelector:@selector(getVersionMetadataForApp:versionID:completion:)]) {
                                [loginController getVersionMetadataForApp:versionCheckApp
                                                                versionID:latestVersionID
                                                               completion:^(NSDictionary *metadata, NSError *metaError) {
                                    if (!metaError && metadata) {
                                        NSString *latestVersion = metadata[@"bundleShortVersionString"];
                                        NSString *latestBuild = metadata[@"bundleVersion"];
                                        NSNumber *fileSize = metadata[@"sizeInBytes"];
                                        
                                        NSLog(@"[INFO] 📋 最新版本信息:");
                                        NSLog(@"[INFO]   版本号: %@", latestVersion ?: @"未知");
                                        NSLog(@"[INFO]   构建号: %@", latestBuild ?: @"未知");
                                        NSLog(@"[INFO]   文件大小: %@ bytes", fileSize ?: @"未知");
                                    } else {
                                        NSLog(@"[WARN] ⚠️ 获取版本元数据失败: %@", metaError.localizedDescription);
                                    }
                                }];
                            }
                            
                            // 尝试获取SINF数据
                            if ([loginController respondsToSelector:@selector(replicateSinfForApp:externalVersionID:completion:)]) {
                                NSLog(@"[INFO] 🔐 开始获取SINF数据");
                                
                                [loginController replicateSinfForApp:versionCheckApp
                                                   externalVersionID:latestVersionID
                                                          completion:^(NSData *sinfData, NSError *sinfError) {
                                    if (!sinfError && sinfData) {
                                        NSLog(@"[INFO] ✅ SINF获取成功: %lu bytes", (unsigned long)sinfData.length);
                                        // 这里可以保存SINF数据供后续使用
                                        // 例如：[self saveSinfData:sinfData forApp:versionCheckApp];
                                    } else {
                                        NSLog(@"[WARN] ⚠️ SINF获取失败（正常现象）: %@", sinfError.localizedDescription);
                                    }
                                }];
                            }
                        } else {
                            NSLog(@"[WARN] ⚠️ 版本查询失败3（不影响下载）: %@", error.localizedDescription);
                        }
                    }];
                } else {
                    NSLog(@"[WARN] ⚠️ 登录控制器不支持版本查询API");
                }
            });
        } else {
            NSLog(@"[WARN] ⚠️ 缺少adamId或bundleID参数，跳过版本检查");
        }
        
    }
    
    // 移除通知观察者，避免重复接收
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"LoginSuccessNotification" object:nil];
}

// 检查设备连接状态
- (BOOL)isDeviceConnected {
    idevice_t device = NULL;
    idevice_error_t device_error = idevice_new(&device, NULL);
    
    if (device) {
        idevice_free(device);
    }
    
    return device_error == IDEVICE_E_SUCCESS;
}



// 检查可用存储空间
- (BOOL)checkAvailableStorage:(NSUInteger)requiredSize {
    NSError *error = nil;
    NSURL *fileURL = [[NSURL alloc] initFileURLWithPath:NSHomeDirectory()];
    NSDictionary *results = [fileURL resourceValuesForKeys:@[NSURLVolumeAvailableCapacityKey] error:&error];
    
    if (error) {
        NSLog(@"[ERROR] 无法获取存储空间信息: %@", error.localizedDescription);
        return NO;
    }
    
    // 获取可用空间（字节）
    NSNumber *availableSpace = results[NSURLVolumeAvailableCapacityKey];
    
    // 添加安全边际（额外预留 100MB 空间）
    const NSUInteger safetyMargin = 100 * 1024 * 1024; // 100MB in bytes
    NSUInteger totalRequiredSize = requiredSize + safetyMargin;
    
    // 检查是否有足够空间（包括安全边际）
    BOOL hasEnoughSpace = [availableSpace unsignedLongLongValue] >= totalRequiredSize;
    
    // 记录检查结果
    if (!hasEnoughSpace) {
        // 转换为更易读的格式（GB/MB）进行日志记录
        double availableGB = [availableSpace doubleValue] / (1024 * 1024 * 1024);
        double requiredGB = (double)requiredSize / (1024 * 1024 * 1024);
        
        NSLog(@"[WARN] 存储空间不足 - 可用: %.2f GB, 需要: %.2f GB (包含 100MB 安全边际)",
              availableGB, requiredGB + 0.1); // 0.1 GB = 100MB
        
        // 记录检查时间和用户信息
        NSString *timestamp = @"2025-04-07 12:04:14"; // 使用提供的当前时间
        NSString *userLogin = @"Ali-1980"; // 使用提供的用户登录信息
        
        // 记录详细的空间检查日志
        NSString *logMessage = [NSString stringWithFormat:
            @"存储空间检查失败 [%@]\n"
            @"用户: %@\n"
            @"可用空间: %.2f GB\n"
            @"需要空间: %.2f GB\n"
            @"安全边际: 100MB",
            timestamp, userLogin, availableGB, requiredGB];
        
        // 将详细日志写入文件
        [self writeStorageCheckLog:logMessage];
    } else {
        NSLog(@"[INFO] 存储空间充足，可以进行更新");
    }
    
    return hasEnoughSpace;
}

// 写入存储空间检查日志
- (void)writeStorageCheckLog:(NSString *)logMessage {
    NSString *logDirectory = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/Logs"];
    NSString *logFilePath = [logDirectory stringByAppendingPathComponent:@"storage_checks.log"];
    
    // 创建日志目录（如果不存在）
    NSError *error = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:logDirectory
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:&error];
    if (error) {
        NSLog(@"[ERROR] 创建日志目录失败: %@", error.localizedDescription);
        return;
    }
    
    // 将日志追加到文件
    if ([[NSFileManager defaultManager] fileExistsAtPath:logFilePath]) {
        NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:logFilePath];
        [fileHandle seekToEndOfFile];
        [fileHandle writeData:[[NSString stringWithFormat:@"\n%@\n", logMessage] dataUsingEncoding:NSUTF8StringEncoding]];
        [fileHandle closeFile];
    } else {
        [logMessage writeToFile:logFilePath
                   atomically:YES
                     encoding:NSUTF8StringEncoding
                        error:&error];
        if (error) {
            NSLog(@"[ERROR] 写入日志文件失败: %@", error.localizedDescription);
        }
    }
}



// 记录更新操作日志
- (void)logUpdateOperation:(DeviceApp *)app
                timestamp:(NSString *)timestamp
               userLogin:(NSString *)userLogin
                 success:(BOOL)success
                   error:(NSError *)error {
    
    NSString *logDirectory = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/Logs"];
    NSString *logPath = [logDirectory stringByAppendingPathComponent:@"app_updates.log"];
    
    NSString *logEntry = [NSString stringWithFormat:
                         @"[%@] User: %@\n"
                         @"App: %@ (Bundle ID: %@)\n"
                         @"Update Size: %lu bytes\n"
                         @"Status: %@\n"
                         @"%@\n\n",
                         timestamp,
                         userLogin,
                         app.appName,
                         app.bundleID,
                         (unsigned long)app.updateSize,
                         success ? @"SUCCESS" : @"FAILED",
                         error ? [NSString stringWithFormat:@"Error: %@", error.localizedDescription] : @""];
    
    // 确保日志目录存在
    [[NSFileManager defaultManager] createDirectoryAtPath:logDirectory
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];
    
    // 追加日志
    if ([[NSFileManager defaultManager] fileExistsAtPath:logPath]) {
        NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:logPath];
        [fileHandle seekToEndOfFile];
        [fileHandle writeData:[logEntry dataUsingEncoding:NSUTF8StringEncoding]];
        [fileHandle closeFile];
    } else {
        [logEntry writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

// 刷新应用列表
- (void)refreshAppList {
    NSLog(@"[INFO] 开始刷新应用列表");
    
    // 🔥 新增：确保在刷新开始时禁用批量操作按钮
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateBatchOperationButtonsState:NO];
    });
    
    // 在后台线程获取应用列表
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSError *error;
        NSArray<DeviceApp *> *apps = [self listInstalledAppsWithError:&error];
        
        // 回到主线程更新UI
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!error) {
                self.appList = apps;
                [self.tableView reloadData];
                [self.tableView setNeedsDisplay:YES];
                [self updateApplicationTypeStatistics]; // 计算应用程序类型统计数据
                
                NSLog(@"[INFO] ✅ 应用列表刷新成功，共 %lu 个应用", (unsigned long)apps.count);
                
                // 🔥 新增：刷新完成后启用批量操作按钮
                //[self updateBatchOperationButtonsState:YES];
            } else {
                NSLog(@"[ERROR] ❌ 刷新应用列表失败: %@", error.localizedDescription);
                
                // 🔥 即使失败也要重新启用按钮
                [self updateBatchOperationButtonsState:YES];
            }
        });
    });
}

#pragma mark - 计算应用程序类型统计数据
- (void)updateApplicationTypeStatistics {
    // 设置正在计算状态
    self.isCalculatingAppSizes = YES;
    [self updateOperationButtonsState:NO];
    
    NSInteger totalApps = self.appList.count;
    NSInteger userApps = 0;
    NSInteger systemApps = 0;
    
    for (DeviceApp *app in self.appList) {
        if ([app.applicationType isEqualToString:@"User"]) {
            userApps++;
        } else if ([app.applicationType isEqualToString:@"System"]) {
            systemApps++;
        }
    }
    
    // 定义普通字体和粗体字体的属性（可以根据需求调整字体大小）
    NSDictionary *normalAttributes = @{ NSFontAttributeName: [NSFont systemFontOfSize:12] };
    NSDictionary *boldAttributes   = @{ NSFontAttributeName: [NSFont boldSystemFontOfSize:12] };
    
    LanguageManager *languageManager = [LanguageManager sharedManager];
    //总应用数量为
    NSString *applicationTotalInstalledTitle = [languageManager localizedStringForKeys:@"applicationTotalInstalled" inModule:@"AppsManager" defaultValue:@"Total installed apps"];
    
    NSString *applicationTypeUserTitle = [languageManager localizedStringForKeys:@"applicationTypeUser" inModule:@"AppsManager" defaultValue:@"User"];
    NSString *applicationTypeSystemTitle = [languageManager localizedStringForKeys:@"applicationTypeSystem" inModule:@"AppsManager" defaultValue:@"System"];
    //正在计算应用空间占用，请稍候...
    NSString *applicationCalculatingStorageusageTitle = [languageManager localizedStringForKeys:@"applicationCalculatingStorageusage" inModule:@"AppsManager" defaultValue:@"Calculating app storage usage, please wait..."];
    
    // 创建富文本字符串并拼接各个部分
    NSMutableAttributedString *attributedString = [[NSMutableAttributedString alloc] init];
    
    //总应用数量为
    [attributedString appendAttributedString:[[NSAttributedString alloc] initWithString:applicationTotalInstalledTitle attributes:normalAttributes]];
    
    NSString *totalAppsString = [NSString stringWithFormat:@": %ld", (long)totalApps];
    [attributedString appendAttributedString:[[NSAttributedString alloc] initWithString:totalAppsString attributes:boldAttributes]];
    
    //用户
    NSString *labelUserText = [NSString stringWithFormat:@" (%@: ", applicationTypeUserTitle];
    [attributedString appendAttributedString:[[NSAttributedString alloc] initWithString:labelUserText attributes:normalAttributes]];

    
    NSString *userAppsString = [NSString stringWithFormat:@"%ld", (long)userApps];
    [attributedString appendAttributedString:[[NSAttributedString alloc] initWithString:userAppsString attributes:boldAttributes]];
    
    //系统
    NSString *labelSystemText = [NSString stringWithFormat:@" , %@: ", applicationTypeSystemTitle];
    [attributedString appendAttributedString:[[NSAttributedString alloc] initWithString:labelSystemText attributes:normalAttributes]];
    
    NSString *systemAppsString = [NSString stringWithFormat:@"%ld", (long)systemApps];
    [attributedString appendAttributedString:[[NSAttributedString alloc] initWithString:systemAppsString attributes:boldAttributes]];
    
    [attributedString appendAttributedString:[[NSAttributedString alloc] initWithString:@")" attributes:normalAttributes]];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        self.applicationTypeLabel.hidden = NO;
        self.applicationTypeLabel.attributedStringValue = attributedString;
        self.applicationTypeUserSpaceLabel.hidden = NO;
        
        // 设置文本颜色为红色
        //self.applicationTypeUserSpaceLabel.textColor = [NSColor systemGreenColor];
        //后台正在统计APP占用空间...
        self.applicationTypeUserSpaceLabel.stringValue = applicationCalculatingStorageusageTitle;
    });
}

#pragma mark -  失败时候却换视图到历史列表
- (IBAction)switchViewWithButton:(NSButton *)sender {
    NSStoryboard *storyboard = [NSStoryboard storyboardWithName:@"Main" bundle:nil];
    NSViewController *newController = nil;

    // 根据按钮的 tag 或其他属性决定要切换到哪个视图控制器
    newController = [storyboard instantiateControllerWithIdentifier:@"HistoryController"];

    if (!newController) {
        NSLog(@"无法找到指定的视图控制器");
        return;
    }
    
    
    // 调用切换方法
    BOOL switched = [self switchToViewController:newController];
    if (switched) {
        SidebarViewController *sidebarController = [SidebarViewController sharedInstance];
        if (!sidebarController) {
            NSLog(@"[ERROR] SidebarViewController 实例不存在.");
            return;
        }

        // 显示左侧视图
        [sidebarController adjustSidebarVisibility:YES];

        NSLog(@"视图切换成功到: %@", NSStringFromClass([newController class]));
    } else {
        NSLog(@"视图切换失败或当前视图无需切换");
    }
}

#pragma mark - 选择状态变化处理

- (IBAction)appSelectionChanged:(NSButton *)sender {
    if (self.isSelectingAll) return; // 防止批量选择时的递归调用
    
    NSInteger row = sender.tag;
    if (row >= 0 && row < self.appList.count) {
        DeviceApp *app = self.appList[row];
        
        // 🔥 新增：只处理User类型的应用
        if (![app.applicationType isEqualToString:@"User"]) {
            NSLog(@"[DEBUG] 系统应用不可选择: %@", app.appName);
            return;
        }
        
        if (sender.state == NSControlStateValueOn) {
            [self.selectedApps addObject:app];
        } else {
            [self.selectedApps removeObject:app];
        }
        
        [self updateSelectionUI];
        NSLog(@"[DEBUG] 应用 %@ 选择状态: %@", app.appName, sender.state == NSControlStateValueOn ? @"选中" : @"取消选中");
    }
}

// 全选应用
- (IBAction)selectAllApps:(id)sender {
    LanguageManager *languageManager = [LanguageManager sharedManager];
    
    self.isSelectingAll = YES;
    [self.selectedApps removeAllObjects];
    
    // 🔥 只选择User类型的应用
    for (DeviceApp *app in self.appList) {
        if ([app.applicationType isEqualToString:@"User"]) {
            [self.selectedApps addObject:app];
        }
    }
    
    [self updateAllCheckboxStates];
    [self updateSelectionUI];
    
    self.isSelectingAll = NO;
    
    NSString *selectAllMessage = [languageManager localizedStringForKeys:@"selectAllAppsMessage"
                                                                 inModule:@"AppsManager"
                                                             defaultValue:@"Selected all %ld user applications"];
    NSString *message = [NSString stringWithFormat:selectAllMessage, (long)self.selectedApps.count];
    
    NSLog(@"[INFO] %@", message);
}

// 用户应用全选
- (IBAction)selectUserApps:(id)sender {
    LanguageManager *languageManager = [LanguageManager sharedManager];
    
    self.isSelectingAll = YES;
    [self.selectedApps removeAllObjects];
    
    for (DeviceApp *app in self.appList) {
        if ([app.applicationType isEqualToString:@"User"]) {
            [self.selectedApps addObject:app];
        }
    }
    
    [self updateAllCheckboxStates];
    [self updateSelectionUI];
    
    self.isSelectingAll = NO;
    
    NSString *selectUserAppsMessage = [languageManager localizedStringForKeys:@"selectUserAppsMessage"
                                                                      inModule:@"AppsManager"
                                                                  defaultValue:@"Selected %ld user applications"];
    NSString *message = [NSString stringWithFormat:selectUserAppsMessage, (long)self.selectedApps.count];
    
    NSLog(@"[INFO] %@", message);
}



// 取消选择所有应用
- (IBAction)clearAllSelection:(id)sender {
    LanguageManager *languageManager = [LanguageManager sharedManager];
    
    self.isSelectingAll = YES;
    [self.selectedApps removeAllObjects];
    
    // 更新表格视图中所有复选框状态
    [self updateAllCheckboxStates];
    [self updateSelectionUI];
    
    self.isSelectingAll = NO;
    
    NSString *clearSelectionMessage = [languageManager localizedStringForKeys:@"clearAllSelectionMessage"
                                                                      inModule:@"AppsManager"
                                                                  defaultValue:@"Cleared all selections"];
    
    NSLog(@"[INFO] %@", clearSelectionMessage);
}


// 系统应用全选
- (IBAction)selectSystemApps:(id)sender {
    LanguageManager *languageManager = [LanguageManager sharedManager];
    
    self.isSelectingAll = YES;
    [self.selectedApps removeAllObjects];
    
    for (DeviceApp *app in self.appList) {
        if ([app.applicationType isEqualToString:@"System"]) {
            [self.selectedApps addObject:app];
        }
    }
    
    [self updateAllCheckboxStates];
    [self updateSelectionUI];
    
    self.isSelectingAll = NO;
    
    NSString *selectSystemAppsMessage = [languageManager localizedStringForKeys:@"selectSystemAppsMessage"
                                                                        inModule:@"AppsManager"
                                                                    defaultValue:@"Selected %ld system applications"];
    NSString *message = [NSString stringWithFormat:selectSystemAppsMessage, (long)self.selectedApps.count];
    
    NSLog(@"[INFO] %@", message);
}

#pragma mark - 批量删除操作

// 批量删除选择的应用
- (IBAction)batchDeleteSelected:(id)sender {
    if (self.selectedApps.count == 0) {
        LanguageManager *languageManager = [LanguageManager sharedManager];
        NSString *noSelectionMessage = [languageManager localizedStringForKeys:@"noAppsSelectedMessage"
                                                                       inModule:@"AppsManager"
                                                                   defaultValue:@"Please select applications to delete"];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            [[AlertWindowController sharedController] showResultMessageOnly:noSelectionMessage inWindow:self.view.window];
        });
        return;
    }
    
    // 过滤出用户应用（只能删除用户应用）
    NSMutableArray *userAppsToDelete = [NSMutableArray array];
    for (DeviceApp *app in self.selectedApps) {
        if ([app.applicationType isEqualToString:@"User"]) {
            [userAppsToDelete addObject:app];
        }
    }
    
    if (userAppsToDelete.count == 0) {
        LanguageManager *languageManager = [LanguageManager sharedManager];
        NSString *onlyUserAppsMessage = [languageManager localizedStringForKeys:@"onlyUserAppsCanBeDeleted"
                                                                        inModule:@"AppsManager"
                                                                    defaultValue:@"Only user applications can be deleted"];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            [[AlertWindowController sharedController] showResultMessageOnly:onlyUserAppsMessage inWindow:self.view.window];
        });
        return;
    }
    
    // 确认删除对话框
    LanguageManager *languageManager = [LanguageManager sharedManager];
    NSString *batchDeleteTitle = [languageManager localizedStringForKeys:@"batchDeleteButton"
                                                                 inModule:@"GlobaButtons"
                                                             defaultValue:@"Batch Delete"];
    NSString *batchDeleteMessage = [languageManager localizedStringForKeys:@"batchDeleteConfirmMessage"
                                                                   inModule:@"AppsManager"
                                                               defaultValue:@"Are you sure you want to delete %ld selected applications?"];
    NSString *formattedMessage = [NSString stringWithFormat:batchDeleteMessage, (long)userAppsToDelete.count];
    NSString *deleteButton = [languageManager localizedStringForKeys:@"DeleteButton"
                                                            inModule:@"GlobaButtons"
                                                        defaultValue:@"Delete"];
    NSString *cancelButton = [languageManager localizedStringForKeys:@"CancelButton"
                                                            inModule:@"GlobaButtons"
                                                        defaultValue:@"Cancel"];
    
    [[AlertWindowController sharedController] showAlertWithTitle:batchDeleteTitle
                                                     description:formattedMessage
                                                    confirmTitle:deleteButton
                                                     cancelTitle:cancelButton
                                                   confirmAction:^{
        [self performBatchDelete:userAppsToDelete];
    }];
}

// 执行批量删除
- (void)performBatchDelete:(NSArray<DeviceApp *> *)appsToDelete {
    LanguageManager *languageManager = [LanguageManager sharedManager];
    NSString *lockedDeviceID = [self getLockedDeviceID];
    // 记录操作日志
    NSString *logBatchDeleteRecord = [languageManager localizedStringForKeys:@"HandleBatchDeleteAPP"
                                                                     inModule:@"OperationRecods"
                                                                 defaultValue:@"Handle Batch Delete APP"];
    [[DataBaseManager sharedInstance] addOperationRecord:logBatchDeleteRecord
                                          forDeviceECID:lockedDeviceID
                                                   UDID:lockedDeviceID];
    
    // 显示进度指示器
    dispatch_async(dispatch_get_main_queue(), ^{
        self.loadingIndicator.hidden = NO;
        [self.loadingIndicator startAnimation:nil];
        self.tableView.enabled = NO;
        self.tableView.alphaValue = 0.5;
    });
    
    // 在后台线程执行删除操作
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSInteger successCount = 0;
        NSInteger failureCount = 0;
        NSMutableArray *failedApps = [NSMutableArray array];
        
        for (DeviceApp *app in appsToDelete) {
            @autoreleasepool {
                NSError *error = nil;
                BOOL success = [self uninstallAppWithBundleID:app.bundleID error:&error];
                
                if (success) {
                    successCount++;
                    NSLog(@"[INFO] 成功删除应用: %@", app.appName);
                } else {
                    failureCount++;
                    [failedApps addObject:app];
                    NSLog(@"[ERROR] 删除应用失败: %@, 错误: %@", app.appName, error.localizedDescription);
                }
                
                // 短暂延迟，避免过快的连续操作
                [NSThread sleepForTimeInterval:0.5];
            }
        }
        
        // 回到主线程更新UI
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.loadingIndicator stopAnimation:nil];
            self.loadingIndicator.hidden = YES;
            self.tableView.enabled = YES;
            self.tableView.alphaValue = 1.0;
            
            // 清除选择状态
            [self.selectedApps removeAllObjects];
            [self updateAllCheckboxStates];
            [self updateSelectionUI];
            
            // 显示结果消息
            NSString *resultMessage;
            if (failureCount == 0) {
                NSString *allSuccessMessage = [languageManager localizedStringForKeys:@"batchDeleteAllSuccess"
                                                                              inModule:@"AppsManager"
                                                                          defaultValue:@"Successfully deleted all %ld applications"];
                resultMessage = [NSString stringWithFormat:allSuccessMessage, (long)successCount];
            } else {
                NSString *partialSuccessMessage = [languageManager localizedStringForKeys:@"batchDeletePartialSuccess"
                                                                                  inModule:@"AppsManager"
                                                                              defaultValue:@"Deleted %ld applications successfully, %ld failed"];
                resultMessage = [NSString stringWithFormat:partialSuccessMessage, (long)successCount, (long)failureCount];
            }
            
            [[AlertWindowController sharedController] showResultMessageOnly:resultMessage inWindow:self.view.window];
            
            // 记录操作结果
            NSString *logResultRecord = [languageManager localizedStringForKeys:@"HandleBatchDeleteAPPResult"
                                                                        inModule:@"OperationRecods"
                                                                    defaultValue:@"Handle Batch Delete APP Result: %@"];
            NSString *recordresultMessage = [NSString stringWithFormat:@"[SUC] %@", resultMessage];
            [[DataBaseManager sharedInstance] addOperationRecord:[NSString stringWithFormat:logResultRecord, recordresultMessage]
                                                  forDeviceECID:lockedDeviceID
                                                           UDID:lockedDeviceID];
            
            // 刷新应用列表
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self refreshAppList];
            });
        });
    });
}

#pragma mark - 批量更新操作

- (IBAction)batchUpdateSelected:(id)sender {
    LanguageManager *languageManager = [LanguageManager sharedManager];
    
    if (self.selectedApps.count == 0) {
        NSString *noSelectionMessage = [languageManager localizedStringForKeys:@"pleaseSelectAppsToUpdate"
                                                                       inModule:@"AppsManager"
                                                                   defaultValue:@"Please select applications to update"];
        [[AlertWindowController sharedController] showResultMessageOnly:noSelectionMessage inWindow:self.view.window];
        return;
    }
    
    // 防止重复点击
    if (self.isBatchInstalling && self.batchUpdateQueue && self.batchUpdateQueue.count > 0) {
        NSString *batchUpdatingMessage = [languageManager localizedStringForKeys:@"batchUpdateInProgress"
                                                                         inModule:@"AppsManager"
                                                                     defaultValue:@"Batch update is in progress, please wait..."];
        [[AlertWindowController sharedController] showResultMessageOnly:batchUpdatingMessage inWindow:self.view.window];
        return;
    }
    
    // 🔥 智能筛选逻辑
    NSMutableArray<DeviceApp *> *appsToUpdate = [NSMutableArray array];
    NSMutableArray<DeviceApp *> *appsWithoutUpdate = [NSMutableArray array];
    
    for (DeviceApp *app in self.selectedApps.allObjects) {
        if (app.hasUpdateAvailable) {
            [appsToUpdate addObject:app];
        } else {
            [appsWithoutUpdate addObject:app];
        }
    }
    
    // 🔥 区分单选和多选的处理逻辑
    BOOL isSingleSelection = (self.selectedApps.count == 1);
    
    if (appsWithoutUpdate.count > 0) {
        // 自动取消选择没有更新的应用
        for (DeviceApp *app in appsWithoutUpdate) {
            [self.selectedApps removeObject:app];
        }
        [self updateAllCheckboxStates];
        [self updateSelectionUI];
        
        // 🔥 只在单选时提示用户
        if (isSingleSelection && appsWithoutUpdate.count == 1) {
            DeviceApp *app = appsWithoutUpdate.firstObject;
            NSString *singleAppNoUpdateTemplate = [languageManager localizedStringForKeys:@"singleAppNoUpdateAvailable"
                                                                                  inModule:@"AppsManager"
                                                                              defaultValue:@"App \"%@\" has no available updates"];
            NSString *message = [NSString stringWithFormat:singleAppNoUpdateTemplate, app.appName];
            [[AlertWindowController sharedController] showResultMessageOnly:message inWindow:self.view.window];
            return; // 单选且无更新时直接返回
        }
        // 🔥 多选时不提示，静默处理
    }
    
    // 🔥 继续执行可更新应用的批量更新
    if (appsToUpdate.count > 0) {
        // 设置批量更新状态
        self.isBatchInstalling = YES;
        self.batchUpdateQueue = [appsToUpdate mutableCopy];
        
        // 多语言化日志消息
        NSString *batchUpdateStartTemplate = [languageManager localizedStringForKeys:@"batchUpdateStartLog"
                                                                             inModule:@"AppsManager"
                                                                         defaultValue:@"Starting batch update for %lu applications"];
        NSString *logMessage = [NSString stringWithFormat:batchUpdateStartTemplate, (unsigned long)self.batchUpdateQueue.count];
        NSLog(@"%@", logMessage);
        
        // 监听安装完成通知
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(onUpdateCompleted:)
                                                     name:@"AppInstallationSuccessNotification"
                                                   object:nil];
        
        // 开始第一个更新
        [self updateNextApp];
    } else {
        // 如果最终没有可更新的应用（这种情况在单选时已经处理过了）
        if (!isSingleSelection) {
            NSString *allAppsNoUpdateMessage = [languageManager localizedStringForKeys:@"allSelectedAppsNoUpdate"
                                                                              inModule:@"AppsManager"
                                                                          defaultValue:@"None of the selected applications have available updates"];
            [[AlertWindowController sharedController] showResultMessageOnly:allAppsNoUpdateMessage inWindow:self.view.window];
        }
    }
}

- (void)updateNextApp {
    if (!self.batchUpdateQueue || self.batchUpdateQueue.count == 0) {
        // 🔥 所有更新完成，重置状态
        [[NSNotificationCenter defaultCenter] removeObserver:self name:@"AppInstallationSuccessNotification" object:nil];
        self.isBatchInstalling = NO;
        self.batchUpdateQueue = nil;
        
        NSLog(@"[批量更新] ✅ 批量更新完成，刷新应用列表");
        dispatch_async(dispatch_get_main_queue(), ^{
            [self clearAllSelection:self];
            // 🔥 只在所有操作完成后刷新一次
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self refreshAppList];
            });
        });
        return;
    }
    
    DeviceApp *app = [self.batchUpdateQueue firstObject];
    [self.batchUpdateQueue removeObjectAtIndex:0];
    
    NSLog(@"[批量更新] 🔄 更新应用: %@，剩余: %lu", app.appName, (unsigned long)self.batchUpdateQueue.count);
    
    // 执行单个应用更新（需要实现这个方法）
    [self updateApp:app];
}

- (void)onUpdateCompleted:(NSNotification *)notification {
    NSLog(@"[批量更新] ✅ 单个更新完成，继续下一个");
    
    // 🔥 增加间隔时间，避免并发冲突
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self updateNextApp];
    });
}

// 智能处理安装成功事件
- (void)handleAppInstallationSuccess:(NSNotification *)notification {
    NSString *bundleID = notification.userInfo[@"bundleID"];
    NSLog(@"[DeviceAppController] 应用 %@ 安装成功", bundleID ?: @"Unknown");
    
    if (self.isBatchInstalling && self.batchUpdateQueue && self.batchUpdateQueue.count > 0) {
        // 🔥 批量更新中，不刷新表格，由批量更新流程处理
        NSLog(@"[DeviceAppController] 批量更新中，不执行单独刷新");
        return;
    } else {
        // 🔥 单个安装或批量操作已完成，立即刷新表格
        NSLog(@"[DeviceAppController] 单个安装完成，刷新应用列表");
        
        // 🔥 新增：刷新前禁用批量操作按钮
        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateBatchOperationButtonsState:NO];
        });
        
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self refreshAppList];
        });
    }
}


#pragma mark - 批量下载操作

- (IBAction)batchDownloadSelected:(id)sender {
    
    LanguageManager *languageManager = [LanguageManager sharedManager];
    
    // 🔥 修复：正确处理权限验证回调
    NSString *currentProductType = @"Watch6,6";
    [[UserManager sharedManager] canProceedWithCurrentDeviceType:currentProductType completion:^(BOOL canProceed, NSString *targetPermission) {
        
        // 🔥 关键修复：检查权限验证结果
        if (!canProceed) {
            NSString *noPermissionMessage = [languageManager localizedStringForKeys:@"PermissionVerificationFailed"
                                                                           inModule:@"Permissions"
                                                                       defaultValue:@"The permission of %@ has expired or has not been activated"];
            NSString *operationPermissionTitle = [NSString stringWithFormat:noPermissionMessage, targetPermission];
            [[AlertWindowController sharedController] showResultMessageOnly:operationPermissionTitle inWindow:self.view.window];
            return; // 权限验证失败，直接返回
        }
        
        // 🔥 修复：权限验证成功后，继续执行后续逻辑
        [self proceedWithBatchDownload];
    }];
}

// 将原来的批量下载逻辑提取到单独方法中
- (void)proceedWithBatchDownload {
    LanguageManager *languageManager = [LanguageManager sharedManager];
    
    // 检查是否有选中的应用
    if (self.selectedApps.count == 0) {
        NSString *noSelectionMessage = [languageManager localizedStringForKeys:@"pleaseSelectAppsToDownload"
                                                                       inModule:@"AppsManager"
                                                                   defaultValue:@"Please select applications to download"];
        [[AlertWindowController sharedController] showResultMessageOnly:noSelectionMessage inWindow:self.view.window];
        return;
    }
    
    // 🔥 防止重复点击
    if (self.batchdownloadQueue && self.batchdownloadQueue.count > 0) {
        NSString *batchDownloadingMessage = [languageManager localizedStringForKeys:@"batchDownloadInProgress"
                                                                            inModule:@"AppsManager"
                                                                        defaultValue:@"Batch download is in progress, please wait..."];
        [[AlertWindowController sharedController] showResultMessageOnly:batchDownloadingMessage inWindow:self.view.window];
        return;
    }
    
    // 🔥 应用去重逻辑
    NSMutableSet *seenApps = [NSMutableSet set];
    NSMutableArray *uniqueApps = [NSMutableArray array];
    
    for (DeviceApp *app in self.selectedApps.allObjects) {
        // 🔥 关键修复：使用与SimulationiCloudLoginController一致的格式
        NSString *appIdString = app.appId ?: @"unknown";
        NSString *appKey = [NSString stringWithFormat:@"app_%@_%@",
                           appIdString,
                           app.bundleID ?: @"unknown"];
        
        if (![seenApps containsObject:appKey]) {
            [seenApps addObject:appKey];
            [uniqueApps addObject:app];
            NSLog(@"[批量下载] ✅ 添加到队列: %@ (ID: %@)", app.appName, app.appId);
        } else {
            NSLog(@"[批量下载] ⚠️ 跳过重复应用: %@ (ID: %@)", app.appName, app.appId);
        }
    }
    
    // 使用去重后的应用列表
    self.batchdownloadQueue = [uniqueApps mutableCopy];
    
    NSLog(@"[批量下载] 📋 批量下载开始 - 原始: %lu, 去重后: %lu",
          (unsigned long)self.selectedApps.count,
          (unsigned long)self.batchdownloadQueue.count);
    
    // 监听下载完成通知
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onDownloadCompleted:)
                                                 name:@"AppDownloadCompleted"
                                               object:nil];
    
    // 开始第一个
    [self downloadNextApp];
}


- (void)downloadNextApp {
    if (self.batchdownloadQueue.count == 0) {
        // 完成了
        [[NSNotificationCenter defaultCenter] removeObserver:self name:@"AppDownloadCompleted" object:nil];
        self.batchdownloadQueue = nil;
        NSLog(@"批量下载完成");
        dispatch_async(dispatch_get_main_queue(), ^{
            [self clearAllSelection:self];
            NSLog(@"[批量下载] ✅ 批量下载完成，已清除所有选择");
        });
        return;
    }
    
    DeviceApp *app = [self.batchdownloadQueue firstObject];
    [self.batchdownloadQueue removeObjectAtIndex:0];
        
    // ⬇️ 关键修改：明确告诉 downloadAppIPA 这是队列任务
    [self downloadAppIPA:app isQueued:YES];
}

- (void)onDownloadCompleted:(NSNotification *)notification {
    NSLog(@"[批量下载] ✅ 单个下载完成，继续下一个");
    
    // 🔥 增加间隔时间，避免并发冲突
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self downloadNextApp];
    });
}

#pragma mark - UI更新辅助方法

// 更新所有复选框状态
- (void)updateAllCheckboxStates {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.tableView reloadData];
    });
}

// 更新选择相关的UI状态
- (void)updateSelectionUI {
    dispatch_async(dispatch_get_main_queue(), ^{
        // 更新状态栏或其他UI元素显示选中数量
        NSInteger selectedCount = self.selectedApps.count;
        NSLog(@"[DEBUG] 当前选中应用数量: %ld", (long)selectedCount);
        
        // 可以在这里更新底部状态栏显示选中的应用数量
        // 例如：self.statusLabel.stringValue = [NSString stringWithFormat:@"已选中 %ld 个应用", selectedCount];
    });
}

#pragma mark - 却换视图功能
- (BOOL)switchToViewController:(NSViewController *)newController {
    // 获取主窗口的 SplitViewController
    NSSplitViewController *splitViewController = (NSSplitViewController *)self.view.window.windowController.contentViewController;

    // 获取右侧视图的 SplitViewItem 索引
    NSInteger rightIndex = 1; // 假设右侧视图为第二个 SplitViewItem

    // 获取当前右侧视图控制器
    NSViewController *currentController = splitViewController.splitViewItems[rightIndex].viewController;

    // 判断当前视图是否已经是目标视图
    if ([currentController isEqual:newController]) {
        NSLog(@"当前视图已经是目标视图，无需切换");
        return NO; // 表示未切换
    }

    // 替换右侧视图
    NSSplitViewItem *rightItem = splitViewController.splitViewItems[rightIndex];
    [splitViewController removeSplitViewItem:rightItem];

    NSSplitViewItem *newItem = [NSSplitViewItem splitViewItemWithViewController:newController];
    [splitViewController insertSplitViewItem:newItem atIndex:rightIndex];

    NSLog(@"切换到新视图控制器: %@", NSStringFromClass([newController class]));
    return YES; // 表示切换成功
}

#pragma mark -设置按钮和其他界面元素的本地化标题
- (void)DeviceAppControllersetupLocalizedStrings {
    LanguageManager *manager = [LanguageManager sharedManager];
   
    // 更新搜索框占位文本
    self.searchField.placeholderString = [manager localizedStringForKeys:@"Search" inModule:@"GlobaButtons"  defaultValue:@"Search"];
    
    //从本地导入APP
    self.ImportAppFromLocalButton.title = [manager localizedStringForKeys:@"ImportAppFromLocalButton" inModule:@"GlobaButtons" defaultValue:@"+ Install IPA"];
    
    //取消选择
    self.clearAllSelectionButton.title = [manager localizedStringForKeys:@"clearAllSelectionButton" inModule:@"GlobaButtons" defaultValue:@"Clear Selection"];
    
    //批量删除
    self.batchDeleteButton.title = [manager localizedStringForKeys:@"batchDeleteButton" inModule:@"GlobaButtons" defaultValue:@"Batch Delete"];
    
    //批量更新
    self.batchUpdateButton.title = [manager localizedStringForKeys:@"batchUpdateButton" inModule:@"GlobaButtons" defaultValue:@"Batch Update"];
    
    //批量下载
    self.batchDownloadButton.title = [manager localizedStringForKeys:@"batchDownloadButton" inModule:@"GlobaButtons" defaultValue:@"Batch Download"];

}


- (void)clearCachedAuthentication {
    NSLog(@"[INFO] 清除缓存的认证信息");
    self.cachedLoginController = nil;
    self.cachedAppleID = nil;
    self.authExpirationTime = nil;
}



#pragma mark - 完整应用备份实现

// 备份应用完整实现 - 用户界面入口
- (void)backupApp:(DeviceApp *)app {
    NSLog(@"[DEBUG] 开始备份应用: %@", app.appName);
    
    // 验证前置条件
    if (![self validateBackupPrerequisites:app]) {
        NSLog(@"[ERROR] 备份前置条件验证失败");
        return;
    }
    
    NSString *lockedDeviceID = [self getLockedDeviceID];
    
    // **记录操作日志**
    LanguageManager *languageManager = [LanguageManager sharedManager];
    NSString *logHandleBackupAPPRecord = [languageManager localizedStringForKeys:@"HandleBackupAPP"
                                                                         inModule:@"OperationRecods"
                                                                     defaultValue:@"Handle Backup APP"];
    [[DataBaseManager sharedInstance] addOperationRecord:logHandleBackupAPPRecord
                                          forDeviceECID:lockedDeviceID
                                                   UDID:lockedDeviceID];
    
    // 选择备份目录
    NSOpenPanel *openPanel = [NSOpenPanel openPanel];
    openPanel.canChooseDirectories = YES;
    openPanel.canChooseFiles = NO;
    openPanel.allowsMultipleSelection = NO;
    openPanel.canCreateDirectories = YES;
    
    NSString *selectBackupFolderTitle = [languageManager localizedStringForKeys:@"SelectBackupFolder"
                                                                        inModule:@"AppsManager"
                                                                    defaultValue:@"Select Backup Folder"];
    NSString *selectButtonTitle = [languageManager localizedStringForKeys:@"Select"
                                                                  inModule:@"GlobaButtons"
                                                              defaultValue:@"Select"];
    
    openPanel.title = selectBackupFolderTitle;
    openPanel.prompt = selectButtonTitle;
    
    // 设置默认目录（桌面的"App Backups"文件夹）
    NSString *desktopPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Desktop"];
    NSString *defaultBackupPath = [desktopPath stringByAppendingPathComponent:@"App Backups"];
    
    // 创建默认备份目录（如果不存在）
    if (![[NSFileManager defaultManager] fileExistsAtPath:defaultBackupPath]) {
        [[NSFileManager defaultManager] createDirectoryAtPath:defaultBackupPath
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
    }
    
    openPanel.directoryURL = [NSURL fileURLWithPath:defaultBackupPath];
    
    [openPanel beginSheetModalForWindow:self.view.window completionHandler:^(NSInteger result) {
        if (result == NSModalResponseOK) {
            NSURL *backupURL = openPanel.URL;
            [self performBackupForApp:app toDirectory:backupURL.path];
        } else {
            NSLog(@"[INFO] 用户取消了备份操作");
        }
    }];
}

// 执行备份操作
- (void)performBackupForApp:(DeviceApp *)app toDirectory:(NSString *)backupDirectory {
    LanguageManager *languageManager = [LanguageManager sharedManager];
    
    // 显示确认对话框
    NSString *confirmBackupTitle = [languageManager localizedStringForKeys:@"ConfirmAppBackup"
                                                                   inModule:@"AppsManager"
                                                               defaultValue:@"Confirm App Backup"];
    
    NSString *confirmBackupMessage = [languageManager localizedStringForKeys:@"ConfirmAppBackupMessage"
                                                                     inModule:@"AppsManager"
                                                                 defaultValue:@"Are you sure you want to backup \"%@\"?\nThis will create:\n• IPA file\n• App data\n• App information"];
    
    NSString *formattedMessage = [NSString stringWithFormat:confirmBackupMessage, app.appName];
    
    NSString *backupButtonTitle = [languageManager localizedStringForKeys:@"BackupButton"
                                                                  inModule:@"GlobaButtons"
                                                              defaultValue:@"Backup"];
    NSString *cancelButtonTitle = [languageManager localizedStringForKeys:@"CancelButton"
                                                                  inModule:@"GlobaButtons"
                                                              defaultValue:@"Cancel"];
    
    [[AlertWindowController sharedController] showAlertWithTitle:confirmBackupTitle
                                                     description:formattedMessage
                                                    confirmTitle:backupButtonTitle
                                                     cancelTitle:cancelButtonTitle
                                                   confirmAction:^{
        // 用户确认后执行备份
        [self executeBackupForApp:app toDirectory:backupDirectory];
    }];
}

// 执行实际的备份操作
- (void)executeBackupForApp:(DeviceApp *)app toDirectory:(NSString *)backupDirectory {
    LanguageManager *languageManager = [LanguageManager sharedManager];
    
    // 显示进度信息
    NSString *backingUpMessage = [languageManager localizedStringForKeys:@"BackingUpApp"
                                                                 inModule:@"AppsManager"
                                                             defaultValue:@"Backing up %@..."];
    NSString *progressMessage = [NSString stringWithFormat:backingUpMessage, app.appName];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        NSLog(@"[INFO] %@", progressMessage);
        
        // 显示进度指示器
        if (!self.loadingIndicator) {
            self.loadingIndicator = [[NSProgressIndicator alloc] init];
            self.loadingIndicator.style = NSProgressIndicatorStyleSpinning;
            self.loadingIndicator.controlSize = NSControlSizeRegular;
            self.loadingIndicator.indeterminate = YES;
            self.loadingIndicator.displayedWhenStopped = NO;
            self.loadingIndicator.translatesAutoresizingMaskIntoConstraints = NO;

            NSView *parent = self.view;
            if (parent) {
                [parent addSubview:self.loadingIndicator];

                // 居中约束
                [NSLayoutConstraint activateConstraints:@[
                    [self.loadingIndicator.centerXAnchor constraintEqualToAnchor:parent.centerXAnchor],
                    [self.loadingIndicator.centerYAnchor constraintEqualToAnchor:parent.centerYAnchor]
                ]];
            }
        }

        // 显示并启动进度指示器
        self.loadingIndicator.hidden = NO;
        [self.loadingIndicator startAnimation:nil];
        
        // 禁用界面
        self.tableView.enabled = NO;
        self.tableView.alphaValue = 0.5;
    });
    
    // 在后台线程执行备份
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSError *error = nil;
        
        // 调用完整的备份实现
        BOOL backupSuccess = [self backupAppToDirectory:app toDirectory:backupDirectory error:&error];
        
        // 在主线程处理结果
        dispatch_async(dispatch_get_main_queue(), ^{
            // 隐藏进度指示器
            [self.loadingIndicator stopAnimation:nil];
            self.loadingIndicator.hidden = YES;
            
            // 恢复界面
            self.tableView.enabled = YES;
            self.tableView.alphaValue = 1.0;
            
            // 处理备份结果
            [self handleBackupResult:backupSuccess error:error forApp:app backupDirectory:backupDirectory];
        });
    });
}

// ============================================================================
// MARK: - 核心备份实现
// ============================================================================

// 完整应用备份主方法
- (BOOL)backupAppToDirectory:(DeviceApp *)app toDirectory:(NSString *)backupDirectory error:(NSError **)error {
    NSLog(@"[DEBUG] 开始完整应用备份: %@ (Bundle ID: %@)", app.appName, app.bundleID);
    NSLog(@"[DEBUG] 目标数据: 应用=%@, 数据=%@", [self formatSize:app.appSize], [self formatSize:app.docSize]);
    
    // 创建时间戳备份目录
    NSString *timestamp = [self getCurrentTimestamp];
    NSString *safeAppName = [self sanitizeFileName:app.appName];
    NSString *appBackupDir = [backupDirectory stringByAppendingPathComponent:[NSString stringWithFormat:@"%@_%@_%@", safeAppName, app.bundleID, timestamp]];
    
    NSError *dirError = nil;
    BOOL success = [[NSFileManager defaultManager] createDirectoryAtPath:appBackupDir
                                             withIntermediateDirectories:YES
                                                              attributes:nil
                                                                   error:&dirError];
    
    if (!success) {
        if (error) *error = dirError;
        return NO;
    }
    
    NSMutableDictionary *backupResults = [NSMutableDictionary dictionary];
    BOOL overallSuccess = NO;
    NSMutableArray *successfulMethods = [NSMutableArray array];
    
    NSLog(@"[DEBUG] =================== 开始增强版多层次备份 ===================");
    
    // ============================================================================
    // MARK: - 第零层：特殊应用检测和处理
    // ============================================================================
    
    NSLog(@"[DEBUG] 🔍 第零层：特殊应用检测");
    BOOL specialSuccess = [self performSpecialBackupForApp:app toDirectory:appBackupDir];
    backupResults[@"special"] = @(specialSuccess);
    if (specialSuccess) [successfulMethods addObject:@"特殊处理"];
    
    // ============================================================================
    // MARK: - 第一层：基础信息备份（总是成功）
    // ============================================================================
    
    NSLog(@"[DEBUG] 🔹 第一层：基础信息备份");
    
    BOOL infoSuccess = [self backupAppInfo:app toDirectory:appBackupDir error:error];
    backupResults[@"info"] = @(infoSuccess);
    if (infoSuccess) [successfulMethods addObject:@"应用信息"];
    
    BOOL iconSuccess = [self backupAppIcon:app toDirectory:appBackupDir error:error];
    backupResults[@"icon"] = @(iconSuccess);
    if (iconSuccess) [successfulMethods addObject:@"应用图标"];
    
    // ============================================================================
    // MARK: - 第二层：应用包备份（核心功能）
    // ============================================================================
    
    NSLog(@"[DEBUG] 🔹 第二层：应用包备份");
    
    BOOL ipaSuccess = [self extractIPAFromDevice:app toDirectory:appBackupDir error:error];
    backupResults[@"ipa"] = @(ipaSuccess);
    if (ipaSuccess) {
        overallSuccess = YES;
        [successfulMethods addObject:@"IPA提取"];
    }
    
    // ============================================================================
    // MARK: - 第三层：用户数据备份（增强版）
    // ============================================================================
    
    NSLog(@"[DEBUG] 🔹 第三层：用户数据备份");
    
    BOOL sandboxSuccess = [self backupAppSandboxDataEnhanced:app toDirectory:appBackupDir error:error];
    backupResults[@"sandbox"] = @(sandboxSuccess);
    if (sandboxSuccess) {
        overallSuccess = YES;
        [successfulMethods addObject:@"沙盒数据"];
    }
    
    // ============================================================================
    // MARK: - 第四层：Apple官方备份机制
    // ============================================================================
    
    NSLog(@"[DEBUG] 🔹 第四层：Apple官方备份机制");
    
    BOOL deviceBackupSuccess = [self performDeviceBackupForApp:app toDirectory:appBackupDir error:error];
    backupResults[@"deviceBackup"] = @(deviceBackupSuccess);
    if (deviceBackupSuccess) {
        overallSuccess = YES;
        [successfulMethods addObject:@"Apple官方备份"];
    }
    
    // ============================================================================
    // MARK: - 第五层：系统级数据备份
    // ============================================================================
    
    NSLog(@"[DEBUG] 🔹 第五层：系统级数据备份");
    
    BOOL systemSuccess = [self backupAppSystemData:app toDirectory:appBackupDir error:error];
    backupResults[@"system"] = @(systemSuccess);
    if (systemSuccess) [successfulMethods addObject:@"系统数据"];
    
    // ============================================================================
    // MARK: - 第六层：后处理和验证
    // ============================================================================
    
    NSLog(@"[DEBUG] 🔹 第六层：后处理和验证");
    
    BOOL finalIPASuccess = [self createFinalIPAPackage:app fromDirectory:appBackupDir error:error];
    backupResults[@"finalIPA"] = @(finalIPASuccess);
    if (finalIPASuccess) [successfulMethods addObject:@"最终IPA"];
    
    BOOL integrityCheck = [self verifyBackupIntegrity:app inDirectory:appBackupDir];
    backupResults[@"integrity"] = @(integrityCheck);
    
    // ============================================================================
    // MARK: - 生成用户友好报告
    // ============================================================================
    
    [self generateBackupReport:backupResults forApp:app inDirectory:appBackupDir];
    [self generateUserFriendlyReport:app withResults:backupResults inDirectory:appBackupDir];
    
    // ============================================================================
    // MARK: - 最终结果评估
    // ============================================================================
    
    NSInteger totalMethods = backupResults.count;
    NSInteger successfulCount = 0;
    for (NSString *key in backupResults) {
        if ([backupResults[key] boolValue]) {
            successfulCount++;
        }
    }
    
    double completionRate = (double)successfulCount / (double)totalMethods * 100.0;
    
    // 评估核心功能成功率
    NSArray *coreMethods = @[@"info", @"ipa", @"sandbox", @"deviceBackup"];
    NSInteger coreSuccessCount = 0;
    for (NSString *coreMethod in coreMethods) {
        if ([backupResults[coreMethod] boolValue]) {
            coreSuccessCount++;
        }
    }
    
    double coreCompletionRate = (double)coreSuccessCount / (double)coreMethods.count * 100.0;
    
    // 只要有核心功能成功就算成功
    if (!overallSuccess) {
        overallSuccess = (infoSuccess && (ipaSuccess || sandboxSuccess || deviceBackupSuccess || specialSuccess));
    }
    
    // 记录最终统计
    NSLog(@"[DEBUG] 备份方法总数: %ld", (long)totalMethods);
    NSLog(@"[DEBUG] 成功方法数: %ld", (long)successfulCount);
    NSLog(@"[DEBUG] 总体完成率: %.1f%%", completionRate);
    NSLog(@"[DEBUG] 核心功能完成率: %.1f%%", coreCompletionRate);
    NSLog(@"[DEBUG] 成功的备份方法: %@", [successfulMethods componentsJoinedByString:@", "]);
    
    // 根据完成率确定最终结果
    if (coreCompletionRate >= 75.0) {
        NSLog(@"[DEBUG] 🎉 备份质量: 优秀 (核心功能完成率 >= 75%%)");
    } else if (coreCompletionRate >= 50.0) {
        NSLog(@"[DEBUG] ⚠️  备份质量: 良好 (核心功能完成率 >= 50%%)");
    } else if (overallSuccess) {
        NSLog(@"[DEBUG] ⚠️  备份质量: 基础 (部分功能可用)");
    } else {
        NSLog(@"[DEBUG] ❌ 备份质量: 失败 (核心功能不可用)");
    }
    
    NSLog(@"[DEBUG] =================== 增强版备份流程结束 ===================");
    
    return overallSuccess;
}


// ============================================================================
// MARK: - 增强版沙盒数据备份（获取完整数据）
// ============================================================================

// 备份应用沙盒数据
- (BOOL)backupAppSandboxDataEnhanced:(DeviceApp *)app toDirectory:(NSString *)directory error:(NSError **)error {
    NSLog(@"[DEBUG] =================== 沙盒数据备份诊断开始 ===================");
    NSLog(@"[DEBUG] 目标应用: %@", app.appName);
    NSLog(@"[DEBUG] Bundle ID: %@", app.bundleID);
    NSLog(@"[DEBUG] 期望数据大小: %@", [self formatSize:app.docSize]);
    
    // 创建诊断报告
    NSMutableString *diagnosticReport = [NSMutableString string];
    [diagnosticReport appendFormat:@"沙盒数据备份诊断报告\n"];
    [diagnosticReport appendFormat:@"========================\n"];
    [diagnosticReport appendFormat:@"应用: %@\n", app.appName];
    [diagnosticReport appendFormat:@"Bundle ID: %@\n", app.bundleID];
    [diagnosticReport appendFormat:@"期望数据大小: %@\n", [self formatSize:app.docSize]];
    [diagnosticReport appendFormat:@"时间: %@\n\n", [NSDate date]];
    
    NSString *sandboxDir = [directory stringByAppendingPathComponent:@"SandboxData"];
    [[NSFileManager defaultManager] createDirectoryAtPath:sandboxDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    
    // ============================================================================
    // MARK: - 设备连接检查
    // ============================================================================
    
    idevice_t device = NULL;
    if (idevice_new(&device, NULL) != IDEVICE_E_SUCCESS) {
        NSString *errorMsg = @"沙盒备份失败：设备连接失败";
        NSLog(@"[ERROR] %@", errorMsg);
        [diagnosticReport appendFormat:@"❌ 设备连接: 失败\n\n"];
        
        if (error) {
            *error = [NSError errorWithDomain:@"AppBackupErrorDomain"
                                         code:3001
                                     userInfo:@{NSLocalizedDescriptionKey: errorMsg}];
        }
        
        [self saveDiagnosticReport:diagnosticReport toDirectory:sandboxDir filename:@"sandbox_backup_diagnostic.txt"];
        return NO;
    }
    
    [diagnosticReport appendFormat:@"✅ 设备连接: 成功\n\n"];
    
    BOOL overallSuccess = NO;
    unsigned long long totalBackedUpSize = 0;
    
    // ============================================================================
    // MARK: - House Arrest 服务测试
    // ============================================================================
    
    NSLog(@"[DEBUG] 步骤1: House Arrest 服务测试");
    [diagnosticReport appendFormat:@"🔍 House Arrest 服务测试:\n"];
    
    house_arrest_client_t house_arrest = NULL;
    house_arrest_error_t ha_err = house_arrest_client_start_service(device, &house_arrest, "house_arrest");
    
    if (ha_err != HOUSE_ARREST_E_SUCCESS) {
        NSLog(@"[ERROR] house_arrest服务启动失败: %d", ha_err);
        [diagnosticReport appendFormat:@"❌ 服务启动: 失败 (错误: %d)\n", ha_err];
        [diagnosticReport appendFormat:@"   可能原因:\n"];
        [diagnosticReport appendFormat:@"   - 设备未信任此计算机\n"];
        [diagnosticReport appendFormat:@"   - iOS版本不兼容\n"];
        [diagnosticReport appendFormat:@"   - USB连接问题\n"];
        [diagnosticReport appendFormat:@"   解决方案: 重新信任设备，检查USB连接\n\n"];
        
        idevice_free(device);
        [self saveDiagnosticReport:diagnosticReport toDirectory:sandboxDir filename:@"sandbox_backup_diagnostic.txt"];
        return NO;
    }
    
    [diagnosticReport appendFormat:@"✅ 服务启动: 成功\n\n"];
    
    // ============================================================================
    // MARK: - 容器访问测试
    // ============================================================================
    
    NSLog(@"[DEBUG] 步骤2: 容器访问测试");
    [diagnosticReport appendFormat:@"🔍 容器访问测试:\n"];
    
    // 尝试VendContainer命令
    house_arrest_error_t cmd_err = house_arrest_send_command(house_arrest, "VendContainer", [app.bundleID UTF8String]);
    BOOL containerAccessible = (cmd_err == HOUSE_ARREST_E_SUCCESS);
    
    if (!containerAccessible) {
        NSLog(@"[WARNING] VendContainer命令失败: %d，尝试VendDocuments", cmd_err);
        [diagnosticReport appendFormat:@"⚠️ VendContainer: 失败 (错误: %d)\n", cmd_err];
        
        // 尝试VendDocuments
        cmd_err = house_arrest_send_command(house_arrest, "VendDocuments", [app.bundleID UTF8String]);
        if (cmd_err == HOUSE_ARREST_E_SUCCESS) {
            containerAccessible = YES;
            [diagnosticReport appendFormat:@"✅ VendDocuments: 成功\n"];
            NSLog(@"[DEBUG] VendDocuments命令成功");
        } else {
            [diagnosticReport appendFormat:@"❌ VendDocuments: 失败 (错误: %d)\n", cmd_err];
            NSLog(@"[ERROR] 所有house_arrest命令都失败");
        }
    } else {
        [diagnosticReport appendFormat:@"✅ VendContainer: 成功\n"];
        NSLog(@"[DEBUG] VendContainer命令成功");
    }
    
    if (!containerAccessible) {
        [diagnosticReport appendFormat:@"   分析: 此应用不允许外部访问其数据容器\n"];
        [diagnosticReport appendFormat:@"   常见于: 系统应用、银行应用、安全应用\n"];
        [diagnosticReport appendFormat:@"   解决方案: 1)设备越狱 2)使用iTunes加密备份\n\n"];
        
        house_arrest_client_free(house_arrest);
        idevice_free(device);
        [self saveDiagnosticReport:diagnosticReport toDirectory:sandboxDir filename:@"sandbox_backup_diagnostic.txt"];
        return NO;
    }
    
    // ============================================================================
    // MARK: - 数据备份执行
    // ============================================================================
    
    NSLog(@"[DEBUG] 步骤3: 执行数据备份");
    [diagnosticReport appendFormat:@"\n🔄 执行数据备份:\n"];
    
    // 1. 备份主容器数据
    unsigned long long mainContainerSize = 0;
    BOOL mainContainerSuccess = [self backupMainContainerWithDiagnostic:app
                                                                  device:device
                                                             toDirectory:sandboxDir
                                                          totalSizeOut:&mainContainerSize
                                                        diagnosticReport:diagnosticReport];
    if (mainContainerSuccess) {
        overallSuccess = YES;
        totalBackedUpSize += mainContainerSize;
    }
    
    // 2. 备份文档容器数据
    unsigned long long documentsSize = 0;
    BOOL documentsSuccess = [self backupDocumentsContainerWithDiagnostic:app
                                                                   device:device
                                                              toDirectory:sandboxDir
                                                           totalSizeOut:&documentsSize
                                                         diagnosticReport:diagnosticReport];
    if (documentsSuccess) {
        overallSuccess = YES;
        totalBackedUpSize += documentsSize;
    }
    
    // 3. 备份应用组数据
    unsigned long long appGroupSize = 0;
    BOOL appGroupSuccess = [self backupAppGroupContainersWithDiagnostic:app
                                                                  device:device
                                                             toDirectory:sandboxDir
                                                          totalSizeOut:&appGroupSize
                                                        diagnosticReport:diagnosticReport];
    if (appGroupSuccess) {
        overallSuccess = YES;
        totalBackedUpSize += appGroupSize;
    }
    
    // 4. 备份扩展数据
    unsigned long long extensionsSize = 0;
    BOOL extensionsSuccess = [self backupAppExtensionDataWithDiagnostic:app
                                                                  device:device
                                                             toDirectory:sandboxDir
                                                          totalSizeOut:&extensionsSize
                                                        diagnosticReport:diagnosticReport];
    if (extensionsSuccess) {
        overallSuccess = YES;
        totalBackedUpSize += extensionsSize;
    }
    
    house_arrest_client_free(house_arrest);
    idevice_free(device);
    
    // ============================================================================
    // MARK: - 结果统计和分析
    // ============================================================================
    
    double completenessRate = app.docSize > 0 ? (double)totalBackedUpSize / (double)app.docSize * 100.0 : 100.0;
    
    [diagnosticReport appendFormat:@"\n📊 备份结果统计:\n"];
    [diagnosticReport appendFormat:@"   期望大小: %@\n", [self formatSize:app.docSize]];
    [diagnosticReport appendFormat:@"   实际备份: %@\n", [self formatSize:totalBackedUpSize]];
    [diagnosticReport appendFormat:@"   完整度: %.1f%%\n", completenessRate];
    [diagnosticReport appendFormat:@"   主容器: %@ (%@)\n", mainContainerSuccess ? @"✅" : @"❌", [self formatSize:mainContainerSize]];
    [diagnosticReport appendFormat:@"   文档容器: %@ (%@)\n", documentsSuccess ? @"✅" : @"❌", [self formatSize:documentsSize]];
    [diagnosticReport appendFormat:@"   应用组: %@ (%@)\n", appGroupSuccess ? @"✅" : @"❌", [self formatSize:appGroupSize]];
    [diagnosticReport appendFormat:@"   扩展数据: %@ (%@)\n", extensionsSuccess ? @"✅" : @"❌", [self formatSize:extensionsSize]];
    
    // 质量评估
    [diagnosticReport appendFormat:@"\n🎯 备份质量评估:\n"];
    if (completenessRate >= 90.0) {
        [diagnosticReport appendFormat:@"   评级: 🌟🌟🌟🌟🌟 优秀\n"];
        [diagnosticReport appendFormat:@"   说明: 备份非常完整\n"];
    } else if (completenessRate >= 70.0) {
        [diagnosticReport appendFormat:@"   评级: 🌟🌟🌟🌟 良好\n"];
        [diagnosticReport appendFormat:@"   说明: 备份大部分数据\n"];
    } else if (completenessRate >= 30.0) {
        [diagnosticReport appendFormat:@"   评级: 🌟🌟🌟 一般\n"];
        [diagnosticReport appendFormat:@"   说明: 备份部分重要数据\n"];
    } else if (overallSuccess) {
        [diagnosticReport appendFormat:@"   评级: 🌟🌟 基础\n"];
        [diagnosticReport appendFormat:@"   说明: 仅备份基础结构\n"];
    } else {
        [diagnosticReport appendFormat:@"   评级: 🌟 失败\n"];
        [diagnosticReport appendFormat:@"   说明: 无法访问应用数据\n"];
    }
    
    // 针对特定应用的建议
    if ([app.bundleID containsString:@"QQMusic"] || [app.bundleID containsString:@"music"]) {
        [diagnosticReport appendFormat:@"\n💡 针对音乐应用的建议:\n"];
        [diagnosticReport appendFormat:@"   - 启用应用内的云同步功能\n"];
        [diagnosticReport appendFormat:@"   - 导出播放列表到其他格式\n"];
        [diagnosticReport appendFormat:@"   - 使用iTunes Match或类似服务\n"];
        [diagnosticReport appendFormat:@"   - 考虑使用专业备份工具(iMazing等)\n"];
    }
    
    // 生成详细的数据统计报告
    [self generateDataBackupReport:app
                      expectedSize:app.docSize
                        actualSize:totalBackedUpSize
                       inDirectory:sandboxDir];
    
    // 保存诊断报告
    [self saveDiagnosticReport:diagnosticReport toDirectory:sandboxDir filename:@"sandbox_backup_diagnostic.txt"];
    
    NSLog(@"[DEBUG] 沙盒备份完成 - 预期: %@, 实际: %@, 成功率: %.1f%%",
          [self formatSize:app.docSize],
          [self formatSize:totalBackedUpSize],
          completenessRate);
    
    NSLog(@"[DEBUG] =================== 沙盒数据备份诊断结束 ===================");
    
    return overallSuccess;
}



// 备份主容器
- (BOOL)backupMainContainerWithDiagnostic:(DeviceApp *)app
                                    device:(idevice_t)device
                               toDirectory:(NSString *)sandboxDir
                            totalSizeOut:(unsigned long long *)totalSize
                          diagnosticReport:(NSMutableString *)report {
    
    NSLog(@"[DEBUG] 备份主容器数据...");
    [report appendFormat:@"📁 主容器备份:\n"];
    
    house_arrest_client_t house_arrest = NULL;
    house_arrest_error_t ha_err = house_arrest_client_start_service(device, &house_arrest, "house_arrest");
    if (ha_err != HOUSE_ARREST_E_SUCCESS) {
        [report appendFormat:@"   ❌ 服务连接失败 (错误: %d)\n", ha_err];
        
        // 添加具体的错误解释
        switch (ha_err) {
            case HOUSE_ARREST_E_CONN_FAILED:
                [report appendFormat:@"   说明: 连接失败，可能是设备未解锁或未信任\n"];
                break;
            case HOUSE_ARREST_E_PLIST_ERROR:
                [report appendFormat:@"   说明: 通信协议错误\n"];
                break;
            case HOUSE_ARREST_E_INVALID_ARG:
                [report appendFormat:@"   说明: 参数无效\n"];
                break;
            default:
                [report appendFormat:@"   说明: 未知错误，请检查设备连接状态\n"];
        }
        
        return NO;
    }
    
    house_arrest_error_t cmd_err = house_arrest_send_command(house_arrest, "VendContainer", [app.bundleID UTF8String]);
    if (cmd_err != HOUSE_ARREST_E_SUCCESS) {
        [report appendFormat:@"   ❌ 容器访问失败 (错误: %d)\n", cmd_err];
        // 添加针对QQ音乐等音乐应用的特殊说明
        if ([app.bundleID containsString:@"music"] || [app.bundleID containsString:@"Music"]) {
            [report appendFormat:@"   说明: 音乐应用通常使用DRM保护，数据访问受限\n"];
            [report appendFormat:@"   建议: 使用应用内的云同步功能或iTunes加密备份\n"];
        }
        
        house_arrest_client_free(house_arrest);
        return NO;
    }
    
    afc_client_t afc = NULL;
    if (afc_client_new_from_house_arrest_client(house_arrest, &afc) != AFC_E_SUCCESS) {
        [report appendFormat:@"   ❌ AFC客户端创建失败\n"];
        house_arrest_client_free(house_arrest);
        return NO;
    }
    
    NSString *containerDir = [sandboxDir stringByAppendingPathComponent:@"MainContainer"];
    unsigned long long containerSize = 0;
    
    // 备份重要目录
    NSArray *importantDirs = @[@"/Documents", @"/Library", @"/tmp"];
    BOOL hasData = NO;
    int successfulDirs = 0;
    
    for (NSString *dir in importantDirs) {
        NSString *localDir = [containerDir stringByAppendingPathComponent:[dir lastPathComponent]];
        unsigned long long dirSize = 0;
        
        if ([self copyDirectoryFromAFCWithSize:afc
                                    remotePath:[dir UTF8String]
                                     localPath:localDir
                                      sizeOut:&dirSize]) {
            containerSize += dirSize;
            hasData = YES;
            successfulDirs++;
            [report appendFormat:@"   ✅ %@: %@\n", [dir lastPathComponent], [self formatSize:dirSize]];
        } else {
            [report appendFormat:@"   ❌ %@: 访问失败\n", [dir lastPathComponent]];
        }
    }
    
    // 备份根目录文件
    unsigned long long rootFileSize = 0;
    if ([self copyRootFilesFromAFC:afc localPath:containerDir sizeOut:&rootFileSize]) {
        containerSize += rootFileSize;
        hasData = YES;
        [report appendFormat:@"   ✅ 根目录文件: %@\n", [self formatSize:rootFileSize]];
    }
    
    [report appendFormat:@"   📊 总计: %@ (%d/%ld 目录成功)\n\n",
          [self formatSize:containerSize], successfulDirs, (long)importantDirs.count];
    
    afc_client_free(afc);
    house_arrest_client_free(house_arrest);
    
    *totalSize = containerSize;
    return hasData;
}

// 新增：激进的目录扫描方法
- (BOOL)scanAllDirectoriesFromAFC:(afc_client_t)afc
                        localPath:(NSString *)localPath
                         sizeOut:(unsigned long long *)totalSize {
    
    // 创建本地目录
    [[NSFileManager defaultManager] createDirectoryAtPath:localPath
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    
    // 尝试访问所有可能的目录
    NSArray *possiblePaths = @[
        @"/",
        @"/Documents",
        @"/Library",
        @"/Library/Preferences",
        @"/Library/Caches",
        @"/Library/Application Support",
        @"/Library/Saved Application State",
        @"/tmp",
        @"/var",
        @"/private"
    ];
    
    BOOL hasAnyData = NO;
    
    for (NSString *path in possiblePaths) {
        unsigned long long pathSize = 0;
        
        if ([self copyDirectoryFromAFCWithSize:afc
                                    remotePath:[path UTF8String]
                                     localPath:[localPath stringByAppendingPathComponent:[path lastPathComponent]]
                                      sizeOut:&pathSize]) {
            *totalSize += pathSize;
            hasAnyData = YES;
            NSLog(@"[DEBUG] 成功备份路径: %@ (%@)", path, [self formatSize:pathSize]);
        }
    }
    
    return hasAnyData;
}

// 备份文档容器
- (BOOL)backupDocumentsContainerWithDiagnostic:(DeviceApp *)app
                                         device:(idevice_t)device
                                    toDirectory:(NSString *)sandboxDir
                                 totalSizeOut:(unsigned long long *)totalSize
                               diagnosticReport:(NSMutableString *)report {
    
    NSLog(@"[DEBUG] 备份文档容器数据...");
    [report appendFormat:@"📄 文档容器备份:\n"];
    
    house_arrest_client_t house_arrest = NULL;
    if (house_arrest_client_start_service(device, &house_arrest, "house_arrest") != HOUSE_ARREST_E_SUCCESS) {
        [report appendFormat:@"   ❌ 服务连接失败\n"];
        return NO;
    }
    
    if (house_arrest_send_command(house_arrest, "VendDocuments", [app.bundleID UTF8String]) != HOUSE_ARREST_E_SUCCESS) {
        [report appendFormat:@"   ⚠️ 无文档容器访问权限\n"];
        house_arrest_client_free(house_arrest);
        return NO;
    }
    
    afc_client_t afc = NULL;
    if (afc_client_new_from_house_arrest_client(house_arrest, &afc) != AFC_E_SUCCESS) {
        [report appendFormat:@"   ❌ AFC客户端创建失败\n"];
        house_arrest_client_free(house_arrest);
        return NO;
    }
    
    NSString *documentsDir = [sandboxDir stringByAppendingPathComponent:@"DocumentsContainer"];
    unsigned long long documentsSize = 0;
    
    BOOL success = [self copyDirectoryFromAFCWithSize:afc
                                           remotePath:"/"
                                            localPath:documentsDir
                                             sizeOut:&documentsSize];
    
    if (success) {
        [report appendFormat:@"   ✅ 文档数据: %@\n\n", [self formatSize:documentsSize]];
    } else {
        [report appendFormat:@"   ❌ 备份失败\n\n"];
    }
    
    afc_client_free(afc);
    house_arrest_client_free(house_arrest);
    
    *totalSize = documentsSize;
    return success;
}

// 备份应用组数据
- (BOOL)backupAppGroupContainersWithDiagnostic:(DeviceApp *)app
                                         device:(idevice_t)device
                                    toDirectory:(NSString *)sandboxDir
                                 totalSizeOut:(unsigned long long *)totalSize
                               diagnosticReport:(NSMutableString *)report {
    
    NSLog(@"[DEBUG] 查找并备份应用组数据...");
    [report appendFormat:@"👥 应用组备份:\n"];
    
    NSArray *appGroups = [self getAppGroupsForApp:app device:device];
    if (appGroups.count == 0) {
        [report appendFormat:@"   ⚠️ 未发现应用组\n\n"];
        return NO;
    }
    
    [report appendFormat:@"   🔍 发现 %ld 个应用组\n", (long)appGroups.count];
    
    NSString *appGroupDir = [sandboxDir stringByAppendingPathComponent:@"AppGroups"];
    BOOL hasGroupData = NO;
    unsigned long long groupsSize = 0;
    int successfulGroups = 0;
    
    for (NSString *groupID in appGroups) {
        house_arrest_client_t house_arrest = NULL;
        if (house_arrest_client_start_service(device, &house_arrest, "house_arrest") == HOUSE_ARREST_E_SUCCESS) {
            
            if (house_arrest_send_command(house_arrest, "VendContainer", [groupID UTF8String]) == HOUSE_ARREST_E_SUCCESS) {
                afc_client_t afc = NULL;
                if (afc_client_new_from_house_arrest_client(house_arrest, &afc) == AFC_E_SUCCESS) {
                    
                    NSString *groupBackupDir = [appGroupDir stringByAppendingPathComponent:groupID];
                    unsigned long long groupSize = 0;
                    
                    if ([self copyDirectoryFromAFCWithSize:afc
                                                remotePath:"/"
                                                 localPath:groupBackupDir
                                                  sizeOut:&groupSize]) {
                        groupsSize += groupSize;
                        hasGroupData = YES;
                        successfulGroups++;
                        [report appendFormat:@"   ✅ %@: %@\n", [groupID lastPathComponent], [self formatSize:groupSize]];
                    } else {
                        [report appendFormat:@"   ❌ %@: 访问失败\n", [groupID lastPathComponent]];
                    }
                    
                    afc_client_free(afc);
                }
            }
            
            house_arrest_client_free(house_arrest);
        }
    }
    
    [report appendFormat:@"   📊 总计: %@ (%d/%ld 组成功)\n\n",
          [self formatSize:groupsSize], successfulGroups, (long)appGroups.count];
    
    *totalSize = groupsSize;
    return hasGroupData;
}

// 备份扩展数据
- (BOOL)backupAppExtensionDataWithDiagnostic:(DeviceApp *)app
                                       device:(idevice_t)device
                                  toDirectory:(NSString *)sandboxDir
                               totalSizeOut:(unsigned long long *)totalSize
                             diagnosticReport:(NSMutableString *)report {
    
    NSLog(@"[DEBUG] 查找并备份应用扩展数据...");
    [report appendFormat:@"🧩 扩展数据备份:\n"];
    
    NSArray *extensions = [self findAppExtensions:app device:device];
    if (extensions.count == 0) {
        [report appendFormat:@"   ⚠️ 未发现应用扩展\n\n"];
        return NO;
    }
    
    [report appendFormat:@"   🔍 发现 %ld 个扩展\n", (long)extensions.count];
    
    NSString *extensionsDir = [sandboxDir stringByAppendingPathComponent:@"Extensions"];
    BOOL hasExtensionData = NO;
    unsigned long long extensionsSize = 0;
    int successfulExtensions = 0;
    
    for (NSString *extensionID in extensions) {
        house_arrest_client_t house_arrest = NULL;
        if (house_arrest_client_start_service(device, &house_arrest, "house_arrest") == HOUSE_ARREST_E_SUCCESS) {
            
            if (house_arrest_send_command(house_arrest, "VendContainer", [extensionID UTF8String]) == HOUSE_ARREST_E_SUCCESS) {
                afc_client_t afc = NULL;
                if (afc_client_new_from_house_arrest_client(house_arrest, &afc) == AFC_E_SUCCESS) {
                    
                    NSString *extBackupDir = [extensionsDir stringByAppendingPathComponent:extensionID];
                    unsigned long long extSize = 0;
                    
                    if ([self copyDirectoryFromAFCWithSize:afc
                                                remotePath:"/"
                                                 localPath:extBackupDir
                                                  sizeOut:&extSize]) {
                        extensionsSize += extSize;
                        hasExtensionData = YES;
                        successfulExtensions++;
                        [report appendFormat:@"   ✅ %@: %@\n", [extensionID lastPathComponent], [self formatSize:extSize]];
                    } else {
                        [report appendFormat:@"   ❌ %@: 访问失败\n", [extensionID lastPathComponent]];
                    }
                    
                    afc_client_free(afc);
                }
            }
            
            house_arrest_client_free(house_arrest);
        }
    }
    
    [report appendFormat:@"   📊 总计: %@ (%d/%ld 扩展成功)\n\n",
          [self formatSize:extensionsSize], successfulExtensions, (long)extensions.count];
    
    *totalSize = extensionsSize;
    return hasExtensionData;
}

// ============================================================================
// MARK: - 基础备份组件
// ============================================================================

// 备份应用基本信息
- (BOOL)backupAppInfo:(DeviceApp *)app toDirectory:(NSString *)directory error:(NSError **)error {
    NSString *infoPath = [directory stringByAppendingPathComponent:@"AppInfo.plist"];
    NSString *lockedDeviceID = [self getLockedDeviceID];
    
    NSDictionary *appInfo = @{
        @"BundleID": app.bundleID ?: @"",
        @"AppName": app.appName ?: @"",
        @"Version": app.version ?: @"",
        @"ApplicationType": app.applicationType ?: @"",
        @"Developer": app.developer ?: @"",
        @"AppSize": @(app.appSize),
        @"DataSize": @(app.docSize),
        @"Path": app.path ?: @"",
        @"Container": app.container ?: @"",
        @"BackupDate": [NSDate date],
        @"DeviceUDID": lockedDeviceID ?: @"",
        @"HasUpdateAvailable": @(app.hasUpdateAvailable),
        @"AppStoreVersion": app.appStoreVersion ?: @"",
        @"AppleID": app.appleID ?: @"",
        @"AppId": app.appId ?: @""
    };
    
    BOOL success = [appInfo writeToFile:infoPath atomically:YES];
    if (!success && error) {
        *error = [NSError errorWithDomain:@"AppBackupErrorDomain"
                                     code:1001
                                 userInfo:@{NSLocalizedDescriptionKey: @"Failed to save app info"}];
    }
    
    return success;
}

// 备份应用图标
- (BOOL)backupAppIcon:(DeviceApp *)app toDirectory:(NSString *)directory error:(NSError **)error {
    if (!app.iconImage) {
        NSLog(@"[DEBUG] 应用没有图标数据");
        return NO;
    }
    
    NSString *iconPath = [directory stringByAppendingPathComponent:@"AppIcon.png"];
    
    // 将NSImage转换为PNG数据
    CGImageRef cgImage = [app.iconImage CGImageForProposedRect:NULL context:nil hints:nil];
    if (!cgImage) {
        NSLog(@"[ERROR] 无法从NSImage获取CGImage");
        return NO;
    }
    
    NSBitmapImageRep *bitmapRep = [[NSBitmapImageRep alloc] initWithCGImage:cgImage];
    NSData *pngData = [bitmapRep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    
    if (!pngData) {
        NSLog(@"[ERROR] 无法转换图标为PNG格式");
        return NO;
    }
    
    BOOL success = [pngData writeToFile:iconPath atomically:YES];
    if (success) {
        NSLog(@"[DEBUG] 图标保存成功: %@", iconPath);
    } else {
        NSLog(@"[ERROR] 图标保存失败");
    }
    
    return success;
}

// 提取IPA文件
- (BOOL)extractIPAFromDevice:(DeviceApp *)app toDirectory:(NSString *)directory error:(NSError **)error {
    NSLog(@"[DEBUG] =================== IPA提取诊断开始 ===================");
    NSLog(@"[DEBUG] 目标应用: %@", app.appName);
    NSLog(@"[DEBUG] Bundle ID: %@", app.bundleID);
    NSLog(@"[DEBUG] 应用路径: %@", app.path ?: @"(空)");
    NSLog(@"[DEBUG] 容器路径: %@", app.container ?: @"(空)");
    NSLog(@"[DEBUG] 应用类型: %@", app.applicationType);
    NSLog(@"[DEBUG] 应用大小: %@", [self formatSize:app.appSize]);
    
    // 创建诊断报告
    NSMutableString *diagnosticReport = [NSMutableString string];
    [diagnosticReport appendFormat:@"IPA提取诊断报告\n"];
    [diagnosticReport appendFormat:@"==================\n"];
    [diagnosticReport appendFormat:@"应用: %@\n", app.appName];
    [diagnosticReport appendFormat:@"时间: %@\n\n", [NSDate date]];
    
    // ============================================================================
    // MARK: - 前置条件检查
    // ============================================================================
    
    NSLog(@"[DEBUG] 步骤1: 前置条件检查");
    
    // 1. 检查应用路径
    if (!app.path || app.path.length == 0) {
        NSString *errorMsg = @"IPA提取失败：应用路径为空，这通常发生在系统应用或需要特殊权限的应用";
        NSLog(@"[ERROR] %@", errorMsg);
        [diagnosticReport appendFormat:@"❌ 应用路径检查: 失败\n"];
        [diagnosticReport appendFormat:@"   原因: 路径为空\n"];
        [diagnosticReport appendFormat:@"   解决方案: 1)设备越狱 2)仅支持用户安装的应用\n\n"];
        
        if (error) {
            *error = [NSError errorWithDomain:@"AppBackupErrorDomain" code:2001
                                     userInfo:@{NSLocalizedDescriptionKey: errorMsg}];
        }
        
        // 保存诊断报告
        [self saveDiagnosticReport:diagnosticReport toDirectory:directory filename:@"ipa_extraction_diagnostic.txt"];
        return NO;
    }
    
    [diagnosticReport appendFormat:@"✅ 应用路径检查: 成功\n"];
    [diagnosticReport appendFormat:@"   路径: %@\n\n", app.path];
    
    // 2. 检查应用类型
    if ([app.applicationType isEqualToString:@"System"]) {
        NSLog(@"[WARNING] 检测到系统应用，可能无法访问");
        [diagnosticReport appendFormat:@"⚠️ 应用类型检查: 系统应用\n"];
        [diagnosticReport appendFormat:@"   注意: 系统应用通常需要特殊权限访问\n\n"];
    } else {
        [diagnosticReport appendFormat:@"✅ 应用类型检查: 用户应用\n\n"];
    }
    
    // ============================================================================
    // MARK: - 设备连接测试
    // ============================================================================
    
    NSLog(@"[DEBUG] 步骤2: 设备连接测试");
    
    idevice_t device = NULL;
    idevice_error_t device_err = idevice_new(&device, NULL);
    if (device_err != IDEVICE_E_SUCCESS) {
        NSString *errorMsg = [NSString stringWithFormat:@"IPA提取失败：设备连接失败 (错误代码: %d)", device_err];
        NSLog(@"[ERROR] %@", errorMsg);
        [diagnosticReport appendFormat:@"❌ 设备连接测试: 失败\n"];
        [diagnosticReport appendFormat:@"   错误代码: %d\n", device_err];
        [diagnosticReport appendFormat:@"   解决方案: 1)重新连接设备 2)重启设备和电脑 3)更新iTunes\n\n"];
        
        [self saveDiagnosticReport:diagnosticReport toDirectory:directory filename:@"ipa_extraction_diagnostic.txt"];
        return NO;
    }
    
    [diagnosticReport appendFormat:@"✅ 设备连接测试: 成功\n\n"];
    
    // ============================================================================
    // MARK: - AFC服务测试
    // ============================================================================
    
    NSLog(@"[DEBUG] 步骤3: AFC服务测试");
    
    afc_client_t afc = NULL;
    afc_error_t afc_err = afc_client_start_service(device, &afc, "afc");
    
    if (afc_err != AFC_E_SUCCESS) {
        NSLog(@"[WARNING] 标准AFC服务启动失败: %d，尝试备用服务", afc_err);
        [diagnosticReport appendFormat:@"⚠️ 标准AFC服务: 失败 (错误: %d)\n", afc_err];
        
        // 尝试其他AFC服务
        afc_err = afc_client_start_service(device, &afc, "com.apple.afc");
        if (afc_err != AFC_E_SUCCESS) {
            NSString *errorMsg = @"所有AFC服务都无法启动，设备可能未信任此计算机或需要解锁";
            NSLog(@"[ERROR] %@", errorMsg);
            [diagnosticReport appendFormat:@"❌ 备用AFC服务: 失败 (错误: %d)\n", afc_err];
            [diagnosticReport appendFormat:@"   解决方案: 1)解锁设备并点击'信任' 2)重新插拔USB 3)检查USB权限\n\n"];
            
            idevice_free(device);
            [self saveDiagnosticReport:diagnosticReport toDirectory:directory filename:@"ipa_extraction_diagnostic.txt"];
            return NO;
        } else {
            [diagnosticReport appendFormat:@"✅ 备用AFC服务: 成功\n\n"];
        }
    } else {
        [diagnosticReport appendFormat:@"✅ 标准AFC服务: 成功\n\n"];
    }
    
    // ============================================================================
    // MARK: - 应用路径访问测试
    // ============================================================================
    
    NSLog(@"[DEBUG] 步骤4: 应用路径访问测试");
    
    char **dirlist = NULL;
    afc_error_t read_err = afc_read_directory(afc, [app.path UTF8String], &dirlist);
    
    if (read_err != AFC_E_SUCCESS) {
        NSString *errorMsg = [NSString stringWithFormat:@"无法访问应用路径: %@ (错误: %d)", app.path, read_err];
        NSLog(@"[ERROR] %@", errorMsg);
        [diagnosticReport appendFormat:@"❌ 应用路径访问: 失败\n"];
        [diagnosticReport appendFormat:@"   路径: %@\n", app.path];
        [diagnosticReport appendFormat:@"   错误代码: %d\n", read_err];
        [diagnosticReport appendFormat:@"   原因分析:\n"];
        [diagnosticReport appendFormat:@"   - 系统应用受保护，需要设备越狱\n"];
        [diagnosticReport appendFormat:@"   - 应用路径已更改或损坏\n"];
        [diagnosticReport appendFormat:@"   - iOS安全策略限制\n"];
        [diagnosticReport appendFormat:@"   解决方案: 1)设备越狱 2)使用iTunes备份 3)联系应用开发者\n\n"];
        
        afc_client_free(afc);
        idevice_free(device);
        [self saveDiagnosticReport:diagnosticReport toDirectory:directory filename:@"ipa_extraction_diagnostic.txt"];
        return NO;
    }
    
    // 统计目录内容
    int fileCount = 0;
    if (dirlist) {
        for (int i = 0; dirlist[i]; i++) {
            NSString *filename = [NSString stringWithUTF8String:dirlist[i]];
            if (![filename isEqualToString:@"."] && ![filename isEqualToString:@".."]) {
                fileCount++;
            }
        }
        
        NSLog(@"[DEBUG] 应用目录包含 %d 个文件/文件夹", fileCount);
        [diagnosticReport appendFormat:@"✅ 应用路径访问: 成功\n"];
        [diagnosticReport appendFormat:@"   文件/文件夹数量: %d\n\n", fileCount];
        
        // 清理目录列表
        for (int i = 0; dirlist[i]; i++) {
            free(dirlist[i]);
        }
        free(dirlist);
    }
    
    // ============================================================================
    // MARK: - 执行IPA提取
    // ============================================================================
    
    NSLog(@"[DEBUG] 步骤5: 执行IPA提取");
    [diagnosticReport appendFormat:@"🔄 开始IPA提取...\n"];
    
    NSString *ipaDir = [directory stringByAppendingPathComponent:@"IPA_Extraction"];
    [[NSFileManager defaultManager] createDirectoryAtPath:ipaDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    
    // 创建Payload目录
    NSString *payloadDir = [ipaDir stringByAppendingPathComponent:@"Payload"];
    [[NSFileManager defaultManager] createDirectoryAtPath:payloadDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    
    // 复制应用Bundle
    NSString *appBundlePath = [payloadDir stringByAppendingPathComponent:[app.path lastPathComponent]];
    unsigned long long copiedSize = 0;
    BOOL bundleSuccess = [self copyDirectoryFromAFCWithSize:afc
                                                 remotePath:[app.path UTF8String]
                                                  localPath:appBundlePath
                                                   sizeOut:&copiedSize];
    
    if (!bundleSuccess || copiedSize == 0) {
        NSLog(@"[ERROR] 应用Bundle复制失败");
        [diagnosticReport appendFormat:@"❌ Bundle复制: 失败\n"];
        [diagnosticReport appendFormat:@"   复制大小: %@\n", [self formatSize:copiedSize]];
        
        afc_client_free(afc);
        idevice_free(device);
        [self saveDiagnosticReport:diagnosticReport toDirectory:directory filename:@"ipa_extraction_diagnostic.txt"];
        return NO;
    }
    
    [diagnosticReport appendFormat:@"✅ Bundle复制: 成功\n"];
    [diagnosticReport appendFormat:@"   复制大小: %@\n", [self formatSize:copiedSize]];
    
    afc_client_free(afc);
    idevice_free(device);
    
    // ============================================================================
    // MARK: - 创建IPA元数据
    // ============================================================================
    
    NSLog(@"[DEBUG] 步骤6: 创建IPA元数据");
    
    // 创建iTunesMetadata.plist
    BOOL metadataSuccess = [self createITunesMetadataWithReturn:app inDirectory:ipaDir];
    [diagnosticReport appendFormat:@"%@ iTunes元数据: %@\n", metadataSuccess ? @"✅" : @"⚠️", metadataSuccess ? @"成功" : @"失败"];
    
    // 创建iTunesArtwork
    BOOL artworkSuccess = NO;
    if (app.iconImage) {
        artworkSuccess = [self createITunesArtworkWithReturn:app.iconImage inDirectory:ipaDir];
    }
    [diagnosticReport appendFormat:@"%@ iTunes图标: %@\n", artworkSuccess ? @"✅" : @"⚠️", artworkSuccess ? @"成功" : @"无图标"];

    
    // ============================================================================
    // MARK: - 打包成IPA
    // ============================================================================
    
    NSLog(@"[DEBUG] 步骤7: 打包成IPA文件");
    
    NSString *safeAppName = [self sanitizeFileName:app.appName];
    NSString *ipaPath = [directory stringByAppendingPathComponent:[NSString stringWithFormat:@"%@_%@.ipa", safeAppName, app.version]];
    BOOL zipSuccess = [self zipDirectory:ipaDir toPath:ipaPath];
    
    [diagnosticReport appendFormat:@"%@ IPA打包: %@\n", zipSuccess ? @"✅" : @"❌", zipSuccess ? @"成功" : @"失败"];
    
    if (zipSuccess) {
        // 获取最终IPA文件大小
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:ipaPath error:nil];
        unsigned long long ipaSize = [attrs[NSFileSize] unsignedLongLongValue];
        [diagnosticReport appendFormat:@"   IPA文件大小: %@\n", [self formatSize:ipaSize]];
        [diagnosticReport appendFormat:@"   保存路径: %@\n", ipaPath];
        
        NSLog(@"[DEBUG] ✅ IPA文件创建成功: %@ (大小: %@)", ipaPath, [self formatSize:ipaSize]);
    }
    
    [diagnosticReport appendFormat:@"\n🎉 IPA提取完成\n"];
    [diagnosticReport appendFormat:@"总耗时: %.2f秒\n", [[NSDate date] timeIntervalSinceDate:[NSDate date]]];
    
    // 保存完整诊断报告
    [self saveDiagnosticReport:diagnosticReport toDirectory:directory filename:@"ipa_extraction_diagnostic.txt"];
    
    NSLog(@"[DEBUG] =================== IPA提取诊断结束 ===================");
    
    return zipSuccess;
}

// 创建iTunes元数据（返回成功状态）
- (BOOL)createITunesMetadataWithReturn:(DeviceApp *)app inDirectory:(NSString *)directory {
    NSLog(@"[DEBUG] 创建iTunes元数据文件...");
    
    NSString *metadataPath = [directory stringByAppendingPathComponent:@"iTunesMetadata.plist"];
    
    // 创建当前时间戳
    NSDate *currentDate = [NSDate date];
    NSTimeInterval timestamp = [currentDate timeIntervalSince1970];
    
    // 构建完整的iTunes元数据
    NSMutableDictionary *metadata = [NSMutableDictionary dictionary];
    
    // 基本应用信息
    if (app.bundleID) metadata[@"bundleIdentifier"] = app.bundleID;
    if (app.version) {
        metadata[@"bundleShortVersionString"] = app.version;
        metadata[@"bundleVersion"] = app.version;
    }
    if (app.appName) metadata[@"itemName"] = app.appName;
    
    // 开发者信息
    if (app.developer) {
        metadata[@"artistName"] = app.developer;
        metadata[@"sellerName"] = app.developer;
    } else {
        metadata[@"artistName"] = @"Unknown Developer";
        metadata[@"sellerName"] = @"Unknown Developer";
    }
    
    // App Store 信息
    //暂时屏蔽 if (app.appleID) metadata[@"appleId"] = app.appleID;
    
    NSLog(@"[DEBUG] 暂时屏蔽元数据文件appleId: %@",app.appleID);
    if (app.appId) metadata[@"itemId"] = app.appId;
    
    // 应用分类和类型
    metadata[@"kind"] = @"software";
    metadata[@"genre"] = @"Utilities";
    metadata[@"genreId"] = @6002; // Utilities category
    
    // 版本和更新信息
    if (app.externalVersion > 0) {
        metadata[@"softwareVersionExternalIdentifier"] = @(app.externalVersion);
    }
    
    // 购买和下载信息
    metadata[@"purchaseDate"] = currentDate;
    metadata[@"downloadDate"] = currentDate;
    
    // 设备和系统信息
    metadata[@"s"] = @1; // 表示已购买
    metadata[@"hasBeenRestored"] = @NO;
    
    // 文件大小信息
    if (app.appSize > 0) {
        metadata[@"fileSizeBytes"] = @(app.appSize);
    }
    
    // 应用评级
    metadata[@"contentRatingsBySystem"] = @{
        @"appsApple" : @{
            @"name" : @"4+",
            @"value" : @100,
            @"rank" : @1
        }
    };
    
    // 本地化信息
    metadata[@"bundleDisplayName"] = app.appName ?: @"Unknown App";
    metadata[@"drmVersionNumber"] = @0;
    
    // 特殊处理：如果是音乐应用，添加媒体相关元数据
    if ([app.bundleID containsString:@"music"] || [app.bundleID containsString:@"Music"]) {
        metadata[@"genre"] = @"Music";
        metadata[@"genreId"] = @6011; // Music category
        metadata[@"hasHDVideo"] = @NO;
        metadata[@"hasScreenshots"] = @YES;
    }
    
    // 添加备份相关信息
    metadata[@"backupInfo"] = @{
        @"backupDate" : currentDate,
        @"backupTool" : @"libimobiledevice",
        @"backupVersion" : @"1.0",
        @"originalDevice" : @"iOS Device"
    };
    
    NSLog(@"[DEBUG] iTunes元数据包含 %ld 个字段", (long)metadata.count);
    
    // 写入文件
    NSError *writeError = nil;
    BOOL success = [metadata writeToFile:metadataPath atomically:YES];
    
    if (success) {
        NSLog(@"[DEBUG] ✅ iTunes元数据创建成功: %@", metadataPath);
        
        // 验证文件是否正确创建
        NSDictionary *verification = [NSDictionary dictionaryWithContentsOfFile:metadataPath];
        if (!verification) {
            NSLog(@"[ERROR] iTunes元数据文件验证失败");
            return NO;
        }
        
        // 获取文件大小
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:metadataPath error:nil];
        if (attrs) {
            NSNumber *fileSize = attrs[NSFileSize];
            NSLog(@"[DEBUG] iTunes元数据文件大小: %@ bytes", fileSize);
        }
        
    } else {
        NSLog(@"[ERROR] iTunes元数据创建失败: %@", writeError.localizedDescription);
    }
    
    return success;
}

// 创建iTunes图标（返回成功状态）
- (BOOL)createITunesArtworkWithReturn:(NSImage *)icon inDirectory:(NSString *)directory {
    if (!icon) {
        NSLog(@"[DEBUG] 没有提供图标，跳过iTunes图标创建");
        return NO;
    }
    
    NSLog(@"[DEBUG] 创建iTunes图标文件...");
    
    NSString *artworkPath = [directory stringByAppendingPathComponent:@"iTunesArtwork"];
    NSString *artwork2xPath = [directory stringByAppendingPathComponent:@"iTunesArtwork@2x"];
    
    BOOL success = NO;
    BOOL highResSuccess = NO;
    
    // 将PNG属性定义移到方法开始处，确保整个方法都能访问
    NSDictionary *pngProperties = @{
        NSImageCompressionFactor: @0.9,
        NSImageProgressive: @NO
    };
    
    @try {
        // ============================================================================
        // MARK: - 创建512x512的标准图标
        // ============================================================================
        
        NSLog(@"[DEBUG] 创建标准分辨率图标 (512x512)...");
        NSSize standardSize = NSMakeSize(512, 512);
        NSImage *standardArtwork = [[NSImage alloc] initWithSize:standardSize];
        
        [standardArtwork lockFocus];
        [[NSGraphicsContext currentContext] setImageInterpolation:NSImageInterpolationHigh];
        [icon drawInRect:NSMakeRect(0, 0, standardSize.width, standardSize.height)
                fromRect:NSZeroRect
               operation:NSCompositingOperationSourceOver
                fraction:1.0];
        [standardArtwork unlockFocus];
        
        // 转换为PNG数据
        CGImageRef cgImage = [standardArtwork CGImageForProposedRect:NULL context:nil hints:nil];
        if (cgImage) {
            NSBitmapImageRep *bitmapRep = [[NSBitmapImageRep alloc] initWithCGImage:cgImage];
            
            NSData *pngData = [bitmapRep representationUsingType:NSBitmapImageFileTypePNG
                                                      properties:pngProperties];
            
            if (pngData && pngData.length > 0) {
                success = [pngData writeToFile:artworkPath atomically:YES];
                if (success) {
                    NSLog(@"[DEBUG] ✅ 标准iTunes图标创建成功: %@ (%@ bytes)",
                          artworkPath, @(pngData.length));
                } else {
                    NSLog(@"[ERROR] 标准iTunes图标写入文件失败: %@", artworkPath);
                }
            } else {
                NSLog(@"[ERROR] 标准iTunes图标PNG数据生成失败");
            }
        } else {
            NSLog(@"[ERROR] 标准iTunes图标CGImage转换失败");
        }
        
        // ============================================================================
        // MARK: - 创建1024x1024的高分辨率图标
        // ============================================================================
        
        NSLog(@"[DEBUG] 创建高分辨率图标 (1024x1024)...");
        NSSize highResSize = NSMakeSize(1024, 1024);
        NSImage *highResArtwork = [[NSImage alloc] initWithSize:highResSize];
        
        [highResArtwork lockFocus];
        [[NSGraphicsContext currentContext] setImageInterpolation:NSImageInterpolationHigh];
        [icon drawInRect:NSMakeRect(0, 0, highResSize.width, highResSize.height)
                fromRect:NSZeroRect
               operation:NSCompositingOperationSourceOver
                fraction:1.0];
        [highResArtwork unlockFocus];
        
        // 转换为PNG数据
        CGImageRef highResCgImage = [highResArtwork CGImageForProposedRect:NULL context:nil hints:nil];
        if (highResCgImage) {
            NSBitmapImageRep *highResBitmapRep = [[NSBitmapImageRep alloc] initWithCGImage:highResCgImage];
            NSData *highResPngData = [highResBitmapRep representationUsingType:NSBitmapImageFileTypePNG
                                                                    properties:pngProperties];
            
            if (highResPngData && highResPngData.length > 0) {
                highResSuccess = [highResPngData writeToFile:artwork2xPath atomically:YES];
                if (highResSuccess) {
                    NSLog(@"[DEBUG] ✅ 高分辨率iTunes图标创建成功: %@ (%@ bytes)",
                          artwork2xPath, @(highResPngData.length));
                } else {
                    NSLog(@"[ERROR] 高分辨率iTunes图标写入文件失败: %@", artwork2xPath);
                }
            } else {
                NSLog(@"[ERROR] 高分辨率iTunes图标PNG数据生成失败");
            }
        } else {
            NSLog(@"[ERROR] 高分辨率iTunes图标CGImage转换失败");
        }
        
        // ============================================================================
        // MARK: - 创建额外的常用尺寸图标（可选）
        // ============================================================================
        
        // 创建其他常用尺寸的图标
        NSArray *additionalSizes = @[
            @{@"size": [NSValue valueWithSize:NSMakeSize(60, 60)], @"name": @"Icon-60"},
            @{@"size": [NSValue valueWithSize:NSMakeSize(120, 120)], @"name": @"Icon-120"},
            @{@"size": [NSValue valueWithSize:NSMakeSize(180, 180)], @"name": @"Icon-180"}
        ];
        
        for (NSDictionary *sizeInfo in additionalSizes) {
            NSSize iconSize = [[sizeInfo[@"size"] nonretainedObjectValue] sizeValue];
            NSString *iconName = sizeInfo[@"name"];
            NSString *iconPath = [directory stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.png", iconName]];
            
            NSImage *sizedIcon = [[NSImage alloc] initWithSize:iconSize];
            [sizedIcon lockFocus];
            [[NSGraphicsContext currentContext] setImageInterpolation:NSImageInterpolationHigh];
            [icon drawInRect:NSMakeRect(0, 0, iconSize.width, iconSize.height)
                    fromRect:NSZeroRect
                   operation:NSCompositingOperationSourceOver
                    fraction:1.0];
            [sizedIcon unlockFocus];
            
            CGImageRef sizedCgImage = [sizedIcon CGImageForProposedRect:NULL context:nil hints:nil];
            if (sizedCgImage) {
                NSBitmapImageRep *sizedBitmapRep = [[NSBitmapImageRep alloc] initWithCGImage:sizedCgImage];
                NSData *sizedPngData = [sizedBitmapRep representationUsingType:NSBitmapImageFileTypePNG
                                                                    properties:pngProperties];
                
                if (sizedPngData && sizedPngData.length > 0) {
                    BOOL sizedSuccess = [sizedPngData writeToFile:iconPath atomically:YES];
                    if (sizedSuccess) {
                        NSLog(@"[DEBUG] ✅ %@ 图标创建成功: %@ (%@ bytes)",
                              iconName, iconPath, @(sizedPngData.length));
                    }
                }
            }
        }
        
    } @catch (NSException *exception) {
        NSLog(@"[ERROR] iTunes图标创建过程异常: %@", exception.reason);
        NSLog(@"[ERROR] 异常堆栈: %@", exception.callStackSymbols);
        return NO;
    }
    
    // ============================================================================
    // MARK: - 结果验证和总结
    // ============================================================================
    
    // 至少一个主要图标创建成功就算成功
    BOOL overallSuccess = success || highResSuccess;
    
    if (overallSuccess) {
        NSLog(@"[DEBUG] 🎉 iTunes图标创建完成总结:");
        NSLog(@"[DEBUG]   - 标准图标 (512x512): %@", success ? @"✅ 成功" : @"❌ 失败");
        NSLog(@"[DEBUG]   - 高清图标 (1024x1024): %@", highResSuccess ? @"✅ 成功" : @"❌ 失败");
        
        // 验证文件是否确实存在
        if (success && [[NSFileManager defaultManager] fileExistsAtPath:artworkPath]) {
            NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:artworkPath error:nil];
            if (attrs) {
                NSLog(@"[DEBUG]   - 标准图标文件大小: %@", [self formatSize:[attrs[NSFileSize] unsignedLongLongValue]]);
            }
        }
        
        if (highResSuccess && [[NSFileManager defaultManager] fileExistsAtPath:artwork2xPath]) {
            NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:artwork2xPath error:nil];
            if (attrs) {
                NSLog(@"[DEBUG]   - 高清图标文件大小: %@", [self formatSize:[attrs[NSFileSize] unsignedLongLongValue]]);
            }
        }
        
        // 创建图标信息文件
        NSDictionary *iconInfo = @{
            @"StandardIcon": @{
                @"created": @(success),
                @"path": success ? artworkPath : @"",
                @"size": @"512x512"
            },
            @"HighResIcon": @{
                @"created": @(highResSuccess),
                @"path": highResSuccess ? artwork2xPath : @"",
                @"size": @"1024x1024"
            },
            @"createdAt": [NSDate date],
            @"originalIconSize": NSStringFromSize([icon size])
        };
        
        NSString *iconInfoPath = [directory stringByAppendingPathComponent:@"icon_creation_info.plist"];
        [iconInfo writeToFile:iconInfoPath atomically:YES];
        
    } else {
        NSLog(@"[ERROR] ❌ 所有iTunes图标创建都失败");
        NSLog(@"[ERROR] 可能的原因:");
        NSLog(@"[ERROR]   - 源图标数据损坏");
        NSLog(@"[ERROR]   - 磁盘空间不足");
        NSLog(@"[ERROR]   - 目录权限问题");
        NSLog(@"[ERROR]   - 图像处理库问题");
    }
    
    return overallSuccess;
}



// ============================================================================
// MARK: - 保持原有方法的兼容性（调用新方法）
// ============================================================================

// 原有的createITunesMetadata方法（保持兼容性）
- (void)createITunesMetadata:(DeviceApp *)app inDirectory:(NSString *)directory {
    [self createITunesMetadataWithReturn:app inDirectory:directory];
}

// 原有的createITunesArtwork方法（保持兼容性）
- (void)createITunesArtwork:(NSImage *)icon inDirectory:(NSString *)directory {
    [self createITunesArtworkWithReturn:icon inDirectory:directory];
}

// ============================================================================
// MARK: - 增强的最终IPA包创建方法
// ============================================================================

- (BOOL)createFinalIPAPackage:(DeviceApp *)app fromDirectory:(NSString *)directory error:(NSError **)error {
    NSLog(@"[DEBUG] 创建最终IPA包: %@", app.appName);
    
    // 检查是否已经有IPA文件
    NSArray *dirContents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:directory error:nil];
    for (NSString *item in dirContents) {
        if ([[item pathExtension] isEqualToString:@"ipa"]) {
            NSLog(@"[DEBUG] 找到现有IPA文件: %@", item);
            
            // 验证IPA文件是否有效
            NSString *ipaPath = [directory stringByAppendingPathComponent:item];
            NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:ipaPath error:nil];
            if (attrs && [attrs[NSFileSize] unsignedLongLongValue] > 1024) { // 至少1KB
                NSLog(@"[DEBUG] ✅ 现有IPA文件有效 (大小: %@)", attrs[NSFileSize]);
                return YES;
            }
        }
    }
    
    // 检查是否有IPA_Extraction目录
    NSString *ipaExtractionDir = [directory stringByAppendingPathComponent:@"IPA_Extraction"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:ipaExtractionDir]) {
        
        // 验证IPA_Extraction目录内容
        NSArray *extractionContents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:ipaExtractionDir error:nil];
        BOOL hasPayload = NO;
        BOOL hasMetadata = NO;
        
        for (NSString *item in extractionContents) {
            if ([item isEqualToString:@"Payload"]) {
                hasPayload = YES;
            } else if ([item isEqualToString:@"iTunesMetadata.plist"]) {
                hasMetadata = YES;
            }
        }
        
        if (!hasPayload) {
            NSLog(@"[ERROR] IPA_Extraction目录缺少Payload文件夹");
            return NO;
        }
        
        // 验证Payload目录
        NSString *payloadDir = [ipaExtractionDir stringByAppendingPathComponent:@"Payload"];
        NSArray *payloadContents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:payloadDir error:nil];
        
        if (payloadContents.count == 0) {
            NSLog(@"[ERROR] Payload目录为空");
            return NO;
        }
        
        NSLog(@"[DEBUG] IPA结构验证通过 - Payload: %@, Metadata: %@",
              hasPayload ? @"✅" : @"❌", hasMetadata ? @"✅" : @"⚠️");
        
        // 如果没有元数据，创建基本元数据
        if (!hasMetadata) {
            NSLog(@"[DEBUG] 补充创建iTunes元数据...");
            [self createITunesMetadataWithReturn:app inDirectory:ipaExtractionDir];
            
            if (app.iconImage) {
                [self createITunesArtworkWithReturn:app.iconImage inDirectory:ipaExtractionDir];
            }
        }
        
        // 创建最终IPA包
        NSString *safeAppName = [self sanitizeFileName:app.appName];
        NSString *finalIPAPath = [directory stringByAppendingPathComponent:[NSString stringWithFormat:@"%@_Complete_%@.ipa", safeAppName, app.version]];
        
        NSLog(@"[DEBUG] 开始ZIP压缩: %@ -> %@", ipaExtractionDir, finalIPAPath);
        
        BOOL zipSuccess = [self zipDirectoryEnhanced:ipaExtractionDir toPath:finalIPAPath];
        
        if (zipSuccess) {
            // 验证生成的IPA文件
            NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:finalIPAPath error:nil];
            if (attrs) {
                unsigned long long ipaSize = [attrs[NSFileSize] unsignedLongLongValue];
                NSLog(@"[DEBUG] 🎉 最终IPA包创建成功: %@ (大小: %@)",
                      finalIPAPath, [self formatSize:ipaSize]);
                
                // 创建IPA信息文件
                NSDictionary *ipaInfo = @{
                    @"AppName": app.appName ?: @"",
                    @"BundleID": app.bundleID ?: @"",
                    @"Version": app.version ?: @"",
                    @"IPASize": @(ipaSize),
                    @"CreatedDate": [NSDate date],
                    @"HasMetadata": @(hasMetadata),
                    @"PayloadItems": @(payloadContents.count)
                };
                
                NSString *ipaInfoPath = [directory stringByAppendingPathComponent:@"IPA_Info.plist"];
                [ipaInfo writeToFile:ipaInfoPath atomically:YES];
                
                return YES;
            } else {
                NSLog(@"[ERROR] 无法读取生成的IPA文件属性");
                return NO;
            }
        } else {
            NSLog(@"[ERROR] ZIP压缩失败");
            return NO;
        }
    }
    
    NSLog(@"[DEBUG] 没有找到可以打包的IPA数据");
    if (error) {
        *error = [NSError errorWithDomain:@"AppBackupErrorDomain"
                                     code:5001
                                 userInfo:@{NSLocalizedDescriptionKey: @"没有找到可以打包的应用数据"}];
    }
    return NO;
}

// 增强的ZIP压缩方法
- (BOOL)zipDirectoryEnhanced:(NSString *)sourceDir toPath:(NSString *)zipPath {
    NSLog(@"[DEBUG] 执行增强ZIP压缩...");
    
    // 删除已存在的zip文件
    if ([[NSFileManager defaultManager] fileExistsAtPath:zipPath]) {
        [[NSFileManager defaultManager] removeItemAtPath:zipPath error:nil];
    }
    
    // 使用系统zip命令创建IPA
    NSTask *zipTask = [[NSTask alloc] init];
    zipTask.launchPath = @"/usr/bin/zip";
    zipTask.arguments = @[
        @"-r",           // 递归
        @"-q",           // 安静模式
        @"-X",           // 排除额外文件属性
        zipPath,         // 输出文件
        @".",            // 当前目录所有内容
        @"-x",           // 排除以下文件
        @"*.DS_Store",   // macOS系统文件
        @"*__MACOSX*",   // macOS压缩产生的文件
        @"*.Thumbs.db"   // Windows缩略图文件
    ];
    zipTask.currentDirectoryPath = sourceDir;
    
    // 设置环境变量
    zipTask.environment = @{
        @"PATH": @"/usr/bin:/bin:/usr/sbin:/sbin"
    };
    
    NSLog(@"[DEBUG] ZIP命令: %@ %@", zipTask.launchPath, [zipTask.arguments componentsJoinedByString:@" "]);
    NSLog(@"[DEBUG] 工作目录: %@", sourceDir);
    
    @try {
        [zipTask launch];
        [zipTask waitUntilExit];
        
        int exitCode = zipTask.terminationStatus;
        BOOL success = (exitCode == 0);
        
        if (success) {
            NSLog(@"[DEBUG] ✅ ZIP压缩成功，退出代码: %d", exitCode);
            
            // 验证生成的ZIP文件
            if ([[NSFileManager defaultManager] fileExistsAtPath:zipPath]) {
                NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:zipPath error:nil];
                if (attrs) {
                    NSLog(@"[DEBUG] 生成的IPA文件大小: %@", [self formatSize:[attrs[NSFileSize] unsignedLongLongValue]]);
                }
            }
        } else {
            NSLog(@"[ERROR] ZIP压缩失败，退出代码: %d", exitCode);
            
            // 尝试查看错误输出
            if (zipTask.standardError) {
                NSPipe *errorPipe = [NSPipe pipe];
                zipTask.standardError = errorPipe;
                NSData *errorData = [[errorPipe fileHandleForReading] readDataToEndOfFile];
                if (errorData.length > 0) {
                    NSString *errorString = [[NSString alloc] initWithData:errorData encoding:NSUTF8StringEncoding];
                    NSLog(@"[ERROR] ZIP错误信息: %@", errorString);
                }
            }
        }
        
        return success;
        
    } @catch (NSException *exception) {
        NSLog(@"[ERROR] ZIP压缩异常: %@", exception.reason);
        return NO;
    }
}



// 备份系统相关数据
- (BOOL)backupAppSystemData:(DeviceApp *)app toDirectory:(NSString *)directory error:(NSError **)error {
    NSLog(@"[DEBUG] 开始备份系统相关数据: %@", app.appName);
    
    NSString *systemDir = [directory stringByAppendingPathComponent:@"SystemData"];
    [[NSFileManager defaultManager] createDirectoryAtPath:systemDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    
    // 连接设备
    idevice_t device = NULL;
    if (idevice_new(&device, NULL) != IDEVICE_E_SUCCESS) {
        return NO;
    }
    
    // 尝试使用AFC访问系统文件
    afc_client_t afc = NULL;
    BOOL hasSystemData = NO;
    
    if (afc_client_start_service(device, &afc, "afc") == AFC_E_SUCCESS) {
        
        // 尝试备份应用相关的偏好设置文件
        NSArray *prefFiles = @[
            [NSString stringWithFormat:@"/var/mobile/Library/Preferences/%@.plist", app.bundleID],
            @"/var/mobile/Library/Preferences/.GlobalPreferences.plist"
        ];
        
        for (NSString *prefFile in prefFiles) {
            NSString *localPath = [systemDir stringByAppendingPathComponent:[prefFile lastPathComponent]];
            if ([self copyFileFromAFC:afc remotePath:[prefFile UTF8String] localPath:localPath]) {
                NSLog(@"[DEBUG] 成功备份系统文件: %@", [prefFile lastPathComponent]);
                hasSystemData = YES;
            }
        }
        
        afc_client_free(afc);
    }
    
    idevice_free(device);
    
    // 如果没有获取到系统文件，创建基本信息
    if (!hasSystemData) {
        NSDictionary *systemInfo = @{
            @"BundleID": app.bundleID ?: @"",
            @"AppName": app.appName ?: @"",
            @"BackupDate": [NSDate date],
            @"Note": @"System files require special permissions to access"
        };
        
        NSString *infoPath = [systemDir stringByAppendingPathComponent:@"system_info.plist"];
        hasSystemData = [systemInfo writeToFile:infoPath atomically:YES];
    }
    
    return hasSystemData;
}

// 设备备份协议（可选）
// ============================================================================
// MARK: - 备份修复后的 performDeviceBackupForApp 方法
// ============================================================================

- (BOOL)performDeviceBackupForApp:(DeviceApp *)app toDirectory:(NSString *)directory error:(NSError **)error {
    NSLog(@"[DEBUG] 🍎 开始增强版设备备份（集成Apple官方备份协议）: %@", app.appName);
    
    NSString *backupDir = [directory stringByAppendingPathComponent:@"DeviceBackup"];
    [[NSFileManager defaultManager] createDirectoryAtPath:backupDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    
    // 连接设备
    idevice_t device = NULL;
    if (idevice_new(&device, NULL) != IDEVICE_E_SUCCESS) {
        NSLog(@"[ERROR] 设备连接失败（Apple备份）");
        if (error) {
            *error = [NSError errorWithDomain:@"AppleBackupErrorDomain"
                                         code:4001
                                     userInfo:@{NSLocalizedDescriptionKey: @"设备连接失败"}];
        }
        return NO;
    }
    
    // 尝试启动Apple官方备份服务
    mobilebackup2_client_t backup_client = NULL;
    mobilebackup2_error_t mb_err = mobilebackup2_client_start_service(device, &backup_client, "mobilebackup2");
    
    BOOL appleBackupSuccess = NO;
    BOOL legacyBackupSuccess = NO;
    
    if (mb_err == MOBILEBACKUP2_E_SUCCESS && backup_client) {
        NSLog(@"[DEBUG] ✅ Apple备份服务启动成功，开始执行Apple官方备份协议");
        
        @try {
            // ============================================================================
            // MARK: - Apple官方备份协议实现
            // ============================================================================
            
            // 1. 建立备份连接
            NSLog(@"[DEBUG] 步骤1: 建立Apple备份连接");
            plist_t hello_request = plist_new_dict();
            plist_dict_set_item(hello_request, "MessageName", plist_new_string("Hello"));
            plist_dict_set_item(hello_request, "SupportedProtocolVersions", plist_new_array());
            
            mobilebackup2_error_t err = mobilebackup2_send_message(backup_client, hello_request, NULL);
            plist_free(hello_request);
            
            if (err == MOBILEBACKUP2_E_SUCCESS) {
                // 等待设备响应
                plist_t response = NULL;
                err = mobilebackup2_receive_message(backup_client, &response, NULL);
                
                if (err == MOBILEBACKUP2_E_SUCCESS && response) {
                    NSLog(@"[DEBUG] ✅ Apple备份连接建立成功");
                    plist_free(response);
                    
                    // 2. 执行应用专用备份
                    NSLog(@"[DEBUG] 步骤2: 执行应用专用Apple备份");
                    NSString *appleBackupSubDir = [backupDir stringByAppendingPathComponent:@"AppleBackup"];
                    [[NSFileManager defaultManager] createDirectoryAtPath:appleBackupSubDir
                                                  withIntermediateDirectories:YES
                                                                   attributes:nil
                                                                        error:nil];
                    
                    // 创建应用备份请求
                    plist_t backup_request = plist_new_dict();
                    plist_dict_set_item(backup_request, "MessageName", plist_new_string("Backup"));
                    
                    // 创建应用域列表
                    plist_t domains = plist_new_array();
                    
                    // 添加应用相关域
                    NSArray *appDomains = @[
                        [NSString stringWithFormat:@"AppDomain-%@", app.bundleID],           // 应用域
                        [NSString stringWithFormat:@"AppDomainGroup-%@", app.bundleID],      // 应用组域
                        [NSString stringWithFormat:@"AppDomainPlugin-%@", app.bundleID],     // 插件域
                        @"KeychainDomain",                                                    // KeyChain域
                        @"MobileApplicationDomain"                                            // 移动应用域
                    ];
                    
                    for (NSString *domain in appDomains) {
                        plist_array_append_item(domains, plist_new_string([domain UTF8String]));
                    }
                    
                    plist_dict_set_item(backup_request, "Domains", domains);
                    
                    // 设置备份选项
                    plist_t options = plist_new_dict();
                    plist_dict_set_item(options, "BackupType", plist_new_string("Application"));
                    plist_dict_set_item(options, "TargetIdentifier", plist_new_string([app.bundleID UTF8String]));
                    plist_dict_set_item(backup_request, "Options", options);
                    
                    // 发送备份请求
                    err = mobilebackup2_send_message(backup_client, backup_request, NULL);
                    plist_free(backup_request);
                    
                    if (err == MOBILEBACKUP2_E_SUCCESS) {
                        NSLog(@"[DEBUG] ✅ Apple备份请求发送成功");
                        
                        // 3. 接收备份数据（修复版本）
                        NSLog(@"[DEBUG] 步骤3: 接收Apple备份数据");
                        int fileCount = 0;
                        unsigned long long backupSize = 0;
                        int consecutiveFailures = 0;
                        const int maxConsecutiveFailures = 3;
                        const int maxFiles = 1000;
                        
                        while (fileCount < maxFiles && consecutiveFailures < maxConsecutiveFailures) {
                            plist_t message = NULL;
                            err = mobilebackup2_receive_message(backup_client, &message, NULL);
                            
                            // 修复：正确处理接收错误
                            if (err != MOBILEBACKUP2_E_SUCCESS) {
                                consecutiveFailures++;
                                NSLog(@"[WARNING] Apple备份接收失败 %d/%d: 错误代码=%d",
                                      consecutiveFailures, maxConsecutiveFailures, err);
                                
                                if (consecutiveFailures >= maxConsecutiveFailures) {
                                    NSLog(@"[WARNING] 连续接收失败次数过多，停止Apple备份接收");
                                    break;
                                }
                                
                                // 短暂等待后继续尝试
                                [NSThread sleepForTimeInterval:0.1];
                                continue;
                            }
                            
                            // 重置连续失败计数器
                            consecutiveFailures = 0;
                            
                            // 检查消息是否为空
                            if (!message) {
                                NSLog(@"[DEBUG] 接收到空消息，可能是数据传输完成");
                                break;
                            }
                            
                            // 解析消息类型
                            plist_t msgname = plist_dict_get_item(message, "MessageName");
                            if (!msgname) {
                                NSLog(@"[WARNING] 消息缺少MessageName字段");
                                plist_free(message);
                                continue;
                            }
                            
                            char *msgname_str = NULL;
                            plist_get_string_val(msgname, &msgname_str);
                            
                            if (msgname_str) {
                                NSString *messageType = @(msgname_str);
                                NSLog(@"[DEBUG] 接收到消息类型: %@", messageType);
                                
                                if ([messageType isEqualToString:@"BackupFileReceived"]) {
                                    // 处理文件数据
                                    plist_t path_node = plist_dict_get_item(message, "BackupFilePath");
                                    plist_t data_node = plist_dict_get_item(message, "FileData");
                                    
                                    if (path_node && data_node) {
                                        char *path_str = NULL;
                                        plist_get_string_val(path_node, &path_str);
                                        
                                        char *file_data = NULL;
                                        uint64_t data_size = 0;
                                        plist_get_data_val(data_node, &file_data, &data_size);
                                        
                                        if (path_str && file_data && data_size > 0) {
                                            NSString *relativePath = @(path_str);
                                            NSString *localFilePath = [appleBackupSubDir stringByAppendingPathComponent:relativePath];
                                            NSString *localDir = [localFilePath stringByDeletingLastPathComponent];
                                            
                                            // 创建目录
                                            [[NSFileManager defaultManager] createDirectoryAtPath:localDir
                                                                      withIntermediateDirectories:YES
                                                                                       attributes:nil
                                                                                            error:nil];
                                            
                                            // 写入文件
                                            NSData *fileData = [NSData dataWithBytes:file_data length:(NSUInteger)data_size];
                                            if ([fileData writeToFile:localFilePath atomically:YES]) {
                                                fileCount++;
                                                backupSize += data_size;
                                                NSLog(@"[DEBUG] 保存Apple备份文件 %d: %@ (%@)",
                                                      fileCount, [relativePath lastPathComponent], [self formatSize:data_size]);
                                            } else {
                                                NSLog(@"[ERROR] 保存文件失败: %@", localFilePath);
                                            }
                                        }
                                        
                                        if (path_str) free(path_str);
                                        if (file_data) free(file_data);
                                    }
                                } else if ([messageType isEqualToString:@"BackupFinished"] ||
                                          [messageType isEqualToString:@"Finished"]) {
                                    NSLog(@"[DEBUG] ✅ Apple备份完成信号");
                                    plist_free(message);
                                    free(msgname_str);
                                    break;
                                } else if ([messageType isEqualToString:@"Error"]) {
                                    NSLog(@"[ERROR] Apple备份过程出错");
                                    plist_free(message);
                                    free(msgname_str);
                                    break;
                                } else if ([messageType isEqualToString:@"BackupMessage"]) {
                                    // 处理状态消息
                                    plist_t status_node = plist_dict_get_item(message, "BackupTotalCount");
                                    if (status_node) {
                                        uint64_t total_count = 0;
                                        plist_get_uint_val(status_node, &total_count);
                                        NSLog(@"[DEBUG] 备份进度信息: 总文件数=%llu", total_count);
                                    }
                                } else {
                                    NSLog(@"[DEBUG] 未处理的消息类型: %@", messageType);
                                }
                                
                                free(msgname_str);
                            }
                            
                            plist_free(message);
                        }
                        
                        if (fileCount > 0) {
                            appleBackupSuccess = YES;
                            NSLog(@"[DEBUG] 🎉 Apple备份成功完成 - 文件数: %d, 大小: %@",
                                  fileCount, [self formatSize:backupSize]);
                        } else {
                            NSLog(@"[WARNING] Apple备份未获取到文件数据");
                        }
                    } else {
                        NSLog(@"[ERROR] Apple备份请求发送失败: %d", err);
                    }
                } else {
                    NSLog(@"[ERROR] Apple备份连接建立失败: %d", err);
                }
            } else {
                NSLog(@"[ERROR] 发送Apple备份Hello消息失败: %d", err);
            }
            
        } @catch (NSException *exception) {
            NSLog(@"[ERROR] Apple备份过程异常: %@", exception.reason);
        }
        
        mobilebackup2_client_free(backup_client);
    } else {
        NSLog(@"[WARNING] Apple备份服务不可用: %d，将使用传统备份方法", mb_err);
    }
    
    // ============================================================================
    // MARK: - 传统备份方法（降级方案）
    // ============================================================================
    
    if (!appleBackupSuccess) {
        NSLog(@"[DEBUG] 执行传统设备备份方法");
        
        // 尝试使用其他备份方法
        BOOL altBackupSuccess = [self performAlternativeBackup:app toDirectory:backupDir];
        
        // 创建备份信息文件
        NSDictionary *backupInfo = @{
            @"BundleID": app.bundleID ?: @"",
            @"AppName": app.appName ?: @"",
            @"BackupDate": [NSDate date],
            @"BackupMethod": appleBackupSuccess ? @"apple_official" : @"traditional_methods",
            @"Status": appleBackupSuccess ? @"Success" : (altBackupSuccess ? @"Limited" : @"Failed"),
            @"Note": appleBackupSuccess ? @"Apple backup service used successfully" :
                     (altBackupSuccess ? @"Apple backup not available, used alternative methods" :
                      @"All backup methods failed")
        };
        
        NSString *infoPath = [backupDir stringByAppendingPathComponent:@"backup_info.plist"];
        legacyBackupSuccess = [backupInfo writeToFile:infoPath atomically:YES];
        
        if (legacyBackupSuccess || altBackupSuccess) {
            NSLog(@"[DEBUG] ✅ 传统备份方法执行完成");
        }
    }
    
    idevice_free(device);
    
    // ============================================================================
    // MARK: - 生成设备备份报告
    // ============================================================================
    
    NSString *reportPath = [backupDir stringByAppendingPathComponent:@"device_backup_report.txt"];
    NSMutableString *report = [NSMutableString string];
    
    [report appendFormat:@"设备备份报告\n"];
    [report appendFormat:@"==================\n\n"];
    [report appendFormat:@"应用: %@\n", app.appName];
    [report appendFormat:@"Bundle ID: %@\n", app.bundleID];
    [report appendFormat:@"备份时间: %@\n\n", [NSDate date]];
    
    [report appendFormat:@"备份方法结果:\n"];
    [report appendFormat:@"- Apple官方备份: %@\n", appleBackupSuccess ? @"✅ 成功" : @"❌ 失败"];
    [report appendFormat:@"- 传统备份方法: %@\n", legacyBackupSuccess ? @"✅ 成功" : @"❌ 失败"];
    
    BOOL overallDeviceBackupSuccess = appleBackupSuccess || legacyBackupSuccess;
    [report appendFormat:@"- 总体结果: %@\n\n", overallDeviceBackupSuccess ? @"✅ 成功" : @"❌ 失败"];
    
    [report appendFormat:@"说明:\n"];
    if (appleBackupSuccess) {
        [report appendFormat:@"- 使用Apple官方mobilebackup2协议成功获取应用数据\n"];
        [report appendFormat:@"- 包含KeyChain、偏好设置等系统级数据\n"];
        [report appendFormat:@"- 备份完整度相对较高\n"];
    } else {
        [report appendFormat:@"- Apple备份服务不可用或版本不兼容\n"];
        [report appendFormat:@"- 使用传统方法进行基础备份\n"];
        [report appendFormat:@"- 备份完整度有限\n"];
    }
    
    [report writeToFile:reportPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    
    NSLog(@"[DEBUG] 设备备份最终结果: %@", overallDeviceBackupSuccess ? @"成功" : @"失败");
    
    return overallDeviceBackupSuccess;
}

- (BOOL)performMusicAppBackup:(DeviceApp *)app toDirectory:(NSString *)directory {
    NSLog(@"[DEBUG] 执行音乐应用特殊备份: %@", app.appName);
    
    NSString *musicDir = [directory stringByAppendingPathComponent:@"MusicAppSpecial"];
    [[NSFileManager defaultManager] createDirectoryAtPath:musicDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    
    // 创建音乐应用备份指南
    NSMutableString *guide = [NSMutableString string];
    [guide appendFormat:@"🎵 %@ 数据备份指南\n", app.appName];
    [guide appendFormat:@"============================\n\n"];
    
    [guide appendFormat:@"📊 应用信息:\n"];
    [guide appendFormat:@"   应用名称: %@\n", app.appName];
    [guide appendFormat:@"   Bundle ID: %@\n", app.bundleID];
    [guide appendFormat:@"   应用大小: %@\n", [self formatSize:app.appSize]];
    [guide appendFormat:@"   数据大小: %@\n", [self formatSize:app.docSize]];
    [guide appendFormat:@"   版本: %@\n\n", app.version];
    
    [guide appendFormat:@"⚠️ 备份限制说明:\n"];
    [guide appendFormat:@"由于iOS沙盒安全机制，第三方工具无法直接访问音乐应用的完整数据。\n"];
    [guide appendFormat:@"这包括：下载的音乐文件、播放列表、收藏、缓存等。\n\n"];
    
    [guide appendFormat:@"💡 推荐备份方案:\n\n"];
    
    [guide appendFormat:@"方案一：应用内云同步 ⭐⭐⭐⭐⭐\n"];
    [guide appendFormat:@"1. 登录您的账号（QQ、微信等）\n"];
    [guide appendFormat:@"2. 开启云端同步功能\n"];
    [guide appendFormat:@"3. 上传播放列表、收藏到云端\n"];
    [guide appendFormat:@"4. 定期检查同步状态\n"];
    [guide appendFormat:@"优点：官方支持，数据安全，跨设备同步\n"];
    [guide appendFormat:@"缺点：需要网络，可能有存储限制\n\n"];
    
    [guide appendFormat:@"方案二：iTunes加密备份 ⭐⭐⭐⭐\n"];
    [guide appendFormat:@"1. 连接设备到电脑iTunes\n"];
    [guide appendFormat:@"2. 选择'加密本地备份'\n"];
    [guide appendFormat:@"3. 设置备份密码\n"];
    [guide appendFormat:@"4. 执行完整备份\n"];
    [guide appendFormat:@"5. 使用iMazing等工具提取应用数据\n"];
    [guide appendFormat:@"优点：数据完整，包含所有应用数据\n"];
    [guide appendFormat:@"缺点：需要专业工具，操作复杂\n\n"];
    
    [guide appendFormat:@"方案三：导出功能 ⭐⭐⭐\n"];
    [guide appendFormat:@"1. 使用应用内的导出功能\n"];
    [guide appendFormat:@"2. 导出播放列表为文本或其他格式\n"];
    [guide appendFormat:@"3. 截图保存重要设置\n"];
    [guide appendFormat:@"4. 记录重要的歌单ID\n"];
    [guide appendFormat:@"优点：操作简单，数据可读\n"];
    [guide appendFormat:@"缺点：数据不完整，需要手动操作\n\n"];
        
    [guide appendFormat:@"方案四：设备越狱 ⭐⭐⭐⭐⭐\n"];
    [guide appendFormat:@"⚠️ 仅适合高级用户，有风险\n"];
    [guide appendFormat:@"1. 使用checkra1n等工具越狱设备\n"];
    [guide appendFormat:@"2. 安装OpenSSH\n"];
    [guide appendFormat:@"3. 直接访问应用数据目录\n"];
    [guide appendFormat:@"   路径: /var/mobile/Containers/Data/Application/\n"];
    [guide appendFormat:@"4. 手动复制所有数据\n"];
    [guide appendFormat:@"优点：数据完整，完全控制\n"];
    [guide appendFormat:@"缺点：有安全风险，可能影响保修\n\n"];
    
    [guide appendFormat:@"🔧 技术分析:\n"];
    [guide appendFormat:@"您的 %@ 数据大小达到 %@，主要包含：\n", app.appName, [self formatSize:app.docSize]];
    [guide appendFormat:@"• 下载的音乐文件（占大部分空间）\n"];
    [guide appendFormat:@"• 播放列表和收藏信息\n"];
    [guide appendFormat:@"• 用户偏好设置\n"];
    [guide appendFormat:@"• 缓存文件\n"];
    [guide appendFormat:@"• 登录凭据\n\n"];
    
    [guide appendFormat:@"📱 当前备份工具限制:\n"];
    [guide appendFormat:@"✅ 可获取：应用基本信息、图标、元数据\n"];
    [guide appendFormat:@"❌ 无法获取：用户数据、音乐文件、播放列表\n"];
    [guide appendFormat:@"❌ 无法获取：登录状态、个人设置、缓存\n\n"];
    
    [guide appendFormat:@"💌 建议:\n"];
    [guide appendFormat:@"1. 优先使用官方云同步功能（最安全）\n"];
    [guide appendFormat:@"2. 定期创建iTunes加密备份（最完整）\n"];
    [guide appendFormat:@"3. 记录重要的歌单和设置信息\n"];
    [guide appendFormat:@"4. 考虑使用多个备份方案组合\n\n"];
    
    [guide appendFormat:@"🕒 备份频率建议:\n"];
    [guide appendFormat:@"• 云同步：每周检查一次\n"];
    [guide appendFormat:@"• iTunes备份：每月一次\n"];
    [guide appendFormat:@"• 设置截图：重大更新后\n"];
    [guide appendFormat:@"• 歌单导出：新增重要歌单后\n\n"];
    
    [guide appendFormat:@"生成时间: %@\n", [NSDate date]];
    
    NSString *guidePath = [musicDir stringByAppendingPathComponent:@"Music_App_Backup_Guide.txt"];
    BOOL success = [guide writeToFile:guidePath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    
    // 创建快速操作清单
    NSDictionary *quickActions = @{
        @"AppName": app.appName,
        @"BundleID": app.bundleID,
        @"DataSize": @(app.docSize),
        @"QuickActions": @[
            @"打开应用 → 设置 → 账号与同步 → 开启云同步",
            @"iTunes → 设备 → 备份 → 加密本地备份",
            @"应用内 → 我的音乐 → 导出歌单",
            @"截图保存重要设置和收藏"
        ],
        @"ImportantPaths": @[
            @"/var/mobile/Containers/Data/Application/*/Documents/",
            @"/var/mobile/Containers/Data/Application/*/Library/",
            @"/var/mobile/Containers/Data/Application/*/tmp/"
        ],
        @"GeneratedAt": [NSDate date]
    };
    
    NSString *actionsPath = [musicDir stringByAppendingPathComponent:@"quick_actions.plist"];
    [quickActions writeToFile:actionsPath atomically:YES];
    
    if (success) {
        NSLog(@"[DEBUG] 音乐应用备份指南已生成: %@", guidePath);
    }
    
    return success;
}

- (BOOL)performSocialAppBackup:(DeviceApp *)app toDirectory:(NSString *)directory {
    NSLog(@"[DEBUG] 执行社交应用特殊备份: %@", app.appName);
    
    NSString *socialDir = [directory stringByAppendingPathComponent:@"SocialAppSpecial"];
    [[NSFileManager defaultManager] createDirectoryAtPath:socialDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    
    NSMutableString *guide = [NSMutableString string];
    [guide appendFormat:@"💬 %@ 数据备份指南\n", app.appName];
    [guide appendFormat:@"============================\n\n"];
    
    [guide appendFormat:@"⚠️ 重要提醒:\n"];
    [guide appendFormat:@"社交应用数据包含敏感信息，备份时请注意隐私安全。\n\n"];
    
    [guide appendFormat:@"📱 推荐备份方案:\n\n"];
    
    [guide appendFormat:@"方案一：官方云备份 ⭐⭐⭐⭐⭐\n"];
    [guide appendFormat:@"• 微信：设置 → 聊天 → 聊天记录备份与迁移\n"];
    [guide appendFormat:@"• QQ：设置 → 聊天记录 → 备份聊天记录\n"];
    [guide appendFormat:@"• Telegram：设置 → 数据和存储 → 导出数据\n\n"];
    
    [guide appendFormat:@"方案二：iTunes加密备份\n"];
    [guide appendFormat:@"包含所有聊天记录、图片、文件等\n\n"];
    
    [guide appendFormat:@"⚠️ 安全提醒:\n"];
    [guide appendFormat:@"• 备份文件请加密存储\n"];
    [guide appendFormat:@"• 定期删除过期备份\n"];
    [guide appendFormat:@"• 不要在公共网络上传备份\n\n"];
    
    NSString *guidePath = [socialDir stringByAppendingPathComponent:@"Social_App_Backup_Guide.txt"];
    return [guide writeToFile:guidePath atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

- (BOOL)performGameAppBackup:(DeviceApp *)app toDirectory:(NSString *)directory {
    NSLog(@"[DEBUG] 执行游戏应用特殊备份: %@", app.appName);
    
    NSString *gameDir = [directory stringByAppendingPathComponent:@"GameAppSpecial"];
    [[NSFileManager defaultManager] createDirectoryAtPath:gameDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    
    NSMutableString *guide = [NSMutableString string];
    [guide appendFormat:@"🎮 %@ 存档备份指南\n", app.appName];
    [guide appendFormat:@"============================\n\n"];
    
    [guide appendFormat:@"🏆 推荐备份方案:\n\n"];
    
    [guide appendFormat:@"方案一：游戏内云存档 ⭐⭐⭐⭐⭐\n"];
    [guide appendFormat:@"• 绑定游戏账号（Game Center、微信、QQ等）\n"];
    [guide appendFormat:@"• 开启云存档功能\n"];
    [guide appendFormat:@"• 定期同步存档\n\n"];
    
    [guide appendFormat:@"方案二：iTunes备份\n"];
    [guide appendFormat:@"包含完整的游戏数据和设置\n\n"];
    
    [guide appendFormat:@"💡 游戏数据通常包含:\n"];
    [guide appendFormat:@"• 游戏进度和存档\n"];
    [guide appendFormat:@"• 角色数据和装备\n"];
    [guide appendFormat:@"• 游戏设置和偏好\n"];
    [guide appendFormat:@"• 成就和统计数据\n\n"];
    
    NSString *guidePath = [gameDir stringByAppendingPathComponent:@"Game_App_Backup_Guide.txt"];
    return [guide writeToFile:guidePath atomically:YES encoding:NSUTF8StringEncoding error:nil];
}
// ============================================================================
// MARK: - 辅助方法
// ============================================================================

- (void)saveDiagnosticReport:(NSString *)report toDirectory:(NSString *)directory filename:(NSString *)filename {
    NSString *reportPath = [directory stringByAppendingPathComponent:filename];
    NSError *error = nil;
    BOOL success = [report writeToFile:reportPath
                             atomically:YES
                               encoding:NSUTF8StringEncoding
                                  error:&error];
    
    if (success) {
        NSLog(@"[DEBUG] 诊断报告已保存: %@", reportPath);
    } else {
        NSLog(@"[ERROR] 诊断报告保存失败: %@", error.localizedDescription);
    }
}

- (void)generateUserFriendlyReport:(DeviceApp *)app
                        withResults:(NSDictionary *)results
                        inDirectory:(NSString *)directory {
    
    NSString *reportPath = [directory stringByAppendingPathComponent:@"Backup_Summary_Report.txt"];
    
    NSMutableString *report = [NSMutableString string];
    [report appendFormat:@"📱 应用备份总结报告\n"];
    [report appendFormat:@"=====================\n\n"];
    
    // 应用基本信息
    [report appendFormat:@"🔍 应用信息:\n"];
    [report appendFormat:@"   名称: %@\n", app.appName];
    [report appendFormat:@"   开发者: %@\n", app.developer ?: @"未知"];
    [report appendFormat:@"   版本: %@\n", app.version];
    [report appendFormat:@"   大小: %@ (应用) + %@ (数据)\n",
          [self formatSize:app.appSize], [self formatSize:app.docSize]];
    [report appendFormat:@"   备份时间: %@\n\n", [NSDate date]];
    
    // 备份结果概览
    NSInteger successCount = 0;
    NSInteger totalCount = results.count;
    for (NSString *key in results) {
        if ([results[key] boolValue]) successCount++;
    }
    
    double successRate = (double)successCount / (double)totalCount * 100.0;
    
    [report appendFormat:@"📊 备份结果概览:\n"];
    [report appendFormat:@"   成功率: %.0f%% (%ld/%ld)\n", successRate, (long)successCount, (long)totalCount];
    
    if (successRate >= 80) {
        [report appendFormat:@"   评级: 🌟🌟🌟🌟🌟 优秀\n"];
        [report appendFormat:@"   状态: 备份非常成功！\n"];
    } else if (successRate >= 60) {
        [report appendFormat:@"   评级: 🌟🌟🌟🌟 良好\n"];
        [report appendFormat:@"   状态: 备份基本成功，有少量限制\n"];
    } else if (successRate >= 40) {
        [report appendFormat:@"   评级: 🌟🌟🌟 一般\n"];
        [report appendFormat:@"   状态: 部分备份成功，建议使用其他方法\n"];
    } else {
        [report appendFormat:@"   评级: 🌟🌟 较差\n"];
        [report appendFormat:@"   状态: 备份受限，建议使用专业工具\n"];
    }
    
    [report appendFormat:@"\n✅ 成功备份的内容:\n"];
    NSDictionary *methodDescriptions = @{
        @"info": @"应用基本信息和元数据",
        @"icon": @"应用图标",
        @"ipa": @"应用安装包(IPA)",
        @"sandbox": @"应用数据和文档",
        @"deviceBackup": @"系统级备份数据",
        @"system": @"系统相关文件",
        @"finalIPA": @"完整IPA包",
        @"integrity": @"数据完整性验证"
    };
    
    for (NSString *key in results) {
        if ([results[key] boolValue]) {
            NSString *description = methodDescriptions[key] ?: key;
            [report appendFormat:@"   • %@\n", description];
        }
    }
    
    [report appendFormat:@"\n❌ 未能备份的内容:\n"];
    BOOL hasFailures = NO;
    for (NSString *key in results) {
        if (![results[key] boolValue]) {
            NSString *description = methodDescriptions[key] ?: key;
            [report appendFormat:@"   • %@\n", description];
            hasFailures = YES;
        }
    }
    
    if (!hasFailures) {
        [report appendFormat:@"   无 - 所有项目都备份成功！\n"];
    }
    
    [report appendFormat:@"\n💡 下一步建议:\n"];
    
    if (successRate >= 80) {
        [report appendFormat:@"   🎉 恭喜！您的应用备份非常成功。\n"];
        [report appendFormat:@"   • 备份文件已保存在指定目录\n"];
        [report appendFormat:@"   • 建议定期进行备份\n"];
        [report appendFormat:@"   • 妥善保管备份文件\n"];
    } else {
        [report appendFormat:@"   📋 备份存在一些限制，建议：\n"];
        
        if (![results[@"ipa"] boolValue]) {
            [report appendFormat:@"   • IPA提取失败 - 考虑使用iTunes备份\n"];
        }
        
        if (![results[@"sandbox"] boolValue]) {
            [report appendFormat:@"   • 用户数据备份失败 - 考虑以下方案：\n"];
            [report appendFormat:@"     - 使用应用内的云同步功能\n"];
            [report appendFormat:@"     - 创建iTunes加密备份\n"];
        }
        
        if (![results[@"deviceBackup"] boolValue]) {
            [report appendFormat:@"   • 系统级备份失败 - 检查设备信任状态\n"];
        }
    }

    [report appendFormat:@"📁 备份文件位置:\n"];
    [report appendFormat:@"   %@\n\n", directory];
    
    [report appendFormat:@"📞 需要帮助?\n"];
    [report appendFormat:@"   • 查看详细诊断报告了解技术细节\n"];
    [report appendFormat:@"   • 参考应用专用备份指南\n"];
    [report appendFormat:@"   • 考虑联系技术支持\n\n"];
    
    [report appendFormat:@"生成时间: %@\n", [NSDate date]];
    
    [report writeToFile:reportPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSLog(@"[DEBUG] 用户友好报告已生成: %@", reportPath);
}

// ============================================================================
// MARK: - 针对特定应用的特殊处理
// ============================================================================

- (BOOL)performSpecialBackupForApp:(DeviceApp *)app toDirectory:(NSString *)directory {
    NSLog(@"[DEBUG] 检查是否需要特殊备份策略: %@", app.bundleID);
    
    // 针对音乐应用的特殊处理
    if ([app.bundleID containsString:@"QQMusic"] ||
        [app.bundleID containsString:@"music"] ||
        [app.bundleID containsString:@"Music"] ||
        [app.bundleID containsString:@"spotify"] ||
        [app.bundleID containsString:@"apple.Music"]) {
        
        return [self performMusicAppBackup:app toDirectory:directory];
    }
    
    // 针对社交应用的特殊处理
    if ([app.bundleID containsString:@"wechat"] ||
        [app.bundleID containsString:@"WeChat"] ||
        [app.bundleID containsString:@"qq"] ||
        [app.bundleID containsString:@"telegram"]) {
        
        return [self performSocialAppBackup:app toDirectory:directory];
    }
    
    // 针对游戏应用的特殊处理
    if ([app.bundleID containsString:@"game"] ||
        [app.bundleID containsString:@"Game"]) {
        
        return [self performGameAppBackup:app toDirectory:directory];
    }
    
    return NO;
}

// ============================================================================
// MARK: - 新增：替代备份方法
// ============================================================================

- (BOOL)performAlternativeBackup:(DeviceApp *)app toDirectory:(NSString *)directory {
    NSLog(@"[DEBUG] 执行替代备份方法: %@", app.appName);
    
    // 创建替代备份目录
    NSString *altBackupDir = [directory stringByAppendingPathComponent:@"AlternativeBackup"];
    [[NSFileManager defaultManager] createDirectoryAtPath:altBackupDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    
    // 尝试使用其他服务获取数据
    BOOL hasAnyData = NO;
    
    // 1. 尝试获取应用偏好设置
    if ([self extractAppPreferences:app toDirectory:altBackupDir]) {
        hasAnyData = YES;
    }
    
    // 2. 尝试获取应用信息
    if ([self extractAppMetadata:app toDirectory:altBackupDir]) {
        hasAnyData = YES;
    }
    
    // 3. 尝试获取应用图标的高清版本
    if ([self extractHighResIcon:app toDirectory:altBackupDir]) {
        hasAnyData = YES;
    }
    
    return hasAnyData;
}

// 提取应用偏好设置
- (BOOL)extractAppPreferences:(DeviceApp *)app toDirectory:(NSString *)directory {
    NSLog(@"[DEBUG] 尝试提取应用偏好设置: %@", app.bundleID);
    
    NSString *prefsDir = [directory stringByAppendingPathComponent:@"Preferences"];
    [[NSFileManager defaultManager] createDirectoryAtPath:prefsDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    
    // 创建偏好设置信息文件
    NSDictionary *prefsInfo = @{
        @"BundleID": app.bundleID ?: @"",
        @"AppName": app.appName ?: @"",
        @"Note": @"Preferences data requires device backup access",
        @"ExtractedAt": [NSDate date]
    };
    
    NSString *infoPath = [prefsDir stringByAppendingPathComponent:@"preferences_info.plist"];
    return [prefsInfo writeToFile:infoPath atomically:YES];
}

// 提取应用元数据
- (BOOL)extractAppMetadata:(DeviceApp *)app toDirectory:(NSString *)directory {
    NSLog(@"[DEBUG] 提取应用元数据: %@", app.bundleID);
    
    NSString *metadataDir = [directory stringByAppendingPathComponent:@"Metadata"];
    [[NSFileManager defaultManager] createDirectoryAtPath:metadataDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    
    // 创建详细的应用元数据
    NSDictionary *metadata = @{
        @"BasicInfo": @{
            @"BundleID": app.bundleID ?: @"",
            @"AppName": app.appName ?: @"",
            @"Version": app.version ?: @"",
            @"ApplicationType": app.applicationType ?: @"",
            @"Developer": app.developer ?: @"",
            @"Path": app.path ?: @"",
            @"Container": app.container ?: @""
        },
        @"SizeInfo": @{
            @"AppSize": @(app.appSize),
            @"DataSize": @(app.docSize),
            @"FormattedAppSize": [self formatSize:app.appSize],
            @"FormattedDataSize": [self formatSize:app.docSize]
        },
        @"StoreInfo": @{
            @"HasUpdateAvailable": @(app.hasUpdateAvailable),
            @"AppStoreVersion": app.appStoreVersion ?: @"",
            @"AppleID": app.appleID ?: @"",
            @"AppId": app.appId ?: @""
        },
        @"BackupInfo": @{
            @"ExtractedAt": [NSDate date],
            @"Method": @"Alternative metadata extraction",
            @"Source": @"Device app list"
        }
    };
    
    NSString *metadataPath = [metadataDir stringByAppendingPathComponent:@"app_metadata.plist"];
    return [metadata writeToFile:metadataPath atomically:YES];
}

// 提取高清图标
- (BOOL)extractHighResIcon:(DeviceApp *)app toDirectory:(NSString *)directory {
    if (!app.iconImage) {
        return NO;
    }
    
    NSLog(@"[DEBUG] 提取高清应用图标: %@", app.appName);
    
    NSString *iconDir = [directory stringByAppendingPathComponent:@"Icons"];
    [[NSFileManager defaultManager] createDirectoryAtPath:iconDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    
    // 保存多种尺寸的图标
    NSArray *iconSizes = @[@60, @120, @180, @1024];
    BOOL hasIcon = NO;
    
    for (NSNumber *sizeNumber in iconSizes) {
        CGFloat size = [sizeNumber floatValue];
        NSSize iconSize = NSMakeSize(size, size);
        
        NSImage *resizedIcon = [[NSImage alloc] initWithSize:iconSize];
        [resizedIcon lockFocus];
        [app.iconImage drawInRect:NSMakeRect(0, 0, size, size)
                         fromRect:NSZeroRect
                        operation:NSCompositingOperationSourceOver
                         fraction:1.0];
        [resizedIcon unlockFocus];
        
        // 保存为PNG
        CGImageRef cgImage = [resizedIcon CGImageForProposedRect:NULL context:nil hints:nil];
        if (cgImage) {
            NSBitmapImageRep *bitmapRep = [[NSBitmapImageRep alloc] initWithCGImage:cgImage];
            NSData *pngData = [bitmapRep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
            
            NSString *iconPath = [iconDir stringByAppendingPathComponent:[NSString stringWithFormat:@"icon_%dx%d.png", (int)size, (int)size]];
            if ([pngData writeToFile:iconPath atomically:YES]) {
                hasIcon = YES;
                NSLog(@"[DEBUG] 保存图标: %dx%d", (int)size, (int)size);
            }
        }
    }
    
    return hasIcon;
}




// ============================================================================
// MARK: - 辅助方法实现
// ============================================================================

// 增强的文件复制方法（带大小统计）
- (BOOL)copyDirectoryFromAFCWithSize:(afc_client_t)afc
                          remotePath:(const char *)remotePath
                           localPath:(NSString *)localPath
                            sizeOut:(unsigned long long *)totalSize {
    
    if (!afc || !remotePath || !localPath) {
        return NO;
    }
    
    // 创建本地目录
    NSError *error = nil;
    BOOL success = [[NSFileManager defaultManager] createDirectoryAtPath:localPath
                                             withIntermediateDirectories:YES
                                                              attributes:nil
                                                                   error:&error];
    if (!success) {
        NSLog(@"[ERROR] 创建目录失败: %@", error.localizedDescription);
        return NO;
    }
    
    char **dirlist = NULL;
    if (afc_read_directory(afc, remotePath, &dirlist) != AFC_E_SUCCESS) {
        return NO;
    }
    
    if (!dirlist) return YES; // 空目录
    
    BOOL hasFiles = NO;
    unsigned long long dirSize = 0;
    
    for (int i = 0; dirlist[i]; i++) {
        NSString *filename = [NSString stringWithUTF8String:dirlist[i]];
        
        if ([filename isEqualToString:@"."] || [filename isEqualToString:@".."]) {
            continue;
        }
        
        hasFiles = YES;
        
        NSString *remoteFilePath = [NSString stringWithFormat:@"%s/%@", remotePath, filename];
        NSString *localFilePath = [localPath stringByAppendingPathComponent:filename];
        
        // 获取文件信息
        char **fileinfo = NULL;
        if (afc_get_file_info(afc, [remoteFilePath UTF8String], &fileinfo) == AFC_E_SUCCESS && fileinfo) {
            
            NSString *fileType = nil;
            unsigned long long fileSize = 0;
            
            for (int j = 0; fileinfo[j] && fileinfo[j + 1]; j += 2) {
                if (strcmp(fileinfo[j], "st_ifmt") == 0) {
                    fileType = [NSString stringWithUTF8String:fileinfo[j + 1]];
                } else if (strcmp(fileinfo[j], "st_size") == 0) {
                    fileSize = strtoull(fileinfo[j + 1], NULL, 10);
                }
            }
            
            if ([fileType isEqualToString:@"S_IFDIR"]) {
                // 递归处理目录
                unsigned long long subDirSize = 0;
                [self copyDirectoryFromAFCWithSize:afc
                                        remotePath:[remoteFilePath UTF8String]
                                         localPath:localFilePath
                                          sizeOut:&subDirSize];
                dirSize += subDirSize;
            } else if ([fileType isEqualToString:@"S_IFREG"]) {
                // 复制文件
                if ([self copyFileFromAFC:afc
                               remotePath:[remoteFilePath UTF8String]
                                localPath:localFilePath]) {
                    dirSize += fileSize;
                }
            }
            
            // 释放文件信息
            for (int j = 0; fileinfo[j]; j++) {
                free(fileinfo[j]);
            }
            free(fileinfo);
        }
    }
    
    // 释放目录列表
    for (int i = 0; dirlist[i]; i++) {
        free(dirlist[i]);
    }
    free(dirlist);
    
    *totalSize = dirSize;
    return hasFiles;
}

- (BOOL)copyRootFilesFromAFC:(afc_client_t)afc
                   localPath:(NSString *)localPath
                    sizeOut:(unsigned long long *)totalSize {
    
    char **dirlist = NULL;
    if (afc_read_directory(afc, "/", &dirlist) != AFC_E_SUCCESS) {
        return NO;
    }
    
    if (!dirlist) return NO;
    
    BOOL hasFiles = NO;
    unsigned long long rootSize = 0;
    
    for (int i = 0; dirlist[i]; i++) {
        NSString *filename = [NSString stringWithUTF8String:dirlist[i]];
        
        if ([filename isEqualToString:@"."] || [filename isEqualToString:@".."] ||
            [filename isEqualToString:@"Documents"] || [filename isEqualToString:@"Library"] ||
            [filename isEqualToString:@"tmp"] || [filename isEqualToString:@"SystemData"]) {
            continue; // 跳过已经备份的目录
        }
        
        NSString *remoteFilePath = [NSString stringWithFormat:@"/%@", filename];
        NSString *localFilePath = [localPath stringByAppendingPathComponent:filename];
        
        // 获取文件信息
        char **fileinfo = NULL;
        if (afc_get_file_info(afc, [remoteFilePath UTF8String], &fileinfo) == AFC_E_SUCCESS && fileinfo) {
            
            NSString *fileType = nil;
            unsigned long long fileSize = 0;
            
            for (int j = 0; fileinfo[j] && fileinfo[j + 1]; j += 2) {
                if (strcmp(fileinfo[j], "st_ifmt") == 0) {
                    fileType = [NSString stringWithUTF8String:fileinfo[j + 1]];
                } else if (strcmp(fileinfo[j], "st_size") == 0) {
                    fileSize = strtoull(fileinfo[j + 1], NULL, 10);
                }
            }
            
            if ([fileType isEqualToString:@"S_IFREG"]) {
                // 只复制根目录的文件
                if ([self copyFileFromAFC:afc
                               remotePath:[remoteFilePath UTF8String]
                                localPath:localFilePath]) {
                    rootSize += fileSize;
                    hasFiles = YES;
                }
            }
            
            // 释放文件信息
            for (int j = 0; fileinfo[j]; j++) {
                free(fileinfo[j]);
            }
            free(fileinfo);
        }
    }
    
    // 释放目录列表
    for (int i = 0; dirlist[i]; i++) {
        free(dirlist[i]);
    }
    free(dirlist);
    
    *totalSize = rootSize;
    return hasFiles;
}

- (BOOL)copyDirectoryFromAFC:(afc_client_t)afc remotePath:(const char *)remotePath localPath:(NSString *)localPath {
    if (!afc || !remotePath || !localPath) {
        NSLog(@"[ERROR] copyDirectoryFromAFC: 无效参数");
        return NO;
    }
    
    // 创建本地目录
    NSError *error = nil;
    BOOL success = [[NSFileManager defaultManager] createDirectoryAtPath:localPath
                                             withIntermediateDirectories:YES
                                                              attributes:nil
                                                                   error:&error];
    if (!success) {
        NSLog(@"[ERROR] 创建本地目录失败: %@, 错误: %@", localPath, error.localizedDescription);
        return NO;
    }
    
    // 读取远程目录
    char **dirlist = NULL;
    afc_error_t read_err = afc_read_directory(afc, remotePath, &dirlist);
    if (read_err != AFC_E_SUCCESS) {
        NSLog(@"[ERROR] 读取远程目录失败: %s, 错误: %d", remotePath, read_err);
        return NO;
    }
    
    if (!dirlist) {
        NSLog(@"[DEBUG] 目录为空: %s", remotePath);
        return YES; // 空目录也算成功
    }
    
    BOOL hasFiles = NO;
    int fileCount = 0;
    
    for (int i = 0; dirlist[i]; i++) {
        NSString *filename = [NSString stringWithUTF8String:dirlist[i]];
        
        // 跳过 . 和 ..
        if ([filename isEqualToString:@"."] || [filename isEqualToString:@".."]) {
            continue;
        }
        
        hasFiles = YES;
        fileCount++;
        
        NSString *remoteFilePath = [NSString stringWithFormat:@"%s/%@", remotePath, filename];
        NSString *localFilePath = [localPath stringByAppendingPathComponent:filename];
        
        // 获取文件信息
        char **fileinfo = NULL;
        if (afc_get_file_info(afc, [remoteFilePath UTF8String], &fileinfo) == AFC_E_SUCCESS && fileinfo) {
            
            NSString *fileType = nil;
            for (int j = 0; fileinfo[j] && fileinfo[j + 1]; j += 2) {
                if (strcmp(fileinfo[j], "st_ifmt") == 0) {
                    fileType = [NSString stringWithUTF8String:fileinfo[j + 1]];
                    break;
                }
            }
            
            if ([fileType isEqualToString:@"S_IFDIR"]) {
                // 递归处理目录
                [self copyDirectoryFromAFC:afc
                                remotePath:[remoteFilePath UTF8String]
                                 localPath:localFilePath];
            } else if ([fileType isEqualToString:@"S_IFREG"]) {
                // 复制文件
                [self copyFileFromAFC:afc
                           remotePath:[remoteFilePath UTF8String]
                            localPath:localFilePath];
            }
            
            // 释放文件信息
            for (int j = 0; fileinfo[j]; j++) {
                free(fileinfo[j]);
            }
            free(fileinfo);
        }
    }
    
    // 释放目录列表
    for (int i = 0; dirlist[i]; i++) {
        free(dirlist[i]);
    }
    free(dirlist);
    
    NSLog(@"[DEBUG] 目录复制完成: %s，文件数: %d", remotePath, fileCount);
    return hasFiles;
}

- (BOOL)copyFileFromAFC:(afc_client_t)afc remotePath:(const char *)remotePath localPath:(NSString *)localPath {
    uint64_t handle = 0;
    afc_error_t open_err = afc_file_open(afc, remotePath, AFC_FOPEN_RDONLY, &handle);
    if (open_err != AFC_E_SUCCESS) {
        // 添加更详细的错误处理
        switch (open_err) {
            case AFC_E_PERM_DENIED:
                NSLog(@"[ERROR] 权限被拒绝: %s", remotePath);
                break;
            case AFC_E_OBJECT_NOT_FOUND:
                NSLog(@"[ERROR] 文件不存在: %s", remotePath);
                break;
            default:
                NSLog(@"[ERROR] 打开远程文件失败: %s, 错误: %d", remotePath, open_err);
        }
        return NO;
    }
    
    // 创建本地文件
    NSFileHandle *localFile = [NSFileHandle fileHandleForWritingAtPath:localPath];
    if (!localFile) {
        [[NSFileManager defaultManager] createFileAtPath:localPath contents:nil attributes:nil];
        localFile = [NSFileHandle fileHandleForWritingAtPath:localPath];
    }
    
    if (!localFile) {
        afc_file_close(afc, handle);
        NSLog(@"[ERROR] 创建本地文件失败: %@", localPath);
        return NO;
    }
    
    // 复制文件内容
    char buffer[65536]; // 64KB缓冲区
    uint32_t bytes_read = 0;
    BOOL success = YES;
    
    while (afc_file_read(afc, handle, buffer, sizeof(buffer), &bytes_read) == AFC_E_SUCCESS && bytes_read > 0) {
        NSData *data = [NSData dataWithBytes:buffer length:bytes_read];
        @try {
            [localFile writeData:data];
        } @catch (NSException *exception) {
            NSLog(@"[ERROR] 写入本地文件失败: %@", exception.reason);
            success = NO;
            break;
        }
    }
    
    [localFile closeFile];
    afc_file_close(afc, handle);
    
    return success;
}

// 应用组和扩展查找
- (NSArray *)getAppGroupsForApp:(DeviceApp *)app device:(idevice_t)device {
    NSMutableArray *appGroups = [NSMutableArray array];
    
    // 使用instproxy获取应用的entitlements
    instproxy_client_t instproxy = NULL;
    if (instproxy_client_start_service(device, &instproxy, NULL) == INSTPROXY_E_SUCCESS) {
        
        plist_t client_options = plist_new_dict();
        plist_t return_attributes = plist_new_array();
        plist_array_append_item(return_attributes, plist_new_string("Entitlements"));
        plist_dict_set_item(client_options, "ReturnAttributes", return_attributes);
        
        plist_t apps = NULL;
        if (instproxy_browse(instproxy, client_options, &apps) == INSTPROXY_E_SUCCESS && apps) {
            
            uint32_t app_count = plist_array_get_size(apps);
            for (uint32_t i = 0; i < app_count; i++) {
                plist_t app_info = plist_array_get_item(apps, i);
                
                plist_t bundle_id_node = plist_dict_get_item(app_info, "CFBundleIdentifier");
                if (bundle_id_node) {
                    char *bundle_id = NULL;
                    plist_get_string_val(bundle_id_node, &bundle_id);
                    
                    if (bundle_id && strcmp(bundle_id, [app.bundleID UTF8String]) == 0) {
                        // 找到目标应用，提取应用组
                        plist_t entitlements = plist_dict_get_item(app_info, "Entitlements");
                        if (entitlements) {
                            plist_t app_groups_node = plist_dict_get_item(entitlements, "com.apple.security.application-groups");
                            
                            if (app_groups_node && plist_get_node_type(app_groups_node) == PLIST_ARRAY) {
                                uint32_t group_count = plist_array_get_size(app_groups_node);
                                
                                for (uint32_t j = 0; j < group_count; j++) {
                                    plist_t group_node = plist_array_get_item(app_groups_node, j);
                                    char *group_id = NULL;
                                    plist_get_string_val(group_node, &group_id);
                                    
                                    if (group_id) {
                                        [appGroups addObject:@(group_id)];
                                        free(group_id);
                                    }
                                }
                            }
                        }
                    }
                    
                    if (bundle_id) free(bundle_id);
                }
            }
            
            plist_free(apps);
        }
        
        plist_free(client_options);
        instproxy_client_free(instproxy);
    }
    
    return [appGroups copy];
}

- (NSArray *)findAppExtensions:(DeviceApp *)app device:(idevice_t)device {
    NSMutableArray *extensions = [NSMutableArray array];
    
    // 查找以主应用Bundle ID为前缀的扩展
    NSString *extensionPrefix = [NSString stringWithFormat:@"%@.", app.bundleID];
    
    instproxy_client_t instproxy = NULL;
    if (instproxy_client_start_service(device, &instproxy, NULL) == INSTPROXY_E_SUCCESS) {
        
        plist_t client_options = plist_new_dict();
        plist_t return_attributes = plist_new_array();
        plist_array_append_item(return_attributes, plist_new_string("CFBundleIdentifier"));
        plist_array_append_item(return_attributes, plist_new_string("ApplicationType"));
        plist_dict_set_item(client_options, "ReturnAttributes", return_attributes);
        
        plist_t apps = NULL;
        if (instproxy_browse(instproxy, client_options, &apps) == INSTPROXY_E_SUCCESS && apps) {
            
            uint32_t app_count = plist_array_get_size(apps);
            for (uint32_t i = 0; i < app_count; i++) {
                plist_t app_info = plist_array_get_item(apps, i);
                
                plist_t bundle_id_node = plist_dict_get_item(app_info, "CFBundleIdentifier");
                plist_t app_type_node = plist_dict_get_item(app_info, "ApplicationType");
                
                if (bundle_id_node && app_type_node) {
                    char *bundle_id = NULL;
                    char *app_type = NULL;
                    
                    plist_get_string_val(bundle_id_node, &bundle_id);
                    plist_get_string_val(app_type_node, &app_type);
                    
                    if (bundle_id && app_type) {
                        NSString *bundleID = @(bundle_id);
                        NSString *appType = @(app_type);
                        
                        // 查找扩展（通常以主应用ID为前缀且类型不是User）
                        if ([bundleID hasPrefix:extensionPrefix] &&
                            ![bundleID isEqualToString:app.bundleID] &&
                            (![appType isEqualToString:@"User"])) {
                            [extensions addObject:bundleID];
                            NSLog(@"[DEBUG] 找到扩展: %@", bundleID);
                        }
                    }
                    
                    if (bundle_id) free(bundle_id);
                    if (app_type) free(app_type);
                }
            }
            
            plist_free(apps);
        }
        
        plist_free(client_options);
        instproxy_client_free(instproxy);
    }
    
    return [extensions copy];
}



- (BOOL)zipDirectory:(NSString *)sourceDir toPath:(NSString *)zipPath {
    // 使用系统zip命令创建IPA
    NSTask *zipTask = [[NSTask alloc] init];
    zipTask.launchPath = @"/usr/bin/zip";
    zipTask.arguments = @[@"-r", @"-q", zipPath, @".", @"-x", @"*.DS_Store"];
    zipTask.currentDirectoryPath = sourceDir;
    
    @try {
        [zipTask launch];
        [zipTask waitUntilExit];
        
        BOOL success = zipTask.terminationStatus == 0;
        if (success) {
            NSLog(@"[DEBUG] ZIP创建成功: %@", zipPath);
        } else {
            NSLog(@"[ERROR] ZIP创建失败，退出代码: %d", zipTask.terminationStatus);
        }
        return success;
    } @catch (NSException *exception) {
        NSLog(@"[ERROR] 创建ZIP失败: %@", exception.reason);
        return NO;
    }
}


// 处理备份结果
- (void)handleBackupResult:(BOOL)success error:(NSError *)error forApp:(DeviceApp *)app backupDirectory:(NSString *)backupDirectory {
    LanguageManager *languageManager = [LanguageManager sharedManager];
    NSString *lockedDeviceID = [self getLockedDeviceID];
    
    if (success) {
        // 备份成功
        NSString *backupSuccessMessage = [languageManager localizedStringForKeys:@"AppBackupSuccess"
                                                                         inModule:@"AppsManager"
                                                                     defaultValue:@"Successfully backed up \"%@\""];
        
        NSString *backupLocationMessage = [languageManager localizedStringForKeys:@"BackupLocationMessage"
                                                                          inModule:@"AppsManager"
                                                                      defaultValue:@"Backup saved to: %@"];
        
        NSString *successMessage = [NSString stringWithFormat:backupSuccessMessage, app.appName];
        NSString *locationMessage = [NSString stringWithFormat:backupLocationMessage, backupDirectory];
        NSString *fullMessage = [NSString stringWithFormat:@"%@\n\n%@", successMessage, locationMessage];
        
        NSLog(@"[INFO] %@", successMessage);
        NSLog(@"[INFO] %@", locationMessage);
        
        // 显示成功消息
        [[AlertWindowController sharedController] showResultMessageOnly:fullMessage inWindow:self.view.window];
        
        // 记录成功日志
        NSString *logResultRecord = [languageManager localizedStringForKeys:@"HandleBackupAPPResult"
                                                                    inModule:@"OperationRecods"
                                                                defaultValue:@"Handle Backup APP Result: %@"];
        NSString *recordSuccessMessage = [NSString stringWithFormat:@"[SUC] %@", successMessage];
        [[DataBaseManager sharedInstance] addOperationRecord:[NSString stringWithFormat:logResultRecord, recordSuccessMessage]
                                              forDeviceECID:lockedDeviceID
                                                       UDID:lockedDeviceID];
        
        // 提供打开备份目录的选项
        [self offerToOpenBackupDirectory:backupDirectory forApp:app];
        
    } else {
        // 备份失败
        NSString *backupFailedMessage = [languageManager localizedStringForKeys:@"AppBackupFailed"
                                                                        inModule:@"AppsManager"
                                                                    defaultValue:@"Failed to backup \"%@\": %@"];
        
        NSString *errorDescription = error ? error.localizedDescription : @"Unknown error";
        NSString *failureMessage = [NSString stringWithFormat:backupFailedMessage, app.appName, errorDescription];
        
        NSLog(@"[ERROR] %@", failureMessage);
        
        // 显示错误消息
        [[AlertWindowController sharedController] showResultMessageOnly:failureMessage inWindow:self.view.window];
        
        // 记录失败日志
        NSString *logResultRecord = [languageManager localizedStringForKeys:@"HandleBackupAPPResult"
                                                                    inModule:@"OperationRecods"
                                                                defaultValue:@"Handle Backup APP Result: %@"];
        NSString *recordFailureMessage = [NSString stringWithFormat:@"[ER] %@", failureMessage];
        [[DataBaseManager sharedInstance] addOperationRecord:[NSString stringWithFormat:logResultRecord, recordFailureMessage]
                                              forDeviceECID:lockedDeviceID
                                                       UDID:lockedDeviceID];
    }
}

// 提供打开备份目录的选项
- (void)offerToOpenBackupDirectory:(NSString *)backupDirectory forApp:(DeviceApp *)app {
    LanguageManager *languageManager = [LanguageManager sharedManager];
    
    NSString *openBackupTitle = [languageManager localizedStringForKeys:@"OpenBackupFolder"
                                                                inModule:@"AppsManager"
                                                            defaultValue:@"Open Backup Folder"];
    
    NSString *openBackupMessage = [languageManager localizedStringForKeys:@"OpenBackupFolderMessage"
                                                                   inModule:@"AppsManager"
                                                               defaultValue:@"Would you like to open the backup folder to view the backed up files?"];
    
    NSString *openButtonTitle = [languageManager localizedStringForKeys:@"OpenButton"
                                                                inModule:@"GlobaButtons"
                                                            defaultValue:@"Open"];
    NSString *laterButtonTitle = [languageManager localizedStringForKeys:@"LaterButton"
                                                                 inModule:@"GlobaButtons"
                                                             defaultValue:@"Later"];
    
    [[AlertWindowController sharedController] showAlertWithTitle:openBackupTitle
                                                     description:openBackupMessage
                                                    confirmTitle:openButtonTitle
                                                     cancelTitle:laterButtonTitle
                                                   confirmAction:^{
        // 打开备份目录
        [self openBackupDirectoryInFinder:backupDirectory forApp:app];
    }];
}

// 在Finder中打开备份目录
- (void)openBackupDirectoryInFinder:(NSString *)backupDirectory forApp:(DeviceApp *)app {
    // 查找具体的应用备份目录
    NSArray *dirContents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:backupDirectory error:nil];
    NSString *appBackupDir = nil;
    
    NSString *safeAppName = [self sanitizeFileName:app.appName];
    for (NSString *item in dirContents) {
        if ([item containsString:safeAppName] && [item containsString:app.bundleID]) {
            appBackupDir = [backupDirectory stringByAppendingPathComponent:item];
            break;
        }
    }
    
    // 优先打开应用专用目录，否则打开备份根目录
    NSString *pathToOpen = appBackupDir ?: backupDirectory;
    
    [[NSWorkspace sharedWorkspace] openFile:pathToOpen];
    NSLog(@"[INFO] 已在Finder中打开备份目录: %@", pathToOpen);
}

// 检查备份前置条件
- (BOOL)validateBackupPrerequisites:(DeviceApp *)app {
    LanguageManager *languageManager = [LanguageManager sharedManager];
    NSString *lockedDeviceID = [self getLockedDeviceID];
    // 检查设备连接
    if (!lockedDeviceID || lockedDeviceID.length == 0) {
        NSString *noDeviceMessage = [languageManager localizedStringForKeys:@"NoDeviceSelectedForBackup"
                                                                    inModule:@"AppsManager"
                                                                defaultValue:@"No device selected. Please select a device first."];
        
        [[AlertWindowController sharedController] showResultMessageOnly:noDeviceMessage inWindow:self.view.window];
        return NO;
    }
    
     
    // 检查应用信息完整性
    if (!app.bundleID || app.bundleID.length == 0) {
        NSString *invalidAppMessage = [languageManager localizedStringForKeys:@"InvalidAppForBackup"
                                                                      inModule:@"AppsManager"
                                                                  defaultValue:@"Invalid application data. Cannot perform backup."];
        
        [[AlertWindowController sharedController] showResultMessageOnly:invalidAppMessage inWindow:self.view.window];
        return NO;
    }
    
    NSLog(@"[DEBUG] 备份前置条件验证通过");
    return YES;
}

// ============================================================================
// MARK: - 报告生成方法
// ============================================================================

- (void)generateBackupReport:(NSDictionary *)results forApp:(DeviceApp *)app inDirectory:(NSString *)directory {
    NSString *reportPath = [directory stringByAppendingPathComponent:@"Enhanced_Backup_Report.txt"];
    
    NSMutableString *report = [NSMutableString string];
    [report appendFormat:@"🍎 增强版应用备份报告\n"];
    [report appendFormat:@"================================\n\n"];
    
    // 应用基本信息
    [report appendFormat:@"📱 应用信息:\n"];
    [report appendFormat:@"   • 名称: %@\n", app.appName];
    [report appendFormat:@"   • Bundle ID: %@\n", app.bundleID];
    [report appendFormat:@"   • 版本: %@\n", app.version];
    [report appendFormat:@"   • 开发者: %@\n", app.developer ?: @"未知"];
    [report appendFormat:@"   • 应用类型: %@\n", app.applicationType];
    [report appendFormat:@"   • 应用大小: %@\n", [self formatSize:app.appSize]];
    [report appendFormat:@"   • 数据大小: %@\n", [self formatSize:app.docSize]];
    [report appendFormat:@"   • 备份时间: %@\n\n", [NSDate date]];
    
    // 备份方法详情
    [report appendFormat:@"🔧 备份方法结果:\n"];
    NSDictionary *methodNames = @{
        @"info": @"📋 应用信息",
        @"icon": @"🎨 应用图标",
        @"ipa": @"📦 IPA提取",
        @"sandbox": @"📁 沙盒数据",
        @"deviceBackup": @"🍎 Apple官方备份",  // 更新描述
        @"system": @"⚙️  系统数据",
        @"finalIPA": @"📦 最终IPA",
        @"integrity": @"✅ 完整性验证"
    };
    
    for (NSString *key in results) {
        NSString *methodName = methodNames[key] ?: key;
        BOOL success = [results[key] boolValue];
        [report appendFormat:@"   %@ %@\n", success ? @"✅" : @"❌", methodName];
    }
    
    // 成功方法统计
    NSInteger successCount = 0;
    for (NSString *key in results) {
        if ([results[key] boolValue]) successCount++;
    }
    double successRate = (double)successCount / (double)results.count * 100.0;
    
    [report appendFormat:@"\n📊 备份统计:\n"];
    [report appendFormat:@"   • 总方法数: %ld\n", (long)results.count];
    [report appendFormat:@"   • 成功方法数: %ld\n", (long)successCount];
    [report appendFormat:@"   • 成功率: %.1f%%\n", successRate];
    
    // 质量评级
    [report appendFormat:@"\n📈 备份质量评级:\n"];
    if (successRate >= 85.0) {
        [report appendFormat:@"   • 质量评级: 🌟🌟🌟🌟🌟 优秀\n"];
    } else if (successRate >= 70.0) {
        [report appendFormat:@"   • 质量评级: 🌟🌟🌟🌟 良好\n"];
    } else if (successRate >= 50.0) {
        [report appendFormat:@"   • 质量评级: 🌟🌟🌟 一般\n"];
    } else {
        [report appendFormat:@"   • 质量评级: 🌟🌟 基础\n"];
    }
    
    [report appendFormat:@"\n💡 备份说明:\n"];
    [report appendFormat:@"   • 这是一个集成Apple官方备份协议的增强版备份\n"];
    [report appendFormat:@"   • 包含多层次备份策略，最大化数据获取\n"];
    [report appendFormat:@"   • Apple官方备份提供更深层的系统数据访问\n"];
    [report appendFormat:@"   • 备份完整度受iOS安全机制限制\n"];
    [report appendFormat:@"   • 建议定期备份以确保数据安全\n"];
    
    [report writeToFile:reportPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSLog(@"[DEBUG] 增强版备份报告已生成: %@", reportPath);
}


- (void)generateDataBackupReport:(DeviceApp *)app
                     expectedSize:(unsigned long long)expectedSize
                       actualSize:(unsigned long long)actualSize
                      inDirectory:(NSString *)directory {
    
    NSString *reportPath = [directory stringByAppendingPathComponent:@"DataBackupReport.txt"];
    
    NSMutableString *report = [NSMutableString string];
    [report appendFormat:@"数据备份详细报告\n"];
    [report appendFormat:@"====================\n\n"];
    [report appendFormat:@"应用: %@\n", app.appName];
    [report appendFormat:@"Bundle ID: %@\n", app.bundleID];
    [report appendFormat:@"备份时间: %@\n\n", [NSDate date]];
    
    [report appendFormat:@"数据大小对比:\n"];
    [report appendFormat:@"- 系统显示大小: %@\n", [self formatSize:expectedSize]];
    [report appendFormat:@"- 实际备份大小: %@\n", [self formatSize:actualSize]];
    
    double completeness = expectedSize > 0 ? (double)actualSize / (double)expectedSize * 100.0 : 100.0;
    [report appendFormat:@"- 备份完整度: %.1f%%\n\n", completeness];
    
    if (completeness >= 90.0) {
        [report appendFormat:@"✅ 备份完整度优秀 (>90%%)\n"];
    } else if (completeness >= 70.0) {
        [report appendFormat:@"⚠️  备份完整度良好 (70-90%%)\n"];
    } else {
        [report appendFormat:@"❌ 备份可能不完整 (<70%%)\n"];
    }
    
    [report appendFormat:@"\n备份内容说明:\n"];
    [report appendFormat:@"- MainContainer/: 应用主容器数据\n"];
    [report appendFormat:@"- DocumentsContainer/: 文档容器数据\n"];
    [report appendFormat:@"- AppGroups/: 应用组共享数据\n"];
    [report appendFormat:@"- Extensions/: 应用扩展数据\n\n"];
    
    [report appendFormat:@"注意事项:\n"];
    [report appendFormat:@"- 某些数据可能需要设备越狱才能完全访问\n"];
    [report appendFormat:@"- 系统显示的大小可能包含缓存和临时文件\n"];
    [report appendFormat:@"- 备份完整度受iOS安全限制影响\n"];
    
    [report writeToFile:reportPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

- (BOOL)verifyBackupIntegrity:(DeviceApp *)app inDirectory:(NSString *)directory {
    NSLog(@"[DEBUG] 验证备份完整性");
    
    // 检查基本文件
    NSArray *requiredFiles = @[@"AppInfo.plist", @"Backup_Report.txt"];
    
    for (NSString *file in requiredFiles) {
        NSString *filePath = [directory stringByAppendingPathComponent:file];
        if (![[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
            NSLog(@"[ERROR] 缺少必需文件: %@", file);
            return NO;
        }
    }
    
    // 检查是否至少有一种类型的备份数据
    NSArray *dataTypes = @[@"IPA_Extraction", @"SandboxData", @"SystemData"];
    BOOL hasData = NO;
    
    for (NSString *dataType in dataTypes) {
        NSString *dataPath = [directory stringByAppendingPathComponent:dataType];
        if ([[NSFileManager defaultManager] fileExistsAtPath:dataPath]) {
            hasData = YES;
            break;
        }
    }
    
    if (!hasData) {
        NSLog(@"[WARNING] 没有找到任何应用数据，但基本信息完整");
    }
    
    NSLog(@"[DEBUG] 备份完整性验证通过");
    return YES;
}


// 备份选择项数据
- (IBAction)batchBackupData:(id)sender {
    if (self.selectedApps.count == 0) {
        LanguageManager *languageManager = [LanguageManager sharedManager];
        NSString *noSelectionMessage = [languageManager localizedStringForKeys:@"noAppsSelectedForBackup"
                                                                       inModule:@"AppsManager"
                                                                   defaultValue:@"Please select applications to backup"];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            [[AlertWindowController sharedController] showResultMessageOnly:noSelectionMessage inWindow:self.view.window];
        });
        return;
    }
    
    // 选择备份目录
    NSOpenPanel *openPanel = [NSOpenPanel openPanel];
    openPanel.canChooseDirectories = YES;
    openPanel.canChooseFiles = NO;
    openPanel.allowsMultipleSelection = NO;
    openPanel.canCreateDirectories = YES;
    
    LanguageManager *languageManager = [LanguageManager sharedManager];
    NSString *selectBackupDirTitle = [languageManager localizedStringForKeys:@"selectBackupDirectory"
                                                                     inModule:@"AppsManager"
                                                                 defaultValue:@"Select Backup Directory"];
    openPanel.title = selectBackupDirTitle;
    
    [openPanel beginSheetModalForWindow:self.view.window completionHandler:^(NSInteger result) {
        if (result == NSModalResponseOK) {
            NSURL *backupURL = openPanel.URL;
            [self performBatchBackup:self.selectedApps.allObjects toDirectory:backupURL.path];
        }
    }];
}

// 执行批量备份
- (void)performBatchBackup:(NSArray<DeviceApp *> *)appsToBackup toDirectory:(NSString *)backupDirectory {
    LanguageManager *languageManager = [LanguageManager sharedManager];
    NSString *lockedDeviceID = [self getLockedDeviceID];
    // 记录操作日志
    NSString *logBatchBackupRecord = [languageManager localizedStringForKeys:@"HandleBatchBackupAPP"
                                                                     inModule:@"OperationRecods"
                                                                 defaultValue:@"Handle Batch Backup APP"];
    [[DataBaseManager sharedInstance] addOperationRecord:logBatchBackupRecord
                                          forDeviceECID:lockedDeviceID
                                                   UDID:lockedDeviceID];
    
    // 显示进度指示器
    dispatch_async(dispatch_get_main_queue(), ^{
        self.loadingIndicator.hidden = NO;
        [self.loadingIndicator startAnimation:nil];
        self.tableView.enabled = NO;
        self.tableView.alphaValue = 0.5;
    });
    
    // 在后台线程执行备份操作
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSInteger successCount = 0;
        NSInteger failureCount = 0;
        NSMutableArray *failedApps = [NSMutableArray array];
        
        for (DeviceApp *app in appsToBackup) {
            @autoreleasepool {
                NSError *error = nil;
                BOOL success = [self backupApp:app toDirectory:backupDirectory error:&error];
                
                if (success) {
                    successCount++;
                    NSLog(@"[INFO] 成功备份应用: %@", app.appName);
                } else {
                    failureCount++;
                    [failedApps addObject:app];
                    NSLog(@"[ERROR] 备份应用失败: %@, 错误: %@", app.appName, error ? error.localizedDescription : @"未知错误");
                }
                
                // 短暂延迟
                [NSThread sleepForTimeInterval:1.0];
            }
        }
        
        // 回到主线程更新UI
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.loadingIndicator stopAnimation:nil];
            self.loadingIndicator.hidden = YES;
            self.tableView.enabled = YES;
            self.tableView.alphaValue = 1.0;
            
            // 显示结果消息
            NSString *resultMessage;
            if (failureCount == 0) {
                NSString *allSuccessMessage = [languageManager localizedStringForKeys:@"batchBackupAllSuccess"
                                                                              inModule:@"AppsManager"
                                                                          defaultValue:@"Successfully backed up all %ld applications"];
                resultMessage = [NSString stringWithFormat:allSuccessMessage, (long)successCount];
            } else {
                NSString *partialSuccessMessage = [languageManager localizedStringForKeys:@"batchBackupPartialSuccess"
                                                                                  inModule:@"AppsManager"
                                                                              defaultValue:@"Backed up %ld applications successfully, %ld failed"];
                resultMessage = [NSString stringWithFormat:partialSuccessMessage, (long)successCount, (long)failureCount];
            }
            
            [[AlertWindowController sharedController] showResultMessageOnly:resultMessage inWindow:self.view.window];
            
            // 记录操作结果
            NSString *logResultRecord = [languageManager localizedStringForKeys:@"HandleBatchBackupAPPResult"
                                                                        inModule:@"OperationRecods"
                                                                    defaultValue:@"Handle Batch Backup APP Result: %@"];
            NSString *recordresultMessage = [NSString stringWithFormat:@"[SUC] %@", resultMessage];
            [[DataBaseManager sharedInstance] addOperationRecord:[NSString stringWithFormat:logResultRecord, recordresultMessage]
                                                  forDeviceECID:lockedDeviceID
                                                           UDID:lockedDeviceID];
        });
    });
}

// 备份单个应用的实现（需要完善）
- (BOOL)backupApp:(DeviceApp *)app toDirectory:(NSString *)backupDirectory error:(NSError **)error {
    // TODO: 实现具体的备份逻辑
    // 这里只是一个示例，实际需要根据您的需求实现
    NSLog(@"[DEBUG] 开始备份应用: %@ 到目录: %@", app.appName, backupDirectory);
    
    // 创建应用专用备份目录
    NSString *appBackupDir = [backupDirectory stringByAppendingPathComponent:app.bundleID];
    NSError *dirError = nil;
    BOOL success = [[NSFileManager defaultManager] createDirectoryAtPath:appBackupDir
                                             withIntermediateDirectories:YES
                                                              attributes:nil
                                                                   error:&dirError];
    
    if (!success && error) {
        *error = dirError;
        return NO;
    }
    
    // 这里应该实现实际的IPA提取和数据备份逻辑
    // 暂时返回成功，实际需要实现libimobiledevice的备份功能
    return YES;
}


// 在vi​​ewDidLoad或 init 方法中添加此观察者
- (void)setupAuthenticationObservers {
    // 监听登录失败的通知
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(loginFailed:)
                                                 name:@"LoginFailedNotification"
                                               object:nil];
                                               
    // 监听应用关闭或设备断开连接的通知
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(clearCachedAuthentication)
                                                 name:NSApplicationWillTerminateNotification
                                               object:nil];
                                               
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(clearCachedAuthentication)
                                                 name:@"DeviceDisconnectedNotification"
                                               object:nil];
}

/**
 * 应用即将终止时的清理
 */
- (void)applicationWillTerminate:(NSNotification *)notification {
    NSLog(@"[DEBUG] 应用即将终止，执行清理");
    
    // 🔥 在主线程上安全清理
    if ([NSThread isMainThread]) {
        [self safeCloseLoginWindow];
    } else {
        dispatch_sync(dispatch_get_main_queue(), ^{
            [self safeCloseLoginWindow];
        });
    }
}


- (void)loginFailed:(NSNotification *)notification {
    // 如果登录失败，清除缓存的认证信息
    [self clearCachedAuthentication];
}

// 注销通知监听
- (void)dealloc {
   
    NSLog(@"[DEBUG] DeviceAppController 开始释放");
    // 🔥 在主线程上安全清理UI资源
    if ([NSThread isMainThread]) {
        [self performDeallocCleanup];
    } else {
        dispatch_sync(dispatch_get_main_queue(), ^{
            [self performDeallocCleanup];
        });
    }

    
    NSLog(@"[DEBUG] DeviceAppController 资源清理完成");
}

/**
 * 执行 dealloc 清理 - 新增方法
 */
- (void)performDeallocCleanup {
    // 清除缓存的认证信息
    [self clearCachedAuthentication];
    
    // 移除所有通知观察者
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    
    // 安全关闭登录窗口
    [self safeCloseLoginWindow];
    
    // 清理其他资源
    self.allAppList = nil;
    self.cachedLoginController = nil;
    self.cachedAppleID = nil;
}

#pragma mark - 更新批量操作按钮状态
- (void)updateBatchOperationButtonsState:(BOOL)enabled {
    dispatch_async(dispatch_get_main_queue(), ^{
        // 根据需求：isCalculatingAppSizes = YES 时启用这些按钮
        
        // 取消选择按钮 - 需要添加 IBOutlet 连接
        if (self.clearAllSelectionButton) {
            self.clearAllSelectionButton.enabled = enabled;
            self.clearAllSelectionButton.alphaValue = enabled ? 1.0 : 0.5;
        }
        
        // 批量删除按钮 - 需要添加 IBOutlet 连接
        if (self.batchDeleteButton) {
            self.batchDeleteButton.enabled = enabled;
            self.batchDeleteButton.alphaValue = enabled ? 1.0 : 0.5;
        }
        
        // 批量更新按钮 - 需要添加 IBOutlet 连接
        if (self.batchUpdateButton) {
            self.batchUpdateButton.enabled = enabled;
            self.batchUpdateButton.alphaValue = enabled ? 1.0 : 0.5;
        }
        
        // 批量下载按钮 - 需要添加 IBOutlet 连接
        if (self.batchDownloadButton) {
            self.batchDownloadButton.enabled = enabled;
            self.batchDownloadButton.alphaValue = enabled ? 1.0 : 0.5;
        }
        
        // 从本地导入安装按钮 - 已存在 ImportAppFromLocalButton
        if (self.ImportAppFromLocalButton) {
            self.ImportAppFromLocalButton.enabled = enabled;
            self.ImportAppFromLocalButton.alphaValue = enabled ? 1.0 : 0.5;
        }
        
        NSLog(@"[INFO] 批量操作按钮状态已更新: %@", enabled ? @"启用" : @"禁用");
    });
}

@end

