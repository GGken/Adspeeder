// AdSpeeder - Alipay mini-game rewarded-video ad accelerator
// No substrate / logos dependency: pure objc runtime swizzling, so the dylib
// loads fine inside a TrollFools-injected (non-jailbroken) Alipay process.
//
// 悬浮球：单击循环倍速（关 / 2x / 4x / 8x / 16x / 32x），长按弹出选单
//         （含"抓取当前界面"诊断），拖动换位置，设置与坐标持久化。

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

static float gRate = 16.0f;                    // 0 = 关闭
static NSHashTable<WKWebView *> *gWebViews = nil;
static NSHashTable<AVPlayer *> *gPlayers  = nil;
static NSMutableArray<NSString *> *gEvents = nil;

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

static BOOL ASSwizzle(Class cls, SEL sel, IMP newImp, IMP *outOrig) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    if (class_getMethodImplementation(cls, sel) != method_getImplementation(m)) return NO;
    if (outOrig) *outOrig = method_getImplementation(m);
    method_setImplementation(m, newImp);
    return YES;
}

static BOOL ASEngineOn(void) { return gRate > 1.0f; }

#pragma mark - 事件记录（给用户看的诊断缓冲）

static void ASRecord(NSString *line) {
    if (!line) return;
    static NSDateFormatter *fmt = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"HH:mm:ss";
    });
    NSString *stamp = [fmt stringFromDate:[NSDate date]];
    if (!gEvents) gEvents = [NSMutableArray array];
    @synchronized (gEvents) {
        [gEvents addObject:[NSString stringWithFormat:@"%@  %@", stamp, line]];
        if (gEvents.count > 300) [gEvents removeObjectAtIndex:0];
    }
}

#pragma mark - 设置

