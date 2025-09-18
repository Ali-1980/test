//
//  KeychainProcessorController.m

//
//  Created by Monterey on 19/1/2025.
//

#import "KeychainProcessorController.h"
#import <CommonCrypto/CommonCrypto.h>
#import <CommonCrypto/CommonKeyDerivation.h>
#import <Security/Security.h>
#include <plist/plist.h>

// 错误域定义
static NSString * const KeychainProcessorErrorDomain = @"KeychainProcessorErrorDomain";

typedef NS_ENUM(NSInteger, KeychainProcessorError) {
    KeychainProcessorErrorInvalidData = 1001,
    KeychainProcessorErrorDecryptionFailed = 1002,
    KeychainProcessorErrorParsingFailed = 1003,
    KeychainProcessorErrorCancelled = 1004,
    KeychainProcessorErrorPasswordRequired = 1005,
    KeychainProcessorErrorExportFailed = 1006,
    KeychainProcessorErrorKeybagNotInitialized = 1007,
    KeychainProcessorErrorHardwareKeyRequired = 1008
};

// ✅ 新增：处理状态枚举
typedef NS_ENUM(NSInteger, KeychainProcessingState) {
    KeychainProcessingStateIdle = 0,
    KeychainProcessingStateCheckingEncryption,
    KeychainProcessingStateAwaitingPassword,
    KeychainProcessingStateValidatingPassword,
    KeychainProcessingStateProcessingData,
    KeychainProcessingStateCompleted,
    KeychainProcessingStateFailed
};

#pragma mark - BackupKeybag实现

@implementation BackupKeybag

- (instancetype)init {
    if (self = [super init]) {
        _protectionClassKeys = [NSMutableDictionary dictionary];
        _isDecrypted = NO;
    }
    return self;
}

@end

#pragma mark - KeychainDataItem实现

@implementation KeychainDataItem

+ (NSString *)stringForItemType:(KeychainItemType)type {
    switch (type) {
        case KeychainItemTypeGenericPassword:
            return @"Generic Password";
        case KeychainItemTypeInternetPassword:
            return @"Internet Password";
        case KeychainItemTypeWiFiPassword:
            return @"Wi-Fi Password";
        case KeychainItemTypeCertificate:
            return @"Certificate";
        case KeychainItemTypeKey:
            return @"Key";
        case KeychainItemTypeApplication:
            return @"Application";
        default:
            return @"Unknown";
    }
}

+ (NSString *)localizedStringForItemType:(KeychainItemType)type {
    switch (type) {
        case KeychainItemTypeGenericPassword:
            return @"通用密码";
        case KeychainItemTypeInternetPassword:
            return @"互联网密码";
        case KeychainItemTypeWiFiPassword:
            return @"Wi-Fi密码";
        case KeychainItemTypeCertificate:
            return @"证书";
        case KeychainItemTypeKey:
            return @"密钥";
        case KeychainItemTypeApplication:
            return @"应用程序";
        default:
            return @"未知类型";
    }
}

- (NSString *)description {
    return [NSString stringWithFormat:@"KeychainDataItem: %@ - %@/%@",
            [KeychainDataItem localizedStringForItemType:self.itemType],
            self.service ?: @"(no service)",
            self.account ?: @"(no account)"];
}

@end

#pragma mark - KeychainProcessorController主实现

@interface KeychainProcessorController ()

@property (nonatomic, strong) dispatch_queue_t processingQueue;
@property (nonatomic, strong) NSMutableArray<KeychainDataItem *> *mutableProcessedItems;
@property (nonatomic, strong) NSMutableDictionary *mutableStatistics;
@property (nonatomic, assign) BOOL shouldCancelProcessing;
@property (nonatomic, assign) double internalProgress;
@property (nonatomic, strong) NSString *internalStatus;
@property (nonatomic, strong) NSError *internalLastError;

// 解密相关属性（更新版）
@property (nonatomic, strong) NSMutableDictionary *decryptionCache;
@property (nonatomic, assign) BOOL hasRequestedPassword;
@property (nonatomic, assign) BOOL userCancelledPassword;
@property (nonatomic, assign) NSInteger passwordRetryCount;

// ✅ 新增：处理状态控制
@property (nonatomic, assign) KeychainProcessingState processingState;
@property (nonatomic, strong) BackupFileSystemItem *currentItem;

// ✅ 存储备份根目录路径
@property (nonatomic, strong) NSString *backupRootPath;

@end

@implementation KeychainProcessorController

#pragma mark - 初始化

- (instancetype)init {
    self = [super init];
    if (self) {
        _processingQueue = dispatch_queue_create("com.mfctool.keychain.processing", DISPATCH_QUEUE_SERIAL);
        _mutableProcessedItems = [NSMutableArray array];
        _mutableStatistics = [NSMutableDictionary dictionary];
        _shouldCancelProcessing = NO;
        _internalProgress = 0.0;
        _internalStatus = @"准备中...";
        _processingState = KeychainProcessingStateIdle;
        
        // 初始化解密缓存
        _decryptionCache = [NSMutableDictionary dictionary];
        
        // 初始化密码请求控制状态
        _hasRequestedPassword = NO;
        _userCancelledPassword = NO;
        _passwordRetryCount = 0;
        
        // 初始化备份相关属性
        _supportsHardwareDecryption = NO;
        
        NSLog(@"🔑 KeychainProcessorController initialized with Keybag-First architecture");
    }
    return self;
}

#pragma mark - 公共属性

- (BOOL)isProcessing {
    return _processingState != KeychainProcessingStateIdle &&
           _processingState != KeychainProcessingStateCompleted &&
           _processingState != KeychainProcessingStateFailed;
}

- (double)currentProgress {
    return _internalProgress;
}

- (NSString *)currentStatus {
    return _internalStatus;
}

- (NSError *)lastError {
    return _internalLastError;
}

- (NSArray<KeychainDataItem *> *)processedItems {
    return [_mutableProcessedItems copy];
}

- (NSDictionary *)statisticsInfo {
    return [_mutableStatistics copy];
}

#pragma mark - ✅ 核心修复：Keybag-First 架构实现

- (void)processKeychainData:(BackupFileSystemItem *)item
          withBackupRootPath:(NSString *)backupRootPath {
    NSLog(@"🔐 启动 Keybag-First Keychain 分析流程");
    
    // ✅ 第一阶段：严格的前置条件检查
    if (self.isProcessing) {
        NSLog(@"⚠️ 处理正在进行中，拒绝新请求");
        return;
    }
    
    if (!item || ![item.domain isEqualToString:@"KeychainDomain"]) {
        [self failWithError:@"无效的Keychain数据项" code:KeychainProcessorErrorInvalidData];
        return;
    }
    
    if (!backupRootPath || backupRootPath.length == 0) {
        [self failWithError:@"备份根目录路径为空" code:KeychainProcessorErrorInvalidData];
        return;
    }
    
    // ✅ 第二阶段：重置状态并存储参数
    [self resetProcessingState];
    self.backupRootPath = backupRootPath;
    self.currentItem = item;
    self.processingState = KeychainProcessingStateCheckingEncryption;
    
    // ✅ 第三阶段：Manifest 路径构建与验证
    NSString *manifestPath = [self constructManifestPathFromBackupRoot:backupRootPath];
    if (!manifestPath) {
        [self failWithError:@"无法找到备份的 Manifest.plist" code:KeychainProcessorErrorInvalidData];
        return;
    }
    
    self.manifestPath = manifestPath;
    NSLog(@"✅ 找到Manifest.plist: %@", manifestPath);
    
    // ✅ 第四阶段：检测加密状态（关键步骤）
    BOOL isEncryptedBackup = [self checkIfBackupIsEncrypted:manifestPath];
    NSLog(@"🔍 备份加密状态: %@", isEncryptedBackup ? @"已加密" : @"未加密");
    
    if (!isEncryptedBackup) {
        // 未加密备份：直接处理
        NSLog(@"✅ 检测到未加密备份，直接处理");
        [self processUnencryptedBackup];
    } else {
        // 加密备份：必须先获取密码
        NSLog(@"🔐 检测到加密备份，要求密码验证");
        [self requirePasswordForEncryptedBackup];
    }
}

// 保持向后兼容
- (void)processKeychainData:(BackupFileSystemItem *)item {
    NSLog(@"🔑 processKeychainData (旧版本) - 尝试搜索Manifest.plist");
    
    NSString *manifestPath = [self findManifestPlistPath];
    if (!manifestPath) {
        [self failWithError:@"无法找到Manifest.plist" code:KeychainProcessorErrorInvalidData];
        return;
    }
    
    NSString *backupRootPath = [manifestPath stringByDeletingLastPathComponent];
    [self processKeychainData:item withBackupRootPath:backupRootPath];
}

#pragma mark - ✅ 未加密备份处理路径

