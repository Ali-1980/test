//
//  DeviceBackupRestore.m
//
//  Created by Monterey on 19/1/2025.
//

#import "DeviceBackupRestore.h"
#import "DefaultBackupViewController.h"
#import "BackupProgressViewController.h"
#import "EncryptedSettingsViewController.h"
#import "RestoreProgressViewController.h"
#import "DeviceManager.h" // 引入设备管理模块
#import "DatalogsSettings.h"//日志保存路径全局
#import "LanguageManager.h" //语言
#import "CurrentHistoryController.h" //历史操作记录
#import "SidebarViewController.h"
#import "LogUtility.h" // 自定义日志函数LogWithTimestamp，自动添加时间戳
#import "LogManager.h" //全局日志区域
#import "UserManager.h" //登录
#import "DataBaseManager.h" //数据储存管理
#import "BackupTask.h"
#import "BackupOptionTask.h"

@interface DeviceBackupRestore () <NSTableViewDataSource, NSTableViewDelegate>

// 子视图控制器
@property (strong) DefaultBackupViewController *defaultBackupViewController;
@property (strong) BackupProgressViewController *backupProgressViewController;
@property (strong) EncryptedSettingsViewController *encryptedSettingsViewController;
@property (strong) RestoreProgressViewController *restoreProgressViewController;
@property (strong) NSViewController *currentViewController;

// 进度属性的私有设置器
@property (nonatomic, readwrite) double backupProgress;
@property (nonatomic, readwrite) double restoreProgress;
@property (nonatomic, readwrite, getter=isBackupInProgress) BOOL backupInProgress;
@property (nonatomic, readwrite, getter=isRestoreInProgress) BOOL restoreInProgress;

// 备份相关配置
@property (nonatomic, strong) NSString *backupLocationPath;
@property (nonatomic, assign) BOOL backupIsEncrypted;

// 备份数据
@property (nonatomic, strong) NSMutableArray *backupItems;

@end

@implementation DeviceBackupRestore


#pragma mark - 单例实现

+ (instancetype)sharedInstance {
    static DeviceBackupRestore *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}


#pragma mark - 初始化方法

- (void)viewDidLoad {
    [super viewDidLoad];
    NSLog(@"DeviceBackupRestore: viewDidLoad");
    
    // 初始化当前备份文件列表
    self.currentBackupFiles = [NSMutableArray array];
        
    // 初始化 NSPopUpButton
    [self populateDevicePopUpButton];

    //当前设备列表信息
    [self getCurrentConnectedDevicesFromHistorylist];
    
    // 初始化数据
    self.backupItems = [NSMutableArray array];

    NSLog(@"DeviceBackupRestore: 已加载样本备份项目: %lu个", (unsigned long)self.backupItems.count);
    
    // 初始化属性
    self.backupProgress = 0.0;
    self.restoreProgress = 0.0;
    self.backupInProgress = NO;
    self.restoreInProgress = NO;
    
    // 初始化备份设置
    self.backupLocationPath = NSHomeDirectory();
    self.backupIsEncrypted = NO;
    NSLog(@"DeviceBackupRestore: 默认备份位置: %@", self.backupLocationPath);
    
    // 初始化视图控制器
    [self initializeViewControllers];
    
    // 显示默认视图
    [self displayContentController:self.defaultBackupViewController];
    
    self.collectedLogs = [[NSMutableString alloc] init]; // 初始化日志缓存
    
    NSLog(@"DeviceBackupRestore: 已显示默认备份视图");
}

- (void)viewDidAppear {
    [super viewDidAppear];
    NSLog(@"DeviceBackupRestore: viewDidAppear");
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
            NSLog(@"[DEBUG] 已选中设备信息: %@  Type: %@  Mode: %@",self.deviceOfficialName, self.currentDeviceType, self.currentDeviceMode);
            
            [self lockDeviceWithInfo:uniqueKey officialName:self.deviceOfficialName type:self.currentDeviceType mode:self.currentDeviceMode];
            NSLog(@"[DEBUG] 已选中设备并锁定: %@  Type: %@  Mode: %@",self.deviceOfficialName, self.currentDeviceType, self.currentDeviceMode);
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
    
    NSLog(@"[DEBUG] populateDevicePopUpButton 方法执行完成");
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
    
    
    NSLog(@"[INFO] 手动选中设备的名称：%@ 模式：%@ 类型：%@ 匹配：%@", deviceOfficialName, deviceMode, deviceTYPE, devicePairStatus);
    
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

        // 在选择新设备之前取消所有下载任务
      //  [self cancelAllDownloadTasks];

        
        // 锁定并持久化设备信息
        [self lockDeviceWithInfo:uniqueKey officialName:deviceOfficialName type:deviceTYPE mode:deviceMode];
        
        
        // ✅ 修改：直接传递设备信息给备份视图控制器
        if (self.backupProgressViewController) {
            NSLog(@"DeviceBackupRestore: 直接传递设备信息给备份视图控制器");
            
            // 创建设备信息字典
            NSDictionary *deviceInfoToPass = @{
                @"uniqueKey": uniqueKey,
                @"officialName": deviceOfficialName,
                @"type": deviceTYPE,
                @"mode": deviceMode,
                @"udid": deviceUDID ?: @"",
                @"ecid": deviceECID ?: @""
            };
            
            // 直接调用加载方法
            [self.backupProgressViewController loadBackupDataForDevice:uniqueKey deviceInfo:deviceInfoToPass];
        } else {
            NSLog(@"DeviceBackupRestore: 备份视图控制器为空");
        }
        
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

    if ([deviceMode isEqualToString:@"Normal"]) {
        [self.backupProgressViewController checkAndLoadExistingBackupData];
    }
    
    // 根据设备类型判断 如果是Watch / Mac 类型 则作相关判断
    if ([deviceTYPE.lowercaseString containsString:@"watch"]) {
        
        /*
        // 如果设备类型为 "watch"，禁用 autoOfficialFirmwareCheckbox
        if (self.autoOfficialFirmwareCheckbox.state == NSControlStateValueOn) {
            // 如果复选框已经选中，取消选择
            self.autoOfficialFirmwareCheckbox.state = NSControlStateValueOff;
        }
        self.autoOfficialFirmwareCheckbox.enabled = NO;
        [self.autoOfficialFirmwareCheckbox setNeedsDisplay:YES]; // 强制刷新*/
    } else {
        /*
        // 如果设备类型不是 "watch"，启用 autoOfficialFirmwareCheckbox
        self.autoOfficialFirmwareCheckbox.enabled = YES;
        [self.autoOfficialFirmwareCheckbox setNeedsDisplay:YES]; // 强制刷新*/
    }
}

