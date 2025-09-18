//
//  KeychainAnalysisController.m
//
//  Created by Monterey on 19/1/2025.
//

#import "KeychainAnalysisController.h"
#import "AlertWindowController.h"
#import "LanguageManager.h"

@interface KeychainAnalysisController ()

@property (nonatomic, strong) KeychainProcessorController *internalProcessorController;  // V4.0 内部处理器
@property (nonatomic, strong) BackupFileSystemItem *currentItem;
@property (nonatomic, strong) NSMutableString *logContent;
@property (nonatomic, assign) BOOL detailViewVisible;
@property (nonatomic, strong) NSTimer *updateTimer;
@property (nonatomic, assign) NSTimeInterval startTime;

// 窗口约束 - 用于动画调整窗口大小
@property (weak) IBOutlet NSLayoutConstraint *windowHeightConstraint;

@end

@implementation KeychainAnalysisController

#pragma mark - 生命周期 V4.0 修复

- (instancetype)init {
    self = [super init];
    if (self) {
        [self commonInit];
        NSLog(@"🔑 KeychainAnalysisController V4.0 initialized via init");
    }
    return self;
}

// ✅ 修复：添加 Storyboard 初始化支持
- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) {
        [self commonInit];
        NSLog(@"🔑 KeychainAnalysisController V4.0 initialized via Storyboard");
    }
    return self;
}

// ✅ 修复：通用初始化方法
- (void)commonInit {
    _internalProcessorController = [[KeychainProcessorController alloc] init];
    _internalProcessorController.delegate = self;
    _logContent = [NSMutableString string];
    _detailViewVisible = NO;
    
    NSLog(@"🔑 KeychainAnalysisController V4.0 common init completed");
    NSLog(@"🔑 _internalProcessorController: %@", _internalProcessorController);
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
    // ✅ 安全检查：确保 _internalProcessorController 已初始化
    if (!_internalProcessorController) {
        NSLog(@"⚠️ _internalProcessorController 未初始化，尝试修复...");
        [self commonInit];
    }
    
    [self setupUI];
    [self setupInitialState];
    
    NSLog(@"🔑 KeychainAnalysisController V4.0 view loaded");
    NSLog(@"🔑 最终检查 _internalProcessorController: %@", _internalProcessorController);
}

- (void)dealloc {
    [self stopUpdateTimer];
    NSLog(@"🔑 KeychainAnalysisController V4.0 dealloc");
}

#pragma mark - V4.0 公开属性访问器

/**
 * ✅ V4.0 公开processorController属性，供外部访问统计信息
 */
- (KeychainProcessorController *)processorController {
    return _internalProcessorController;
}

#pragma mark - 公共属性 V4.0

- (BOOL)isAnalysisRunning {
    return _internalProcessorController.isProcessing;
}

#pragma mark - UI初始化 V4.0

- (void)setupUI {
    // 设置标题
    if (self.titleLabel) {
        self.titleLabel.stringValue = @"钥匙串数据分析 V4.0";
        self.titleLabel.font = [NSFont boldSystemFontOfSize:16];
    }
    
    // 设置进度条
    if (self.progressIndicator) {
        self.progressIndicator.minValue = 0.0;
        self.progressIndicator.maxValue = 1.0;
        self.progressIndicator.doubleValue = 0.0;
        self.progressIndicator.indeterminate = NO;
    }
    
    // 设置状态标签
    if (self.statusLabel) {
        self.statusLabel.stringValue = @"准备开始分析...";
    }
    
    // 设置详细信息标签
    if (self.detailLabel) {
        self.detailLabel.stringValue = @"";
        self.detailLabel.textColor = [NSColor secondaryLabelColor];
    }
    
    // 设置按钮
    if (self.cancelButton) {
        [self.cancelButton setTitle:@"取消"];
        self.cancelButton.keyEquivalent = @"\e"; // ESC键
    }
    
    if (self.detailButton) {
        [self.detailButton setTitle:@"显示详细信息"];
    }
    
    // 设置日志视图
    if (self.logTextView) {
        self.logTextView.editable = NO;
        self.logTextView.selectable = YES;
        self.logTextView.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
        self.logTextView.textColor = [NSColor labelColor];
        self.logTextView.backgroundColor = [NSColor controlBackgroundColor];
    }
    
    // 初始隐藏详细信息视图
    [self hideDetailView:NO];
}