- (void)processUnencryptedBackup {
    self.processingState = KeychainProcessingStateProcessingData;
    [self updateProgress:0.1 status:@"处理未加密备份..."];
    
    // 创建空 Keybag 标识未加密状态
    self.backupKeybag = [[BackupKeybag alloc] init];
    self.backupKeybag.isDecrypted = YES;
    
    dispatch_async(self.processingQueue, ^{
        [self executeKeychainDataParsing];
    });
}

#pragma mark - ✅ 加密备份处理路径 - 强制密码验证

- (void)requirePasswordForEncryptedBackup {
    self.processingState = KeychainProcessingStateAwaitingPassword;
    [self updateProgress:0.0 status:@"需要 iTunes 备份密码"];
    
    // ❌ 关键修复：在密码验证成功之前，绝不显示任何数据
    [self clearAllDisplayData];
    
    // 请求密码
    [self requestPasswordWithCompletion:^(NSString *password, BOOL cancelled) {
        if (cancelled) {
            [self failWithError:@"用户取消密码输入" code:KeychainProcessorErrorCancelled];
            return;
        }
        
        [self validatePasswordAndProceed:password];
    }];
}

- (void)validatePasswordAndProceed:(NSString *)password {
    if (!password || password.length == 0) {
        [self failWithError:@"密码不能为空" code:KeychainProcessorErrorPasswordRequired];
        return;
    }
    
    self.processingState = KeychainProcessingStateValidatingPassword;
    [self updateProgress:0.1 status:@"验证密码中..."];
    
    dispatch_async(self.processingQueue, ^{
        NSError *error = nil;
        BOOL success = [self initializeBackupKeybagWithManifestPath:self.manifestPath
                                                           password:password
                                                              error:&error];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (success && self.backupKeybag.isDecrypted) {
                NSLog(@"✅ 密码验证成功，开始数据处理");
                [self proceedWithValidatedKeybag];
            } else {
                NSLog(@"❌ 密码验证失败: %@", error.localizedDescription ?: @"未知错误");
                [self handlePasswordValidationFailure:error];
            }
        });
    });
}

- (void)proceedWithValidatedKeybag {
    self.processingState = KeychainProcessingStateProcessingData;
    
    dispatch_async(self.processingQueue, ^{
        [self executeKeychainDataParsing];
    });
}

- (void)handlePasswordValidationFailure:(NSError *)error {
    if (error.code == KeychainProcessorErrorPasswordRequired) {
        // 密码错误，允许重试（但不显示数据）
        NSLog(@"⚠️ 密码错误，清除显示数据");
        [self clearAllDisplayData];
        [self updateProgress:0.0 status:@"密码错误，请重新输入"];
        
        // 重置状态允许重新输入密码
        self.processingState = KeychainProcessingStateIdle;
        self.hasRequestedPassword = NO;
    } else {
        [self failWithError:error.localizedDescription ?: @"Keybag 初始化失败" code:error.code];
    }
}

#pragma mark - ✅ 核心数据解析 - 只在 Keybag 就绪后执行

- (void)executeKeychainDataParsing {
    // ✅ 断言：确保 Keybag 状态正确
    NSAssert(self.backupKeybag != nil, @"BackupKeybag 不能为 nil");
    NSAssert(self.backupKeybag.isDecrypted, @"BackupKeybag 必须已解密");
    
    @try {
        [self updateProgress:0.2 status:@"读取 Keychain 文件..."];
        
        // 读取 Keychain 数据
        NSData *keychainData = [self readKeychainDataFromItem:self.currentItem];
        if (!keychainData || self.shouldCancelProcessing) {
            if (!self.shouldCancelProcessing) {
                [self failWithError:@"无法读取Keychain数据文件" code:KeychainProcessorErrorInvalidData];
            }
            return;
        }
        
        [self updateProgress:0.3 status:@"解析 Keychain 结构..."];
        
        // 解析 plist
        plist_t keychainPlist = [self parseKeychainPlist:keychainData];
        if (!keychainPlist || self.shouldCancelProcessing) {
            if (!self.shouldCancelProcessing) {
                [self failWithError:@"无法解析Keychain plist格式" code:KeychainProcessorErrorParsingFailed];
            }
            return;
        }
        
        [self updateProgress:0.4 status:@"提取 Keychain 条目..."];
        
        // ✅ 关键：只有在此时才开始解析数据项
        [self parseKeychainItemsFromPlist:keychainPlist];
        
        plist_free(keychainPlist);
        
        [self updateProgress:1.0 status:@"分析完成"];
        self.processingState = KeychainProcessingStateCompleted;
        
        // 生成统计信息
        [self generateStatistics];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            [self notifyCompletion];
        });
        
    } @catch (NSException *exception) {
        [self failWithError:[NSString stringWithFormat:@"处理异常: %@", exception.reason]
                       code:KeychainProcessorErrorParsingFailed];
    }
}

#pragma mark - ✅ Keybag-Aware 的数据解析逻辑

- (plist_t)parseKeychainPlist:(NSData *)keychainData {
    plist_t keychainPlist = NULL;
    plist_from_bin((char *)keychainData.bytes, (uint32_t)keychainData.length, &keychainPlist);
    
    if (!keychainPlist) {
        // 尝试XML格式
        plist_from_xml((char *)keychainData.bytes, (uint32_t)keychainData.length, &keychainPlist);
    }
    
    return keychainPlist;
}

- (void)parseKeychainItemsFromPlist:(plist_t)plist {
    if (plist_get_node_type(plist) != PLIST_DICT) {
        NSLog(@"❌ Keychain plist根节点不是字典类型");
        return;
    }
    
    NSLog(@"🔍 开始处理 iOS Keychain 备份数据...");
    
    NSArray<NSDictionary *> *categories = @[
        @{@"key": @"genp", @"name": @"通用密码", @"type": @(KeychainItemTypeGenericPassword)},
        @{@"key": @"inet", @"name": @"网络密码", @"type": @(KeychainItemTypeInternetPassword)},
        @{@"key": @"cert", @"name": @"证书", @"type": @(KeychainItemTypeCertificate)},
        @{@"key": @"keys", @"name": @"密钥", @"type": @(KeychainItemTypeKey)}
    ];
    
    uint32_t totalItems = 0;
    uint32_t processedItems = 0;
    
    // 统计总数
    for (NSDictionary *category in categories) {
        plist_t categoryArray = plist_dict_get_item(plist, [category[@"key"] UTF8String]);
        if (categoryArray && plist_get_node_type(categoryArray) == PLIST_ARRAY) {
            totalItems += plist_array_get_size(categoryArray);
        }
    }
    
    NSLog(@"📊 总共 %u 个 Keychain 条目需要解析", totalItems);
    
    // 解析每个类别
    for (NSDictionary *category in categories) {
        if (self.shouldCancelProcessing) break;
        
        NSString *key = category[@"key"];
        NSString *categoryName = category[@"name"];
        KeychainItemType itemType = [category[@"type"] intValue];
        
        plist_t categoryArray = plist_dict_get_item(plist, [key UTF8String]);
        if (!categoryArray || plist_get_node_type(categoryArray) != PLIST_ARRAY) {
            continue;
        }
        
        uint32_t categoryCount = plist_array_get_size(categoryArray);
        NSLog(@"🔄 处理 %@ 类别，共 %u 个条目", categoryName, categoryCount);
        
        for (uint32_t i = 0; i < categoryCount; i++) {
            if (self.shouldCancelProcessing) break;
            
            plist_t itemNode = plist_array_get_item(categoryArray, i);
            if (itemNode && plist_get_node_type(itemNode) == PLIST_DICT) {
                // ✅ 关键：使用 Keybag-aware 的解析方法
                KeychainDataItem *dataItem = [self createKeychainItemFromPlistWithKeybag:itemNode
                                                                                itemType:itemType];
                if (dataItem) {
                    [self.mutableProcessedItems addObject:dataItem];
                }
            }
            
            processedItems++;
            
            // 更新进度
            if (processedItems % 100 == 0) {
                double progress = 0.4 + (0.5 * processedItems / totalItems);
                [self updateProgress:progress
                              status:[NSString stringWithFormat:@"解析中... (%u/%u)",
                                     processedItems, totalItems]];
            }
        }
    }
    
    NSLog(@"✅ Keychain 解析完成，成功处理 %u/%u 个条目", processedItems, totalItems);
}

#pragma mark - ✅ Keybag-Aware 的数据项创建