- (NSDictionary *)getDeviceInfoByID:(NSString *)deviceID {
    // 示例：从当前已加载的设备列表中找到设备详情
    NSDictionary *allDevicesData = [self getCurrentConnectedDevicesFromHistorylist];
    return allDevicesData[deviceID];
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


#pragma mark -锁定设备并持久化设备信息 同步更新
- (void)lockDeviceWithInfo:(NSString *)uniqueKey officialName:(NSString *)officialName type:(NSString *)type mode:(NSString *)mode {
    // 更新锁定的设备信息
    self.lockedDeviceID = uniqueKey;
    self.deviceType = type;
    self.deviceMode = mode;

    // 创建设备信息字典
    NSDictionary *lockedDeviceInfo = @{
        @"uniqueKey": uniqueKey,
        @"officialName": officialName ?: @"",
        @"type": type ?: @"",
        @"mode": mode ?: @""
    };

    // 持久化锁定的设备信息
    [self setLockedDeviceInfo:lockedDeviceInfo];
    
    // 记录锁定设备的其他信息，如 officialName 和 type 等
    NSLog(@"[INFO] 设备已锁定 - uniqueKey: %@, officialName: %@, type: %@, 模式: %@", uniqueKey, officialName, type, mode);

    // 验证设备信息同步
    NSDictionary *syncedDeviceInfo = [self getLockedDeviceInfo];
    NSLog(@"[INFO] 锁定设备同步信息 - %@", syncedDeviceInfo);
}


#pragma mark - 从内存获取锁定的设备ID
- (NSString *)getLockedDeviceID {
    return self.lockedDeviceID;
}

#pragma mark - 设备锁定信息存入内存
- (void)setLockedDeviceID:(NSString *)lockedDeviceID {
    _lockedDeviceID = lockedDeviceID;
}

#pragma mark - 从内存获取已锁定的设备信息
- (NSDictionary *)getLockedDeviceInfo {
    return self.LockedDeviceInfo;
}

#pragma mark - 设备锁定信息存入内存（字典）
- (void)setLockedDeviceInfo:(NSDictionary *)LockedDeviceInfo {
    _LockedDeviceInfo = LockedDeviceInfo;
}


#pragma mark -  辅助方法：根据 deviceUDID 或 deviceECID 自动选中对应的设备项
- (void)AutoSelectDeviceInPopUpButton {
    BOOL found = NO;
    NSString *selectedDeviceID = nil;
    
    // 在执行固件操作之前移除 deviceListDidChange 监听
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"DeviceListChangedNotification" object:nil];
    
    // 优先根据 deviceUDID 进行匹配
    if (self.deviceUDID && self.deviceUDID.length > 0) {
        for (NSMenuItem *item in self.devicePopUpButton.menu.itemArray) {
            if ([item.representedObject isEqualToString:self.deviceUDID]) {
                [self.devicePopUpButton selectItem:item];
                selectedDeviceID = self.deviceUDID; //自动选中的
                found = YES;
                break;
            }
        }
    }

    // 如果未找到匹配的 deviceUDID，尝试根据 deviceECID 进行匹配
    if (!found && self.deviceECID && self.deviceECID.length > 0) {
        for (NSMenuItem *item in self.devicePopUpButton.menu.itemArray) {
            if ([item.representedObject isEqualToString:self.deviceECID]) {
                [self.devicePopUpButton selectItem:item];
                selectedDeviceID = self.deviceECID; //自动选中的
                found = YES;
                break;
            }
        }
    }
    

    if (found) {
        self.lockedDeviceID = selectedDeviceID;  // 锁定设备
        //[self setLockedDeviceID];
        
        [self setLockedDeviceID:selectedDeviceID]; // 持久化设备信息
        
        //判断按钮显示状态
        NSLog(@"自动选中后判断按钮显示状态: %@" , self.currentDeviceMode);
        BOOL isLoggedIn = [UserManager sharedManager].isUserLoggedIn;
        if ([self.currentDeviceMode isEqualToString:@"Normal"] && isLoggedIn) {
          //  self.eraseDevice.enabled = YES; //擦除内容
         //   self.triggerPairButton.enabled = YES;
           // self.triggerUnPairButton.enabled = YES;
        }else{
          //  self.eraseDevice.enabled = NO; //擦除内容
          //  self.triggerPairButton.enabled = NO;
          //  self.triggerUnPairButton.enabled = NO;
        }
        
        // 固件操作完成后开始定时每 3 秒监听一次
       // [self startDeviceListMonitoring];
        
    } else {
        // 未找到匹配设备，解除锁定
        self.lockedDeviceID = nil;
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"LockedDeviceID"];
    }
}

#pragma mark - 刷新日志显示

- (void)showLogsWithMessage:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        // 生成时间戳
        NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
        [dateFormatter setDateFormat:@"yyyy-MM-dd HH:mm:ss"];
        NSString *timestamp = [dateFormatter stringFromDate:[NSDate date]];

        // 手动生成带时间戳的日志
        NSString *formattedLog = [NSString stringWithFormat:@"[%@] %@", timestamp, message];

        // 获取日志显示的 NSTextView
        NSTextView *textView = (NSTextView *)[LogManager sharedManager].logScrollView.documentView;
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

#pragma mark - 初始化视图控制器

- (void)initializeViewControllers {
    NSLog(@"DeviceBackupRestore: 初始化视图控制器");
    
    // 从Storyboard实例化子视图控制器
    self.defaultBackupViewController = [self.storyboard instantiateControllerWithIdentifier:@"DefaultBackupViewController"];
    NSLog(@"DeviceBackupRestore: 已实例化DefaultBackupViewController");
    
    self.backupProgressViewController = [self.storyboard instantiateControllerWithIdentifier:@"BackupProgressViewController"];
    NSLog(@"DeviceBackupRestore: 已实例化BackupProgressViewController");
    
    self.encryptedSettingsViewController = [self.storyboard instantiateControllerWithIdentifier:@"EncryptedSettingsViewController"];
    NSLog(@"DeviceBackupRestore: 已实例化EncryptedSettingsViewController");
    
    self.restoreProgressViewController = [self.storyboard instantiateControllerWithIdentifier:@"RestoreProgressViewController"];
    NSLog(@"DeviceBackupRestore: 已实例化RestoreProgressViewController");
    
    // 设置默认备份视图的数据源
    self.defaultBackupViewController.backupItems = self.backupItems;
    
    // 将自己设置为各个子视图控制器的代理
    self.backupProgressViewController.delegate = (id<BackupProgressDelegate>)self;
    self.encryptedSettingsViewController.delegate = (id<EncryptedSettingsDelegate>)self;
    self.restoreProgressViewController.delegate = (id<RestoreProgressDelegate>)self;
}

#pragma mark - 视图切换管理

- (void)displayContentController:(NSViewController *)content {
    NSLog(@"DeviceBackupRestore: 切换到视图控制器: %@", NSStringFromClass([content class]));
    
    // 检查新内容是否为空
    if (!content) {
        NSLog(@"DeviceBackupRestore: 错误 - 尝试显示空的视图控制器");
        return;
    }
    
    // 检查 contentView 是否存在
    if (!self.contentView) {
        NSLog(@"DeviceBackupRestore: 错误 - contentView 为空，无法添加子视图");
        return;
    }
    
    // 移除当前视图控制器
    if (self.currentViewController) {
        // 先从视图层级中移除视图
        [self.currentViewController.view removeFromSuperview];
        
        // 直接从父视图控制器中移除
        [self.currentViewController removeFromParentViewController];
        
        NSLog(@"DeviceBackupRestore: 已移除当前视图控制器: %@", NSStringFromClass([self.currentViewController class]));
    }
    
    // 添加新的视图控制器
    [self addChildViewController:content];
    
    // 添加视图
    NSView *contentView = content.view;
    [self.contentView addSubview:contentView];
    contentView.frame = self.contentView.bounds;
    contentView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    
    // 更新当前视图控制器引用
    self.currentViewController = content;
    NSLog(@"DeviceBackupRestore: 已添加新视图控制器: %@", NSStringFromClass([content class]));
}



#pragma mark - 按钮动作方法
- (IBAction)showBackupManageView:(id)sender {
    NSLog(@"DeviceBackupRestore: 点击了备份管理按钮");
    [self displayContentController:self.defaultBackupViewController];
    [self updateButtonStates:self.backupManageButton];
}


- (IBAction)showBackupView:(id)sender {
    NSLog(@"DeviceBackupRestore: 点击了立即备份按钮");
    [self displayContentController:self.backupProgressViewController];
    [self updateButtonStates:self.startBackupButton];
    
    // ✅ 在切换到备份视图时也传递当前设备信息
    if (self.lockedDeviceID && self.lockedDeviceID.length > 0) {
        NSLog(@"DeviceBackupRestore: 传递当前设备信息到备份视图");
        [self.backupProgressViewController loadBackupDataForDevice:self.lockedDeviceID deviceInfo:self.LockedDeviceInfo];
    }
    
    // 获取当前锁定的设备ID（UDID 或 ECID）
    NSString *lockedDeviceID = self.lockedDeviceID;
    if (!lockedDeviceID) {
        lockedDeviceID = [self getLockedDeviceID];
        NSLog(@"尝试从UserDefaults获取锁定的设备ID: %@", lockedDeviceID);
    }
    NSLog(@"当前获取到锁定的设备ID: %@", lockedDeviceID);
    
    // 自动开始备份
    [self triggerStartBackup:nil];
}

