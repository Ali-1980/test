//
//  KeychainviewModalController.m
//
//  Created by Monterey on 19/1/2025.
//

#import "KeychainviewModalController.h"
#import "AlertWindowController.h"
#import "CustomTableRowView.h" 

// 表格列标识符
static NSString * const KeychainTableColumnTypeIdentifier = @"TypeColumn";
static NSString * const KeychainTableColumnServiceIdentifier = @"ServiceColumn";
static NSString * const KeychainTableColumnAccountIdentifier = @"AccountColumn";
static NSString * const KeychainTableColumnPasswordIdentifier = @"PasswordColumn";
static NSString * const KeychainTableColumnServerIdentifier = @"ServerColumn";
static NSString * const KeychainTableColumnPortIdentifier = @"PortColumn";
static NSString * const KeychainTableColumnCreationDateIdentifier = @"CreationDateColumn";
static NSString * const KeychainTableColumnModificationDateIdentifier = @"ModificationDateColumn";
static NSString * const KeychainTableColumnCommentIdentifier = @"CommentColumn";

#pragma mark - KeychainCategoryNode 实现

@implementation KeychainCategoryNode

- (instancetype)initWithName:(NSString *)name localizedName:(NSString *)localizedName itemType:(KeychainItemType)itemType {
    self = [super init];
    if (self) {
        _name = [name copy];
        _localizedName = [localizedName copy];
        _itemType = itemType;
        _items = [NSMutableArray array];
        _children = [NSMutableArray array];
        _totalCount = 0;
    }
    return self;
}

- (void)addItem:(KeychainDataItem *)item {
    if (item) {
        [self.items addObject:item];
        [self updateTotalCount];
    }
}

- (void)addChildNode:(KeychainCategoryNode *)childNode {
    if (childNode) {
        [self.children addObject:childNode];
        childNode.parent = self;
        [self updateTotalCount];
    }
}

- (void)updateTotalCount {
    self.totalCount = self.items.count;
    for (KeychainCategoryNode *child in self.children) {
        self.totalCount += child.totalCount;
    }
    
    if (self.parent) {
        [self.parent updateTotalCount];
    }
}

- (BOOL)isLeaf {
    return self.children.count == 0;
}

@end

#pragma mark - KeychainviewModalController 实现

@interface KeychainviewModalController ()
@property (nonatomic, strong) NSString *currentSearchText;
@property (nonatomic, strong) NSArray<KeychainDataItem *> *currentDisplayItems;
@property (nonatomic, strong) NSDateFormatter *dateFormatter;
@property (nonatomic, assign) BOOL isInitialLoad;
@property (nonatomic, assign) BOOL isTransitioningFromAnalysis; // 新增：标记是否来自分析窗口切换

@end

@implementation KeychainviewModalController

#pragma mark - 生命周期管理

- (instancetype)init {
    self = [super init];
    if (self) {
        [self commonInit];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) {
        [self commonInit];
    }
    return self;
}

- (void)commonInit {
    _dateFormatter = [[NSDateFormatter alloc] init];
    _dateFormatter.dateStyle = NSDateFormatterMediumStyle;
    _dateFormatter.timeStyle = NSDateFormatterMediumStyle;
    _isInitialLoad = YES;
    _isTransitioningFromAnalysis = NO; // 初始化新属性
    
    NSLog(@"KeychainviewModalController initialized");
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
    // 确保格式化器已初始化
    if (!self.dateFormatter) {
        [self commonInit];
    }
    
    [self setupUI];
    [self setupTableColumns];
    
    // 注册展开/折叠通知
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(outlineViewItemDidExpand:)
                                                 name:NSOutlineViewItemDidExpandNotification
                                               object:self.categoryOutlineView];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(outlineViewItemDidCollapse:)
                                                 name:NSOutlineViewItemDidCollapseNotification
                                               object:self.categoryOutlineView];
    
    NSLog(@"KeychainviewModalController view loaded");
}

- (void)viewDidAppear {
    [super viewDidAppear];
    
    // **关键修复**: 延迟设置第一响应者，确保事件传递正常
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self fixEventHandling];
        [self testOutlineViewInteraction];
        
        // 如果是从分析窗口切换过来的，执行特殊的初始化
        if (self.isTransitioningFromAnalysis) {
            [self handleTransitionFromAnalysisWindow];
        }
    });
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - 分析窗口切换专用方法 - **新增关键功能**

/**
 * 显示来自分析完成的结果窗口
 * 这是专门用于处理分析窗口切换的方法
 * @param results 分析结果
 * @param statistics 统计信息
 * @param parentWindow 父窗口
 */
- (void)showResultsFromAnalysis:(NSArray<KeychainDataItem *> *)results
                 withStatistics:(NSDictionary *)statistics
                   parentWindow:(NSWindow *)parentWindow {
    
    NSLog(@"🔄 开始从分析窗口切换到结果显示...");
    
    // 标记为来自分析窗口的切换
    self.isTransitioningFromAnalysis = YES;
    
    // 先设置数据，但不立即显示UI
    self.originalResults = [results copy];
    self.statisticsInfo = statistics;
    self.isInitialLoad = YES;
    
    // 确保在主线程上执行窗口切换
    dispatch_async(dispatch_get_main_queue(), ^{
        // 添加短暂延迟，确保分析窗口完全关闭
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self performAnalysisToResultTransition:parentWindow];
        });
    });
}

/**
 * 执行从分析到结果的窗口切换
 */
- (void)performAnalysisToResultTransition:(NSWindow *)parentWindow {
    NSLog(@"🔄 执行窗口切换...");
    
    // 构建数据结构
    [self buildCategoryTree];
    [self applyCurrentFilter];
    
    // 显示窗口
    [self showModalWindow:parentWindow];
    
    // 延迟刷新UI，确保窗口已完全显示
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self completeTransitionSetup];
    });
}

/**
 * 完成切换后的设置
 */