static void ASLoadPrefs(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if ([d objectForKey:kPrefEnabled] == nil) {
        gRate = 16.0f;
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
static IMP gOrigPlay = NULL;
static IMP gOrigPlayAtRate = NULL;
static IMP gOrigSetRateTime = NULL;

static float ASAdRateForPlayer(AVPlayer *player) {
    if (!ASEngineOn()) return 0.0f;
    AVPlayerItem *item = player.currentItem;
    if (!item) return 0.0f;
    Float64 d = CMTimeGetSeconds(item.duration);
    if (!isfinite(d) || d <= 0.0 || d > kAdMaxDuration) return 0.0f;
    if (!item.canPlayFastForward && gRate > kAdRateFallback) return kAdRateFallback;
    return gRate;
}

static void ASRegisterPlayer(AVPlayer *p) {
    if (!p || !gPlayers) return;
    @synchronized (gPlayers) { [gPlayers addObject:p]; }
}

static void ASMySetRate(AVPlayer *self, SEL _cmd, float rate) {
    ASRegisterPlayer(self);
    if (rate > 0.0f) {
        float target = ASAdRateForPlayer(self);
        if (target > rate) {
            Float64 d = CMTimeGetSeconds(self.currentItem.duration);
            ASRecord([NSString stringWithFormat:@"AVPlayer 广告命中 %.0fx (时长 %.1fs)", target, d]);
            NSLog(@"[AdSpeeder] ad detected at %.0fx (duration=%.1fs)", target, d);
            rate = target;
            self.muted = YES;
        }
    }
    ((void (*)(id, SEL, float))gOrigSetRate)(self, _cmd, rate);
}

static void ASMyPlay(AVPlayer *self, SEL _cmd) {
    ASRegisterPlayer(self);
    ((void (*)(id, SEL))gOrigPlay)(self, _cmd);
    float target = ASAdRateForPlayer(self);
    if (target > 1.0f) {
        self.muted = YES;
        self.rate = target;
    }
}

static void ASMyPlayAtRate(AVPlayer *self, SEL _cmd, float rate) {
    ASRegisterPlayer(self);
    float target = ASAdRateForPlayer(self);
    if (target > rate) {
        ASRecord([NSString stringWithFormat:@"AVPlayer(playImmediately) 广告命中 %.0fx", target]);
        rate = target;
        self.muted = YES;
    }
    ((void (*)(id, SEL, float))gOrigPlayAtRate)(self, _cmd, rate);
}

static void ASMySetRateTime(AVPlayer *self, SEL _cmd, float rate, CMTime time, CMTime host) {
    ASRegisterPlayer(self);
    float target = ASAdRateForPlayer(self);
    if (target > rate) {
        ASRecord([NSString stringWithFormat:@"AVPlayer(setRate:time:) 广告命中 %.0fx", target]);
        rate = target;
        self.muted = YES;
    }
    ((void (*)(id, SEL, float, CMTime, CMTime))gOrigSetRateTime)(self, _cmd, rate, time, host);
}

// 有些广告 SDK 会自己把 rate 拨回 1.0，这里每 0.35 秒补一刀
static void ASStartRateWatchdog(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSTimer *timer = [NSTimer timerWithTimeInterval:0.35 repeats:YES block:^(NSTimer *t) {
            if (!ASEngineOn()) return;
            NSArray *players = nil;
            @synchronized (gPlayers) { players = gPlayers.allObjects; }
            for (AVPlayer *p in players) {
                if (p.timeControlStatus != AVPlayerTimeControlStatusPlaying) continue;
                AVPlayerItem *item = p.currentItem;
                if (!item) continue;
                Float64 d = CMTimeGetSeconds(item.duration);
                if (!isfinite(d) || d <= 0.0 || d > kAdMaxDuration) continue;
                float target = item.canPlayFastForward ? gRate : kAdRateFallback;
                if (p.rate < target - 0.01f) {
                    p.muted = YES;
                    p.rate = target;
                }
            }
        }];
        [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
    });
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

#pragma mark - 弹窗记录（广告界面大概率是 present 出来的）

static IMP gOrigPresent = NULL;

static void ASMyPresent(UIViewController *self, SEL _cmd, UIViewController *vc, BOOL animated, id completion) {
    @try {
        ASRecord([NSString stringWithFormat:@"弹窗: %@ -> %@",
                  NSStringFromClass([self class]), NSStringFromClass([vc class])]);
    } @catch (__unused NSException *e) {}
    ((void (*)(id, SEL, id, BOOL, id))gOrigPresent)(self, _cmd, vc, animated, completion);
}

#pragma mark - 诊断：抓当前界面

static void ASDumpView(UIView *view, int depth, NSMutableArray<NSString *> *lines) {
    if (!view || lines.count > 150) return;
    NSMutableString *indent = [NSMutableString string];
    for (int i = 0; i < depth && i < 8; i++) [indent appendString:@"  "];
    NSString *name = NSStringFromClass([view class]);
    NSString *extra = @"";
    if ([view isKindOfClass:NSClassFromString(@"WKWebView")]) extra = @"  <WKWebView>";
    if (view.layer && [view.layer isKindOfClass:NSClassFromString(@"AVPlayerLayer")]) extra = @"  <AVPlayerLayer>";
    [lines addObject:[NSString stringWithFormat:@"%@%@%@", indent, name, extra]];
    for (UIView *sub in view.subviews) ASDumpView(sub, depth + 1, lines);
}

static int ASCountPlayerLayers(CALayer *layer) {
    if (!layer) return 0;
    int n = [layer isKindOfClass:NSClassFromString(@"AVPlayerLayer")] ? 1 : 0;
    for (CALayer *sub in layer.sublayers) n += ASCountPlayerLayers(sub);
    return n;
}

static NSArray<NSString *> *ASAdClassCandidates(void) {
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    NSMutableArray<NSString *> *hits = [NSMutableArray array];
    if (!classes) return hits;
    NSArray<NSString *> *needles = @[@"reward", @"interstitial", @"adplayer", @"adview", @"admanager", @"splash"];
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
    return hits;
}

static NSString *ASBuildDiagnostics(void) {
    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"AdSpeeder 诊断\n当前倍速: %gx\n\n", gRate];

    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) [windows addObject:w];
    }

    [out appendFormat:@"== 窗口 %lu 个 ==\n", (unsigned long)windows.count];
    for (UIWindow *w in windows) {
        [out appendFormat:@"Lv%.0f %@  playerLayer=%d\n",
         w.windowLevel, NSStringFromClass([w class]), ASCountPlayerLayers(w.layer)];
    }

    UIWindow *key = nil;
    for (UIWindow *w in windows) { if (w.isKeyWindow) { key = w; break; } }
    if (!key) key = windows.lastObject;

    if (key) {
        [out appendString:@"\n== 弹出的控制器链 ==\n"];
        UIViewController *vc = key.rootViewController;
        int guard = 0;
        while (vc && guard++ < 8) {
            [out appendFormat:@"%@\n", NSStringFromClass([vc class])];
            vc = vc.presentedViewController;
        }

        [out appendString:@"\n== 视图层级 ==\n"];
        NSMutableArray<NSString *> *lines = [NSMutableArray array];
        ASDumpView(key.rootViewController.view, 0, lines);
        [out appendFormat:@"%@\n", [lines componentsJoinedByString:@"\n"]];
    }

    [out appendString:@"\n== 名字像广告的类 ==\n"];
    NSArray *cands = ASAdClassCandidates();
    [out appendFormat:@"%@\n", cands.count ? [cands componentsJoinedByString:@"\n"] : @"(无)"];

    return out;
}