- (IBAction)showEncryptedSettingsView:(id)sender {
    NSLog(@"DeviceBackupRestore: 点击了备份加密按钮");
    [self displayContentController:self.encryptedSettingsViewController];
    [self updateButtonStates:self.encryptedBackupButton];
    
    // 更新加密设置视图中的状态
    [self.encryptedSettingsViewController updateEncryptionStatus:self.backupIsEncrypted];
}

- (IBAction)showRestoreView:(id)sender {
    NSLog(@"DeviceBackupRestore: 点击了恢复备份按钮");
    [self displayContentController:self.restoreProgressViewController];
    [self updateButtonStates:self.restoreButton];
    
    // 更新恢复视图的备份列表
    [self.restoreProgressViewController setBackupItems:self.backupItems];
}

- (void)updateButtonStates:(NSButton *)activeButton {
    if (!activeButton) {
        NSLog(@"DeviceBackupRestore: 警告 - 尝试更新按钮状态，但活动按钮为空");
        return;
    }
    
    NSLog(@"DeviceBackupRestore: 更新按钮状态，当前活动按钮: %@", activeButton.title);
    
    // 全面进行空指针检查
    if ([self.backupManageButton isKindOfClass:[NSButton class]]) {
        [self.backupManageButton setState:(activeButton == self.backupManageButton) ? NSControlStateValueOn : NSControlStateValueOff];
    } else {
        NSLog(@"DeviceBackupRestore: 警告 - backupManageButton 类型错误或为空");
    }
    
    if ([self.startBackupButton isKindOfClass:[NSButton class]]) {
        [self.startBackupButton setState:(activeButton == self.startBackupButton) ? NSControlStateValueOn : NSControlStateValueOff];
    } else {
        NSLog(@"DeviceBackupRestore: 警告 - startBackupButton 类型错误或为空");
    }
    
    if ([self.encryptedBackupButton isKindOfClass:[NSButton class]]) {
        [self.encryptedBackupButton setState:(activeButton == self.encryptedBackupButton) ? NSControlStateValueOn : NSControlStateValueOff];
    } else {
        NSLog(@"DeviceBackupRestore: 警告 - encryptedBackupButton 类型错误或为空");
    }
    
    if ([self.restoreButton isKindOfClass:[NSButton class]]) {
        [self.restoreButton setState:(activeButton == self.restoreButton) ? NSControlStateValueOn : NSControlStateValueOff];
    } else {
        NSLog(@"DeviceBackupRestore: 警告 - restoreButton 类型错误或为空");
    }
}

#pragma mark - 公开方法
//选择性备份对话框
- (IBAction)showSelectiveBackupOptions:(id)sender {
    BackupOptionTask *optionTask = [BackupOptionTask sharedInstance];
    
    NSError *error = nil;
    if ([optionTask connectToDevice:self.lockedDeviceID error:&error]) {
        BackupDataType supportedTypes = [optionTask getSupportedDataTypes:&error];
        [self showDataTypeSelectionDialog:supportedTypes];
    }
}

- (void)showDataTypeSelectionDialog:(BackupDataType)supportedTypes {
    NSLog(@"DeviceBackupRestore: 显示数据类型选择对话框，支持的类型: %lu", (unsigned long)supportedTypes);
    
    @autoreleasepool {
        // 1. 在主线程执行所有 UI 操作
        dispatch_async(dispatch_get_main_queue(), ^{
            // 2. 安全地清理现有窗口
            if (self.dataTypeSelectionWindow) {
                // 保存临时引用
                NSWindow *oldWindow = self.dataTypeSelectionWindow;
                // 清除代理
                oldWindow.delegate = nil;
                // 清除属性
                self.dataTypeSelectionWindow = nil;
                self.dataTypeCheckboxes = nil;
                // 关闭窗口
                [oldWindow close];
            }
            
            // 3. 创建新窗口
            NSWindow *selectionWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 500, 600)
                                                                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                                    backing:NSBackingStoreBuffered
                                                                      defer:NO];
            
            // 4. 配置窗口基本属性
            [selectionWindow setReleasedWhenClosed:NO];
            
            // 5. 设置窗口标题
            NSString *windowTitle = [[LanguageManager sharedManager] localizedStringForKeys:@"SelectiveBackupTitle"
                                                                                inModule:@"Backup"
                                                                            defaultValue:@"选择备份数据类型"];
            [selectionWindow setTitle:windowTitle];
            [selectionWindow center];
            
            // 6. 创建和配置内容视图
            NSView *contentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 500, 600)];
            [selectionWindow setContentView:contentView];
            
            // 7. 创建和配置滚动视图
            NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(20, 80, 460, 450)];
            [scrollView setHasVerticalScroller:YES];
            [scrollView setHasHorizontalScroller:NO];
            [scrollView setBorderType:NSBezelBorder];
            [contentView addSubview:scrollView];
            
            // 8. 创建文档视图
            NSView *documentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 440, 400)];
            [scrollView setDocumentView:documentView];
            
            // 9. 创建复选框数组
            NSMutableArray *checkboxes = [NSMutableArray array];
            NSMutableArray *dataTypes = [NSMutableArray array];
            
            // 10. 创建和配置说明标签
            NSTextField *instructionLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 520, 460, 60)];
            [instructionLabel setStringValue:[[LanguageManager sharedManager] localizedStringForKeys:@"SelectiveBackupInstruction"
                                                                                         inModule:@"Backup"
                                                                                    defaultValue:@"请选择要备份的数据类型。只有支持的数据类型会被显示。"]];
            [self configureInstructionLabel:instructionLabel];
            [contentView addSubview:instructionLabel];
            
            // 11. 创建复选框
            CGFloat yPosition = [self createCheckboxesInView:documentView
                                              withDataTypes:[BackupOptionTask getAllAvailableDataTypes]
                                           supportedTypes:supportedTypes
                                              checkboxes:checkboxes
                                              dataTypes:dataTypes];
            
            // 12. 调整文档视图大小
            CGFloat totalHeight = MAX((checkboxes.count * 40) + 50, 400);
            [documentView setFrame:NSMakeRect(0, 0, 440, totalHeight)];
            
            // 13. 创建控制按钮
            [self createControlButtonsInView:contentView];
            
            // 14. 保存引用（确保在设置代理之前）
            self.dataTypeCheckboxes = [checkboxes copy];
            self.dataTypeSelectionWindow = selectionWindow;
            self.supportedDataTypes = supportedTypes;
            
            // 15. 最后设置代理
            selectionWindow.delegate = self;
            
            // 16. 显示窗口（只调用一次）
            [selectionWindow makeKeyAndOrderFront:nil];
        });
    }
}

#pragma mark - Helper Methods

- (void)configureInstructionLabel:(NSTextField *)label {
    [label setBezeled:NO];
    [label setDrawsBackground:NO];
    [label setEditable:NO];
    [label setSelectable:NO];
    [label setFont:[NSFont systemFontOfSize:13]];
    [label setTextColor:[NSColor secondaryLabelColor]];
    [label setLineBreakMode:NSLineBreakByWordWrapping];
    NSTextFieldCell *cell = [[NSTextFieldCell alloc] init];
    [cell setWraps:YES];
    [label setCell:cell];
}