- (KeychainDataItem *)createKeychainItemFromPlistWithKeybag:(plist_t)itemDict
                                                   itemType:(KeychainItemType)itemType {
    KeychainDataItem *item = [[KeychainDataItem alloc] init];
    item.itemType = itemType;
    
    // ✅ 关键修复：确保 Keybag 可用
    BOOL hasValidKeybag = self.backupKeybag && self.backupKeybag.isDecrypted;
    NSLog(@"🔍 [调试] 创建Keychain项目，Keybag状态: %@", hasValidKeybag ? @"有效" : @"无效");
        
    // ✅ 服务名称提取（优先解密）
    item.service = [self extractServiceNameFromPlist:itemDict withKeybag:hasValidKeybag];
    
    // ✅ 账户名称提取（优先解密）
    item.account = [self extractAccountNameFromPlist:itemDict withKeybag:hasValidKeybag];
    
    // 网络密码特有字段
    if (itemType == KeychainItemTypeInternetPassword) {
        item.server = [self extractStringField:@"srvr" fromPlist:itemDict withKeybag:hasValidKeybag] ?:
                     [self stringValueForKey:@"server" fromDict:itemDict];
        item.protocol = [self extractStringField:@"ptcl" fromPlist:itemDict withKeybag:hasValidKeybag] ?:
                       [self stringValueForKey:@"protocol" fromDict:itemDict];
        item.path = [self stringValueForKey:@"path" fromDict:itemDict];
        item.port = [self numberValueForKey:@"port" fromDict:itemDict];
    }
    
    // 其他字段
    item.label = [self extractStringField:@"labl" fromPlist:itemDict withKeybag:hasValidKeybag] ?:
                [self stringValueForKey:@"label" fromDict:itemDict];
    item.comment = [self extractStringField:@"icmt" fromPlist:itemDict withKeybag:hasValidKeybag] ?:
                  [self stringValueForKey:@"comment" fromDict:itemDict];
    
    // 时间戳
    item.creationDate = [self dateValueForKey:@"cdat" fromDict:itemDict] ?:
                       [self dateValueForKey:@"creationDate" fromDict:itemDict];
    item.modificationDate = [self dateValueForKey:@"mdat" fromDict:itemDict] ?:
                           [self dateValueForKey:@"modificationDate" fromDict:itemDict];
    
    // ✅ 密码数据提取（必须有 Keybag）
    NSData *passwordData = [self dataValueForKey:@"v_Data" fromDict:itemDict];
    if (passwordData && hasValidKeybag) {
        NSString *decryptedPassword = [self decryptPasswordData:passwordData];
        if (decryptedPassword) {
            item.password = decryptedPassword;
            item.isPasswordEncrypted = NO;
            item.canDecrypt = YES;
        } else {
            item.isPasswordEncrypted = YES;
            item.canDecrypt = NO;
            item.encryptedData = passwordData;
        }
    } else if (passwordData) {
        // 有数据但无 Keybag（这种情况在新架构下不应该发生）
        item.isPasswordEncrypted = YES;
        item.canDecrypt = NO;
        item.encryptedData = passwordData;
    }
    
    // 其他属性
    NSDictionary *rawAttributes = [self plistDictToNSDictionary:itemDict];
    
    NSLog(@"🔍 [调试] 项目原始字段: %@", rawAttributes.allKeys);
    
    // 检查是否有服务相关字段
    NSArray *serviceKeys = @[@"svce", @"labl", @"service", @"desc"];
    for (NSString *key in serviceKeys) {
        id value = rawAttributes[key];
        if (value) {
            NSLog(@"🔍 [调试] 字段 %@: %@ (类型: %@)", key, value, [value class]);
        }
    }
    
    // 检查是否有账户相关字段
    NSArray *accountKeys = @[@"acct", @"account"];
    for (NSString *key in accountKeys) {
        id value = rawAttributes[key];
        if (value) {
            NSLog(@"🔍 [调试] 字段 %@: %@ (类型: %@)", key, value, [value class]);
        }
    }
    
    item.protectionClass = [self inferProtectionClassFromAttributes:rawAttributes];
    item.isThisDeviceOnly = (item.protectionClass >= iOSProtectionClassWhenUnlockedThisDeviceOnly);
    item.rawAttributes = rawAttributes;
    
    return item;
}

#pragma mark - ✅ 改进的字段提取方法

- (NSString *)extractServiceNameFromPlist:(plist_t)itemDict withKeybag:(BOOL)hasValidKeybag {
    NSLog(@"🔍 [调试] 提取服务名称 - hasValidKeybag: %@", hasValidKeybag ? @"YES" : @"NO");
    
    // 尝试解密加密字段
    if (hasValidKeybag) {
        NSData *encryptedService = [self dataValueForKey:@"svce" fromDict:itemDict];
        if (encryptedService) {
            NSLog(@"🔍 [调试] 找到加密的服务字段 svce，长度: %lu", (unsigned long)encryptedService.length);
            NSString *decryptedService = [self decryptMetadataField:encryptedService];
            if (decryptedService && decryptedService.length > 0) {
                NSLog(@"✅ [调试] 成功解密服务名称: %@", decryptedService);
                return decryptedService;
            } else {
                NSLog(@"❌ [调试] 解密服务字段失败");
            }
        } else {
            NSLog(@"🔍 [调试] 未找到加密的服务字段 svce");
        }
        
        // 尝试其他可能的服务字段名
        NSArray *serviceFields = @[@"labl", @"service", @"desc"];
        for (NSString *field in serviceFields) {
            NSString *plainService = [self stringValueForKey:field fromDict:itemDict];
            if (plainService && plainService.length > 0) {
                NSLog(@"✅ [调试] 从字段 %@ 找到明文服务名称: %@", field, plainService);
                return plainService;
            }
        }
    }
    
    // 尝试明文字段
    NSString *service = [self stringValueForKey:@"labl" fromDict:itemDict] ?:
                       [self stringValueForKey:@"service" fromDict:itemDict];
    
    if (service && service.length > 0) {
        NSLog(@"✅ [调试] 找到明文服务名称: %@", service);
        return service;
    }
    
    NSLog(@"⚠️ [调试] 未找到任何服务信息");
    return hasValidKeybag ? @"<无服务信息>" : @"<需要密码>";
}

- (NSString *)extractAccountNameFromPlist:(plist_t)itemDict withKeybag:(BOOL)hasValidKeybag {
    NSLog(@"🔍 [调试] 提取账户名称 - hasValidKeybag: %@", hasValidKeybag ? @"YES" : @"NO");
    
    // 尝试解密加密字段
    if (hasValidKeybag) {
        NSData *encryptedAccount = [self dataValueForKey:@"acct" fromDict:itemDict];
        if (encryptedAccount) {
            NSLog(@"🔍 [调试] 找到加密的账户字段 acct，长度: %lu", (unsigned long)encryptedAccount.length);
            NSString *decryptedAccount = [self decryptMetadataField:encryptedAccount];
            if (decryptedAccount && decryptedAccount.length > 0) {
                NSLog(@"✅ [调试] 成功解密账户名称: %@", decryptedAccount);
                return decryptedAccount;
            } else {
                NSLog(@"❌ [调试] 解密账户字段失败");
            }
        } else {
            NSLog(@"🔍 [调试] 未找到加密的账户字段 acct");
        }
    }
    
    // 尝试明文字段
    NSString *account = [self stringValueForKey:@"account" fromDict:itemDict];
    
    if (account && account.length > 0) {
        NSLog(@"✅ [调试] 找到明文账户名称: %@", account);
        return account;
    }
    
    NSLog(@"⚠️ [调试] 未找到任何账户信息");
    return hasValidKeybag ? @"<无账户信息>" : @"<需要密码>";
}


- (NSString *)extractStringField:(NSString *)key fromPlist:(plist_t)itemDict withKeybag:(BOOL)hasValidKeybag {
    if (!hasValidKeybag) {
        return nil;
    }
    
    // 尝试作为加密数据解密
    NSData *encryptedData = [self dataValueForKey:key fromDict:itemDict];
    if (encryptedData) {
        return [self decryptMetadataField:encryptedData];
    }
    
    // 尝试作为明文字符串
    return [self stringValueForKey:key fromDict:itemDict];
}