- (void)completeTransitionSetup {
    NSLog(@"🔄 完成切换设置...");
    
    // 刷新所有视图
    [self updateStatisticsDisplay];
    [self refreshViews];
    
    // 自动展开顶级类别
    if (self.categoryOutlineView && self.rootCategoryNode) {
        [self.categoryOutlineView expandItem:self.rootCategoryNode];
        for (KeychainCategoryNode *child in self.rootCategoryNode.children) {
            [self.categoryOutlineView expandItem:child];
        }
    }
    
    // 重置标记
    self.isInitialLoad = NO;
    self.isTransitioningFromAnalysis = NO;
    
    // 确保窗口获得焦点
    if (self.modalWindow) {
        [self.modalWindow makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
    }
    
    NSLog(@"✅ 从分析窗口到结果窗口的切换完成");
}

/**
 * 处理从分析窗口切换过来的特殊初始化
 */
- (void)handleTransitionFromAnalysisWindow {
    NSLog(@"🔄 处理分析窗口切换的特殊初始化...");
    
    // 确保UI组件正确初始化
    [self fixEventHandling];
    
    // 如果有数据但UI还没有更新，强制更新
    if (self.originalResults && self.originalResults.count > 0) {
        if ([self.categoryOutlineView numberOfRows] == 0) {
            NSLog(@"🔄 检测到数据存在但UI未更新，强制刷新...");
            [self.categoryOutlineView reloadData];
            [self.detailTableView reloadData];
        }
    }
    
    // 确保统计信息显示正确
    [self updateStatisticsDisplay];
}

#pragma mark - 核心修复方法

/**
 * **关键修复**: 修复事件处理机制
 * 解决模态窗口中左侧菜单无法点击的问题
 */
- (void)fixEventHandling {
    if (!self.categoryOutlineView) {
        NSLog(@"❌ categoryOutlineView为空，无法修复事件处理");
        return;
    }
    
    NSLog(@"🔧 开始修复事件处理机制...");
    
    // 1. 检查视图层级，确保没有阻挡
    [self checkViewHierarchy];
    
    // 2. 重新设置OutlineView属性
    [self resetOutlineViewProperties];
    
    // 3. 确保第一响应者设置正确
    [self setupFirstResponder];
    
    NSLog(@"✅ 事件处理修复完成");
}

/**
 * 检查视图层级，移除可能的阻挡
 */
- (void)checkViewHierarchy {
    NSView *currentView = self.categoryOutlineView.superview;
    
    while (currentView && currentView != self.view) {
        // 检查是否有隐藏的父视图
        if (currentView.hidden) {
            NSLog(@"🔧 发现隐藏的父视图，正在修复: %@", NSStringFromClass([currentView class]));
            currentView.hidden = NO;
        }
        
        // 特别处理ScrollView配置
        if ([currentView isKindOfClass:[NSScrollView class]]) {
            NSScrollView *scrollView = (NSScrollView *)currentView;
            scrollView.hasVerticalScroller = YES;
            scrollView.autohidesScrollers = YES;
            scrollView.borderType = NSNoBorder;
        }
        
        currentView = currentView.superview;
    }
}

/**
 * 重新设置OutlineView的关键属性
 */
- (void)resetOutlineViewProperties {
    // 基础属性设置
    self.categoryOutlineView.enabled = YES;
    self.categoryOutlineView.hidden = NO;
    
    // 交互设置
    self.categoryOutlineView.allowsColumnSelection = NO;
    self.categoryOutlineView.allowsMultipleSelection = NO;
    self.categoryOutlineView.allowsEmptySelection = YES;
    
    // **关键**: 重新设置数据源和代理
    self.categoryOutlineView.dataSource = self;
    self.categoryOutlineView.delegate = self;
    
    // **关键**: 设置目标和动作
    self.categoryOutlineView.target = self;
    self.categoryOutlineView.action = @selector(outlineViewSelectionDidChange:);
    self.categoryOutlineView.doubleAction = @selector(outlineViewDoubleClick:);
    
    // 强制刷新显示
    [self.categoryOutlineView setNeedsDisplay:YES];
}

/**
 * 设置第一响应者
 */
- (void)setupFirstResponder {
    if (self.categoryOutlineView.acceptsFirstResponder) {
        [self.view.window makeFirstResponder:self.categoryOutlineView];
        NSLog(@"✅ 已设置categoryOutlineView为第一响应者");
    } else {
        NSLog(@"⚠️ categoryOutlineView不接受第一响应者");
    }
}

/**
 * 测试OutlineView交互功能
 */
- (void)testOutlineViewInteraction {
    if (!self.categoryOutlineView) return;
    
    NSLog(@"🧪 测试OutlineView交互功能");
    
    NSInteger rowCount = [self.categoryOutlineView numberOfRows];
    NSLog(@"   当前行数: %ld", (long)rowCount);
    
    if (rowCount > 0) {
        // 程序化选择第一行进行测试
        [self.categoryOutlineView selectRowIndexes:[NSIndexSet indexSetWithIndex:0]
                              byExtendingSelection:NO];
        
        NSInteger selectedRow = [self.categoryOutlineView selectedRow];
        if (selectedRow >= 0) {
            NSLog(@"✅ 程序化选择测试成功，选中行: %ld", (long)selectedRow);
        } else {
            NSLog(@"❌ 程序化选择测试失败");
        }
        
        // 清除选择
        [self.categoryOutlineView deselectAll:nil];
    } else {
        NSLog(@"⚠️ 没有数据行可供测试");
        
        // 如果没有数据，尝试重新加载
        if (self.rootCategoryNode && self.rootCategoryNode.children.count > 0) {
            NSLog(@"🔄 有数据但未显示，重新加载");
            [self.categoryOutlineView reloadData];
        }
    }
}

#pragma mark - UI初始化

- (void)setupUI {
    // 设置分割视图
    if (self.mainSplitView) {
        [self.mainSplitView setPosition:300 ofDividerAtIndex:0];
        self.mainSplitView.dividerStyle = NSSplitViewDividerStyleThin;
    }
    
    // 设置OutlineView基础属性
    if (self.categoryOutlineView) {
        self.categoryOutlineView.headerView = nil;
        self.categoryOutlineView.indentationPerLevel = 16.0;
        self.categoryOutlineView.selectionHighlightStyle = NSTableViewSelectionHighlightStyleSourceList;
        
        // 设置右键菜单
        [self setupContextMenu];
        
        NSLog(@"✅ OutlineView基础设置完成");
    }
    
    // 设置TableView
    [self setupDetailTableView];
    
    // 设置搜索框
    [self setupSearchField];
    
    // 设置导出格式选择
    [self setupExportFormatPopUp];
    
    // 设置初始状态
    [self updateButtonStates];
    [self updateStatisticsDisplay];
}

- (void)setupDetailTableView {
    if (self.detailTableView) {
        self.detailTableView.dataSource = self;
        self.detailTableView.delegate = self;
        self.detailTableView.selectionHighlightStyle = NSTableViewSelectionHighlightStyleRegular;
        self.detailTableView.allowsMultipleSelection = YES;
        self.detailTableView.allowsColumnReordering = YES;
        self.detailTableView.allowsColumnResizing = YES;
        self.detailTableView.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;
    }
}

- (void)setupSearchField {
    if (self.searchField) {
        self.searchField.delegate = self;
        self.searchField.placeholderString = @"搜索服务、账户或备注...";
    }
}

- (void)setupExportFormatPopUp {
    if (self.exportFormatPopUp) {
        [self.exportFormatPopUp removeAllItems];
        [self.exportFormatPopUp addItemWithTitle:@"JSON 格式"];
        [self.exportFormatPopUp addItemWithTitle:@"CSV 格式"];
        [self.exportFormatPopUp addItemWithTitle:@"属性列表格式"];
        [self.exportFormatPopUp selectItemAtIndex:0]; // 默认选择 JSON
    }
}

- (void)setupContextMenu {
    if (!self.categoryOutlineView) return;
    
    NSMenu *contextMenu = [[NSMenu alloc] initWithTitle:@"分类操作"];
    
    // 展开所有分类
    NSMenuItem *expandAllItem = [[NSMenuItem alloc] initWithTitle:@"展开所有分类"
                                                          action:@selector(expandAllCategories:)
                                                   keyEquivalent:@""];
    expandAllItem.target = self;
    [contextMenu addItem:expandAllItem];
    
    // 折叠所有分类
    NSMenuItem *collapseAllItem = [[NSMenuItem alloc] initWithTitle:@"折叠所有分类"
                                                            action:@selector(collapseAllCategories:)
                                                     keyEquivalent:@""];
    collapseAllItem.target = self;
    [contextMenu addItem:collapseAllItem];
    
    // 分隔线
    [contextMenu addItem:[NSMenuItem separatorItem]];
    
    // 切换当前选中项
    NSMenuItem *toggleCurrentItem = [[NSMenuItem alloc] initWithTitle:@"展开/折叠当前项"
                                                              action:@selector(toggleSelectedCategory:)
                                                       keyEquivalent:@""];
    toggleCurrentItem.target = self;
    [contextMenu addItem:toggleCurrentItem];
    
    self.categoryOutlineView.menu = contextMenu;
}

#pragma mark - 窗口关闭功能

- (IBAction)closeWindow:(id)sender {
    [self closeModalWindow];
}

#pragma mark - 窗口管理 - **修改版 - 优化切换逻辑**

- (void)showModalWindow:(NSWindow *)parentWindow {
    NSLog(@"🔑 开始显示模态窗口...");
    
    // **修复**: 检查是否已经有窗口存在，避免重复创建
    if (self.modalWindow && self.modalWindow.isVisible) {
        NSLog(@"⚠️ 窗口已显示，将其置前");
        [self.modalWindow makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
        return;
    }
    
    // 如果窗口存在但不可见，先关闭它
    if (self.modalWindow) {
        [self.modalWindow close];
        self.modalWindow = nil;
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [self createAndShowModalWindow:parentWindow];
    });
}

/**
 * 创建并显示模态窗口
 */
- (void)createAndShowModalWindow:(NSWindow *)parentWindow {
    // 防止重复创建
    if (self.modalWindow) {
        return;
    }
    
    // 创建窗口
    NSRect windowFrame = NSMakeRect(0, 0, 900, 600);
    self.modalWindow = [[NSWindow alloc] initWithContentRect:windowFrame
                                                   styleMask:(NSWindowStyleMaskTitled |
                                                             NSWindowStyleMaskClosable |
                                                             NSWindowStyleMaskResizable)
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    
    if (!self.modalWindow) {
        NSLog(@"❌ 创建窗口失败");
        return;
    }
    
    // 设置窗口属性
    self.modalWindow.title = self.isTransitioningFromAnalysis ? @"钥匙串分析结果" : @"钥匙串数据详情";
    self.modalWindow.contentViewController = self;
    self.modalWindow.releasedWhenClosed = NO;
    self.modalWindow.minSize = NSMakeSize(600, 400);
    self.modalWindow.level = NSNormalWindowLevel;
    
    // **关键修复**: 相对于主窗口居中，而不是屏幕居中
    [self centerModalWindowRelativeToMainWindow:parentWindow];
    
    [self.modalWindow makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    
    NSLog(@"✅ 模态窗口创建并显示成功，已相对于主窗口居中");
}

/**
 * **新增**: 将模态窗口相对于主窗口居中显示
 * @param parentWindow 父窗口（可能为 nil）
 */
- (void)centerModalWindowRelativeToMainWindow:(NSWindow *)parentWindow {
    if (!self.modalWindow) {
        return;
    }
    
    // 确定主窗口
    NSWindow *mainWindow = parentWindow;
    if (!mainWindow) {
        // 尝试获取应用程序的主窗口
        mainWindow = [NSApp mainWindow];
    }
    if (!mainWindow) {
        // 尝试获取关键窗口
        mainWindow = [NSApp keyWindow];
    }
    
    if (mainWindow && mainWindow != self.modalWindow) {
        NSRect mainFrame = mainWindow.frame;
        NSRect modalFrame = self.modalWindow.frame;
        
        // 计算居中位置
        CGFloat centerX = NSMidX(mainFrame) - (modalFrame.size.width / 2);
        CGFloat centerY = NSMidY(mainFrame) - (modalFrame.size.height / 2);
        
        // 确保窗口不会超出屏幕边界
        NSRect screenFrame = mainWindow.screen ? mainWindow.screen.visibleFrame : [[NSScreen mainScreen] visibleFrame];
        centerX = MAX(screenFrame.origin.x, MIN(centerX, NSMaxX(screenFrame) - modalFrame.size.width));
        centerY = MAX(screenFrame.origin.y, MIN(centerY, NSMaxY(screenFrame) - modalFrame.size.height));
        
        NSPoint newOrigin = NSMakePoint(centerX, centerY);
        [self.modalWindow setFrameOrigin:newOrigin];
        
        NSLog(@"🎯 钥匙串窗口已相对于主窗口居中显示");
    } else {
        // 备用方案：屏幕居中
        [self.modalWindow center];
        NSLog(@"🎯 使用屏幕居中作为备用方案");
    }
}

/**
 * **新增**: 显示 Storyboard 窗口
 */
- (void)showStoryboardWindow:(NSWindow *)storyboardWindow {
    // 设置窗口属性
    storyboardWindow.title = self.isTransitioningFromAnalysis ? @"钥匙串分析结果" : @"钥匙串数据详情";
    storyboardWindow.level = NSNormalWindowLevel;
    
    // 设置窗口大小和位置
    NSRect currentFrame = storyboardWindow.frame;
    if (currentFrame.size.width < 900 || currentFrame.size.height < 600) {
        NSRect newFrame = NSMakeRect(currentFrame.origin.x, currentFrame.origin.y, 900, 600);
        [storyboardWindow setFrame:newFrame display:NO];
    }
    
    // 居中显示
    [storyboardWindow center];
    
    // 显示窗口
    [storyboardWindow makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    
    NSLog(@"✅ Storyboard 窗口显示成功");
}

- (void)closeModalWindow {
    NSLog(@"🔑 开始关闭模态窗口...");
    
    if (self.modalWindow) {
        // 通知代理
        if ([self.delegate respondsToSelector:@selector(keychainviewModalControllerWillClose:)]) {
            [self.delegate keychainviewModalControllerWillClose:self];
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.modalWindow close];
            self.modalWindow = nil;
            NSLog(@"✅ 窗口关闭完成");
        });
    } else {
        NSLog(@"⚠️ 没有窗口需要关闭");
    }
}

#pragma mark - 表格列设置

- (void)setupTableColumns {
    if (!self.detailTableView) return;
    
    // 清除现有列
    NSArray *existingColumns = [self.detailTableView.tableColumns copy];
    for (NSTableColumn *column in existingColumns) {
        [self.detailTableView removeTableColumn:column];
    }
    
    // 创建列的信息数组
    NSArray *columnInfo = @[
        @{@"identifier": KeychainTableColumnTypeIdentifier, @"title": @"类型", @"minWidth": @80, @"maxWidth": @120},
        @{@"identifier": KeychainTableColumnServiceIdentifier, @"title": @"服务", @"minWidth": @120, @"maxWidth": @300},
        @{@"identifier": KeychainTableColumnAccountIdentifier, @"title": @"账户", @"minWidth": @100, @"maxWidth": @250},
        @{@"identifier": KeychainTableColumnPasswordIdentifier, @"title": @"密码", @"minWidth": @80, @"maxWidth": @150},
        @{@"identifier": KeychainTableColumnServerIdentifier, @"title": @"服务器", @"minWidth": @100, @"maxWidth": @200},
        @{@"identifier": KeychainTableColumnPortIdentifier, @"title": @"端口", @"minWidth": @50, @"maxWidth": @80},
        @{@"identifier": KeychainTableColumnCreationDateIdentifier, @"title": @"创建时间", @"minWidth": @120, @"maxWidth": @180},
        @{@"identifier": KeychainTableColumnModificationDateIdentifier, @"title": @"修改时间", @"minWidth": @120, @"maxWidth": @180},
        @{@"identifier": KeychainTableColumnCommentIdentifier, @"title": @"备注", @"minWidth": @100, @"maxWidth": @300}
    ];
    
    // 批量创建列
    for (NSDictionary *info in columnInfo) {
        NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:info[@"identifier"]];
        column.title = info[@"title"];
        column.minWidth = [info[@"minWidth"] floatValue];
        column.maxWidth = [info[@"maxWidth"] floatValue];
        [self.detailTableView addTableColumn:column];
    }
}

#pragma mark - 数据显示和管理

- (void)displayKeychainResults:(NSArray<KeychainDataItem *> *)results withStatistics:(NSDictionary *)statistics {
    if (!results) {
        NSLog(@"⚠️ 收到空的结果数据");
        return;
    }
    
    NSLog(@"🔑 开始显示 %lu 个Keychain条目", (unsigned long)results.count);
    
    // **关键修复**: 确保在主线程中设置数据
    dispatch_async(dispatch_get_main_queue(), ^{
        self.originalResults = [results copy];
        self.statisticsInfo = statistics;
        self.isInitialLoad = YES;
        
        NSLog(@"📊 数据设置完成: originalResults.count = %lu", (unsigned long)self.originalResults.count);
        
        [self buildCategoryTree];
        [self applyCurrentFilter];
        [self updateStatisticsDisplay];
        [self refreshViews];
        
        // 自动展开顶级类别
        if (self.categoryOutlineView && self.rootCategoryNode) {
            [self.categoryOutlineView expandItem:self.rootCategoryNode];
            for (KeychainCategoryNode *child in self.rootCategoryNode.children) {
                [self.categoryOutlineView expandItem:child];
            }
            NSLog(@"📂 已展开 %lu 个分类", (unsigned long)self.rootCategoryNode.children.count);
        } else {
            NSLog(@"⚠️ categoryOutlineView=%@ rootCategoryNode=%@", self.categoryOutlineView, self.rootCategoryNode);
        }
        
        self.isInitialLoad = NO;
        NSLog(@"✅ 数据显示设置完成");
    });
}

- (void)buildCategoryTree {
    NSLog(@"🌳 开始构建分类树，原始数据: %lu 个条目", (unsigned long)self.originalResults.count);
    
    // 创建根节点
    self.rootCategoryNode = [[KeychainCategoryNode alloc] initWithName:@"Root"
                                                         localizedName:@"全部钥匙串项目"
                                                              itemType:KeychainItemTypeUnknown];
    
    if (!self.originalResults || self.originalResults.count == 0) {
        NSLog(@"⚠️ 没有原始数据可用于构建分类树");
        return;
    }
    
    // 按类型创建分类
    NSMutableDictionary<NSNumber *, KeychainCategoryNode *> *typeNodes = [NSMutableDictionary dictionary];
    
    for (KeychainDataItem *item in self.originalResults) {
        NSNumber *typeKey = @(item.itemType);
        KeychainCategoryNode *typeNode = typeNodes[typeKey];
        
        if (!typeNode) {
            NSString *typeName = [KeychainDataItem stringForItemType:item.itemType];
            NSString *localizedTypeName = [KeychainDataItem localizedStringForItemType:item.itemType];
            
            typeNode = [[KeychainCategoryNode alloc] initWithName:typeName
                                                   localizedName:localizedTypeName
                                                        itemType:item.itemType];
            typeNodes[typeKey] = typeNode;
            [self.rootCategoryNode addChildNode:typeNode];
            NSLog(@"📁 创建分类节点: %@", localizedTypeName);
        }
        
        // 根据类型决定是否进一步分类
        if (item.itemType == KeychainItemTypeGenericPassword ||
            item.itemType == KeychainItemTypeInternetPassword ||
            item.itemType == KeychainItemTypeWiFiPassword) {
            
            [self addItemToServiceCategory:item inTypeNode:typeNode];
        } else {
            [typeNode addItem:item];
        }
    }
    
    NSLog(@"✅ 分类树构建完成: 根节点有 %ld 个子分类，总计 %ld 个项目",
          (long)self.rootCategoryNode.children.count, (long)self.rootCategoryNode.totalCount);
}

- (void)addItemToServiceCategory:(KeychainDataItem *)item inTypeNode:(KeychainCategoryNode *)typeNode {
    NSString *service = item.service ?: @"未知服务";
    
    // 查找或创建服务节点
    KeychainCategoryNode *serviceNode = nil;
    for (KeychainCategoryNode *child in typeNode.children) {
        if ([child.name isEqualToString:service]) {
            serviceNode = child;
            break;
        }
    }
    
    if (!serviceNode) {
        serviceNode = [[KeychainCategoryNode alloc] initWithName:service
                                                  localizedName:service
                                                       itemType:item.itemType];
        [typeNode addChildNode:serviceNode];
    }
    
    [serviceNode addItem:item];
}

- (void)applyCurrentFilter {
    if (!self.currentSearchText || self.currentSearchText.length == 0) {
        self.filteredResults = self.originalResults;
        self.currentDisplayItems = self.originalResults;
    } else {
        NSString *searchText = self.currentSearchText.lowercaseString;
        NSMutableArray *filtered = [NSMutableArray array];
        
        for (KeychainDataItem *item in self.originalResults) {
            if ([self item:item matchesSearchText:searchText]) {
                [filtered addObject:item];
            }
        }
        
        self.filteredResults = [filtered copy];
        self.currentDisplayItems = self.filteredResults;
    }
    
    NSLog(@"🔍 过滤结果: %lu/%lu", (unsigned long)self.filteredResults.count, (unsigned long)self.originalResults.count);
}

- (BOOL)item:(KeychainDataItem *)item matchesSearchText:(NSString *)searchText {
    NSArray *searchFields = @[item.service, item.account, item.comment, item.label, item.server];
    
    for (NSString *field in searchFields) {
        if (field && [field.lowercaseString containsString:searchText]) {
            return YES;
        }
    }
    
    return NO;
}

#pragma mark - 视图更新

- (void)refreshViews {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.categoryOutlineView reloadData];
        [self.detailTableView reloadData];
        [self updateButtonStates];
    });
}