- (CGFloat)createCheckboxesInView:(NSView *)documentView
                   withDataTypes:(NSArray<NSNumber *> *)allDataTypes
                supportedTypes:(BackupDataType)supportedTypes
                   checkboxes:(NSMutableArray *)checkboxes
                   dataTypes:(NSMutableArray *)dataTypes {
    CGFloat yPosition = 350;
    CGFloat checkboxHeight = 30;
    CGFloat padding = 10;
    
    for (NSNumber *dataTypeNum in allDataTypes) {
        BackupDataType dataType = [dataTypeNum unsignedIntegerValue];
        if (!(supportedTypes & dataType)) {
            continue;
        }
        
        NSButton *checkbox = [self createCheckboxWithFrame:NSMakeRect(20, yPosition, 400, checkboxHeight)
                                               dataType:dataType];
        [documentView addSubview:checkbox];
        [checkboxes addObject:checkbox];
        [dataTypes addObject:dataTypeNum];
        
        yPosition -= (checkboxHeight + padding);
    }
    
    return yPosition;
}

- (NSButton *)createCheckboxWithFrame:(NSRect)frame dataType:(BackupDataType)dataType {
    NSButton *checkbox = [[NSButton alloc] initWithFrame:frame];
    [checkbox setButtonType:NSButtonTypeSwitch];
    [checkbox setState:NSControlStateValueOff];
    [checkbox setTitle:[self getLocalizedDataTypeName:dataType]];
    [checkbox setFont:[NSFont systemFontOfSize:14]];
    [checkbox setTag:dataType];
    [checkbox setTarget:self];
    [checkbox setAction:@selector(dataTypeCheckboxChanged:)];
    return checkbox;
}

- (void)createControlButtonsInView:(NSView *)contentView {
    // 创建全选/全不选按钮
    [self createButton:@"SelectAll" frame:NSMakeRect(20, 45, 100, 30)
               action:@selector(selectAllDataTypes:) tag:1 inView:contentView];
    
    [self createButton:@"DeselectAll" frame:NSMakeRect(130, 45, 100, 30)
               action:@selector(deselectAllDataTypes:) tag:0 inView:contentView];
    
    // 创建操作按钮
    [self createButton:@"Cancel" frame:NSMakeRect(280, 10, 100, 30)
               action:@selector(cancelDataTypeSelection:) tag:-1 inView:contentView];
    
    NSButton *startButton = [self createButton:@"StartBackup" frame:NSMakeRect(390, 10, 100, 30)
                                      action:@selector(startSelectiveBackup:) tag:-1 inView:contentView];
    [startButton setKeyEquivalent:@"\r"];
}

- (NSButton *)createButton:(NSString *)titleKey frame:(NSRect)frame action:(SEL)action tag:(NSInteger)tag inView:(NSView *)view {
    NSButton *button = [[NSButton alloc] initWithFrame:frame];
    [button setTitle:[[LanguageManager sharedManager] localizedStringForKeys:titleKey
                                                                  inModule:@"Backup"
                                                              defaultValue:titleKey]];
    [button setTarget:self];
    [button setAction:action];
    [button setTag:tag];
    [view addSubview:button];
    return button;
}

#pragma mark - Window Delegate Methods

- (void)windowWillClose:(NSNotification *)notification {
    if (notification.object == self.dataTypeSelectionWindow) {
        // 清理复选框
        for (NSButton *checkbox in self.dataTypeCheckboxes) {
            [checkbox setTarget:nil];
            [checkbox setAction:NULL];
        }
        
        // 清理窗口引用
        self.dataTypeSelectionWindow.delegate = nil;
        self.dataTypeSelectionWindow = nil;
        self.dataTypeCheckboxes = nil;
    }
}





#pragma mark - 数据类型本地化

- (NSString *)getLocalizedDataTypeName:(BackupDataType)dataType {
    LanguageManager *languageManager = [LanguageManager sharedManager];
    
    // 定义数据类型到本地化键的映射
    NSDictionary<NSNumber *, NSString *> *dataTypeLocalizationKeys = @{
        @(BackupDataTypeContacts): @"DataTypeContacts",
        @(BackupDataTypeCalendars): @"DataTypeCalendars",
        @(BackupDataTypeBookmarks): @"DataTypeBookmarks",
        @(BackupDataTypeNotes): @"DataTypeNotes",
        @(BackupDataTypeReminders): @"DataTypeReminders",
        @(BackupDataTypeApplications): @"DataTypeApplications",
        @(BackupDataTypeConfiguration): @"DataTypeConfiguration",
        @(BackupDataTypeKeychain): @"DataTypeKeychain",
        @(BackupDataTypeVoiceMemos): @"DataTypeVoiceMemos",
        @(BackupDataTypeWallpaper): @"DataTypeWallpaper"
    };
    
    // 获取对应的本地化键
    NSString *localizationKey = dataTypeLocalizationKeys[@(dataType)];
    
    if (localizationKey) {
        NSString *localizedName = [languageManager localizedStringForKeys:localizationKey
                                                                inModule:@"DataTypes"
                                                            defaultValue:[BackupOptionTask stringForDataType:dataType]];
        return localizedName;
    }
    
    // 如果没有找到对应的本地化键，返回英文名称
    return [BackupOptionTask stringForDataType:dataType];
}

#pragma mark - 复选框事件处理

- (IBAction)dataTypeCheckboxChanged:(NSButton *)sender {
    BackupDataType dataType = (BackupDataType)sender.tag;
    BOOL isSelected = (sender.state == NSControlStateValueOn);
    
    NSLog(@"DeviceBackupRestore: 数据类型 %@ %@",
          [BackupOptionTask stringForDataType:dataType],
          isSelected ? @"已选中" : @"已取消选中");
}

- (IBAction)selectAllDataTypes:(NSButton *)sender {
    NSLog(@"DeviceBackupRestore: 选择所有数据类型");
    
    for (NSButton *checkbox in self.dataTypeCheckboxes) {
        [checkbox setState:NSControlStateValueOn];
    }
}

- (IBAction)deselectAllDataTypes:(NSButton *)sender {
    NSLog(@"DeviceBackupRestore: 取消选择所有数据类型");
    
    for (NSButton *checkbox in self.dataTypeCheckboxes) {
        [checkbox setState:NSControlStateValueOff];
    }
}

- (IBAction)cancelDataTypeSelection:(NSButton *)sender {
    NSLog(@"DeviceBackupRestore: 取消数据类型选择");
    
    // 安全关闭窗口
    if (self.dataTypeSelectionWindow) {
        [self.dataTypeSelectionWindow performClose:nil]; // 使用 performClose 而不是直接 close
    }
}