- (NSString *)decryptMetadataField:(NSData *)encryptedData {
    if (!encryptedData || !self.backupKeybag.isDecrypted) {
        NSLog(@"❌ [调试] 元数据解密前置条件失败 - 数据: %@, Keybag: %@",
              encryptedData ? @"有" : @"无",
              self.backupKeybag.isDecrypted ? @"已解密" : @"未解密");
        return nil;
    }
    
    NSLog(@"🔍 [调试] 开始解密元数据字段，数据长度: %lu", (unsigned long)encryptedData.length);
    
    // 首先尝试作为明文字符串处理
    NSString *plainText = [[NSString alloc] initWithData:encryptedData encoding:NSUTF8StringEncoding];
    if (plainText && [self isValidPasswordString:plainText]) {
        NSLog(@"✅ [调试] 元数据字段实际为明文: %@", plainText);
        return plainText;
    }
    
    // 尝试不同的保护类解密元数据
    NSArray *protectionClasses = @[
        @(iOSProtectionClassWhenUnlocked),
        @(iOSProtectionClassAfterFirstUnlock),
        @(iOSProtectionClassAlways),
        @(iOSProtectionClassWhenUnlockedThisDeviceOnly),
        @(iOSProtectionClassAfterFirstUnlockThisDeviceOnly),
        @(iOSProtectionClassAlwaysThisDeviceOnly)
    ];
    
    for (NSNumber *protectionClassNum in protectionClasses) {
        iOSProtectionClass protectionClass = [protectionClassNum integerValue];
        NSLog(@"🔍 [调试] 尝试使用保护类 %ld 解密元数据", (long)protectionClass);
        
        NSError *error = nil;
        NSString *decryptedText = [self decryptKeychainData:encryptedData
                                            protectionClass:protectionClass
                                                      error:&error];
        if (decryptedText && decryptedText.length > 0) {
            NSLog(@"✅ [调试] 使用保护类 %ld 成功解密元数据: %@", (long)protectionClass, decryptedText);
            return decryptedText;
        } else if (error) {
            NSLog(@"❌ [调试] 保护类 %ld 解密失败: %@", (long)protectionClass, error.localizedDescription);
        } else {
            NSLog(@"❌ [调试] 保护类 %ld 解密返回空结果", (long)protectionClass);
        }
    }
    
    NSLog(@"❌ [调试] 所有保护类解密元数据都失败");
    return nil;
}

#pragma mark - ✅ 状态管理和用户界面

- (void)resetProcessingState {
    [self clearResults];
    [self clearAllDisplayData];
    self.processingState = KeychainProcessingStateIdle;
    self.currentItem = nil;
}

- (void)clearAllDisplayData {
    // 清空当前结果，确保界面不显示无效数据
    [self.mutableProcessedItems removeAllObjects];
    [self.mutableStatistics removeAllObjects];
    
    // 通知 UI 清除现有显示
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self.delegate respondsToSelector:@selector(keychainProcessor:didCompleteWithResults:)]) {
            [self.delegate keychainProcessor:self didCompleteWithResults:@[]];
        }
    });
}

- (void)failWithError:(NSString *)errorDescription code:(KeychainProcessorError)errorCode {
    self.processingState = KeychainProcessingStateFailed;
    [self clearAllDisplayData]; // 确保失败时不显示任何数据
    NSError *error = [self errorWithCode:errorCode description:errorDescription];
    [self notifyError:error];
}

- (void)requestPasswordWithCompletion:(void(^)(NSString *password, BOOL cancelled))completion {
    if ([self.delegate respondsToSelector:@selector(keychainProcessor:needsPasswordWithCompletion:)]) {
        NSLog(@"🔐 请求iTunes备份密码以解密Keychain");
        [self.delegate keychainProcessor:self needsPasswordWithCompletion:completion];
    } else {
        completion(nil, YES);
    }
}

- (NSString *)constructManifestPathFromBackupRoot:(NSString *)backupRoot {
    NSString *manifestPath = [backupRoot stringByAppendingPathComponent:@"Manifest.plist"];
    return [[NSFileManager defaultManager] fileExistsAtPath:manifestPath] ? manifestPath : nil;
}

- (BOOL)checkIfBackupIsEncrypted:(NSString *)manifestPath {
    NSDictionary *manifest = [NSDictionary dictionaryWithContentsOfFile:manifestPath];
    NSNumber *isEncrypted = manifest[@"IsEncrypted"];
    NSData *keybagData = manifest[@"BackupKeyBag"];
    
    return isEncrypted.boolValue || keybagData != nil;
}

- (void)cancelProcessing {
    NSLog(@"🛑 用户取消Keychain处理");
    _shouldCancelProcessing = YES;
    
    dispatch_async(_processingQueue, ^{
        [self updateProgress:0.0 status:@"已取消"];
        NSError *error = [self errorWithCode:KeychainProcessorErrorCancelled
                                 description:@"用户取消了处理"];
        [self notifyError:error];
    });
}

- (void)clearResults {
    [_mutableProcessedItems removeAllObjects];
    [_mutableStatistics removeAllObjects];
    _internalProgress = 0.0;
    _internalStatus = @"准备中...";
    _internalLastError = nil;
    
    // 清除解密相关数据
    [_decryptionCache removeAllObjects];
    _backupPassword = nil;
    _backupKeybag = nil;
    _manifestPath = nil;
    _backupRootPath = nil;
    
    // 重置密码请求控制状态
    _hasRequestedPassword = NO;
    _userCancelledPassword = NO;
    _passwordRetryCount = 0;
    
    NSLog(@"🔄 已重置所有状态，包括Backup Keybag和密码缓存");
}

#pragma mark - 🔑 现有的基于irestore的核心解密方法（保持不变）

- (BOOL)initializeBackupKeybagWithManifestPath:(NSString *)manifestPath
                                      password:(NSString *)password
                                         error:(NSError **)error {
    NSLog(@"🔐 初始化Backup Keybag: %@", manifestPath);
    
    // 1. 读取Manifest.plist
    NSData *manifestData = [NSData dataWithContentsOfFile:manifestPath];
    if (!manifestData) {
        if (error) {
            *error = [self errorWithCode:KeychainProcessorErrorInvalidData
                             description:@"无法读取Manifest.plist"];
        }
        return NO;
    }
    
    // 2. 解析Manifest plist
    NSError *plistError;
    NSDictionary *manifest = [NSPropertyListSerialization propertyListWithData:manifestData
                                                                       options:0
                                                                        format:NULL
                                                                         error:&plistError];
    if (!manifest) {
        NSLog(@"❌ Manifest解析失败: %@", plistError);
        if (error) *error = plistError;
        return NO;
    }
    
    // 3. 检查备份加密状态
    NSNumber *isEncrypted = manifest[@"IsEncrypted"];
    NSLog(@"🔍 备份加密状态: %@", isEncrypted ? (isEncrypted.boolValue ? @"✅ 加密" : @"❌ 未加密") : @"❓ 未知");
    
    // 4. 提取Backup Keybag数据
    NSData *keybagData = manifest[@"BackupKeyBag"];
    if (!keybagData) {
        NSLog(@"⚠️ Manifest中未找到BackupKeyBag，可能是未加密备份");
        
        // ✅ 对于未加密备份，创建一个空的keybag
        self.backupKeybag = [[BackupKeybag alloc] init];
        self.backupKeybag.isDecrypted = YES; // 未加密备份标记为已解密
        self.manifestPath = manifestPath;
        self.backupPassword = password;
        
        NSLog(@"✅ 未加密备份Keybag初始化成功");
        return YES; // 未加密备份返回成功
    }
    
    NSLog(@"🔐 发现BackupKeyBag，数据长度: %lu bytes", (unsigned long)keybagData.length);
    
    // 5. 解密Backup Keybag
    self.backupKeybag = [[BackupKeybag alloc] init];
    self.manifestPath = manifestPath;
    self.backupPassword = password;
    
    return [self decryptBackupKeybag:keybagData withPassword:password error:error];
}

// ✅ 保留所有现有的解密方法（decryptBackupKeybag, unwrapKey, deriveKeyWithPBKDF2 等）
// 这些方法已经经过验证，工作正常，不需要修改