- (void)updateStatisticsDisplay {
    if (!self.statisticsLabel) return;
    
    NSString *statsText = @"";
    if (self.originalResults.count > 0) {
        if (self.currentSearchText && self.currentSearchText.length > 0) {
            statsText = [NSString stringWithFormat:@"显示 %lu / %lu 个条目",
                        (unsigned long)self.filteredResults.count,
                        (unsigned long)self.originalResults.count];
        } else {
            statsText = [NSString stringWithFormat:@"共 %lu 个钥匙串条目",
                        (unsigned long)self.originalResults.count];
        }
        
        // 添加统计信息
        if (self.statisticsInfo) {
            NSNumber *decryptedCount = self.statisticsInfo[@"已解密密码"];
            NSNumber *encryptedCount = self.statisticsInfo[@"加密密码"];
            if (decryptedCount && encryptedCount) {
                statsText = [statsText stringByAppendingFormat:@" (已解密: %@, 加密: %@)", decryptedCount, encryptedCount];
            }
        }
    } else {
        statsText = @"暂无数据";
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        self.statisticsLabel.stringValue = statsText;
    });
}

- (void)updateSelectionDisplay {
    if (!self.selectionLabel) return;
    
    NSIndexSet *selectedRows = self.detailTableView.selectedRowIndexes;
    NSString *selectionText = @"";
    
    if (selectedRows.count > 0) {
        selectionText = selectedRows.count == 1 ?
            @"已选中 1 个条目" :
            [NSString stringWithFormat:@"已选中 %lu 个条目", (unsigned long)selectedRows.count];
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        self.selectionLabel.stringValue = selectionText;
    });
}