- (IBAction)startSelectiveBackup:(NSButton *)sender {
    NSLog(@"DeviceBackupRestore: 开始选择性备份");
    
    NSLog(@"DeviceBackupRestore: 开始选择性备份");
    
    // 收集选中的数据类型
    BackupDataType selectedTypes = BackupDataTypeNone;
    NSMutableArray *selectedTypeNames = [NSMutableArray array];
    
    // ✅ 添加空指针检查
    if (!self.dataTypeCheckboxes) {
        NSLog(@"DeviceBackupRestore: 错误 - 复选框数组为空");
        return;
    }

    
    for (NSButton *checkbox in self.dataTypeCheckboxes) {
        // ✅ 确保 checkbox 有效
        if (checkbox && [checkbox isKindOfClass:[NSButton class]]) {
            if (checkbox.state == NSControlStateValueOn) {
                BackupDataType dataType = (BackupDataType)checkbox.tag;
                selectedTypes |= dataType;
                [selectedTypeNames addObject:[BackupOptionTask stringForDataType:dataType]];
            }
        }
    }
    
    // 检查是否至少选择了一种数据类型
    if (selectedTypes == BackupDataTypeNone) {
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:[[LanguageManager sharedManager] localizedStringForKeys:@"NoDataTypeSelected"
                                                                            inModule:@"Backup"
                                                                        defaultValue:@"未选择数据类型"]];
        [alert setInformativeText:[[LanguageManager sharedManager] localizedStringForKeys:@"PleaseSelectAtLeastOneDataType"
                                                                                inModule:@"Backup"
                                                                            defaultValue:@"请至少选择一种要备份的数据类型"]];
        [alert addButtonWithTitle:[[LanguageManager sharedManager] localizedStringForKeys:@"OK"
                                                                                inModule:@"Common"
                                                                            defaultValue:@"确定"]];
        
        // ✅ 安全地显示警告对话框
        if (self.dataTypeSelectionWindow) {
            [alert beginSheetModalForWindow:self.dataTypeSelectionWindow completionHandler:nil];
        } else {
            [alert runModal];
        }
        return;
    }
    
    // ✅ 安全关闭选择对话框
     if (self.dataTypeSelectionWindow) {
         [self.dataTypeSelectionWindow performClose:nil];
     }
    
    // 关闭选择对话框
    self.dataTypeSelectionWindow = nil;
    self.dataTypeCheckboxes = nil;
    
    // 显示选中的数据类型
    NSString *selectedTypesString = [selectedTypeNames componentsJoinedByString:@", "];
    NSString *logMessage = [NSString stringWithFormat:@"[INFO] 开始选择性备份，数据类型: %@", selectedTypesString];
    [self showLogsWithMessage:logMessage];
    
    // 切换到备份进度视图
    [self displayContentController:self.backupProgressViewController];
    [self updateButtonStates:self.startBackupButton];
    
    // 开始选择性备份
    [self performSelectiveBackup:selectedTypes];
}

#pragma mark - 执行选择性备份

- (void)performSelectiveBackup:(BackupDataType)selectedTypes {
    NSLog(@"DeviceBackupRestore: 执行选择性备份，类型: %lu", (unsigned long)selectedTypes);
    
    // 获取设备信息
    NSString *deviceUDID = self.lockedDeviceID;
    if (!deviceUDID || deviceUDID.length == 0) {
        NSString *errorMessage = @"[ERR] 设备未连接或未选择";
        [self showLogsWithMessage:errorMessage];
        return;
    }
    
    // 创建时间戳备份目录
    NSString *timestampedBackupPath = [self createTimestampedBackupDirectoryForDevice:deviceUDID];
    if (!timestampedBackupPath) {
        NSString *errorMessage = @"[ERR] 无法创建备份目录";
        [self showLogsWithMessage:errorMessage];
        return;
    }
    
    [self showLogsWithMessage:[NSString stringWithFormat:@"选择性备份目录: %@", [timestampedBackupPath lastPathComponent]]];
    
    // 更新备份进度视图
    if (self.backupProgressViewController) {
        [self.backupProgressViewController startBackupWithInitialLog:@"开始选择性备份...\n"];
        [self.backupProgressViewController updateProgress:0.0];
    }
    
    // 使用BackupOptionTask执行选择性备份
    BackupOptionTask *optionTask = [BackupOptionTask sharedInstance];
    
    // ✅ 使用 weak self 避免循环引用
    __weak typeof(self) weakSelf = self;
    
    // 设置日志回调
    optionTask.logCallback = ^(NSString *logMessage) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [strongSelf showLogsWithMessage:logMessage];
            });
        }
    };
    
    // 设置进度回调
    optionTask.progressCallback = ^(float progress, NSString *operation, NSUInteger current, NSUInteger total) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf && strongSelf.backupProgressViewController) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [strongSelf.backupProgressViewController updateProgress:progress];
                
                NSString *progressMessage = [NSString stringWithFormat:@"[进度] %@ (%.1f%%) - %lu/%lu",
                                           operation, progress, (unsigned long)current, (unsigned long)total];
                [strongSelf showLogsWithMessage:progressMessage];
            });
        }
    };
    
    // 设置完成回调
    optionTask.completionCallback = ^(BOOL success, BackupDataType completedTypes, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (success) {
                    NSString *successMessage = @"[SUC] 选择性备份完成";
                    [strongSelf showLogsWithMessage:successMessage];
                    
                    if (strongSelf.backupProgressViewController) {
                        [strongSelf.backupProgressViewController updateProgress:100.0];
                    }
                    
                    // 刷新备份列表
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        [strongSelf refreshBackupListAfterCompletion:timestampedBackupPath];
                    });
                } else {
                    NSString *errorMessage = [NSString stringWithFormat:@"[ERR] 选择性备份失败: %@",
                                            error ? error.localizedDescription : @"未知错误"];
                    [strongSelf showLogsWithMessage:errorMessage];
                    
                    if (strongSelf.backupProgressViewController) {
                        [strongSelf.backupProgressViewController updateProgress:50.0];
                    }
                }
                
                // ✅ 清除回调，避免内存泄漏
                optionTask.logCallback = nil;
                optionTask.progressCallback = nil;
                optionTask.completionCallback = nil;
            });
        } else {
            // ✅ 如果 weakSelf 已经被释放，也要清除回调
            optionTask.logCallback = nil;
            optionTask.progressCallback = nil;
            optionTask.completionCallback = nil;
        }
    };
    
    // 在后台线程执行备份
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSError *error = nil;
        BOOL success = [optionTask backupSelectedDataTypes:selectedTypes
                                               toDirectory:timestampedBackupPath
                                                     error:&error];
        
        if (!success && error) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (strongSelf) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSString *errorMessage = [NSString stringWithFormat:@"[ERR] 备份启动失败: %@", error.localizedDescription];
                    [strongSelf showLogsWithMessage:errorMessage];
                });
            }
        }
    });
}