- (BOOL)decryptBackupKeybag:(NSData *)keybagData
               withPassword:(NSString *)password
                      error:(NSError **)error {
    
    NSLog(@"🔍 Keybag数据长度: %lu bytes", (unsigned long)keybagData.length);
    NSLog(@"🔍 提供的密码: %@", password ? @"✅ 有密码" : @"❌ 无密码");
    
    // 输出前64字节的十六进制数据用于调试
    NSData *headerData = [keybagData subdataWithRange:NSMakeRange(0, MIN(64, keybagData.length))];
    NSLog(@"🔍 Keybag头部数据: %@", headerData);
    
    const uint8_t *bytes = keybagData.bytes;
    NSUInteger length = keybagData.length;
    NSUInteger offset = 0;
    
    // 查找盐值和迭代次数
    NSData *salt = nil;
    NSUInteger iterations = 0;
    NSMutableDictionary *wrappedKeys = [NSMutableDictionary dictionary];
    
    // 临时变量保存保护类信息
    uint32_t currentClass = 0;
    uint32_t currentWrap = 0;
    uint32_t currentKeyType = 0;
    
    // ✅ 新的解析策略：更智能的TLV解析
    while (offset < length - 8) {
        if (offset + 8 > length) {
            NSLog(@"🔍 到达数据末尾，停止解析");
            break;
        }
        
        // 读取标签和长度
        uint32_t tag, len;
        [keybagData getBytes:&tag range:NSMakeRange(offset, 4)];
        [keybagData getBytes:&len range:NSMakeRange(offset + 4, 4)];
        
        // 转换字节序
        tag = CFSwapInt32BigToHost(tag);
        len = CFSwapInt32BigToHost(len);
        
        if (len > length - offset - 8 || len > 10240) {
            NSLog(@"⚠️ 检测到异常长度 %u，跳过此标签: 0x%x", len, tag);
            offset += 8;
            continue;
        }
        
        offset += 8;
        NSData *data = (len > 0 && offset + len <= length) ? [NSData dataWithBytes:bytes + offset length:len] : nil;
        
        switch (tag) {
            case 'SALT': {
                salt = data;
                NSLog(@"🧂 找到盐值: %lu bytes", (unsigned long)salt.length);
                break;
            }
            case 'ITER': {
                if (len >= 4 && data) {
                    uint32_t iterValue;
                    [data getBytes:&iterValue length:4];
                    iterations = CFSwapInt32BigToHost(iterValue);
                    NSLog(@"🔄 迭代次数: %lu", (unsigned long)iterations);
                }
                break;
            }
            case 'VERS': {
                if (len >= 4 && data) {
                    uint32_t version;
                    [data getBytes:&version length:4];
                    version = CFSwapInt32BigToHost(version);
                    NSLog(@"📋 Keybag版本: %u", version);
                }
                break;
            }
            case 'TYPE': {
                if (len >= 4 && data) {
                    uint32_t type;
                    [data getBytes:&type length:4];
                    type = CFSwapInt32BigToHost(type);
                    NSLog(@"📋 Keybag类型: %u", type);
                }
                break;
            }
            // ✅ 新增：保护类相关标签
            case 'CLAS': {
                if (len >= 4 && data) {
                    [data getBytes:&currentClass length:4];
                    currentClass = CFSwapInt32BigToHost(currentClass);
                    NSLog(@"📂 保护类: %u", currentClass);
                }
                break;
            }
            case 'WRAP': {
                if (len >= 4 && data) {
                    [data getBytes:&currentWrap length:4];
                    currentWrap = CFSwapInt32BigToHost(currentWrap);
                    NSLog(@"📦 WRAP: %u", currentWrap);
                }
                break;
            }
            case 'KTYP': {
                if (len >= 4 && data) {
                    [data getBytes:&currentKeyType length:4];
                    currentKeyType = CFSwapInt32BigToHost(currentKeyType);
                    NSLog(@"🔑 KeyType: %u", currentKeyType);
                }
                break;
            }
            case 'WPKY': {
                if (data) {
                    wrappedKeys[@(currentClass)] = data;
                    NSLog(@"🔐 收到保护类 %u 的wrapped key (长度: %lu)",
                          currentClass, (unsigned long)data.length);
                }
                break;
            }
            default: {
                char tagString[5] = {0};
                uint32_t tagBE = CFSwapInt32HostToBig(tag);
                memcpy(tagString, &tagBE, 4);
                
                BOOL isPrintable = YES;
                for (int i = 0; i < 4; i++) {
                    if (!isprint(tagString[i])) { isPrintable = NO; break; }
                }
                
                if (isPrintable) {
                    NSLog(@"🔍 未知TLV标签: '%s' (0x%x, 长度: %u)", tagString, tag, len);
                } else {
                    NSLog(@"🔍 未知TLV标签: 0x%x (长度: %u)", tag, len);
                }
                break;
            }
        }
        
        offset += len;
    }
    
    NSLog(@"🔍 解析完成 - 盐值: %@, 迭代次数: %lu, Wrapped Keys: %lu",
          salt ? @"✅" : @"❌", (unsigned long)iterations, (unsigned long)wrappedKeys.count);
    
    self.backupKeybag.salt = salt;
    self.backupKeybag.iterations = iterations;
    
    if (wrappedKeys.count == 0) {
        NSLog(@"✅ 未找到wrapped keys，确认为未加密备份");
        self.backupKeybag.isDecrypted = YES;
        return YES;
    }
    
    if (!password || password.length == 0) {
        NSLog(@"🔐 发现%lu个wrapped keys，但未提供密码", (unsigned long)wrappedKeys.count);
        self.backupKeybag.isDecrypted = NO;
        if (error) {
            *error = [self errorWithCode:KeychainProcessorErrorPasswordRequired
                             description:@"需要iTunes备份密码"];
        }
        return NO;
    }
    
    if (salt && iterations > 0) {
        NSData *masterKey = [self deriveKeyWithPBKDF2:password
                                                 salt:salt
                                           iterations:(int)iterations
                                              keySize:32];
        
        if (!masterKey) {
            if (error) {
                *error = [self errorWithCode:KeychainProcessorErrorDecryptionFailed
                                 description:@"PBKDF2密钥派生失败"];
            }
            return NO;
        }
        
        NSLog(@"🔑 成功派生主密钥: %lu bytes", (unsigned long)masterKey.length);
        
        NSMutableDictionary *protectionClassKeys = [NSMutableDictionary dictionary];
        
        for (NSNumber *protectionClassNum in wrappedKeys) {
            NSData *wrappedKey = wrappedKeys[protectionClassNum];
            NSLog(@"🔓 尝试解包保护类 %@ (长度: %lu)", protectionClassNum, (unsigned long)wrappedKey.length);
            
            NSData *unwrappedKey = [self unwrapKey:wrappedKey withMasterKey:masterKey];
            
            if (unwrappedKey) {
                protectionClassKeys[protectionClassNum] = unwrappedKey;
                NSLog(@"✅ 成功解包保护类 %@ (解包后长度: %lu)", protectionClassNum, (unsigned long)unwrappedKey.length);
            } else {
                NSLog(@"❌ 保护类 %@ 密钥解包失败", protectionClassNum);
            }
        }
        
        self.backupKeybag.protectionClassKeys = protectionClassKeys;
        self.backupKeybag.isDecrypted = protectionClassKeys.count > 0;
        
        NSLog(@"✅ Backup Keybag解密完成，共解包 %lu/%lu 个保护类密钥",
              (unsigned long)protectionClassKeys.count, (unsigned long)wrappedKeys.count);
        
        return self.backupKeybag.isDecrypted;
    } else {
        NSLog(@"⚠️ 缺少必要的解密参数（盐值或迭代次数）");
        if (error) {
            *error = [self errorWithCode:KeychainProcessorErrorInvalidData
                             description:@"Keybag中缺少必要的解密参数"];
        }
        return NO;
    }
}

#pragma mark - 🛠️ 保留所有现有的工具方法

// 保留所有现有方法：unwrapKey, deriveKeyWithPBKDF2, decryptKeychainData, decryptPasswordData,
// readKeychainDataFromItem, findKeychainFileInDirectory, processKeychainPlist,
// createKeychainDataItemFromPlist, stringValueForKey, dataValueForKey, 等等...
// 这些方法已经验证有效，保持不变

- (nullable NSData *)unwrapKey:(NSData *)wrappedKey withMasterKey:(NSData *)masterKey {
    if (wrappedKey.length < 16 || wrappedKey.length % 8 != 0) {
        NSLog(@"❌ wrapped key长度无效: %lu bytes", (unsigned long)wrappedKey.length);
        return nil;
    }
    
    NSLog(@"🔓 尝试解包密钥 (长度: %lu)", (unsigned long)wrappedKey.length);
    
    // 方法1：标准AES-WRAP (RFC 3394)
    size_t unwrappedKeyLength = wrappedKey.length - 8;
    NSMutableData *unwrappedKey = [NSMutableData dataWithLength:unwrappedKeyLength];
    
    size_t actualLength = 0;
    CCCryptorStatus status = CCSymmetricKeyUnwrap(kCCWRAPAES,
                                                  CCrfc3394_iv, CCrfc3394_ivLen,
                                                  masterKey.bytes, masterKey.length,
                                                  wrappedKey.bytes, wrappedKey.length,
                                                  unwrappedKey.mutableBytes, &actualLength);
    
    if (status == kCCSuccess && actualLength > 0) {
        unwrappedKey.length = actualLength;
        NSLog(@"✅ 标准AES-WRAP解包成功 (解包后长度: %lu)", (unsigned long)actualLength);
        return [unwrappedKey copy];
    }
    
    NSLog(@"❌ 标准AES-WRAP解包失败: %d，尝试替代方法", status);
    
    // 方法2：AES-CBC解密
    if (wrappedKey.length >= 16) {
        NSLog(@"🔓 尝试AES-CBC解密方法");
        NSData *iv = [wrappedKey subdataWithRange:NSMakeRange(0, 16)];
        NSData *ciphertext = [wrappedKey subdataWithRange:NSMakeRange(16, wrappedKey.length - 16)];
        
        NSData *decrypted = [self performStandardAESDecryption:ciphertext withKey:masterKey iv:iv];
        if (decrypted && decrypted.length >= 16) {
            NSLog(@"✅ AES-CBC解包成功 (解包后长度: %lu)", (unsigned long)decrypted.length);
            return decrypted;
        }
    }
    
    NSLog(@"❌ 所有密钥解包方法都失败");
    return nil;
}