- (void)updateButtonStates {
    BOOL hasData = self.currentDisplayItems.count > 0;
    BOOL hasSelection = self.detailTableView.selectedRowIndexes.count > 0;
    
    if (self.exportAllButton) {
        self.exportAllButton.enabled = hasData;
    }
    
    if (self.exportSelectedButton) {
        self.exportSelectedButton.enabled = hasSelection;
    }
    
    if (self.refreshButton) {
        self.refreshButton.enabled = hasData;
    }
}

#pragma mark - NSOutlineViewDataSource

- (NSInteger)outlineView:(NSOutlineView *)outlineView numberOfChildrenOfItem:(id)item {
    if (!item) {
        return self.rootCategoryNode ? 1 : 0;
    }
    
    if ([item isKindOfClass:[KeychainCategoryNode class]]) {
        KeychainCategoryNode *node = (KeychainCategoryNode *)item;
        return node.children.count;
    }
    
    return 0;
}

- (id)outlineView:(NSOutlineView *)outlineView child:(NSInteger)index ofItem:(id)item {
    if (!item) {
        return self.rootCategoryNode;
    }
    
    if ([item isKindOfClass:[KeychainCategoryNode class]]) {
        KeychainCategoryNode *node = (KeychainCategoryNode *)item;
        if (index < node.children.count) {
            return node.children[index];
        }
    }
    
    return nil;
}