- (void)dealloc {
    NSLog(@"DeviceBackupRestore: dealloc");
    
    // 清理窗口引用
    if (self.dataTypeSelectionWindow) {
        [self.dataTypeSelectionWindow close];
        self.dataTypeSelectionWindow = nil;
    }
    
    // 清理数组引用
    self.dataTypeCheckboxes = nil;
    
    // 清理 BackupOptionTask 的回调
    BackupOptionTask *optionTask = [BackupOptionTask sharedInstance];
    optionTask.logCallback = nil;
    optionTask.progressCallback = nil;
    optionTask.completionCallback = nil;
    
    // 移除通知观察者
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

// 添加应用终止时的清理
- (void)applicationWillTerminate:(NSNotification *)notification {
    NSLog(@"DeviceBackupRestore: 应用即将终止，清理资源");
    
    // 清理所有回调
    BackupOptionTask *optionTask = [BackupOptionTask sharedInstance];
    optionTask.logCallback = nil;
    optionTask.progressCallback = nil;
    optionTask.completionCallback = nil;
    
    // 关闭窗口
    if (self.dataTypeSelectionWindow) {
        [self.dataTypeSelectionWindow close];
        self.dataTypeSelectionWindow = nil;
    }
}

// 备份调用方法
- (IBAction)triggerStartBackup:(NSButton *)sender {
    sender.enabled = NO; // 禁用按钮，防止重复点击
    
    NSString *deviceUDID = self.lockedDeviceID;
    
    if (!deviceUDID || deviceUDID.length == 0) {
        NSString *pleaseSelectDeviceTitle = [[LanguageManager sharedManager] localizedStringForKeys:@"PleaseSelectDeviceTitle" inModule:@"Flasher" defaultValue:@"Please Select Device"];
        pleaseSelectDeviceTitle = [NSString stringWithFormat:@"[WAR] %@", pleaseSelectDeviceTitle];
        [self showLogsWithMessage:pleaseSelectDeviceTitle];
        sender.enabled = YES;
        return;
    }

    [self showLogsWithMessage:[NSString stringWithFormat:@"将要备份的设备: %@ 模式: %@", self.lockedDeviceID, self.deviceMode]];
    
    // 清空当前备份文件列表
    [self.currentBackupFiles removeAllObjects];
    
    // 重置备份进度视图控制器的状态
    if (self.backupProgressViewController) {
        [self.backupProgressViewController startBackupWithInitialLog:@"准备开始备份...\n"];
        [self.backupProgressViewController updateProgress:0.0];
    }
    
    // 记录操作日志
    NSString *logRecord = [[LanguageManager sharedManager] localizedStringForKeys:@"HandleBackupDevice"
                                                                       inModule:@"OperationRecods"
                                                                  defaultValue:@"Handle Backup Device"];
    [[DataBaseManager sharedInstance] addOperationRecord:logRecord forDeviceECID:deviceUDID UDID:deviceUDID];
    
    if (![self.deviceMode isEqualToString:@"Normal"]) {
        NSString *logMessage = @"[WAR] 设备模式非正常，无法执行备份";
        [self showLogsWithMessage:logMessage];
        sender.enabled = YES;
        self.isWorking = NO;
        return;
    }
    
    // ✅ 创建带时间戳的备份目录
    NSString *timestampedBackupPath = [self createTimestampedBackupDirectoryForDevice:deviceUDID];
    if (!timestampedBackupPath) {
        NSString *errorMessage = @"[ERR] 无法创建备份目录";
        [self showLogsWithMessage:errorMessage];
        sender.enabled = YES;
        self.isWorking = NO;
        return;
    }
    
    [self showLogsWithMessage:[NSString stringWithFormat:@"备份目录已创建: %@", [timestampedBackupPath lastPathComponent]]];
    
    // 强引用保留自己，防止被释放
    __strong typeof(self) strongSelf = self;
    
    // 获取BackupTask实例并设置日志回调
    BackupTask *backupTask = [BackupTask sharedInstance];
    
    // 设置日志回调 - 关键修改
    backupTask.logCallback = ^(NSString *logMessage) {
        dispatch_async(dispatch_get_main_queue(), ^{
            // 格式化日志消息并显示
            NSString *formattedMessage = [NSString stringWithFormat:@"%@", logMessage];
            [strongSelf showLogsWithMessage:formattedMessage];
            
            // 解析文件信息并添加到列表
            [strongSelf parseAndAddBackupFileInfo:logMessage];
        });
    };
    
    // 预先检查设备连接性
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // 初步测试设备连接性
        idevice_t testDevice = NULL;
        idevice_error_t ierr = idevice_new(&testDevice, [deviceUDID UTF8String]);
        
        if (ierr != IDEVICE_E_SUCCESS) {
            NSString *errorMsg = [NSString stringWithFormat:@"设备连接测试失败，错误码: %d", ierr];
            
            dispatch_async(dispatch_get_main_queue(), ^{
                [strongSelf showLogsWithMessage:[NSString stringWithFormat:@"[ERR] %@", errorMsg]];
                sender.enabled = YES;
                strongSelf.isWorking = NO;
            });
            
            if (testDevice) {
                idevice_free(testDevice);
            }
            return;
        }
        
        if (testDevice) {
            idevice_free(testDevice);
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            [strongSelf showLogsWithMessage:@"设备连接测试成功，开始执行备份任务"];
        });
        
        // 使用新的方法：传递自定义备份路径
        [backupTask startBackupForDevice:deviceUDID
                       customBackupPath:timestampedBackupPath  // 传递时间戳备份路径
                               progress:^(double progress, NSString *message) {
            // 进度更新逻辑保持不变
            dispatch_async(dispatch_get_main_queue(), ^{
                // 更新备份进度视图控制器的进度
                if (strongSelf.backupProgressViewController) {
                    [strongSelf.backupProgressViewController updateProgress:progress * 100];
                }
                
                // 定期显示进度信息到日志
                static double lastLoggedProgress = -1;
                if (progress - lastLoggedProgress >= 0.10 || progress >= 1.0) { // 每10%显示一次
                    NSString *progressMessage = [NSString stringWithFormat:@"%@", message];
                    [strongSelf showLogsWithMessage:progressMessage];
                    lastLoggedProgress = progress;
                }
            });
        }
        completion:^(BOOL success, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                sender.enabled = YES;
                strongSelf.isWorking = NO;
                
                if (success) {
                    
                    // ✅ 计算当前备份的实际大小
                    uint64_t currentBackupSize = [strongSelf calculateDirectorySize:timestampedBackupPath];
                    NSString *currentBackupSizeFormatted = [strongSelf formatSize:currentBackupSize];
                    
                    
                    // 更新进度为完成状态
                    if (strongSelf.backupProgressViewController) {
                        [strongSelf.backupProgressViewController updateProgress:100.0];
                        // ✅ 备份完成后刷新当前设备的备份列表
                        [strongSelf.backupProgressViewController checkAndLoadExistingBackupData];
                    }
                    
                    NSString *logDeviceBackupCompletedMessage = [[LanguageManager sharedManager] localizedStringForKeys:@"DeviceBackupCompleted"
                                                                                   inModule:@"Backup"
                                                                              defaultValue:@"Device Backup completed successfully"];
                    
                    // ✅ 显示当前备份的大小而不是总大小
                    [strongSelf showLogsWithMessage:[NSString stringWithFormat:@"[SUC] %@ - 备份路径: %@, 备份大小: %@",
                                                   logDeviceBackupCompletedMessage,
                                                   [timestampedBackupPath lastPathComponent],
                                                   currentBackupSizeFormatted]];
                    
                    
                    // ✅ 延迟刷新备份列表，确保文件系统操作完成
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        [strongSelf refreshBackupListAfterCompletion:timestampedBackupPath];
                    });
                    
                } else {
                    // 更新进度为失败状态
                    if (strongSelf.backupProgressViewController) {
                        [strongSelf.backupProgressViewController updateProgress:50.0];
                    }
                    
                    NSString *errorMessage = error ? error.localizedDescription : @"未知错误";
                    NSString *logDeviceBackupFailedMessage = [NSString stringWithFormat:@"设备备份失败: %@", errorMessage];
                    [strongSelf showLogsWithMessage:[NSString stringWithFormat:@"[ERR] %@", logDeviceBackupFailedMessage]];
                }
                
                // 清除日志回调，避免内存泄漏
                backupTask.logCallback = nil;
            });
        }];
    });
}

#pragma mark - 备份完成后刷新
// 计算目录大小的辅助方法
- (unsigned long long)calculateDirectorySize:(NSString *)dirPath {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSDirectoryEnumerator *enumerator = [fileManager enumeratorAtPath:dirPath];
    unsigned long long totalSize = 0;
    
    NSString *filePath;
    while ((filePath = [enumerator nextObject])) {
        NSString *fullPath = [dirPath stringByAppendingPathComponent:filePath];
        NSDictionary *fileAttributes = [fileManager attributesOfItemAtPath:fullPath error:nil];
        if (fileAttributes) {
            totalSize += [fileAttributes[NSFileSize] unsignedLongLongValue];
        }
    }
    
    return totalSize;
}

// 格式化文件大小的辅助方法
- (NSString *)formatSize:(uint64_t)size {
    NSByteCountFormatter *formatter = [[NSByteCountFormatter alloc] init];
    formatter.countStyle = NSByteCountFormatterCountStyleFile;
    formatter.allowedUnits = NSByteCountFormatterUseAll;
    return [formatter stringFromByteCount:(long long)size];
}