- (nullable NSData *)deriveKeyWithPBKDF2:(NSString *)password
                                    salt:(NSData *)salt
                              iterations:(int)iterations
                                 keySize:(size_t)keySize {
    
    if (!password || password.length == 0 || !salt || salt.length == 0) {
        return nil;
    }
    
    NSLog(@"🔐 PBKDF2参数: 密码长度=%lu, 盐值长度=%lu, 迭代次数=%d, 目标密钥长度=%zu",
          (unsigned long)password.length, (unsigned long)salt.length, iterations, keySize);
    
    NSMutableData *key = [NSMutableData dataWithLength:keySize];
    
    int result = CCKeyDerivationPBKDF(kCCPBKDF2,
                                     password.UTF8String,
                                     password.length,
                                     salt.bytes,
                                     salt.length,
                                     kCCPRFHmacAlgSHA1,
                                     iterations,
                                     key.mutableBytes,
                                     key.length);
    
    if (result == kCCSuccess) {
        NSLog(@"✅ PBKDF2密钥派生成功");
        return [key copy];
    }
    
    NSLog(@"❌ PBKDF2密钥派生失败: %d", result);
    return nil;
}

- (nullable NSData *)performStandardAESDecryption:(NSData *)ciphertext
                                          withKey:(NSData *)key
                                               iv:(NSData *)iv {
    
    size_t bufferSize = ciphertext.length + kCCBlockSizeAES128;
    NSMutableData *decryptedData = [NSMutableData dataWithLength:bufferSize];
    size_t actualDecryptedSize = 0;
    
    CCCryptorStatus result = CCCrypt(kCCDecrypt,
                                   kCCAlgorithmAES128,
                                   kCCOptionPKCS7Padding,
                                   key.bytes,
                                   key.length,
                                   iv.bytes,
                                   ciphertext.bytes,
                                   ciphertext.length,
                                   decryptedData.mutableBytes,
                                   bufferSize,
                                   &actualDecryptedSize);
    
    if (result == kCCSuccess) {
        decryptedData.length = actualDecryptedSize;
        return [decryptedData copy];
    }
    
    return nil;
}

- (nullable NSString *)decryptKeychainData:(NSData *)encryptedData
                           protectionClass:(iOSProtectionClass)protectionClass
                                     error:(NSError **)error {
    
    if (!self.backupKeybag.isDecrypted) {
        if (error) {
            *error = [self errorWithCode:KeychainProcessorErrorKeybagNotInitialized
                             description:@"Backup Keybag未初始化"];
        }
        return nil;
    }
    
    // 获取保护类密钥
    NSData *classKey = self.backupKeybag.protectionClassKeys[@(protectionClass)];
    if (!classKey) {
        return nil;
    }
    
    // 解析加密数据结构
    if (encryptedData.length < 16) {
        return nil;
    }
    
    NSData *iv = [encryptedData subdataWithRange:NSMakeRange(0, 16)];
    NSData *ciphertext = [encryptedData subdataWithRange:NSMakeRange(16, encryptedData.length - 16)];
    
    NSData *decryptedData = [self performStandardAESDecryption:ciphertext withKey:classKey iv:iv];
    if (!decryptedData) {
        return nil;
    }
    
    NSString *result = [[NSString alloc] initWithData:decryptedData encoding:NSUTF8StringEncoding];
    if (!result) {
        result = [[NSString alloc] initWithData:decryptedData encoding:NSASCIIStringEncoding];
    }
    
    return result;
}

- (NSString *)decryptPasswordData:(NSData *)encryptedData {
    if (!encryptedData || encryptedData.length == 0) {
        return nil;
    }
    
    // 缓存检查
    NSString *cacheKey = [self cacheKeyForData:encryptedData];
    NSString *cachedResult = self.decryptionCache[cacheKey];
    if (cachedResult) {
        return [cachedResult isEqualToString:@"__FAILED__"] ? nil : cachedResult;
    }
    
    // 尝试简单解密
    NSString *result = [self attemptSimpleDecrypt:encryptedData];
    if (result) {
        [self cacheDecryptionResult:result forKey:cacheKey];
        return result;
    }
    
    // 检查Keybag状态
    if (!self.backupKeybag || !self.backupKeybag.isDecrypted) {
        [self cacheDecryptionResult:@"__FAILED__" forKey:cacheKey];
        return nil;
    }
    
    // 尝试不同保护类解密
    NSArray *protectionClasses = @[
        @(iOSProtectionClassWhenUnlocked),
        @(iOSProtectionClassAfterFirstUnlock),
        @(iOSProtectionClassAlways),
        @(iOSProtectionClassWhenUnlockedThisDeviceOnly),
        @(iOSProtectionClassAfterFirstUnlockThisDeviceOnly),
        @(iOSProtectionClassAlwaysThisDeviceOnly)
    ];
    
    for (NSNumber *protectionClassNum in protectionClasses) {
        iOSProtectionClass protectionClass = [protectionClassNum integerValue];
        NSError *error = nil;
        NSString *decryptedText = [self decryptKeychainData:encryptedData
                                            protectionClass:protectionClass
                                                      error:&error];
        if (decryptedText) {
            NSLog(@"✅ 使用保护类 %ld 解密成功", (long)protectionClass);
            [self cacheDecryptionResult:decryptedText forKey:cacheKey];
            return decryptedText;
        }
    }
    
    [self cacheDecryptionResult:@"__FAILED__" forKey:cacheKey];
    return nil;
}

#pragma mark - 🔧 保留所有辅助方法

// 保留所有现有的辅助方法，包括：
// readKeychainDataFromItem, findKeychainFileInDirectory, readKeychainFileAtPath,
// isValidKeychainData, stringValueForKey, dataValueForKey, numberValueForKey,
// dateValueForKey, plistDictToNSDictionary, attemptSimpleDecrypt,
// isValidPasswordString, cacheKeyForData, generateStatistics, exportResults等

- (NSData *)readKeychainDataFromItem:(BackupFileSystemItem *)item {
    NSLog(@"🔑 开始读取Keychain文件");
    
    if (item.fullPath) {
        NSFileManager *fileManager = [NSFileManager defaultManager];
        BOOL isDirectory = NO;
        BOOL fileExists = [fileManager fileExistsAtPath:item.fullPath isDirectory:&isDirectory];
        
        if (!fileExists) {
            NSLog(@"❌ 路径不存在: %@", item.fullPath);
            return nil;
        }
        
        if (isDirectory) {
            return [self findKeychainFileInDirectory:item.fullPath];
        } else {
            return [self readKeychainFileAtPath:item.fullPath];
        }
    }
    
    NSLog(@"❌ 无有效路径信息");
    return nil;
}

- (NSData *)findKeychainFileInDirectory:(NSString *)directoryPath {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSError *error = nil;
    NSArray<NSString *> *fileNames = [fileManager contentsOfDirectoryAtPath:directoryPath error:&error];
    
    if (error || !fileNames) {
        NSLog(@"❌ 无法读取目录内容: %@", error.localizedDescription ?: @"未知错误");
        return nil;
    }
    
    NSArray<NSString *> *prioritizedFileNames = @[
        @"keychain-backup.plist",
        @"keychain.plist",
        @"Keychain.plist"
    ];
    
    for (NSString *targetFileName in prioritizedFileNames) {
        if ([fileNames containsObject:targetFileName]) {
            NSString *keychainFilePath = [directoryPath stringByAppendingPathComponent:targetFileName];
            NSData *data = [self readKeychainFileAtPath:keychainFilePath];
            if (data && [self isValidKeychainData:data]) {
                NSLog(@"✅ 找到有效Keychain文件: %@", targetFileName);
                return data;
            }
        }
    }
    
    return nil;
}

- (NSData *)readKeychainFileAtPath:(NSString *)filePath {
    if (!filePath) return nil;
    
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager fileExistsAtPath:filePath]) {
        return nil;
    }
    
    NSError *error = nil;
    NSData *data = [NSData dataWithContentsOfFile:filePath options:0 error:&error];
    return error ? nil : data;
}

- (BOOL)isValidKeychainData:(NSData *)data {
    if (!data || data.length < 8) return NO;
    
    NSString *dataString = [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(0, MIN(100, data.length))] encoding:NSUTF8StringEncoding];
    if (dataString && ([dataString containsString:@"<?xml"] || [dataString containsString:@"<plist"])) {
        return YES;
    }
    
    const uint8_t *bytes = [data bytes];
    if (data.length >= 8 && bytes[0] == 'b' && bytes[1] == 'p' && bytes[2] == 'l' && bytes[3] == 'i' && bytes[4] == 's' && bytes[5] == 't') {
        return YES;
    }
    
    return data.length > 1024;
}

#pragma mark - 保留所有plist解析方法

- (NSString *)stringValueForKey:(NSString *)key fromDict:(plist_t)dict {
    if (!dict || !key) return nil;
    
    plist_t node = plist_dict_get_item(dict, [key UTF8String]);
    if (!node || plist_get_node_type(node) != PLIST_STRING) return nil;
    
    char *value = NULL;
    plist_get_string_val(node, &value);
    if (value) {
        NSString *result = [NSString stringWithUTF8String:value];
        free(value);
        return result;
    }
    
    return nil;
}