- (BOOL)outlineView:(NSOutlineView *)outlineView isItemExpandable:(id)item {
    if ([item isKindOfClass:[KeychainCategoryNode class]]) {
        KeychainCategoryNode *node = (KeychainCategoryNode *)item;
        return !node.isLeaf;
    }
    
    return NO;
}

#pragma mark - NSOutlineViewDelegate

- (NSView *)outlineView:(NSOutlineView *)outlineView viewForTableColumn:(NSTableColumn *)tableColumn item:(id)item {
    if (![item isKindOfClass:[KeychainCategoryNode class]]) {
        return nil;
    }
    
    KeychainCategoryNode *node = (KeychainCategoryNode *)item;
    
    NSTableCellView *cellView = [outlineView makeViewWithIdentifier:@"CategoryCell" owner:self];
    if (!cellView) {
        cellView = [[NSTableCellView alloc] init];
        cellView.identifier = @"CategoryCell";
        
        // 创建图标
        NSImageView *imageView = [[NSImageView alloc] init];
        imageView.translatesAutoresizingMaskIntoConstraints = NO;
        [cellView addSubview:imageView];
        cellView.imageView = imageView;
        
        // 创建文本标签
        NSTextField *textField = [[NSTextField alloc] init];
        textField.translatesAutoresizingMaskIntoConstraints = NO;
        textField.bordered = NO;
        textField.editable = NO;
        textField.backgroundColor = [NSColor clearColor];
        [cellView addSubview:textField];
        cellView.textField = textField;
        
        // 设置约束
        [NSLayoutConstraint activateConstraints:@[
            [imageView.leadingAnchor constraintEqualToAnchor:cellView.leadingAnchor],
            [imageView.centerYAnchor constraintEqualToAnchor:cellView.centerYAnchor],
            [imageView.widthAnchor constraintEqualToConstant:16],
            [imageView.heightAnchor constraintEqualToConstant:16],
            
            [textField.leadingAnchor constraintEqualToAnchor:imageView.trailingAnchor constant:4],
            [textField.trailingAnchor constraintEqualToAnchor:cellView.trailingAnchor],
            [textField.centerYAnchor constraintEqualToAnchor:cellView.centerYAnchor]
        ]];
    }
    
    // 设置图标
    NSString *iconName = [self iconNameForItemType:node.itemType];
    cellView.imageView.image = [NSImage imageNamed:iconName];
    
    // 设置文本
    NSString *displayText = [NSString stringWithFormat:@"%@ (%ld)", node.localizedName, (long)node.totalCount];
    cellView.textField.stringValue = displayText;
    
    return cellView;
}

/**
 * **关键事件处理**: OutlineView选择变化
 */
- (void)outlineViewSelectionDidChange:(NSNotification *)notification {
    NSInteger selectedRow = self.categoryOutlineView.selectedRow;
    
    if (selectedRow < 0) {
        // 没有选中任何项目，显示所有过滤后的结果
        self.currentDisplayItems = self.filteredResults;
    } else {
        id selectedItem = [self.categoryOutlineView itemAtRow:selectedRow];
        if ([selectedItem isKindOfClass:[KeychainCategoryNode class]]) {
            KeychainCategoryNode *selectedNode = (KeychainCategoryNode *)selectedItem;
            NSLog(@"🔑 选中分类: %@ (%ld个项目)", selectedNode.localizedName, (long)selectedNode.totalCount);
            [self updateDisplayForSelectedNode:selectedNode];
        }
    }
    
    [self.detailTableView reloadData];
    [self updateSelectionDisplay];
    [self updateButtonStates];
}

- (void)updateDisplayForSelectedNode:(KeychainCategoryNode *)node {
    if (!node) {
        self.currentDisplayItems = @[];
        return;
    }
    
    NSMutableArray *items = [NSMutableArray array];
    [self collectItemsFromNode:node intoArray:items];
    
    // 应用搜索过滤
    if (self.currentSearchText && self.currentSearchText.length > 0) {
        NSString *searchText = self.currentSearchText.lowercaseString;
        NSMutableArray *filtered = [NSMutableArray array];
        
        for (KeychainDataItem *item in items) {
            if ([self item:item matchesSearchText:searchText]) {
                [filtered addObject:item];
            }
        }
        
        self.currentDisplayItems = [filtered copy];
    } else {
        self.currentDisplayItems = [items copy];
    }
    
    [self updateCategoryStatistics:node];
}

- (void)collectItemsFromNode:(KeychainCategoryNode *)node intoArray:(NSMutableArray *)items {
    if (!node) return;
    
    // 添加当前节点的项目
    [items addObjectsFromArray:node.items];
    
    // 递归添加子节点的项目
    for (KeychainCategoryNode *child in node.children) {
        [self collectItemsFromNode:child intoArray:items];
    }
}

- (void)updateCategoryStatistics:(KeychainCategoryNode *)node {
    if (!self.statisticsLabel) return;
    
    NSUInteger displayCount = self.currentDisplayItems.count;
    NSUInteger totalCount = node.totalCount;
    
    NSString *statsText;
    if (displayCount == totalCount) {
        statsText = [NSString stringWithFormat:@"分类: %@ - 共 %lu 个条目",
                    node.localizedName, (unsigned long)totalCount];
    } else {
        statsText = [NSString stringWithFormat:@"分类: %@ - 显示 %lu / 共 %lu 个条目",
                    node.localizedName, (unsigned long)displayCount, (unsigned long)totalCount];
    }
    
    // 添加加密状态统计
    NSUInteger encryptedCount = 0;
    NSUInteger decryptedCount = 0;
    
    for (KeychainDataItem *item in self.currentDisplayItems) {
        if (item.isPasswordEncrypted) {
            encryptedCount++;
        } else {
            decryptedCount++;
        }
    }
    
    if (displayCount > 0) {
        statsText = [statsText stringByAppendingFormat:@" (已解密: %lu, 加密: %lu)",
                    (unsigned long)decryptedCount, (unsigned long)encryptedCount];
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        self.statisticsLabel.stringValue = statsText;
    });
}