- (void)setupInitialState {
    [self updateProgress:0.0 status:@"等待开始..." detail:@""];
    
    if (self.cancelButton) {
        self.cancelButton.enabled = NO;
    }
    
    if (self.detailButton) {
        self.detailButton.enabled = YES;
    }
}

#pragma mark - 窗口管理 V4.0

- (void)showProgressWindowModal:(NSWindow *)parentWindow {
    if (self.progressWindow || !parentWindow) {
        NSLog(@"⚠️ KeychainAnalysisController V4.0: 窗口已存在或父窗口无效");
        return;
    }
    
    // 创建窗口
    NSRect windowFrame = NSMakeRect(0, 0, 480, 160); // 基础尺寸
    self.progressWindow = [[NSWindow alloc] initWithContentRect:windowFrame
                                                      styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                                                        backing:NSBackingStoreBuffered
                                                          defer:NO];
    
    self.progressWindow.title = @"钥匙串数据分析 V4.0";
    self.progressWindow.contentViewController = self;
    self.progressWindow.releasedWhenClosed = NO;
    
    // 居中显示
    [self.progressWindow center];
    
    // 模态显示
    [parentWindow beginSheet:self.progressWindow completionHandler:^(NSModalResponse returnCode) {
        NSLog(@"🔑 V4.0 分析窗口关闭，返回码: %ld", (long)returnCode);
    }];
    
    NSLog(@"🔑 V4.0 模态分析窗口已显示");
}

- (void)showProgressWindow {
    if (self.progressWindow) {
        NSLog(@"⚠️ KeychainAnalysisController V4.0: 窗口已存在");
        return;
    }
    
    // 创建窗口
    NSRect windowFrame = NSMakeRect(0, 0, 480, 160);
    self.progressWindow = [[NSWindow alloc] initWithContentRect:windowFrame
                                                      styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable)
                                                        backing:NSBackingStoreBuffered
                                                          defer:NO];
    
    self.progressWindow.title = @"钥匙串数据分析 V4.0";
    self.progressWindow.contentViewController = self;
    self.progressWindow.releasedWhenClosed = NO;
    self.progressWindow.minSize = NSMakeSize(400, 150);
    
    // 居中显示
    [self.progressWindow center];
    [self.progressWindow makeKeyAndOrderFront:nil];
    
    NSLog(@"🔑 V4.0 非模态分析窗口已显示");
}

- (void)closeProgressWindow {
    [self stopUpdateTimer];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        NSWindow *window = self.progressWindow ?: self.view.window;
        
        if (window) {
            if (window.sheetParent) {
                // Sheet 模式
                [window.sheetParent endSheet:window returnCode:NSModalResponseOK];
            } else {
                // 普通窗口
                [window performClose:nil];
            }
        }
        
        self.progressWindow = nil;
        NSLog(@"🔑 V4.0 分析窗口已强制关闭");
    });
}

#pragma mark - 分析控制 V4.0 修复

- (void)startAnalysis:(BackupFileSystemItem *)item {
    NSLog(@"🔑 V4.0 startAnalysis 开始");
    NSLog(@"🔑 传入的 item: %@", item);
    NSLog(@"🔑 item.domain: %@", item.domain);
    NSLog(@"🔑 item.name: %@", item.name);
    NSLog(@"🔑 item.fullPath: %@", item.fullPath);
    NSLog(@"🔑 _internalProcessorController 状态: %@", _internalProcessorController);
    NSLog(@"🔑 item.backupRootPath: %@", item.backupRootPath);  // 备份文件目录
    
    /*
    if (self.isAnalysisRunning) {
        NSLog(@"⚠️ V4.0 分析已在进行中，忽略新请求");
        return;
    }*/
    
    if (!item) {
        NSLog(@"❌ V4.0 无效的分析项目");
        [self showError:@"无效的分析项目"];
        return;
    }
    
    // ✅ 验证备份根目录路径
    if (!item.backupRootPath) {
        NSLog(@"❌ 缺少备份根目录路径信息");
        [self showError:@"缺少备份根目录路径信息"];
        return;
    }
    
    // ✅ 安全检查：确保处理器存在
    if (!_internalProcessorController) {
        NSLog(@"❌ _internalProcessorController 为 nil，尝试重新初始化...");
        [self commonInit];
        
        if (!_internalProcessorController) {
            NSLog(@"❌ 无法初始化处理器，分析失败");
            [self showError:@"处理器初始化失败"];
            return;
        }
    }
    
    self.currentItem = item;
    [self prepareForAnalysis];
    
    NSLog(@"🔑 V4.0 开始分析Keychain数据: %@", item.displayName ?: item.name);
    NSLog(@"🔑 V4.0 调用 processKeychainData...");
    
    // ✅ 传递备份根目录路径给处理器
    [_internalProcessorController processKeychainData:item withBackupRootPath:item.backupRootPath];
    
    NSLog(@"🔑 V4.0 processKeychainData 调用完成");
}

