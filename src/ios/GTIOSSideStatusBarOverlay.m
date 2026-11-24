#import <Cordova/CDV.h>
#import <Cordova/CDVViewController.h>
#import <objc/runtime.h>

static const CGFloat kSideInsetThreshold = 32.0;
static const CGFloat kSideDominanceMargin = 8.0;
static const NSInteger kMaxLayoutRetries = 2;
static BOOL gForceStatusBarLightContent = NO;
static IMP gOriginalPreferredStatusBarStyle = NULL;
static BOOL gStatusBarStyleSwizzled = NO;

/**
 * lightContent 时固定白色图标。释放后回到 Cordova 原来的样式选择。
 * 输入：CDVViewController 实例。
 * 输出：状态栏图标样式。
 */
static UIStatusBarStyle gtiosPreferredStatusBarStyle(id self, SEL selector) {
    if (gForceStatusBarLightContent) {
        return UIStatusBarStyleLightContent;
    }
    if (gOriginalPreferredStatusBarStyle != NULL) {
        return ((UIStatusBarStyle (*)(id, SEL))gOriginalPreferredStatusBarStyle)(self, selector);
    }
    return UIStatusBarStyleDefault;
}

@interface GTIOSSideStatusBarOverlay : CDVPlugin
@end

@interface GTIOSSideStatusBarOverlay ()
@property (nonatomic, strong) UIView *overlayView;
@property (nonatomic, assign) BOOL observing;
@property (nonatomic, assign) NSInteger layoutGeneration;
@property (nonatomic, assign) NSInteger pendingRetries;
@end

@implementation GTIOSSideStatusBarOverlay

/**
 * 创建不接收触摸的黑色覆盖层，并开始跟随布局。
 * 输入：Cordova 注入的 viewController。
 * 输出：覆盖层默认隐藏。
 */
- (void)pluginInitialize {
    [super pluginInitialize];
    [self ensureOverlay];
    [self startObserving];
    [self handleLayoutChange];
}

/**
 * 取消尚未执行的重试，释放白色图标覆盖，并移除覆盖层。
 * 输入：无。
 * 输出：不再监听布局通知。方法交换保留。
 */
- (void)dispose {
    self.layoutGeneration += 1;
    gForceStatusBarLightContent = NO;
    [self.viewController setNeedsStatusBarAppearanceUpdate];
    [self stopObserving];
    [self.overlayView removeFromSuperview];
    self.overlayView = nil;
    [super dispose];
}

/**
 * 按页面请求强制或释放顶部白色图标。方法交换保留到进程结束。
 * 输入：Cordova 命令的第一个布尔参数。
 * 输出：成功或参数错误。
 */
- (void)setStatusBarLightContent:(CDVInvokedUrlCommand *)command {
    id rawValue = [command argumentAtIndex:0];
    if (![rawValue isKindOfClass:[NSNumber class]]) {
        CDVPluginResult *error = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"expected boolean"];
        [self.commandDelegate sendPluginResult:error callbackId:command.callbackId];
        return;
    }
    if (![self installStatusBarStyleOverride]) {
        CDVPluginResult *error = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"preferredStatusBarStyle unavailable"];
        [self.commandDelegate sendPluginResult:error callbackId:command.callbackId];
        return;
    }
    gForceStatusBarLightContent = [rawValue boolValue];
    [self.viewController setNeedsStatusBarAppearanceUpdate];
    CDVPluginResult *ok = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    [self.commandDelegate sendPluginResult:ok callbackId:command.callbackId];
}

/**
 * 只替换 CDVViewController 自己的实现，避免改到 UIViewController。
 * 输入：无。
 * 输出：已安装或本来已安装时为 YES。
 */
- (BOOL)installStatusBarStyleOverride {
    if (gStatusBarStyleSwizzled) {
        return YES;
    }
    Method method = [self declaredPreferredStatusBarStyle];
    if (method == NULL) {
        return NO;
    }
    gOriginalPreferredStatusBarStyle = method_setImplementation(method, (IMP)gtiosPreferredStatusBarStyle);
    gStatusBarStyleSwizzled = YES;
    return YES;
}

/**
 * 输入：CDVViewController 的实例方法表。
 * 输出：本类声明的 preferredStatusBarStyle；继承来的方法返回 NULL。
 */
- (Method)declaredPreferredStatusBarStyle {
    unsigned int count = 0;
    Method *methods = class_copyMethodList([CDVViewController class], &count);
    Method found = NULL;
    for (unsigned int index = 0; index < count; index += 1) {
        if (method_getName(methods[index]) == @selector(preferredStatusBarStyle)) {
            found = methods[index];
            break;
        }
    }
    free(methods);
    return found;
}

/**
 * 判断状态栏是否位于物理右侧。
 * 输入：当前 Cordova 视图控制器。
 * 输出：物理右侧为 YES；顶部、左侧和对称安全区为 NO。
 * 有 verticalBarEdge 时以它为准，避免安全区圆角把普通机型误判成侧栏。
 */
- (BOOL)resolveRightSide:(CDVViewController *)viewController {
    NSNumber *verticalEdge = [self physicalRightFromVerticalBarEdge:viewController];
    if (verticalEdge != nil) {
        return verticalEdge.boolValue;
    }
    return [self physicalRightFromSafeArea:viewController.view];
}

/**
 * 按当前姿态显示或隐藏右侧黑条。
 * 输入：当前视图和安全区。
 * 输出：仅物理右侧显示全高黑条。
 */
- (void)refreshOverlay {
    UIView *host = self.viewController.view;
    if (!host || !self.overlayView) {
        return;
    }
    if (![self resolveRightSide:(CDVViewController *)self.viewController]) {
        self.overlayView.hidden = YES;
        return;
    }
    [self placeOverlayOnHost:host];
}