- (NSData *)dataValueForKey:(NSString *)key fromDict:(plist_t)dict {
    if (!dict || !key) return nil;
    
    plist_t node = plist_dict_get_item(dict, [key UTF8String]);
    if (!node || plist_get_node_type(node) != PLIST_DATA) return nil;
    
    char *value = NULL;
    uint64_t length = 0;
    plist_get_data_val(node, &value, &length);
    if (value && length > 0) {
        NSData *result = [NSData dataWithBytes:value length:(NSUInteger)length];
        free(value);
        return result;
    }
    
    return nil;
}

- (NSNumber *)numberValueForKey:(NSString *)key fromDict:(plist_t)dict {
    if (!dict || !key) return nil;
    
    plist_t node = plist_dict_get_item(dict, [key UTF8String]);
    if (!node) return nil;
    
    plist_type nodeType = plist_get_node_type(node);
    
    if (nodeType == PLIST_UINT) {
        uint64_t value = 0;
        plist_get_uint_val(node, &value);
        return @(value);
    } else if (nodeType == PLIST_REAL) {
        double value = 0.0;
        plist_get_real_val(node, &value);
        return @(value);
    }
    
    return nil;
}

- (NSDate *)dateValueForKey:(NSString *)key fromDict:(plist_t)dict {
    if (!dict || !key) return nil;
    
    plist_t node = plist_dict_get_item(dict, [key UTF8String]);
    if (!node || plist_get_node_type(node) != PLIST_DATE) return nil;
    
    int32_t sec = 0;
    int32_t usec = 0;
    plist_get_date_val(node, &sec, &usec);
    
    NSTimeInterval timeInterval = sec + (usec / 1000000.0);
    return [NSDate dateWithTimeIntervalSinceReferenceDate:timeInterval];
}

- (NSDictionary *)plistDictToNSDictionary:(plist_t)dict {
    if (!dict || plist_get_node_type(dict) != PLIST_DICT) {
        return nil;
    }
    
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    
    plist_dict_iter iter = NULL;
    plist_dict_new_iter(dict, &iter);
    
    char *key = NULL;
    plist_t value = NULL;
    
    while (iter) {
        plist_dict_next_item(dict, iter, &key, &value);
        if (!key || !value) break;
        
        NSString *nsKey = [NSString stringWithUTF8String:key];
        id nsValue = [self plistNodeToNSObject:value];
        
        if (nsKey && nsValue) {
            result[nsKey] = nsValue;
        }
        
        free(key);
        key = NULL;
    }
    
    if (iter) {
        free(iter);
    }
    
    return [result copy];
}

- (id)plistNodeToNSObject:(plist_t)node {
    if (!node) return nil;
    
    plist_type nodeType = plist_get_node_type(node);
    
    switch (nodeType) {
        case PLIST_STRING: {
            char *value = NULL;
            plist_get_string_val(node, &value);
            if (value) {
                NSString *result = [NSString stringWithUTF8String:value];
                free(value);
                return result;
            }
            break;
        }
        case PLIST_DATA: {
            char *value = NULL;
            uint64_t length = 0;
            plist_get_data_val(node, &value, &length);
            if (value && length > 0) {
                NSData *result = [NSData dataWithBytes:value length:(NSUInteger)length];
                free(value);
                return result;
            }
            break;
        }
        case PLIST_UINT: {
            uint64_t value = 0;
            plist_get_uint_val(node, &value);
            return @(value);
        }
        case PLIST_REAL: {
            double value = 0.0;
            plist_get_real_val(node, &value);
            return @(value);
        }
        case PLIST_BOOLEAN: {
            uint8_t value = 0;
            plist_get_bool_val(node, &value);
            return @(value != 0);
        }
        case PLIST_DATE: {
            int32_t sec = 0;
            int32_t usec = 0;
            plist_get_date_val(node, &sec, &usec);
            NSTimeInterval timeInterval = sec + (usec / 1000000.0);
            return [NSDate dateWithTimeIntervalSinceReferenceDate:timeInterval];
        }
        default:
            break;
    }
    
    return nil;
}

- (iOSProtectionClass)inferProtectionClassFromAttributes:(NSDictionary *)attributes {
    NSString *accessible = attributes[@"pdmn"];
    
    if ([accessible isEqualToString:@"ak"]) {
        return iOSProtectionClassAlways;
    } else if ([accessible isEqualToString:@"ck"]) {
        return iOSProtectionClassAfterFirstUnlock;
    } else if ([accessible isEqualToString:@"dk"]) {
        return iOSProtectionClassWhenUnlocked;
    } else if ([accessible isEqualToString:@"aku"]) {
        return iOSProtectionClassAlwaysThisDeviceOnly;
    } else if ([accessible isEqualToString:@"cku"]) {
        return iOSProtectionClassAfterFirstUnlockThisDeviceOnly;
    } else if ([accessible isEqualToString:@"dku"]) {
        return iOSProtectionClassWhenUnlockedThisDeviceOnly;
    }
    
    return iOSProtectionClassWhenUnlocked;
}

#pragma mark - 工具方法

- (NSString *)attemptSimpleDecrypt:(NSData *)data {
    NSString *utf8String = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if ([self isValidPasswordString:utf8String]) {
        return utf8String;
    }
    
    NSString *asciiString = [[NSString alloc] initWithData:data encoding:NSASCIIStringEncoding];
    if ([self isValidPasswordString:asciiString]) {
        return asciiString;
    }
    
    return nil;
}

