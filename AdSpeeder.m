// AdSpeeder - Alipay mini-game rewarded-video ad accelerator
// No substrate / logos dependency: pure objc runtime swizzling, so the dylib
// loads fine inside a TrollFools-injected (non-jailbroken) Alipay process.
//
// 悬浮球：单击循环倍速（关 / 2x / 4x / 8x / 16x / 32x），长按弹出选单，
//         拖动可换位置，设置与坐标都会持久化。

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <math.h>

static const float   kAdRateFallback = 2.0f;   // 播放项不支持快进时的保守倍速
static const Float64 kAdMaxDuration  = 65.0;   // 秒；超过这个时长不认为是广告

static NSString *const kPrefEnabled = @"adspeeder.enabled";
static NSString *const kPrefRate    = @"adspeeder.rate";
static NSString *const kPrefPosX    = @"adspeeder.x";
static NSString *const kPrefPosY    = @"adspeeder.y";

// 0 = 关闭
static float gRate = 16.0f;
static NSHashTable<WKWebView *> *gWebViews = nil;

#pragma mark - 基础

static BOOL ASIsAlipay(void) {
    static BOOL result = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *bid = [NSBundle mainBundle].bundleIdentifier ?: @"";
        result = [bid hasPrefix:@"com.alipay"];
    });
    return result;
}

// 只改本类自己的方法，避免污染父类实现
static BOOL ASSwizzle(Class cls, SEL sel, IMP newImp, IMP *outOrig) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    if (class_getMethodImplementation(cls, sel) != method_getImplementation(m)) return NO;
    if (outOrig) *outOrig = method_getImplementation(m);
    method_setImplementation(m, newImp);
    return YES;
}

static BOOL ASEngineOn(void) { return gRate > 1.0f; }

#pragma mark - 设置

static void ASLoadPrefs(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if ([d objectForKey:kPrefEnabled] == nil) {
        gRate = 16.0f;              // 首次安装默认开启 16 倍
        [d setBool:YES forKey:kPrefEnabled];
        [d setFloat:gRate forKey:kPrefRate];
    } else {
        BOOL on = [d boolForKey:kPrefEnabled];
        float r = [d floatForKey:kPrefRate];
        if (r < 2.0f) r = 16.0f;
        gRate = on ? r : 0.0f;
    }
}

static void ASSavePrefs(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setBool:ASEngineOn() forKey:kPrefEnabled];
    [d setFloat:(ASEngineOn() ? gRate : 16.0f) forKey:kPrefRate];
    [d synchronize];
}

static void ASPushRateToWebView(WKWebView *webView);

static void ASPushRateToAllWebViews(void) {
    NSArray *snapshot = nil;
    @synchronized (gWebViews) { snapshot = gWebViews.allObjects; }
    for (WKWebView *w in snapshot) ASPushRateToWebView(w);
}

#pragma mark - AVPlayer 路径

static IMP gOrigSetRate = NULL;
static IMP gOrigPlay    = NULL;

// 判断当前播放项像不像广告：时长短 + 支持快进
static float ASAdRateForPlayer(AVPlayer *player) {
    if (!ASEngineOn()) return 0.0f;
    AVPlayerItem *item = player.currentItem;
    if (!item) return 0.0f;
    Float64 d = CMTimeGetSeconds(item.duration);
    if (!isfinite(d) || d <= 0.0 || d > kAdMaxDuration) return 0.0f;
    if (!item.canPlayFastForward && gRate > kAdRateFallback) return kAdRateFallback;
    return gRate;
}

static void ASMySetRate(AVPlayer *self, SEL _cmd, float rate) {
    if (rate > 0.0f) {
        float target = ASAdRateForPlayer(self);
        if (target > rate) {
            Float64 d = CMTimeGetSeconds(self.currentItem.duration);
            NSLog(@"[AdSpeeder] ad detected at %.0fx (duration=%.1fs)", target, d);
            rate = target;
            self.muted = YES;
        }
    }
    ((void (*)(id, SEL, float))gOrigSetRate)(self, _cmd, rate);
}

static void ASMyPlay(AVPlayer *self, SEL _cmd) {
    ((void (*)(id, SEL))gOrigPlay)(self, _cmd);
    float target = ASAdRateForPlayer(self);
    if (target > 1.0f) {
        self.muted = YES;
        self.rate = target;   // 走 swizzle 后的 setRate:
    }
}

#pragma mark - WKWebView / Nebula 路径

static NSString *const kBoostJS =
@"(function(){"
 "if(window.__asBoost)return;window.__asBoost=1;"
 "function r(){var v=window.__asRate;return (typeof v==='number'&&v>1)?v:1;}"
 "function b(e){var k=r();if(k<=1)return;try{if(e.playbackRate<k)e.playbackRate=k;"
 "e.muted=!0;e.volume=0;}catch(x){}}"
 "function s(){var a=document.querySelectorAll('video');for(var i=0;i<a.length;i++)b(a[i]);}"
 "document.addEventListener('loadedmetadata',function(e){"
 "if(e.target&&e.target.tagName==='VIDEO')b(e.target);},true);"
 "document.addEventListener('play',function(e){"
 "if(e.target&&e.target.tagName==='VIDEO')b(e.target);},true);"
 "setInterval(s,400);"
 "try{new MutationObserver(s).observe(document.documentElement,{childList:!0,subtree:!0});}catch(e){}"
 "s();})();";