#pragma mark - 诊断面板

@interface ASDiagController : UIViewController
@property (nonatomic, copy) NSString *body;
@property (nonatomic, copy) NSString *heading;
@end

@implementation ASDiagController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0.07 alpha:0.98];
    CGRect b = self.view.bounds;
    CGFloat top = 52, bottomBar = 64;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, top, b.size.width - 32, 28)];
    title.text = self.heading ?: @"诊断";
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    [self.view addSubview:title];

    UITextView *tv = [[UITextView alloc] initWithFrame:CGRectMake(12, top + 36,
                                                                 b.size.width - 24,
                                                                 b.size.height - top - 36 - bottomBar - 10)];
    tv.text = self.body ?: @"";
    tv.editable = NO;
    tv.backgroundColor = [UIColor colorWithWhite:0.14 alpha:1];
    tv.textColor = [UIColor colorWithWhite:0.92 alpha:1];
    tv.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    tv.layer.cornerRadius = 8;
    tv.textContainerInset = UIEdgeInsetsMake(10, 8, 10, 8);
    [self.view addSubview:tv];

    CGFloat by = b.size.height - bottomBar + 4;
    UIButton *copy = [UIButton buttonWithType:UIButtonTypeSystem];
    copy.frame = CGRectMake(16, by, (b.size.width - 44) / 2, 44);
    [copy setTitle:@"复制全部" forState:UIControlStateNormal];
    copy.backgroundColor = [UIColor colorWithWhite:0.22 alpha:1];
    [copy setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    copy.layer.cornerRadius = 10;
    [copy addTarget:self action:@selector(doCopy) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:copy];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(b.size.width / 2 + 6, by, (b.size.width - 44) / 2, 44);
    [close setTitle:@"关闭" forState:UIControlStateNormal];
    close.backgroundColor = [UIColor colorWithWhite:0.22 alpha:1];
    [close setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    close.layer.cornerRadius = 10;
    [close addTarget:self action:@selector(doClose) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:close];
}

- (void)doCopy {
    UIPasteboard.generalPasteboard.string = self.body ?: @"";
    UIButton *b = nil;
    for (UIView *v in self.view.subviews) if ([v isKindOfClass:[UIButton class]]) { b = (UIButton *)v; break; }
    [b setTitle:@"已复制 ✓" forState:UIControlStateNormal];
}

- (void)doClose { [self dismissViewControllerAnimated:YES completion:nil]; }

@end

#pragma mark - 悬浮球

static const float kSpeedSteps[] = {0.0f, 2.0f, 4.0f, 8.0f, 16.0f, 32.0f};
static const int   kSpeedCount   = 6;

@interface ASFloatingView : UIView
@property (nonatomic, strong) UILabel *label;
@end

@interface ASOverlayWindow : UIWindow
@end

@implementation ASOverlayWindow
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
        gBall.backgroundColor = [UIColor colorWithRed:0.09 green:0.62 blue:0.35 alpha:0.86];
    } else {
        gBall.label.text = @"关";
        gBall.backgroundColor = [UIColor colorWithWhite:0.15 alpha:0.78];
    }
}