- (void)prepareForAnalysis {
    [self.logContent setString:@""];
    [self addLogMessage:@"=== 钥匙串数据分析开始 V4.0 ==="];
    [self addLogMessage:[NSString stringWithFormat:@"分析项目: %@", self.currentItem.displayName ?: self.currentItem.name]];
    [self addLogMessage:[NSString stringWithFormat:@"文件路径: %@", self.currentItem.fullPath ?: @"未知"]];
    [self addLogMessage:@""];
    
    self.startTime = [NSDate timeIntervalSinceReferenceDate];
    
    // 更新UI状态
    if (self.cancelButton) {
        self.cancelButton.enabled = YES;
    }
    
    [self updateProgress:0.0 status:@"正在初始化..." detail:@"准备读取Keychain数据文件"];
    [self startUpdateTimer];
}

#pragma mark - 定时器管理 V4.0

- (void)startUpdateTimer {
    [self stopUpdateTimer];
    
    self.updateTimer = [NSTimer scheduledTimerWithTimeInterval:0.1
                                                        target:self
                                                      selector:@selector(updateElapsedTime)
                                                      userInfo:nil
                                                       repeats:YES];
}

- (void)stopUpdateTimer {
    if (self.updateTimer) {
        [self.updateTimer invalidate];
        self.updateTimer = nil;
    }
}

- (void)updateElapsedTime {
    if (!self.isAnalysisRunning) {
        return;
    }
    
    NSTimeInterval elapsed = [NSDate timeIntervalSinceReferenceDate] - self.startTime;
    NSString *timeString = [self formatTimeInterval:elapsed];
    
    NSString *currentDetail = self.detailLabel.stringValue;
    if (![currentDetail containsString:@"已用时:"]) {
        currentDetail = [currentDetail stringByAppendingFormat:@" (已用时: %@)", timeString];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.detailLabel) {
                self.detailLabel.stringValue = currentDetail;
            }
        });
    }
}

- (NSString *)formatTimeInterval:(NSTimeInterval)interval {
    int minutes = (int)(interval / 60);
    int seconds = (int)(interval - minutes * 60);
    
    if (minutes > 0) {
        return [NSString stringWithFormat:@"%d分%d秒", minutes, seconds];
    } else {
        return [NSString stringWithFormat:@"%d秒", seconds];
    }
}

#pragma mark - UI更新 V4.0

- (void)updateProgress:(double)progress status:(NSString *)status detail:(NSString *)detail {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.progressIndicator) {
            self.progressIndicator.doubleValue = progress;
        }
        
        if (self.statusLabel && status) {
            self.statusLabel.stringValue = status;
        }
        
        if (self.detailLabel && detail) {
            self.detailLabel.stringValue = detail;
        }
        
        // 更新窗口标题显示进度百分比
        if (self.progressWindow && progress > 0) {
            NSString *title = [NSString stringWithFormat:@"钥匙串数据分析 V4.0 - %.0f%%", progress * 100];
            self.progressWindow.title = title;
        }
    });
}

- (void)addLogMessage:(NSString *)message {
    if (!message) return;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *timestamp = [self currentTimestamp];
        NSString *logLine = [NSString stringWithFormat:@"[%@] %@\n", timestamp, message];
        
        [self.logContent appendString:logLine];
        
        if (self.logTextView) {
            self.logTextView.string = self.logContent;
            
            // 滚动到底部
            NSRange range = NSMakeRange(self.logContent.length, 0);
            [self.logTextView scrollRangeToVisible:range];
        }
    });
}

- (NSString *)currentTimestamp {
    static NSDateFormatter *formatter = nil;
    if (!formatter) {
        formatter = [[NSDateFormatter alloc] init];
        formatter.dateFormat = @"HH:mm:ss";
    }
    return [formatter stringFromDate:[NSDate date]];
}