static IMP gOrigInitWithFrameConfig = NULL;

static void ASPushRateToWebView(WKWebView *webView) {
    NSString *js = [NSString stringWithFormat:@"window.__asRate=%g;", gRate];
    [webView evaluateJavaScript:js completionHandler:nil];
}

static id ASMyInitWithFrameConfig(WKWebView *self, SEL _cmd, CGRect frame, WKWebViewConfiguration *config) {
    if (config) {
        WKUserContentController *ucc = config.userContentController;
        if (!ucc) {
            ucc = [[WKUserContentController alloc] init];
            config.userContentController = ucc;
        }
        // 每次导航开始就把当前倍速写进 window，避免页面跳转后丢设置
        NSString *seed = [NSString stringWithFormat:@"window.__asRate=%g;", gRate];
        [ucc addUserScript:[[WKUserScript alloc] initWithSource:seed
                                                    injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                                 forMainFrameOnly:NO]];
        [ucc addUserScript:[[WKUserScript alloc] initWithSource:kBoostJS
                                                    injectionTime:WKUserScriptInjectionTimeAtDocumentEnd
                                                 forMainFrameOnly:NO]];
    }
    id result = ((id (*)(id, SEL, CGRect, id))gOrigInitWithFrameConfig)(self, _cmd, frame, config);
    if (result && [result isKindOfClass:[WKWebView class]]) {
        @synchronized (gWebViews) { [gWebViews addObject:result]; }
        ASPushRateToWebView((WKWebView *)result);
    }
    return result;
}

#pragma mark - 悬浮球

static const float kSpeedSteps[] = {0.0f, 2.0f, 4.0f, 8.0f, 16.0f, 32.0f};
static const int   kSpeedCount   = 6;

@interface ASFloatingView : UIView
@property (nonatomic, strong) UILabel *label;
@end

@interface ASOverlayWindow : UIWindow
@end

@implementation ASOverlayWindow
// 只让悬浮球本身接收触摸，其余区域完全透传，否则支付宝会点不动
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *v = [super hitTest:point withEvent:event];
    if (v == self || v == self.rootViewController.view) return nil;
    return v;
}
@end

static ASOverlayWindow *gOverlay = nil;
static ASFloatingView *gBall = nil;

static void ASRefreshBall(void) {
    if (!gBall) return;
    if (ASEngineOn()) {
        gBall.label.text = [NSString stringWithFormat:@"%gx", gRate];
        gBall.backgroundColor = [UIColor colorWithRed:0.09 green:0.62 blue:0.35 alpha:0.78];
    } else {
        gBall.label.text = @"关";
        gBall.backgroundColor = [UIColor colorWithWhite:0.15 alpha:0.72];
    }
}

static void ASSetRate(float rate, BOOL persist) {
    gRate = rate;
    if (persist) ASSavePrefs();
    ASRefreshBall();
    ASPushRateToAllWebViews();
    NSLog(@"[AdSpeeder] rate -> %gx (enabled=%d)", gRate, ASEngineOn());
}

@implementation ASFloatingView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.layer.cornerRadius = 11;
    self.layer.masksToBounds = YES;
    self.layer.borderWidth = 1;
    self.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.35].CGColor;
    self.userInteractionEnabled = YES;

    _label = [[UILabel alloc] initWithFrame:self.bounds];
    _label.textAlignment = NSTextAlignmentCenter;
    _label.textColor = [UIColor whiteColor];
    _label.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightSemibold];
    _label.userInteractionEnabled = NO;
    [self addSubview:_label];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap)];
    [self addGestureRecognizer:tap];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [self addGestureRecognizer:pan];
    [tap requireGestureRecognizerToFail:pan];

    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
    lp.minimumPressDuration = 0.45;
    [self addGestureRecognizer:lp];

    return self;
}