- (void)outlineViewDoubleClick:(NSOutlineView *)outlineView {
    NSInteger clickedRow = outlineView.clickedRow;
    if (clickedRow < 0) return;
    
    id clickedItem = [outlineView itemAtRow:clickedRow];
    if ([clickedItem isKindOfClass:[KeychainCategoryNode class]]) {
        KeychainCategoryNode *node = (KeychainCategoryNode *)clickedItem;
        [self toggleNodeExpansion:node];
    }
}

- (void)toggleNodeExpansion:(KeychainCategoryNode *)node {
    if (!node || node.isLeaf) return;
    
    BOOL isExpanded = [self.categoryOutlineView isItemExpanded:node];
    
    if (isExpanded) {
        [self.categoryOutlineView collapseItem:node];
        NSLog(@"🔑 折叠分类: %@", node.localizedName);
    } else {
        [self.categoryOutlineView expandItem:node];
        NSLog(@"🔑 展开分类: %@", node.localizedName);
    }
}

- (NSString *)iconNameForItemType:(KeychainItemType)itemType {
    switch (itemType) {
        case KeychainItemTypeGenericPassword:
            return @"key.fill";
        case KeychainItemTypeInternetPassword:
            return @"globe";
        case KeychainItemTypeWiFiPassword:
            return @"wifi";
        case KeychainItemTypeCertificate:
            return @"certificate.fill";
        case KeychainItemTypeKey:
            return @"key";
        case KeychainItemTypeApplication:
            return @"app.fill";
        default:
            return @"folder";
    }
}

#pragma mark - NSTableViewDataSource

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return self.currentDisplayItems.count;
}

#pragma mark - NSTableViewDelegate

#pragma mark - 自动行高
- (CGFloat)tableView:(NSTableView *)tableView heightOfRow:(NSInteger)row {
    return 32; // 默认行高
}