#pragma mark - 详细信息视图控制 V4.0

- (void)showDetailView:(BOOL)animated {
    if (self.detailViewVisible) return;
    
    self.detailViewVisible = YES;
    
    if (self.detailButton) {
        [self.detailButton setTitle:@"隐藏详细信息"];
    }
    
    if (self.logScrollView) {
        self.logScrollView.hidden = NO;
    }
    
    // 调整窗口大小
    if (self.progressWindow && animated) {
        NSRect currentFrame = self.progressWindow.frame;
        NSRect newFrame = currentFrame;
        newFrame.size.height = 400; // 展开后的高度
        newFrame.origin.y -= (newFrame.size.height - currentFrame.size.height);
        
        [self.progressWindow setFrame:newFrame display:YES animate:YES];
    }
}

- (void)hideDetailView:(BOOL)animated {
    if (!self.detailViewVisible) return;
    
    self.detailViewVisible = NO;
    
    if (self.detailButton) {
        [self.detailButton setTitle:@"显示详细信息"];
    }
    
    if (self.logScrollView) {
        self.logScrollView.hidden = YES;
    }
    
    // 调整窗口大小
    if (self.progressWindow && animated) {
        NSRect currentFrame = self.progressWindow.frame;
        NSRect newFrame = currentFrame;
        newFrame.size.height = 160; // 收缩后的高度
        newFrame.origin.y += (currentFrame.size.height - newFrame.size.height);
        
        [self.progressWindow setFrame:newFrame display:YES animate:YES];
    }
}

#pragma mark - IBAction方法 V4.0

- (IBAction)cancelAnalysis:(id)sender {
    NSLog(@"🛑 V4.0 用户请求取消Keychain分析");
    
    // 显示确认对话框
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"确认取消";
    alert.informativeText = @"确定要取消当前的钥匙串数据分析吗？";
    alert.alertStyle = NSAlertStyleWarning;
    [alert addButtonWithTitle:@"取消分析"];
    [alert addButtonWithTitle:@"继续分析"];
    
    NSModalResponse response = [alert runModal];
    if (response == NSAlertFirstButtonReturn) {
        [self performCancellation];
    }
}

- (void)performCancellation {
    [_internalProcessorController cancelProcessing];
    [self stopUpdateTimer];
    
    [self addLogMessage:@"用户取消了分析操作"];
    [self updateProgress:0.0 status:@"已取消" detail:@"分析已被用户取消"];
    
    if (self.cancelButton) {
        self.cancelButton.enabled = NO;
    }
    
    // 通知代理
    if ([self.delegate respondsToSelector:@selector(keychainAnalysisControllerDidCancel:)]) {
        [self.delegate keychainAnalysisControllerDidCancel:self];
    }
    
    // 延迟关闭窗口
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self closeProgressWindow];
    });
}

- (IBAction)toggleDetailView:(id)sender {
    if (self.detailViewVisible) {
        [self hideDetailView:YES];
    } else {
        [self showDetailView:YES];
    }
}

- (IBAction)saveLogToFile:(id)sender {
    NSSavePanel *savePanel = [NSSavePanel savePanel];
    savePanel.allowedFileTypes = @[@"txt"];
    savePanel.nameFieldStringValue = [NSString stringWithFormat:@"Keychain分析日志_V4_%@.txt",
                                     [[NSDate date] descriptionWithLocale:nil]];
    
    [savePanel beginWithCompletionHandler:^(NSInteger result) {
        if (result == NSModalResponseOK) {
            NSURL *fileURL = savePanel.URL;
            NSError *error = nil;
            BOOL success = [self.logContent writeToURL:fileURL
                                           atomically:YES
                                             encoding:NSUTF8StringEncoding
                                                error:&error];
            
            if (!success) {
                NSLog(@"❌ V4.0 保存日志文件失败: %@", error.localizedDescription);
                [self showError:[NSString stringWithFormat:@"保存日志失败: %@", error.localizedDescription]];
            } else {
                NSLog(@"✅ V4.0 日志已保存到: %@", fileURL.path);
            }
        }
    }];
}

#pragma mark - KeychainProcessorDelegate V4.0

- (void)keychainProcessor:(KeychainProcessorController *)processor
           didUpdateProgress:(double)progress
                 withMessage:(NSString *)message {
    [self updateProgress:progress status:message detail:@""];
    [self addLogMessage:message];
}