- (BOOL)isValidPasswordString:(NSString *)string {
    if (!string || string.length == 0 || string.length > 256) {
        return NO;
    }
    
    NSCharacterSet *printableSet = [NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*()_+-=[]{}|\\;:'\",.<>?/`~ "];
    NSCharacterSet *controlSet = [NSCharacterSet controlCharacterSet];
    NSMutableCharacterSet *allowedSet = [printableSet mutableCopy];
    [allowedSet formUnionWithCharacterSet:[NSCharacterSet whitespaceCharacterSet]];
    
    NSUInteger validChars = 0;
    for (NSUInteger i = 0; i < string.length; i++) {
        unichar ch = [string characterAtIndex:i];
        if ([allowedSet characterIsMember:ch] && ![controlSet characterIsMember:ch]) {
            validChars++;
        }
    }
    
    return (validChars >= string.length * 0.8);
}

- (NSString *)cacheKeyForData:(NSData *)data {
    if (!data) return @"";
    
    NSMutableData *hash = [NSMutableData dataWithLength:CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, hash.mutableBytes);
    
    return [hash base64EncodedStringWithOptions:0];
}

- (void)cacheDecryptionResult:(NSString *)result forKey:(NSString *)key {
    if (!self.decryptionCache) {
        self.decryptionCache = [NSMutableDictionary dictionary];
    }
    
    if (key && result) {
        self.decryptionCache[key] = result;
    }
}

- (nullable NSString *)findManifestPlistPath {
    NSArray *searchPaths = @[
        [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/MobileSync/Backup"],
        [[NSFileManager defaultManager] currentDirectoryPath],
        [NSTemporaryDirectory() stringByDeletingLastPathComponent]
    ];
    
    NSFileManager *fileManager = [NSFileManager defaultManager];
    
    for (NSString *searchPath in searchPaths) {
        NSError *error = nil;
        NSArray *contents = [fileManager contentsOfDirectoryAtPath:searchPath error:&error];
        
        if (!contents) continue;
        
        for (NSString *item in contents) {
            NSString *itemPath = [searchPath stringByAppendingPathComponent:item];
            NSString *manifestPath = [itemPath stringByAppendingPathComponent:@"Manifest.plist"];
            
            if ([fileManager fileExistsAtPath:manifestPath]) {
                NSLog(@"🎯 找到候选Manifest.plist: %@", manifestPath);
                return manifestPath;
            }
        }
    }
    
    NSLog(@"❌ 在所有搜索路径中都未找到有效的Manifest.plist");
    return nil;
}

#pragma mark - 统计和导出（保持不变）

- (void)generateStatistics {
    NSMutableDictionary *stats = [NSMutableDictionary dictionary];
    
    NSUInteger totalCount = _mutableProcessedItems.count;
    NSUInteger encryptedCount = 0;
    NSUInteger decryptedCount = 0;
    
    NSMutableDictionary *typeStats = [NSMutableDictionary dictionary];
    
    for (KeychainDataItem *item in _mutableProcessedItems) {
        NSString *typeKey = [KeychainDataItem localizedStringForItemType:item.itemType];
        NSNumber *currentCount = typeStats[typeKey] ?: @0;
        typeStats[typeKey] = @([currentCount integerValue] + 1);
        
        if (item.isPasswordEncrypted) {
            encryptedCount++;
        } else if (item.password) {
            decryptedCount++;
        }
    }
    
    stats[@"总数"] = @(totalCount);
    stats[@"已解密"] = @(decryptedCount);
    stats[@"加密"] = @(encryptedCount);
    stats[@"类型统计"] = typeStats;
    
    if (encryptedCount + decryptedCount > 0) {
        double successRate = (double)decryptedCount / (encryptedCount + decryptedCount) * 100;
        stats[@"解密成功率"] = @(successRate);
    }
    
    _mutableStatistics = stats;
    
    NSLog(@"📊 统计信息: 总数=%lu, 已解密=%lu, 加密=%lu",
          (unsigned long)totalCount, (unsigned long)decryptedCount, (unsigned long)encryptedCount);
}

- (BOOL)exportResultsToFile:(NSString *)filePath
                     format:(NSString *)format
                      error:(NSError **)error {
    if (!filePath || !format || _mutableProcessedItems.count == 0) {
        if (error) {
            *error = [self errorWithCode:KeychainProcessorErrorExportFailed
                             description:@"导出参数无效或无数据可导出"];
        }
        return NO;
    }
    
    NSData *exportData = nil;
    
    if ([format.lowercaseString isEqualToString:@"json"]) {
        exportData = [self exportAsJSON];
    } else if ([format.lowercaseString isEqualToString:@"csv"]) {
        exportData = [self exportAsCSV];
    } else if ([format.lowercaseString isEqualToString:@"plist"]) {
        exportData = [self exportAsPlist];
    } else {
        if (error) {
            *error = [self errorWithCode:KeychainProcessorErrorExportFailed
                             description:[NSString stringWithFormat:@"不支持的导出格式: %@", format]];
        }
        return NO;
    }
    
    if (!exportData) {
        if (error) {
            *error = [self errorWithCode:KeychainProcessorErrorExportFailed
                             description:@"导出数据生成失败"];
        }
        return NO;
    }
    
    NSError *writeError = nil;
    BOOL success = [exportData writeToFile:filePath options:NSDataWritingAtomic error:&writeError];
    
    if (!success && error) {
        *error = writeError;
    }
    
    return success;
}

- (NSData *)exportAsJSON {
    NSMutableArray *exportArray = [NSMutableArray array];
    
    for (KeychainDataItem *item in _mutableProcessedItems) {
        NSMutableDictionary *dict = [NSMutableDictionary dictionary];
        
        dict[@"Type"] = [KeychainDataItem stringForItemType:item.itemType];
        dict[@"LocalizedType"] = [KeychainDataItem localizedStringForItemType:item.itemType];
        if (item.service) dict[@"Service"] = item.service;
        if (item.account) dict[@"Account"] = item.account;
        if (item.password) dict[@"Password"] = item.password;
        if (item.server) dict[@"Server"] = item.server;
        if (item.protocol) dict[@"Protocol"] = item.protocol;
        if (item.path) dict[@"Path"] = item.path;
        if (item.port) dict[@"Port"] = item.port;
        if (item.creationDate) dict[@"CreationDate"] = [item.creationDate description];
        if (item.modificationDate) dict[@"ModificationDate"] = [item.modificationDate description];
        if (item.comment) dict[@"Comment"] = item.comment;
        if (item.label) dict[@"Label"] = item.label;
        dict[@"IsPasswordEncrypted"] = @(item.isPasswordEncrypted);
        dict[@"ProtectionClass"] = @(item.protectionClass);
        dict[@"IsThisDeviceOnly"] = @(item.isThisDeviceOnly);
        dict[@"CanDecrypt"] = @(item.canDecrypt);
        
        [exportArray addObject:dict];
    }
    
    NSError *error = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:exportArray
                                                       options:NSJSONWritingPrettyPrinted
                                                         error:&error];
    
    if (error) {
        NSLog(@"❌ JSON导出失败: %@", error.localizedDescription);
        return nil;
    }
    
    return jsonData;
}

- (NSData *)exportAsCSV {
    NSMutableString *csvString = [NSMutableString string];
    
    [csvString appendString:@"Type,Service,Account,Password,Server,Protocol,Path,Port,CreationDate,ModificationDate,Comment,Label,IsEncrypted,ProtectionClass,IsThisDeviceOnly,CanDecrypt\n"];
    
    for (KeychainDataItem *item in _mutableProcessedItems) {
        NSArray *fields = @[
            [KeychainDataItem stringForItemType:item.itemType] ?: @"",
            item.service ?: @"",
            item.account ?: @"",
            item.password ?: @"",
            item.server ?: @"",
            item.protocol ?: @"",
            item.path ?: @"",
            item.port ? [item.port stringValue] : @"",
            item.creationDate ? [item.creationDate description] : @"",
            item.modificationDate ? [item.modificationDate description] : @"",
            item.comment ?: @"",
            item.label ?: @"",
            item.isPasswordEncrypted ? @"Yes" : @"No",
            [@(item.protectionClass) stringValue],
            item.isThisDeviceOnly ? @"Yes" : @"No",
            item.canDecrypt ? @"Yes" : @"No"
        ];
        
        NSMutableArray *escapedFields = [NSMutableArray array];
        for (NSString *field in fields) {
            NSString *escapedField = [field stringByReplacingOccurrencesOfString:@"\"" withString:@"\"\""];
            if ([escapedField containsString:@","] || [escapedField containsString:@"\n"] || [escapedField containsString:@"\""]) {
                escapedField = [NSString stringWithFormat:@"\"%@\"", escapedField];
            }
            [escapedFields addObject:escapedField];
        }
        
        [csvString appendFormat:@"%@\n", [escapedFields componentsJoinedByString:@","]];
    }
    
    return [csvString dataUsingEncoding:NSUTF8StringEncoding];
}

- (NSData *)exportAsPlist {
    NSMutableArray *exportArray = [NSMutableArray array];
    
    for (KeychainDataItem *item in _mutableProcessedItems) {
        NSMutableDictionary *dict = [NSMutableDictionary dictionary];
        
        dict[@"Type"] = [KeychainDataItem stringForItemType:item.itemType];
        dict[@"LocalizedType"] = [KeychainDataItem localizedStringForItemType:item.itemType];
        if (item.service) dict[@"Service"] = item.service;
        if (item.account) dict[@"Account"] = item.account;
        if (item.password) dict[@"Password"] = item.password;
        if (item.server) dict[@"Server"] = item.server;
        if (item.protocol) dict[@"Protocol"] = item.protocol;
        if (item.path) dict[@"Path"] = item.path;
        if (item.port) dict[@"Port"] = item.port;
        if (item.creationDate) dict[@"CreationDate"] = item.creationDate;
        if (item.modificationDate) dict[@"ModificationDate"] = item.modificationDate;
        if (item.comment) dict[@"Comment"] = item.comment;
        if (item.label) dict[@"Label"] = item.label;
        dict[@"IsPasswordEncrypted"] = @(item.isPasswordEncrypted);
        dict[@"ProtectionClass"] = @(item.protectionClass);
        dict[@"IsThisDeviceOnly"] = @(item.isThisDeviceOnly);
        dict[@"CanDecrypt"] = @(item.canDecrypt);
        
        [exportArray addObject:dict];
    }
    
    NSError *error = nil;
    NSData *plistData = [NSPropertyListSerialization dataWithPropertyList:exportArray
                                                                    format:NSPropertyListXMLFormat_v1_0
                                                                   options:0
                                                                     error:&error];
    
    if (error) {
        NSLog(@"❌ Plist导出失败: %@", error.localizedDescription);
        return nil;
    }
    
    return plistData;
}

#pragma mark - 通知方法

- (void)updateProgress:(double)progress status:(NSString *)status {
    _internalProgress = progress;
    _internalStatus = status;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self.delegate respondsToSelector:@selector(keychainProcessor:didUpdateProgress:withMessage:)]) {
            [self.delegate keychainProcessor:self didUpdateProgress:progress withMessage:status];
        }
    });
}

- (void)notifyCompletion {
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self.delegate respondsToSelector:@selector(keychainProcessor:didCompleteWithResults:)]) {
            [self.delegate keychainProcessor:self didCompleteWithResults:self.processedItems];
        }
    });
}

- (void)notifyError:(NSError *)error {
    _internalLastError = error;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self.delegate respondsToSelector:@selector(keychainProcessor:didFailWithError:)]) {
            [self.delegate keychainProcessor:self didFailWithError:error];
        }
    });
}

#pragma mark - 错误处理

- (NSError *)errorWithCode:(KeychainProcessorError)code description:(NSString *)description {
    NSDictionary *userInfo = @{
        NSLocalizedDescriptionKey: description,
        NSLocalizedFailureReasonErrorKey: description
    };
    
    return [NSError errorWithDomain:KeychainProcessorErrorDomain
                               code:code
                           userInfo:userInfo];
}

@end