/**
 * 保证覆盖层只创建一次。黑条不能拦截页面点击。
 * 输入：Cordova 根视图。
 * 输出：已加入根视图的隐藏覆盖层。
 */
- (void)ensureOverlay {
    UIView *host = self.viewController.view;
    if (!host || self.overlayView) {
        return;
    }
    UIView *overlay = [[UIView alloc] initWithFrame:CGRectZero];
    overlay.backgroundColor = UIColor.blackColor;
    overlay.userInteractionEnabled = NO;
    overlay.hidden = YES;
    overlay.autoresizingMask = UIViewAutoresizingFlexibleHeight | UIViewAutoresizingFlexibleLeftMargin;
    [host addSubview:overlay];
    self.overlayView = overlay;
}

/**
 * 布局通知只绑定一次。重复初始化不能叠加观察者。
 * 输入：无。
 * 输出：已注册布局、旋转和回前台通知。
 */
- (void)startObserving {
    if (self.observing) {
        return;
    }
    self.observing = YES;
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserver:self selector:@selector(handleLayoutChange) name:CDVViewDidLayoutSubviewsNotification object:nil];
    [center addObserver:self selector:@selector(handleLayoutChange) name:CDVViewWillTransitionToSizeNotification object:nil];
    [center addObserver:self selector:@selector(handleLayoutChange) name:UIApplicationDidBecomeActiveNotification object:nil];
}

/**
 * 输入：无。
 * 输出：移除本插件注册的全部通知。
 */
- (void)stopObserving {
    if (!self.observing) {
        return;
    }
    [NSNotificationCenter.defaultCenter removeObserver:self];
    self.observing = NO;
}

/**
 * 新的布局事件使上一次延迟重试失效。
 * 输入：Cordova 布局通知。
 * 输出：立即刷新，并在安全区尚未就绪时最多再等两帧。
 */
- (void)handleLayoutChange {
    self.layoutGeneration += 1;
    self.pendingRetries = kMaxLayoutRetries;
    [self refreshOverlay];
    [self scheduleRetryIfNeeded];
}

/**
 * Duo 展开的首帧安全区可能仍是 0，不能把这一帧当成最终姿态。
 * 输入：剩余重试次数和当前布局代次。
 * 输出：安全区全为 0 时在主队列再刷新一次。
 */
- (void)scheduleRetryIfNeeded {
    if (self.pendingRetries <= 0 || ![self safeAreaStillEmpty]) {
        return;
    }
    self.pendingRetries -= 1;
    NSInteger generation = self.layoutGeneration;
    __weak GTIOSSideStatusBarOverlay *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        GTIOSSideStatusBarOverlay *strongSelf = weakSelf;
        if (!strongSelf || strongSelf.layoutGeneration != generation) {
            return;
        }
        [strongSelf refreshOverlay];
        [strongSelf scheduleRetryIfNeeded];
    });
}

/**
 * 输入：根视图安全区。
 * 输出：四边都还没上报时为 YES。
 */
- (BOOL)safeAreaStillEmpty {
    UIView *host = self.viewController.view;
    if (!host) {
        return NO;
    }
    UIEdgeInsets insets = host.safeAreaInsets;
    return insets.top == 0 && insets.right == 0 && insets.bottom == 0 && insets.left == 0;
}

/**
 * 输入：Cordova 根视图和右侧安全区宽度。
 * 输出：贴在物理右边缘的全高黑色区域。
 */
- (void)placeOverlayOnHost:(UIView *)host {
    CGFloat width = host.safeAreaInsets.right;
    if (width <= 0) {
        self.overlayView.hidden = YES;
        return;
    }
    self.overlayView.hidden = NO;
    self.overlayView.frame = CGRectMake(
        CGRectGetWidth(host.bounds) - width,
        0,
        width,
        CGRectGetHeight(host.bounds)
    );
    [host bringSubviewToFront:self.overlayView];
}

/**
 * 输入：视图控制器的 verticalBarEdge 和布局方向。
 * 输出：API 可用时返回是否为物理右侧；旧系统返回 nil，交给安全区回退。
 */
- (NSNumber *)physicalRightFromVerticalBarEdge:(CDVViewController *)viewController {
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 270100
    if (@available(iOS 27.1, *)) {
        return @([self verticalBarEdgeIsPhysicalRight:viewController]);
    }
#endif
    return nil;
}

#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 270100
/**
 * LTR 的 trailing 是物理右侧；RTL 的 leading 才是物理右侧。
 * 输入：verticalBarEdge 和布局方向。
 * 输出：物理右侧为 YES。
 */
- (BOOL)verticalBarEdgeIsPhysicalRight:(CDVViewController *)viewController API_AVAILABLE(ios(27.1)) {
    UIUserInterfaceLayoutDirection direction = viewController.view.effectiveUserInterfaceLayoutDirection;
    UIVerticalBarEdge edge = viewController.traitCollection.verticalBarEdge;
    if (direction == UIUserInterfaceLayoutDirectionRightToLeft) {
        return edge == UIVerticalBarEdgeLeading;
    }
    return edge == UIVerticalBarEdgeTrailing;
}
#endif

/**
 * 输入：根视图左右安全区。
 * 输出：右侧达到侧栏宽度且明显大于左侧时为 YES。
 */
- (BOOL)physicalRightFromSafeArea:(UIView *)host {
    if (!host) {
        return NO;
    }
    UIEdgeInsets insets = host.safeAreaInsets;
    return insets.right >= kSideInsetThreshold && insets.right > insets.left + kSideDominanceMargin;
}

@end