- (void)handleTap {
    int idx = 0;
    for (int i = 0; i < kSpeedCount; i++) {
        if (fabsf(kSpeedSteps[i] - gRate) < 0.01f) { idx = i; break; }
    }
    idx = (idx + 1) % kSpeedCount;
    ASSetRate(kSpeedSteps[idx], YES);
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    CGPoint t = [pan translationInView:self.superview];
    self.center = CGPointMake(self.center.x + t.x, self.center.y + t.y);
    [pan setTranslation:CGPointZero inView:self.superview];

    if (pan.state == UIGestureRecognizerStateEnded || pan.state == UIGestureRecognizerStateCancelled) {
        CGRect bounds = self.superview.bounds;
        CGFloat halfW = self.bounds.size.width / 2.0;
        CGFloat x = (self.center.x < bounds.size.width / 2.0) ? (halfW + 6) : (bounds.size.width - halfW - 6);
        CGFloat y = MAX(halfW + 40, MIN(bounds.size.height - halfW - 40, self.center.y));
        [UIView animateWithDuration:0.18 animations:^{
            self.center = CGPointMake(x, y);
        }];
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        [d setDouble:x forKey:kPrefPosX];
        [d setDouble:y forKey:kPrefPosY];
    }
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)lp {
    if (lp.state != UIGestureRecognizerStateBegan) return;
    UIViewController *root = gOverlay.rootViewController;
    if (!root) return;

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"AdSpeeder"
                                                                  message:@"选择广告加速倍速"
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray *titles = @[@"关闭加速", @"2 倍", @"4 倍", @"8 倍", @"16 倍", @"32 倍"];
    for (int i = 0; i < kSpeedCount; i++) {
        float step = kSpeedSteps[i];
        NSString *title = titles[i];
        if (fabsf(step - gRate) < 0.01f) title = [title stringByAppendingString:@"  ✓"];
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            ASSetRate(step, YES);
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self;
    sheet.popoverPresentationController.sourceRect = self.bounds;
    [root presentViewController:sheet animated:YES completion:nil];
}

@end

static void ASSetupFloatingUI(void) {
    if (gOverlay) return;
    if (!ASIsAlipay()) return;

    UIWindowScene *scene = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]] && s.activationState == UISceneActivationStateForegroundActive) {
            scene = (UIWindowScene *)s;
            break;
        }
    }
    if (!scene) return;   // 还没进前台，稍后重试

    CGRect bounds = scene.coordinateSpace.bounds;

    ASOverlayWindow *win = [[ASOverlayWindow alloc] initWithWindowScene:scene];
    win.frame = bounds;
    win.windowLevel = UIWindowLevelAlert + 5;
    win.backgroundColor = [UIColor clearColor];
    UIViewController *root = [[UIViewController alloc] init];
    root.view.backgroundColor = [UIColor clearColor];
    win.rootViewController = root;
    win.hidden = NO;

    CGFloat side = 46.0;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    CGFloat x = [d doubleForKey:kPrefPosX];
    CGFloat y = [d doubleForKey:kPrefPosY];
    if (x <= 0 || y <= 0) { x = bounds.size.width - side / 2 - 10; y = bounds.size.height * 0.42; }

    ASFloatingView *ball = [[ASFloatingView alloc] initWithFrame:CGRectMake(0, 0, side, side)];
    ball.center = CGPointMake(x, y);
    [root.view addSubview:ball];

    gOverlay = win;
    gBall = ball;
    ASRefreshBall();
    NSLog(@"[AdSpeeder] overlay ready at %.0f,%.0f", x, y);
}

#pragma mark - 诊断：把名字像广告的类打到日志里

static void ASLogAdCandidates(void) {
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    if (!classes) return;
    NSMutableArray<NSString *> *hits = [NSMutableArray array];
    NSArray<NSString *> *needles = @[@"reward", @"interstitial", @"adplayer", @"adview", @"admanager"];
    for (unsigned int i = 0; i < count; i++) {
        const char *name = class_getName(classes[i]);
        if (!name) continue;
        NSString *s = [NSString stringWithUTF8String:name];
        NSString *lower = s.lowercaseString;
        for (NSString *n in needles) {
            if ([lower containsString:n]) { [hits addObject:s]; break; }
        }
    }
    free(classes);
    NSLog(@"[AdSpeeder] ad-class candidates (%lu): %@", (unsigned long)hits.count, hits);
}

#pragma mark - 入口

static void ASScheduleOverlay(int attempts) {
    if (gOverlay) return;
    ASSetupFloatingUI();
    if (gOverlay || attempts <= 0) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        ASScheduleOverlay(attempts - 1);
    });
}

__attribute__((constructor))
static void AdSpeederInit(void) {
    if (!ASIsAlipay()) {
        NSLog(@"[AdSpeeder] not Alipay, skip");
        return;
    }

    gWebViews = [NSHashTable weakObjectsHashTable];
    ASLoadPrefs();

    Class avPlayer = objc_getClass("AVPlayer");
    if (avPlayer) {
        ASSwizzle(avPlayer, @selector(setRate:), (IMP)ASMySetRate, &gOrigSetRate);
        ASSwizzle(avPlayer, @selector(play),    (IMP)ASMyPlay,    &gOrigPlay);
    }

    Class wk = objc_getClass("WKWebView");
    if (wk) {
        ASSwizzle(wk, @selector(initWithFrame:configuration:),
                  (IMP)ASMyInitWithFrameConfig, &gOrigInitWithFrameConfig);
    }

    NSLog(@"[AdSpeeder] installed (AVPlayer=%d, WKWebView=%d, rate=%gx)",
          gOrigSetRate != NULL, gOrigInitWithFrameConfig != NULL, gRate);

    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            ASScheduleOverlay(15);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ ASLogAdCandidates(); });
        });
    }];

    // 兜底：dylib 晚于 App 启动才加载时，直接排一次
    if (UIApplication.sharedApplication) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ ASScheduleOverlay(15); });
    }
}