- (void)refreshBackupListAfterCompletion:(NSString *)newBackupPath {
    NSLog(@"DeviceBackupRestore: 备份完成，刷新表格数据");
    
    if (self.backupProgressViewController) {
        // 获取当前设备信息
        NSString *currentDeviceID = self.lockedDeviceID;
        NSDictionary *deviceInfo = self.LockedDeviceInfo;
        
        if (currentDeviceID && currentDeviceID.length > 0) {
            NSLog(@"DeviceBackupRestore: 为设备 %@ 刷新备份列表", currentDeviceID);
            
            // 重新加载当前设备的备份数据
            [self.backupProgressViewController loadBackupDataForDevice:currentDeviceID deviceInfo:deviceInfo];
            
            // 显示刷新成功消息
            NSString *refreshMessage = [NSString stringWithFormat:@"备份列表已刷新，新备份: %@", [newBackupPath lastPathComponent]];
            [self showLogsWithMessage:refreshMessage];
            
            // ✅ 可选：滚动到最新的备份项（如果需要的话）
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self.backupProgressViewController scrollToNewestBackup];
            });
        } else {
            NSLog(@"DeviceBackupRestore: 无法刷新 - 当前设备ID为空");
            [self showLogsWithMessage:@"[WAR] 无法刷新备份列表 - 设备信息缺失"];
        }
    }
}



#pragma mark - 时间戳备份目录创建

// 为设备创建带时间戳的备份目录
- (NSString *)createTimestampedBackupDirectoryForDevice:(NSString *)deviceUDID {
    NSLog(@"DeviceBackupRestore: 为设备 %@ 创建时间戳备份目录", deviceUDID);
    
    // 获取基础备份路径
    NSString *defaultBackupPath = [DatalogsSettings defaultBackupPath];
    
    // 创建设备专用目录路径
    NSString *deviceBackupPath = [defaultBackupPath stringByAppendingPathComponent:deviceUDID];
    
    // 生成时间戳字符串
    NSString *timestampString = [self generateBackupTimestamp];
    
    // 创建完整的备份目录路径：/BackupPath/[DeviceUDID]/[TimeStamp]/
    NSString *timestampedBackupPath = [deviceBackupPath stringByAppendingPathComponent:timestampString];
    
    NSLog(@"DeviceBackupRestore: 时间戳备份路径: %@", timestampedBackupPath);
    
    // 创建目录
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSError *error = nil;
    
    BOOL success = [fileManager createDirectoryAtPath:timestampedBackupPath
                           withIntermediateDirectories:YES
                                            attributes:nil
                                                 error:&error];
    
    if (!success) {
        NSLog(@"DeviceBackupRestore: 创建备份目录失败: %@", error.localizedDescription);
        [self showLogsWithMessage:[NSString stringWithFormat:@"[ERR] 创建备份目录失败: %@", error.localizedDescription]];
        return nil;
    }
    
    NSLog(@"DeviceBackupRestore: 成功创建备份目录: %@", timestampedBackupPath);
    return timestampedBackupPath;
}

// 生成备份时间戳字符串
- (NSString *)generateBackupTimestamp {
    NSDate *now = [NSDate date];
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    
    // 设置时区为本地时区
    [formatter setTimeZone:[NSTimeZone localTimeZone]];
    
    // 创建年月日部分 (YYYYMMDD)
    [formatter setDateFormat:@"yyyyMMdd"];
    NSString *datePart = [formatter stringFromDate:now];
    
    // 创建时分部分 (HHMM)
    [formatter setDateFormat:@"HHmm"];
    NSString *timePart = [formatter stringFromDate:now];
    
    // 确定AM/PM
    [formatter setDateFormat:@"a"];
    NSString *ampmPart = [formatter stringFromDate:now];
    
    // 转换AM/PM为英文（防止本地化问题）
    if ([ampmPart containsString:@"上午"] || [ampmPart containsString:@"AM"]) {
        ampmPart = @"AM";
    } else {
        ampmPart = @"PM";
    }
    
    // 组合成最终的时间戳字符串
    NSString *timestamp = [NSString stringWithFormat:@"%@%@%@", datePart, timePart, ampmPart];
    
    NSLog(@"DeviceBackupRestore: 生成备份时间戳: %@", timestamp);
    return timestamp;
}

// 修改解析备份文件信息的方法，使用新的时间戳目录
- (void)parseAndAddBackupFileInfo:(NSString *)logMessage {
    // 解析不同类型的文件信息
    if ([logMessage containsString:@"Receiving file"] || [logMessage containsString:@"Sending file"]) {
        NSString *fileName = [self extractFileNameFromMessage:logMessage];
        NSString *fileSize = [self extractFileSizeFromMessage:logMessage];
        NSString *operation = [logMessage containsString:@"Receiving"] ? @"接收" : @"发送";
        
        // ✅ 使用当前备份会话的路径而不是默认路径
        NSString *currentBackupPath = [self getCurrentBackupSessionPath];
        NSString *isEncrypted = [logMessage containsString:@"Encrypted"] ? @"Yes" : @"No";
        NSString *isImported = [logMessage containsString:@"Backuptype"] ? @"Import" : @"-";
        
        if (fileName && fileName.length > 0) {
            NSDictionary *fileInfo = @{
                @"fileName": fileName,
                @"backuplocation": currentBackupPath ?: [DatalogsSettings defaultBackupPath],
                @"backupfilesize": fileSize ?: @"-",
                @"backupencryptionstatus": isEncrypted ?: @"-",
                @"backuptype": isImported ?: @"-",
                @"backupdate": [NSDate date]
            };
            
            [self.currentBackupFiles addObject:fileInfo];
            
            // 限制列表长度，避免过多条目影响性能
            if (self.currentBackupFiles.count > 1000) {
                [self.currentBackupFiles removeObjectsInRange:NSMakeRange(0, 100)];
            }
            
            // 通知备份进度视图控制器更新文件列表
            if (self.backupProgressViewController) {
                [self.backupProgressViewController updateBackupFilesList:self.currentBackupFiles];
            }
        }
    }
}

// 获取当前备份会话的路径（如果需要跟踪当前备份路径）
- (NSString *)getCurrentBackupSessionPath {
    // 这里可以保存当前备份会话的路径，如果需要的话
    // 目前返回默认路径，可以根据需要进行扩展
    return nil; // 返回nil使用默认路径
}



- (NSString *)extractFileNameFromMessage:(NSString *)message {
    // 提取文件名的正则表达式
    NSError *error = nil;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"(?:Receiving|Sending) file (.+?)(?:\\s|$)"
                                                                           options:NSRegularExpressionCaseInsensitive
                                                                             error:&error];
    
    if (error) {
        return nil;
    }
    
    NSTextCheckingResult *match = [regex firstMatchInString:message
                                                    options:0
                                                      range:NSMakeRange(0, message.length)];
    
    if (match && match.numberOfRanges > 1) {
        NSString *fullPath = [message substringWithRange:[match rangeAtIndex:1]];
        // 只返回文件名，不包含路径
        return [fullPath lastPathComponent];
    }
    
    return nil;
}

- (NSString *)extractFileSizeFromMessage:(NSString *)message {
    // 提取文件大小信息
    NSError *error = nil;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"(\\d+(?:\\.\\d+)?\\s*(?:KB|MB|GB|B))"
                                                                           options:NSRegularExpressionCaseInsensitive
                                                                             error:&error];
    
    if (error) {
        return nil;
    }
    
    NSTextCheckingResult *match = [regex firstMatchInString:message
                                                    options:0
                                                      range:NSMakeRange(0, message.length)];
    
    if (match) {
        return [message substringWithRange:match.range];
    }
    
    return nil;
}

- (void)clearBackupFilesList {
    [self.currentBackupFiles removeAllObjects];
    if (self.backupProgressViewController) {
        [self.backupProgressViewController updateBackupFilesList:self.currentBackupFiles];
    }
}


- (void)startBackup {
    NSLog(@"DeviceBackupRestore: 开始备份");
    if (self.isBackupInProgress) {
        NSLog(@"DeviceBackupRestore: 备份已在进行中，忽略请求");
        return;
    }
    
    self.backupInProgress = YES;
    self.backupProgress = 0.0;
    
    // 通知备份进度视图控制器开始备份
    [self.backupProgressViewController startBackupWithInitialLog:@"开始备份...\n"];
}