#pragma mark - 行自动高亮
- (NSTableRowView *)tableView:(NSTableView *)tableView rowViewForRow:(NSInteger)row {
    
    CustomTableRowView *rowView = [[CustomTableRowView alloc] init];

    // 检测暗黑模式
    NSAppearance *appearance = [rowView effectiveAppearance];
    BOOL isDarkMode = [appearance.name containsString:NSAppearanceNameDarkAqua];

    // 调整文字颜色
    dispatch_async(dispatch_get_main_queue(), ^{
        for (NSView *subview in rowView.subviews) {
            if ([subview isKindOfClass:[NSTableCellView class]]) {
                NSTableCellView *cellView = (NSTableCellView *)subview;
                if (cellView.textField) {
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


- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    if (row < 0 || row >= self.currentDisplayItems.count) {
        return nil;
    }
    
    KeychainDataItem *item = self.currentDisplayItems[row];
    NSString *identifier = tableColumn.identifier;
    
    NSTableCellView *cellView = [tableView makeViewWithIdentifier:identifier owner:self];
    if (!cellView) {
        cellView = [[NSTableCellView alloc] init];
        cellView.identifier = identifier;
        
        NSTextField *textField = [[NSTextField alloc] init];
        textField.translatesAutoresizingMaskIntoConstraints = NO;
        textField.bordered = NO;
        textField.editable = NO;
        textField.backgroundColor = [NSColor clearColor];
        [cellView addSubview:textField];
        cellView.textField = textField;
        
        [NSLayoutConstraint activateConstraints:@[
            [textField.leadingAnchor constraintEqualToAnchor:cellView.leadingAnchor constant:4],
            [textField.trailingAnchor constraintEqualToAnchor:cellView.trailingAnchor constant:-4],
            [textField.centerYAnchor constraintEqualToAnchor:cellView.centerYAnchor]
        ]];
    }
    
    NSString *cellText = [self textForItem:item columnIdentifier:identifier];
    cellView.textField.stringValue = cellText ?: @"";
    
    // 特殊处理密码列
    if ([identifier isEqualToString:KeychainTableColumnPasswordIdentifier]) {
        if (item.isPasswordEncrypted) {
            cellView.textField.textColor = [NSColor systemOrangeColor];
        } else if (item.password) {
            cellView.textField.textColor = [NSColor systemGreenColor];
        } else {
            cellView.textField.textColor = [NSColor secondaryLabelColor];
        }
    } else {
        cellView.textField.textColor = [NSColor labelColor];
    }
    
    return cellView;
}

- (NSString *)textForItem:(KeychainDataItem *)item columnIdentifier:(NSString *)identifier {
    if ([identifier isEqualToString:KeychainTableColumnTypeIdentifier]) {
        return [KeychainDataItem localizedStringForItemType:item.itemType];
    } else if ([identifier isEqualToString:KeychainTableColumnServiceIdentifier]) {
        return item.service ?: @"";
    } else if ([identifier isEqualToString:KeychainTableColumnAccountIdentifier]) {
        return item.account ?: @"";
    } else if ([identifier isEqualToString:KeychainTableColumnPasswordIdentifier]) {
        if (item.isPasswordEncrypted) {
            return @"🔒 已加密";
        } else if (item.password) {
            // 显示部分密码，其余用星号替代
            NSString *password = item.password;
            if (password.length > 6) {
                NSString *prefix = [password substringToIndex:2];
                NSString *suffix = [password substringFromIndex:password.length - 2];
                return [NSString stringWithFormat:@"%@%@%@", prefix, [@"" stringByPaddingToLength:password.length - 4 withString:@"*" startingAtIndex:0], suffix];
            } else {
               return [@"" stringByPaddingToLength:password.length withString:@"*" startingAtIndex:0];
            }
        } else {
            return @"无密码";
        }
    } else if ([identifier isEqualToString:KeychainTableColumnServerIdentifier]) {
        return item.server ?: @"";
    } else if ([identifier isEqualToString:KeychainTableColumnPortIdentifier]) {
        return item.port ? item.port.stringValue : @"";
    } else if ([identifier isEqualToString:KeychainTableColumnCreationDateIdentifier]) {
        return item.creationDate ? [self.dateFormatter stringFromDate:item.creationDate] : @"";
    } else if ([identifier isEqualToString:KeychainTableColumnModificationDateIdentifier]) {
        return item.modificationDate ? [self.dateFormatter stringFromDate:item.modificationDate] : @"";
    } else if ([identifier isEqualToString:KeychainTableColumnCommentIdentifier]) {
        return item.comment ?: @"";
    }
    
    return @"";
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    [self updateSelectionDisplay];
    [self updateButtonStates];
}

#pragma mark - 通知处理

- (void)outlineViewItemDidExpand:(NSNotification *)notification {
    id expandedItem = notification.userInfo[@"NSObject"];
    if ([expandedItem isKindOfClass:[KeychainCategoryNode class]]) {
        KeychainCategoryNode *node = (KeychainCategoryNode *)expandedItem;
        NSLog(@"🔑 已展开分类: %@", node.localizedName);
    }
}

- (void)outlineViewItemDidCollapse:(NSNotification *)notification {
    id collapsedItem = notification.userInfo[@"NSObject"];
    if ([collapsedItem isKindOfClass:[KeychainCategoryNode class]]) {
        KeychainCategoryNode *node = (KeychainCategoryNode *)collapsedItem;
        NSLog(@"🔑 已折叠分类: %@", node.localizedName);
    }
}

#pragma mark - 搜索功能

- (void)controlTextDidChange:(NSNotification *)notification {
    if (notification.object == self.searchField) {
        [self performDelayedSearch];
    }
}

- (void)performDelayedSearch {
    // 取消之前的延迟搜索
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(performSearchNow) object:nil];
    
    // 延迟0.3秒执行搜索
    [self performSelector:@selector(performSearchNow) withObject:nil afterDelay:0.3];
}

- (void)performSearchNow {
    self.currentSearchText = self.searchField.stringValue;
    [self applyCurrentFilter];
    [self updateStatisticsDisplay];
    
    // 更新显示
    NSInteger selectedRow = self.categoryOutlineView.selectedRow;
    if (selectedRow >= 0) {
        id selectedItem = [self.categoryOutlineView itemAtRow:selectedRow];
        if ([selectedItem isKindOfClass:[KeychainCategoryNode class]]) {
            [self updateDisplayForSelectedNode:(KeychainCategoryNode *)selectedItem];
        }
    } else {
        self.currentDisplayItems = self.filteredResults;
    }
    
    [self.detailTableView reloadData];
    [self updateButtonStates];
}

#pragma mark - IBAction方法实现

- (IBAction)exportSelectedItems:(id)sender {
    NSIndexSet *selectedRows = self.detailTableView.selectedRowIndexes;
    if (selectedRows.count == 0) {
        [self showError:@"请先选择要导出的条目"];
        return;
    }
    
    NSMutableArray *selectedItems = [NSMutableArray array];
    [selectedRows enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL * _Nonnull stop) {
        if (idx < self.currentDisplayItems.count) {
            [selectedItems addObject:self.currentDisplayItems[idx]];
        }
    }];
    
    [self exportItems:selectedItems];
}

- (IBAction)exportAllItems:(id)sender {
    if (self.currentDisplayItems.count == 0) {
        [self showError:@"没有可导出的数据"];
        return;
    }
    
    [self exportItems:self.currentDisplayItems];
}

- (IBAction)refreshView:(id)sender {
    [self buildCategoryTree];
    [self applyCurrentFilter];
    [self updateStatisticsDisplay];
    [self refreshViews];
    
    NSLog(@"🔄 已刷新Keychain视图");
}

- (IBAction)performSearch:(id)sender {
    [self performSearchNow];
}

- (IBAction)clearSearch:(id)sender {
    if (self.searchField) {
        self.searchField.stringValue = @"";
    }
    
    self.currentSearchText = nil;
    [self applyCurrentFilter];
    [self updateStatisticsDisplay];
    
    // 重置显示
    self.currentDisplayItems = self.filteredResults;
    [self.detailTableView reloadData];
    [self updateButtonStates];
}

- (IBAction)expandAllCategories:(id)sender {
    if (!self.rootCategoryNode) return;
    
    [self expandNodeAndAllChildren:self.rootCategoryNode];
    NSLog(@"🔑 已展开所有分类");
}

- (IBAction)collapseAllCategories:(id)sender {
    if (!self.rootCategoryNode) return;
    
    [self collapseNodeAndAllChildren:self.rootCategoryNode];
    NSLog(@"🔑 已折叠所有分类");
}

- (IBAction)smartExpandCategories:(id)sender {
    if (!self.rootCategoryNode) return;
    
    // 展开根节点
    [self.categoryOutlineView expandItem:self.rootCategoryNode];
    
    // 展开第一级子节点
    for (KeychainCategoryNode *child in self.rootCategoryNode.children) {
        [self.categoryOutlineView expandItem:child];
    }
    
    NSLog(@"🔑 智能展开完成");
}

- (IBAction)filterDecryptedOnly:(id)sender {
    [self applyFilter:^BOOL(KeychainDataItem *item) {
        return !item.isPasswordEncrypted;
    }];
    NSLog(@"🔑 应用过滤器：仅显示已解密");
}

- (IBAction)filterEncryptedOnly:(id)sender {
    [self applyFilter:^BOOL(KeychainDataItem *item) {
        return item.isPasswordEncrypted;
    }];
    NSLog(@"🔑 应用过滤器：仅显示加密");
}

- (IBAction)showAllItems:(id)sender {
    [self applyFilter:nil];
    NSLog(@"🔑 清除过滤器：显示全部");
}

- (IBAction)toggleSelectedCategory:(id)sender {
    NSInteger selectedRow = self.categoryOutlineView.selectedRow;
    if (selectedRow < 0) return;
    
    id selectedItem = [self.categoryOutlineView itemAtRow:selectedRow];
    if ([selectedItem isKindOfClass:[KeychainCategoryNode class]]) {
        KeychainCategoryNode *node = (KeychainCategoryNode *)selectedItem;
        [self toggleNodeExpansion:node];
    }
}

#pragma mark - 辅助方法

- (void)applyFilter:(BOOL (^)(KeychainDataItem *item))filterBlock {
    if (filterBlock == nil) {
        // 清除过滤，显示所有项目
        self.filteredResults = [self.originalResults copy];
    } else {
        // 应用过滤条件
        NSMutableArray *filtered = [NSMutableArray array];
        for (KeychainDataItem *item in self.originalResults) {
            if (filterBlock(item)) {
                [filtered addObject:item];
            }
        }
        self.filteredResults = [filtered copy];
    }
    
    // 重建分类树
    [self buildCategoryTree];
    
    // 刷新显示
    [self.categoryOutlineView reloadData];
    [self.detailTableView reloadData];
    [self updateStatisticsDisplay];
}

- (void)expandNodeAndAllChildren:(KeychainCategoryNode *)node {
    if (!node || node.isLeaf) return;
    
    [self.categoryOutlineView expandItem:node];
    
    for (KeychainCategoryNode *child in node.children) {
        [self expandNodeAndAllChildren:child];
    }
}

- (void)collapseNodeAndAllChildren:(KeychainCategoryNode *)node {
    if (!node || node.isLeaf) return;
    
    // 先折叠子节点
    for (KeychainCategoryNode *child in node.children) {
        [self collapseNodeAndAllChildren:child];
    }
    
    // 再折叠当前节点
    [self.categoryOutlineView collapseItem:node];
}

- (void)exportItems:(NSArray<KeychainDataItem *> *)items {
    NSSavePanel *savePanel = [NSSavePanel savePanel];
    
    NSString *format = @"json";
    NSString *extension = @"json";
    
    NSInteger selectedIndex = self.exportFormatPopUp.indexOfSelectedItem;
    switch (selectedIndex) {
        case 0: // JSON
            format = @"json";
            extension = @"json";
            break;
        case 1: // CSV
            format = @"csv";
            extension = @"csv";
            break;
        case 2: // Plist
            format = @"plist";
            extension = @"plist";
            break;
    }
    
    savePanel.allowedFileTypes = @[extension];
    savePanel.nameFieldStringValue = [NSString stringWithFormat:@"Keychain导出_%@.%@",
                                     [[NSDate date] description], extension];
    
    [savePanel beginWithCompletionHandler:^(NSInteger result) {
        if (result == NSModalResponseOK) {
            [self performExport:items toFile:savePanel.URL.path format:format];
        }
    }];
}

- (void)performExport:(NSArray<KeychainDataItem *> *)items toFile:(NSString *)filePath format:(NSString *)format {
    if (!items || items.count == 0) {
        [self showError:@"没有可导出的数据"];
        return;
    }
    
    if (!filePath || filePath.length == 0) {
        [self showError:@"导出路径无效"];
        return;
    }
    
    NSLog(@"🔑 开始导出 %lu 个条目到: %@", (unsigned long)items.count, filePath);
    
    NSError *error = nil;
    BOOL success = [self exportKeychainItems:items toFile:filePath format:format error:&error];
    
    if (success) {
        NSLog(@"✅ 成功导出 %lu 个条目", (unsigned long)items.count);
        
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"导出成功";
        alert.informativeText = [NSString stringWithFormat:@"已成功导出 %lu 个钥匙串条目到指定文件", (unsigned long)items.count];
        alert.alertStyle = NSAlertStyleInformational;
        [alert addButtonWithTitle:@"确定"];
        [alert addButtonWithTitle:@"显示文件"];
        
        NSModalResponse response = [alert runModal];
        if (response == NSAlertSecondButtonReturn) {
            [[NSWorkspace sharedWorkspace] selectFile:filePath inFileViewerRootedAtPath:nil];
        }
    } else {
        NSLog(@"❌ 导出失败: %@", error.localizedDescription ?: @"未知错误");
        [self showError:[NSString stringWithFormat:@"导出失败: %@", error.localizedDescription ?: @"未知错误"]];
    }
}

- (BOOL)exportKeychainItems:(NSArray<KeychainDataItem *> *)items
                     toFile:(NSString *)filePath
                     format:(NSString *)format
                      error:(NSError **)error {
    
    if (!items || items.count == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"KeychainExportErrorDomain"
                                         code:1001
                                     userInfo:@{NSLocalizedDescriptionKey: @"没有可导出的数据"}];
        }
        return NO;
    }
    
    NSData *exportData = nil;
    
    if ([format.lowercaseString isEqualToString:@"json"]) {
        exportData = [self exportItemsAsJSON:items];
    } else if ([format.lowercaseString isEqualToString:@"csv"]) {
        exportData = [self exportItemsAsCSV:items];
    } else if ([format.lowercaseString isEqualToString:@"plist"]) {
        exportData = [self exportItemsAsPlist:items];
    } else {
        if (error) {
            *error = [NSError errorWithDomain:@"KeychainExportErrorDomain"
                                         code:1002
                                     userInfo:@{NSLocalizedDescriptionKey: @"不支持的导出格式"}];
        }
        return NO;
    }
    
    if (!exportData) {
        if (error) {
            *error = [NSError errorWithDomain:@"KeychainExportErrorDomain"
                                         code:1003
                                     userInfo:@{NSLocalizedDescriptionKey: @"生成导出数据失败"}];
        }
        return NO;
    }
    
    BOOL success = [exportData writeToFile:filePath atomically:YES];
    if (!success && error) {
        *error = [NSError errorWithDomain:@"KeychainExportErrorDomain"
                                     code:1004
                                 userInfo:@{NSLocalizedDescriptionKey: @"写入文件失败"}];
    }
    
    return success;
}

- (NSData *)exportItemsAsJSON:(NSArray<KeychainDataItem *> *)items {
    NSMutableArray *exportArray = [NSMutableArray array];
    
    for (KeychainDataItem *item in items) {
        NSMutableDictionary *dict = [NSMutableDictionary dictionary];
        
        dict[@"类型"] = [KeychainDataItem localizedStringForItemType:item.itemType];
        if (item.service) dict[@"服务"] = item.service;
        if (item.account) dict[@"账户"] = item.account;
        if (item.password && !item.isPasswordEncrypted) dict[@"密码"] = item.password;
        if (item.server) dict[@"服务器"] = item.server;
        if (item.protocol) dict[@"协议"] = item.protocol;
        if (item.path) dict[@"路径"] = item.path;
        if (item.port) dict[@"端口"] = item.port;
        if (item.creationDate) dict[@"创建时间"] = [item.creationDate description];
        if (item.modificationDate) dict[@"修改时间"] = [item.modificationDate description];
        if (item.comment) dict[@"备注"] = item.comment;
        if (item.label) dict[@"标签"] = item.label;
        dict[@"密码已加密"] = @(item.isPasswordEncrypted);
        
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

- (NSData *)exportItemsAsCSV:(NSArray<KeychainDataItem *> *)items {
    NSMutableString *csvString = [NSMutableString string];
    
    // CSV头部
    [csvString appendString:@"类型,服务,账户,密码,服务器,协议,路径,端口,创建时间,修改时间,备注,标签,密码已加密\n"];
    
    for (KeychainDataItem *item in items) {
        NSMutableArray *fields = [NSMutableArray array];
        
        [fields addObject:[self csvEscapeString:[KeychainDataItem localizedStringForItemType:item.itemType]]];
        [fields addObject:[self csvEscapeString:item.service ?: @""]];
        [fields addObject:[self csvEscapeString:item.account ?: @""]];
        [fields addObject:[self csvEscapeString:(item.password && !item.isPasswordEncrypted) ? item.password : @""]];
        [fields addObject:[self csvEscapeString:item.server ?: @""]];
        [fields addObject:[self csvEscapeString:item.protocol ?: @""]];
        [fields addObject:[self csvEscapeString:item.path ?: @""]];
        [fields addObject:[self csvEscapeString:item.port ? item.port.stringValue : @""]];
        [fields addObject:[self csvEscapeString:item.creationDate ? item.creationDate.description : @""]];
        [fields addObject:[self csvEscapeString:item.modificationDate ? item.modificationDate.description : @""]];
        [fields addObject:[self csvEscapeString:item.comment ?: @""]];
        [fields addObject:[self csvEscapeString:item.label ?: @""]];
        [fields addObject:item.isPasswordEncrypted ? @"是" : @"否"];
        
        [csvString appendString:[fields componentsJoinedByString:@","]];
        [csvString appendString:@"\n"];
    }
    
    return [csvString dataUsingEncoding:NSUTF8StringEncoding];
}

- (NSData *)exportItemsAsPlist:(NSArray<KeychainDataItem *> *)items {
    NSMutableArray *exportArray = [NSMutableArray array];
    
    for (KeychainDataItem *item in items) {
        NSMutableDictionary *dict = [NSMutableDictionary dictionary];
        
        dict[@"ItemType"] = @(item.itemType);
        if (item.service) dict[@"Service"] = item.service;
        if (item.account) dict[@"Account"] = item.account;
        if (item.password && !item.isPasswordEncrypted) dict[@"Password"] = item.password;
        if (item.server) dict[@"Server"] = item.server;
        if (item.protocol) dict[@"Protocol"] = item.protocol;
        if (item.path) dict[@"Path"] = item.path;
        if (item.port) dict[@"Port"] = item.port;
        if (item.creationDate) dict[@"CreationDate"] = item.creationDate;
        if (item.modificationDate) dict[@"ModificationDate"] = item.modificationDate;
        if (item.comment) dict[@"Comment"] = item.comment;
        if (item.label) dict[@"Label"] = item.label;
        dict[@"IsPasswordEncrypted"] = @(item.isPasswordEncrypted);
        
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

- (NSString *)csvEscapeString:(NSString *)string {
    if (!string) return @"\"\"";
    
    if ([string containsString:@","] || [string containsString:@"\""] || [string containsString:@"\n"]) {
        string = [string stringByReplacingOccurrencesOfString:@"\"" withString:@"\"\""];
        return [NSString stringWithFormat:@"\"%@\"", string];
    }
    
    return string;
}

- (void)showError:(NSString *)errorMessage {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"错误";
        alert.informativeText = errorMessage;
        alert.alertStyle = NSAlertStyleCritical;
        [alert addButtonWithTitle:@"确定"];
        
        if (self.modalWindow) {
            [alert beginSheetModalForWindow:self.modalWindow completionHandler:nil];
        } else {
            [alert runModal];
        }
    });
}

@end