static void ASSetRate(float rate, BOOL persist) {
    gRate = rate;
    if (persist) ASSavePrefs();
    ASRefreshBall();
    ASPushRateToAllWebViews();
    NSLog(@"[AdSpeeder] rate -> %gx (enabled=%d)", gRate, ASEngineOn());
    ASRecord([NSString stringWithFormat:@"切换到 %gx", gRate]);
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
                                                                  message:@"倍速 / 诊断"
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
    [sheet addAction:[UIAlertAction actionWithTitle:@"🔍 抓取当前界面" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        ASDiagController *vc = [[ASDiagController alloc] init];
        vc.heading = @"当前界面（广告播放时抓）";
        vc.body = ASBuildDiagnostics();
        [root presentViewController:vc animated:YES completion:nil];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"📋 查看事件记录" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSArray *snapshot = nil;
        @synchronized (gEvents) { snapshot = [gEvents copy]; }
        ASDiagController *vc = [[ASDiagController alloc] init];
        vc.heading = @"事件记录";
        vc.body = snapshot.count ? [snapshot componentsJoinedByString:@"\n"] : @"(暂无记录)";
        [root presentViewController:vc animated:YES completion:nil];
    }]];
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
    if (!scene) return;

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
    ASRecord(@"悬浮球已就绪");
    NSLog(@"[AdSpeeder] overlay ready at %.0f,%.0f", x, y);
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
    gPlayers  = [NSHashTable weakObjectsHashTable];
    gEvents   = [NSMutableArray array];
    ASLoadPrefs();

    Class avPlayer = objc_getClass("AVPlayer");
    if (avPlayer) {
        ASSwizzle(avPlayer, @selector(setRate:), (IMP)ASMySetRate, &gOrigSetRate);
        ASSwizzle(avPlayer, @selector(play), (IMP)ASMyPlay, &gOrigPlay);
        ASSwizzle(avPlayer, @selector(playImmediatelyAtRate:), (IMP)ASMyPlayAtRate, &gOrigPlayAtRate);
        ASSwizzle(avPlayer, @selector(setRate:time:atHostTime:), (IMP)ASMySetRateTime, &gOrigSetRateTime);
    }

    Class wk = objc_getClass("WKWebView");
    if (wk) {
        ASSwizzle(wk, @selector(initWithFrame:configuration:),
                  (IMP)ASMyInitWithFrameConfig, &gOrigInitWithFrameConfig);
    }

    Class vcc = objc_getClass("UIViewController");
    if (vcc) {
        ASSwizzle(vcc, @selector(presentViewController:animated:completion:),
                  (IMP)ASMyPresent, &gOrigPresent);
    }

    ASStartRateWatchdog();

    NSLog(@"[AdSpeeder] installed (setRate=%d, play=%d, atRate=%d, setRateTime=%d, wk=%d, present=%d, rate=%gx)",
          gOrigSetRate != NULL, gOrigPlay != NULL, gOrigPlayAtRate != NULL,
          gOrigSetRateTime != NULL, gOrigInitWithFrameConfig != NULL, gOrigPresent != NULL, gRate);

    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ ASScheduleOverlay(15); });
    }];

    if (UIApplication.sharedApplication) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ ASScheduleOverlay(15); });
    }
}