#pragma mark - BackupProgressDelegate
- (void)cancelBackup {
    NSLog(@"DeviceBackupRestore: 取消备份");
    if (!self.isBackupInProgress) {
        NSLog(@"DeviceBackupRestore: 当前没有正在进行的备份，忽略请求");
        return;
    }
    
    self.backupInProgress = NO;
    [self.backupProgressViewController appendLog:@"备份已取消\n"];
    NSLog(@"DeviceBackupRestore: 备份已取消");
}

- (void)startRestore {
    NSLog(@"DeviceBackupRestore: 开始恢复");
    if (self.isRestoreInProgress) {
        NSLog(@"DeviceBackupRestore: 恢复已在进行中，忽略请求");
        return;
    }
    
    self.restoreInProgress = YES;
    self.restoreProgress = 0.0;
    
    // 通知恢复进度视图控制器开始恢复
    [self.restoreProgressViewController startRestoreWithInitialLog:@"开始恢复...\n"];
    
    // 模拟恢复进度
    [self simulateRestoreProcess];
}

- (void)cancelRestore {
    NSLog(@"DeviceBackupRestore: 取消恢复");
    if (!self.isRestoreInProgress) {
        NSLog(@"DeviceBackupRestore: 当前没有正在进行的恢复，忽略请求");
        return;
    }
    
    self.restoreInProgress = NO;
    [self.restoreProgressViewController appendLog:@"恢复已取消\n"];
    NSLog(@"DeviceBackupRestore: 恢复已取消");
}

- (void)setBackupLocation:(NSString *)location {
    NSLog(@"DeviceBackupRestore: 设置备份位置: %@", location);
    self.backupLocationPath = location;
}

- (NSString *)currentBackupLocation {
    NSLog(@"DeviceBackupRestore: 获取当前备份位置: %@", self.backupLocationPath);
    return self.backupLocationPath;
}

- (void)setBackupEncryption:(BOOL)encrypted {
    NSLog(@"DeviceBackupRestore: 设置备份加密状态: %@", encrypted ? @"已加密" : @"未加密");
    self.backupIsEncrypted = encrypted;
}

- (BOOL)isBackupEncrypted {
    NSLog(@"DeviceBackupRestore: 获取备份加密状态: %@", self.backupIsEncrypted ? @"已加密" : @"未加密");
    return self.backupIsEncrypted;
}

#pragma mark - 加密设置

- (void)changePassword:(NSString *)currentPassword newPassword:(NSString *)newPassword {
    NSLog(@"DeviceBackupRestore: 修改密码");
    
    // 在实际应用中，应该执行实际的密码验证和修改
    self.backupIsEncrypted = YES;
    NSLog(@"DeviceBackupRestore: 密码已更新");
    
    // 显示成功提示
    [self showAlert:@"密码已更新" informativeText:@"设备备份密码已成功更新"];
}

- (void)deletePassword:(NSString *)currentPassword {
    NSLog(@"DeviceBackupRestore: 删除密码");
    
    // 在实际应用中，应该执行实际的密码验证和删除
    self.backupIsEncrypted = NO;
    NSLog(@"DeviceBackupRestore: 密码已删除");
    
    // 显示成功提示
    [self showAlert:@"密码已删除" informativeText:@"设备备份密码已成功删除"];
}

#pragma mark - 帮助方法

- (void)showAlert:(NSString *)title informativeText:(NSString *)text {
    NSLog(@"DeviceBackupRestore: 显示警告: %@ - %@", title, text);
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:title];
    [alert setInformativeText:text];
    [alert addButtonWithTitle:@"确定"];
    [alert beginSheetModalForWindow:self.view.window completionHandler:nil];
}


// 模拟恢复过程
- (void)simulateRestoreProcess {
    NSLog(@"DeviceBackupRestore: 开始模拟恢复过程");
    __block double progress = 0.0;
    __block NSInteger step = 0;
    
    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_source_set_timer(timer, dispatch_walltime(NULL, 0), 0.2 * NSEC_PER_SEC, 0.05 * NSEC_PER_SEC);
    
    dispatch_source_set_event_handler(timer, ^{
        if (!self.isRestoreInProgress || progress >= 100.0) {
            NSLog(@"DeviceBackupRestore: 恢复进程将终止，状态: isRestoreInProgress=%d, progress=%.1f",
                  self.isRestoreInProgress, progress);
            dispatch_source_cancel(timer);
            
            if (progress >= 100.0) {
                NSLog(@"DeviceBackupRestore: 恢复完成");
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self.restoreProgressViewController appendLog:@"恢复完成!\n"];
                    self.restoreInProgress = NO;
                });
            }
            return;
        }
        
        progress += 2.0;
        step++;
        
        dispatch_async(dispatch_get_main_queue(), ^{
            self.restoreProgress = progress;
            [self.restoreProgressViewController updateProgress:progress];
            
            // 每5步添加一条日志
            if (step % 5 == 0) {
                NSString *logMessage = [NSString stringWithFormat:@"恢复进度: %.1f%%...\n", progress];
                NSLog(@"DeviceBackupRestore: %@", logMessage);
                [self.restoreProgressViewController appendLog:logMessage];
            }
        });
    });
    
    dispatch_resume(timer);
    NSLog(@"DeviceBackupRestore: 恢复进程计时器已启动");
}

// 加载示例备份数据
- (void)loadSampleBackupItems {
    NSLog(@"DeviceBackupRestore: 加载示例备份数据");
    NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
    [dateFormatter setDateStyle:NSDateFormatterMediumStyle];
    [dateFormatter setTimeStyle:NSDateFormatterShortStyle];
    
    NSDate *now = [NSDate date];
    NSDate *yesterday = [now dateByAddingTimeInterval:-86400]; // 24小时前
    NSDate *lastWeek = [now dateByAddingTimeInterval:-604800]; // 一周前
    
    NSString *defaultDir = [DatalogsSettings defaultBackupPath];
    
    [self.backupItems addObject:@{
        @"Default": @YES,
        @"Location": @"/Users/username/Backups/backup1",
        @"Date": [dateFormatter stringFromDate:now],
        @"DataSize": @"1.2 GB",
        @"Encryption": @"Yes",
        @"Operate": @"删除",
        @"Select": @NO,
        @"Name": @"Backup 1",
        @"Size": @"1.2 GB",
        @"Encrypted": @"Yes"
    }];
    
    [self.backupItems addObject:@{
        @"Default": @NO,
        @"Location": @"/Users/username/Backups/backup2",
        @"Date": [dateFormatter stringFromDate:yesterday],
        @"DataSize": @"980 MB",
        @"Encryption": @"No",
        @"Operate": @"删除",
        @"Select": @NO,
        @"Name": @"Backup 2",
        @"Size": @"980 MB",
        @"Encrypted": @"No"
    }];
    
    [self.backupItems addObject:@{
        @"Default": @NO,
        @"Location": @"/Users/username/Backups/backup3",
        @"Date": [dateFormatter stringFromDate:lastWeek],
        @"DataSize": @"850 MB",
        @"Encryption": @"Yes",
        @"Operate": @"删除",
        @"Select": @NO,
        @"Name": @"Backup 3",
        @"Size": @"850 MB",
        @"Encrypted": @"Yes"
    }];
    
    NSLog(@"DeviceBackupRestore: 已加载 %lu 条示例备份数据", (unsigned long)self.backupItems.count);
}

#pragma mark - 统一权限管理
- (BOOL)validateForAction {
    if (!self.deviceUDID) {
        //NSLog(@"设备 UDID 无效或为空");
        // 可以在这里显示一个提示框给用户
        return NO;
    }
    
    UserManager *userManager = [UserManager sharedManager];
    if (!userManager.isUserLoggedIn) {
       // NSLog(@"没有登录");
        // 发送通知以触发登录流程
        [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowLoginNotification" object:nil];
        return NO;
    }
    
    return YES;
}


@end