- (void)keychainProcessor:(KeychainProcessorController *)processor
         didCompleteWithResults:(NSArray *)results {
    [self stopUpdateTimer];
    
    NSTimeInterval totalTime = [NSDate timeIntervalSinceReferenceDate] - self.startTime;
    NSString *timeString = [self formatTimeInterval:totalTime];
    
    [self addLogMessage:@""];
    [self addLogMessage:@"=== 分析完成 V4.0 ==="];
    [self addLogMessage:[NSString stringWithFormat:@"总共解析 %lu 个钥匙串条目", (unsigned long)results.count]];
    [self addLogMessage:[NSString stringWithFormat:@"总用时: %@", timeString]];
    
    [self updateProgress:1.0
                  status:@"分析完成"
                  detail:[NSString stringWithFormat:@"共解析 %lu 个条目，用时 %@",
                         (unsigned long)results.count, timeString]];
    
    if (self.cancelButton) {
        [self.cancelButton setTitle:@"关闭"];
        self.cancelButton.keyEquivalent = @"";
        self.cancelButton.action = @selector(closeWindow:);
    }
    
    // 通知代理
    if ([self.delegate respondsToSelector:@selector(keychainAnalysisController:didCompleteWithResults:)]) {
        [self.delegate keychainAnalysisController:self didCompleteWithResults:results];
    }
    
    NSLog(@"✅ V4.0 Keychain分析完成，共解析 %lu 个条目", (unsigned long)results.count);
}

- (void)keychainProcessor:(KeychainProcessorController *)processor
            didFailWithError:(NSError *)error {
    [self stopUpdateTimer];
    
    NSString *errorMessage = error.localizedDescription ?: @"未知错误";
    
    [self addLogMessage:@""];
    [self addLogMessage:@"=== 分析失败 V4.0 ==="];
    [self addLogMessage:[NSString stringWithFormat:@"错误信息: %@", errorMessage]];
    
    [self updateProgress:0.0 status:@"分析失败" detail:errorMessage];
    
    if (self.cancelButton) {
        [self.cancelButton setTitle:@"关闭"];
        self.cancelButton.keyEquivalent = @"";
        self.cancelButton.action = @selector(closeWindow:);
    }
    
    // 通知代理
    if ([self.delegate respondsToSelector:@selector(keychainAnalysisController:didFailWithError:)]) {
        [self.delegate keychainAnalysisController:self didFailWithError:error];
    }
    
    // 显示错误对话框
    [self showError:errorMessage];
    
    NSLog(@"❌ V4.0 Keychain分析失败: %@", errorMessage);
}

- (void)keychainProcessor:(KeychainProcessorController *)processor
     needsPasswordWithCompletion:(void(^)(NSString * _Nullable password, BOOL cancelled))completion {
    
    [self addLogMessage:@"需要输入解锁密码"];
    
    // 显示密码输入对话框
    dispatch_async(dispatch_get_main_queue(), ^{
        [self showPasswordInputDialogWithCompletion:completion];
    });
}

#pragma mark - 辅助方法 V4.0

- (void)showPasswordInputDialogWithCompletion:(void(^)(NSString * _Nullable password, BOOL cancelled))completion {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"需要密码";
    alert.informativeText = @"该钥匙串数据已加密，请输入解锁密码：";
    alert.alertStyle = NSAlertStyleInformational;
    
    NSSecureTextField *passwordField = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(0, 0, 200, 24)];
    passwordField.placeholderString = @"请输入密码";
    alert.accessoryView = passwordField;
    
    [alert addButtonWithTitle:@"确定"];
    [alert addButtonWithTitle:@"取消"];
    
    NSModalResponse response = [alert runModal];
    
    if (response == NSAlertFirstButtonReturn) {
        NSString *password = passwordField.stringValue;
        if (password.length > 0) {
            completion(password, NO);
        } else {
            completion(nil, YES);
        }
    } else {
        completion(nil, YES);
    }
}

- (void)showError:(NSString *)errorMessage {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"V4.0 错误";
        alert.informativeText = errorMessage;
        alert.alertStyle = NSAlertStyleCritical;
        [alert addButtonWithTitle:@"确定"];
        
        if (self.progressWindow) {
            [alert beginSheetModalForWindow:self.progressWindow completionHandler:nil];
        } else {
            [alert runModal];
        }
    });
}

- (IBAction)closeWindow:(id)sender {
    [self closeProgressWindow];
}

@end
