// AdSpeeder v3 - Alipay mini-game rewarded-video ad accelerator
// 纯 objc runtime swizzling，不带 substrate / logos 依赖，TrollFools 注入可加载。
//
// v3 相对 v2 的变化：
//   1. 诊断改成"全窗口采集"（v2 只抓 keyWindow，结果抓到的是悬浮球自己）
//   2. 广告视图自动捕获（0.4s 巡检，首次出现即快照，不用卡时间手点）
//   3. 通用倍速 hook：扫描所有"播放器类"的 setRate:/setPlaybackRate:/setSpeed:，
//      不再依赖 AVPlayer 一个入口（支付宝广告 SDK 用的不是系统播放器）
//   4. 广告类方法自省：把 AdRewardVC / AdRewardedVideoView 这类类的
//      image 路径、父类链、方法名直接打印出来，用于定位真正的关闭/回调入口
//   5. 秒过按钮：对已知 AVPlayer 直接 seek 到片尾

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

static float gRate = 16.0f;                     // 0 = 关闭
static NSHashTable<WKWebView *> *gWebViews = nil;
static NSHashTable<AVPlayer *> *gPlayers  = nil;
static NSMutableArray<NSString *> *gEvents = nil;
static NSMutableSet<NSString *> *gSeenAdClasses = nil;
static NSMutableSet<NSString *> *gAdoptedWebViews = nil;
static NSString *gLastAdSnapshot = nil;
static NSTimeInterval gAdSeenAt = 0;
static int gTimerHits = 0;

#pragma mark - 基础

static void ASRecord(NSString *line);
static void ASRegisterPlayer(AVPlayer *p);
static void ASBoostPlayerNow(AVPlayer *p);
static void ASPushRateToWebView(WKWebView *webView);
static void ASInstallGenericRateHooks(void);

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
    if (outOrig) *outOrig = method_getImplementation(m);
    method_setImplementation(m, newImp);
    return YES;
}

static BOOL ASSwizzleClass(Class meta, SEL sel, IMP newImp, IMP *outOrig) {
    Method m = class_getInstanceMethod(meta, sel);   // meta 的实例方法 == 类方法
    if (!m) return NO;
    if (outOrig) *outOrig = method_getImplementation(m);
    method_setImplementation(m, newImp);
    return YES;
}

static BOOL ASEngineOn(void) { return gRate > 1.0f; }

#pragma mark - 事件记录

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
        if (gEvents.count > 400) [gEvents removeObjectAtIndex:0];
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

static void ASPushRateToAllWebViews(void) {
    NSArray *snapshot = nil;
    @synchronized (gWebViews) { snapshot = gWebViews.allObjects; }
    for (WKWebView *w in snapshot) ASPushRateToWebView(w);
}

#pragma mark - 名字启发式

// 判断类名是否像"广告"：AdRewardView / AdRewardedVideoView / BEEAdView 都命中，
// 但不能把 LoadManager / HeadView 这种误判成广告。
static BOOL ASLooksLikeAdName(NSString *name) {
    if (name.length < 3) return NO;
    NSString *l = name.lowercaseString;
    if ([l containsString:@"reward"] || [l containsString:@"interstitial"] || [l containsString:@"advert"]) return YES;
    if ([l hasPrefix:@"ad"] && [[NSCharacterSet uppercaseLetterCharacterSet] characterIsMember:[name characterAtIndex:2]]) return YES;
    if ([l containsString:@"adview"] || [l containsString:@"adplayer"] ||
        [l containsString:@"admanager"] || [l containsString:@"adcontroller"] ||
        [l containsString:@"adreward"]) return YES;
    return NO;
}

static BOOL ASLooksLikePlayerName(NSString *name) {
    NSString *l = name.lowercaseString;
    NSArray *kw = @[@"player", @"video", @"media", @"ijk", @"ffmpeg",
                    @"vod", @"adview", @"adreward", @"aliyun", @"mpmovie", @"admanager"];
    for (NSString *k in kw) if ([l containsString:k]) return YES;
    return NO;
}

static NSString *ASImagePath(Class cls) {
    const char *img = class_getImageName(cls);
    if (!img) return @"(未知)";
    NSString *p = [NSString stringWithUTF8String:img] ?: @"(未知)";
    NSArray *parts = [p componentsSeparatedByString:@"/"];
    if (parts.count >= 2) return [NSString stringWithFormat:@"%@/%@", parts[parts.count - 2], parts.lastObject];
    return p;
}

static NSString *ASClassChain(Class cls) {
    NSMutableArray *names = [NSMutableArray array];
    Class c = class_getSuperclass(cls);
    for (int i = 0; i < 4 && c; i++) {
        [names addObject:NSStringFromClass(c)];
        c = class_getSuperclass(c);
    }
    return [names componentsJoinedByString:@" → "];
}

static NSString *ASMethodDigest(Class cls, NSUInteger limit) {
    unsigned int n = 0;
    Method *ms = class_copyMethodList(cls, &n);
    NSMutableArray *hits = [NSMutableArray array];
    NSArray *keys = @[@"play", @"rate", @"speed", @"seek", @"close", @"finish",
                      @"complet", @"reward", @"dismiss", @"end", @"countdown",
                      @"timer", @"video", @"start", @"stop", @"callback", @"fire"];
    for (unsigned int i = 0; i < n; i++) {
        NSString *sel = NSStringFromSelector(method_getName(ms[i]));
        NSString *low = sel.lowercaseString;
        for (NSString *k in keys) {
            if ([low containsString:k]) { [hits addObject:sel]; break; }
        }
    }
    if (ms) free(ms);
    if (hits.count > limit) hits = [[hits subarrayWithRange:NSMakeRange(0, limit)] mutableCopy];
    return hits.count ? [hits componentsJoinedByString:@", "] : @"(无匹配方法)";
}

#pragma mark - 窗口与视图遍历

static NSArray<UIWindow *> *ASAllWindows(void) {
    NSMutableArray *out = [NSMutableArray array];
    @try {
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
            if (![s isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)s).windows) {
                if (![out containsObject:w]) [out addObject:w];
            }
        }
    } @catch (__unused NSException *e) {}
    return out;
}

static BOOL ASIsOwnWindow(UIWindow *w) {
    return [NSStringFromClass([w class]) isEqualToString:@"ASOverlayWindow"];
}

static void ASWalkViews(UIView *v, int depth, void (^visit)(UIView *, int)) {
    if (!v || depth > 30) return;
    visit(v, depth);
    for (UIView *s in [v.subviews copy]) ASWalkViews(s, depth + 1, visit);
}

static void ASWalkLayers(CALayer *l, int depth, void (^visit)(CALayer *, int)) {
    if (!l || depth > 30) return;
    visit(l, depth);
    for (CALayer *s in [l.sublayers copy]) ASWalkLayers(s, depth + 1, visit);
}

static int ASCountPlayerLayers(CALayer *layer) {
    if (!layer) return 0;
    int n = [layer isKindOfClass:NSClassFromString(@"AVPlayerLayer")] ? 1 : 0;
    for (CALayer *sub in [layer.sublayers copy]) n += ASCountPlayerLayers(sub);
    return n;
}

static void ASDumpViewTree(UIView *view, int depth, int maxDepth, NSMutableArray<NSString *> *lines) {
    if (!view || depth > maxDepth || lines.count > 160) return;
    NSMutableString *indent = [NSMutableString string];
    for (int i = 0; i < depth && i < 10; i++) [indent appendString:@"  "];
    NSMutableString *extra = [NSMutableString string];
    if ([view isKindOfClass:[WKWebView class]]) [extra appendString:@" <WKWebView>"];
    if ([view.layer isKindOfClass:NSClassFromString(@"AVPlayerLayer")]) [extra appendString:@" <AVPlayerLayer>"];
    if (ASLooksLikeAdName(NSStringFromClass([view class]))) [extra appendString:@" <AD>"];
    if (!view.hidden && view.alpha < 0.05) [extra appendString:@" (alpha≈0)"];
    CGRect f = view.frame;
    [lines addObject:[NSString stringWithFormat:@"%@%@ %.0fx%.0f%@", indent,
                      NSStringFromClass([view class]), f.size.width, f.size.height, extra]];
    for (UIView *sub in [view.subviews copy]) ASDumpViewTree(sub, depth + 1, maxDepth, lines);
}

static void ASCollectAdViews(UIView *root, NSMutableArray<UIView *> *out) {
    ASWalkViews(root, 0, ^(UIView *v, int d) {
        if (ASLooksLikeAdName(NSStringFromClass([v class]))) [out addObject:v];
    });
}

#pragma mark - AVPlayer 路径

static IMP gOrigSetRate = NULL;
static IMP gOrigPlay = NULL;
static IMP gOrigPlayAtRate = NULL;
static IMP gOrigSetRateTime = NULL;
static IMP gOrigSetPVPlayer = NULL;

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

static void ASBoostPlayerNow(AVPlayer *p) {
    if (!p) return;
    float target = ASAdRateForPlayer(p);
    if (target <= 1.0f) return;
    @try {
        p.muted = YES;
        p.rate = target;
    } @catch (__unused NSException *e) {}
}

static void ASMySetRate(AVPlayer *self, SEL _cmd, float rate) {
    ASRegisterPlayer(self);
    if (rate > 0.0f) {
        float target = ASAdRateForPlayer(self);
        if (target > rate) {
            Float64 d = CMTimeGetSeconds(self.currentItem.duration);
            ASRecord([NSString stringWithFormat:@"AVPlayer 命中 %.0fx (%.1fs)", target, d]);
            rate = target;
            self.muted = YES;
        }
    }
    ((void (*)(id, SEL, float))gOrigSetRate)(self, _cmd, rate);
}

static void ASMyPlay(AVPlayer *self, SEL _cmd) {
    ASRegisterPlayer(self);
    ((void (*)(id, SEL))gOrigPlay)(self, _cmd);
    ASBoostPlayerNow(self);
}

static void ASMyPlayAtRate(AVPlayer *self, SEL _cmd, float rate) {
    ASRegisterPlayer(self);
    float target = ASAdRateForPlayer(self);
    if (target > rate) {
        ASRecord([NSString stringWithFormat:@"AVPlayer(playImmediately) 命中 %.0fx", target]);
        rate = target;
        self.muted = YES;
    }
    ((void (*)(id, SEL, float))gOrigPlayAtRate)(self, _cmd, rate);
}

static void ASMySetRateTime(AVPlayer *self, SEL _cmd, float rate, CMTime time, CMTime host) {
    ASRegisterPlayer(self);
    float target = ASAdRateForPlayer(self);
    if (target > rate) {
        ASRecord([NSString stringWithFormat:@"AVPlayer(setRate:time:) 命中 %.0fx", target]);
        rate = target;
        self.muted = YES;
    }
    ((void (*)(id, SEL, float, CMTime, CMTime))gOrigSetRateTime)(self, _cmd, rate, time, host);
}

static void ASMySetPVPlayer(id self, SEL _cmd, AVPlayer *player) {
    ASRegisterPlayer(player);
    ((void (*)(id, SEL, id))gOrigSetPVPlayer)(self, _cmd, player);
    ASBoostPlayerNow(player);
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

#pragma mark - 通用倍速 hook（核心新增）

static NSMutableDictionary<NSString *, NSValue *> *gGenOrig = nil;
static NSMutableSet<NSString *> *gGenHooked = nil;
static NSMutableSet<NSString *> *gGenReported = nil;

// 取第一个参数的类型字符：v24@0:8f16 → 'f'
static char ASArgType(const char *enc) {
    if (!enc) return 0;
    const char *c = enc;
    while (*c && *c != ':') c++;
    if (*c == ':') c++;
    while (*c >= '0' && *c <= '9') c++;
    return *c;
}

static IMP ASGenOrigIMP(id self, SEL _cmd) {
    for (Class c = object_getClass(self); c; c = class_getSuperclass(c)) {
        NSString *k = [NSString stringWithFormat:@"%s|%s", class_getName(c), sel_getName(_cmd)];
        NSValue *v = gGenOrig[k];
        if (v) return (IMP)v.pointerValue;
    }
    return NULL;
}

// 幂等改写：1.0 / 0.5 → 目标倍速；已经是 16 就原样透传（避免父子类重复 hook 叠乘）
static float ASBoostF(float in) {
    if (!ASEngineOn()) return in;
    if (in <= 0.05f) return in;
    if (in <= 1.5f) return gRate;
    return in;
}

static void ASGenSetRateF(id self, SEL _cmd, float rate) {
    IMP orig = ASGenOrigIMP(self, _cmd);
    if (!orig) return;
    float r = ASBoostF(rate);
    if (fabsf(r - rate) > 0.001f) {
        NSString *key = [NSString stringWithFormat:@"%@|%s", NSStringFromClass(object_getClass(self)), sel_getName(_cmd)];
        if (![gGenReported containsObject:key]) {
            [gGenReported addObject:key];
            ASRecord([NSString stringWithFormat:@"通用倍速: %@ %s  %g → %g",
                      NSStringFromClass(object_getClass(self)), sel_getName(_cmd), rate, r]);
        }
    }
    ((void (*)(id, SEL, float))orig)(self, _cmd, r);
}

static void ASGenSetRateD(id self, SEL _cmd, double rate) {
    IMP orig = ASGenOrigIMP(self, _cmd);
    if (!orig) return;
    double r = (double)ASBoostF((float)rate);
    ((void (*)(id, SEL, double))orig)(self, _cmd, r);
}

static void ASInstallGenericRateHooks(void) {
    if (!gGenOrig) {
        gGenOrig = [NSMutableDictionary dictionary];
        gGenHooked = [NSMutableSet set];
        gGenReported = [NSMutableSet set];
    }
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    if (!classes) return;

    NSArray *selNames = @[@"setRate:", @"setPlaybackRate:", @"setSpeed:",
                          @"setPlayRate:", @"setPlayerRate:"];
    int hooked = 0;

    for (unsigned int i = 0; i < count; i++) {
        Class cls = classes[i];
        const char *nm = class_getName(cls);
        if (!nm) continue;
        NSString *cn = [NSString stringWithUTF8String:nm];
        if (!ASLooksLikePlayerName(cn)) continue;
        if ([cn isEqualToString:@"AVPlayer"]) continue;

        for (NSString *selName in selNames) {
            NSString *key = [NSString stringWithFormat:@"%@|%@", cn, selName];
            if ([gGenHooked containsObject:key]) continue;
            SEL sel = NSSelectorFromString(selName);

            // 只处理本类自己声明的方法，继承来的留给祖先类去 hook
            Method own = NULL;
            unsigned int mc = 0;
            Method *list = class_copyMethodList(cls, &mc);
            for (unsigned int k = 0; k < mc; k++) {
                if (method_getName(list[k]) == sel) { own = list[k]; break; }
            }
            if (list) free(list);
            if (!own) continue;

            char t = ASArgType(method_getTypeEncoding(own));
            if (t != 'f' && t != 'd') continue;

            IMP orig = method_getImplementation(own);
            [gGenOrig setObject:[NSValue valueWithPointer:orig] forKey:key];
            [gGenHooked addObject:key];
            method_setImplementation(own, (t == 'f') ? (IMP)ASGenSetRateF : (IMP)ASGenSetRateD);
            hooked++;
        }
    }
    free(classes);
    if (hooked > 0) ASRecord([NSString stringWithFormat:@"通用倍速 hook +%d 个", hooked]);
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

static float gPushedRate = -1.0f;   // 上次推给 JS 的倍速，避免每 0.4 秒重复 eval

static void ASPushRateToWebView(WKWebView *webView) {
    if (!webView) return;
    NSString *js = [NSString stringWithFormat:@"window.__asRate=%g;", gRate];
    @try { [webView evaluateJavaScript:js completionHandler:nil]; } @catch (__unused NSException *e) {}
    gPushedRate = gRate;
}

static void ASAdoptWebView(WKWebView *wv) {
    if (!wv) return;
    @synchronized (gWebViews) { [gWebViews addObject:wv]; }
    if (!gAdoptedWebViews) gAdoptedWebViews = [NSMutableSet set];
    NSString *key = [NSString stringWithFormat:@"%p", (void *)wv];
    BOOL first = ![gAdoptedWebViews containsObject:key];
    if (first) {
        [gAdoptedWebViews addObject:key];
        @try {
            NSString *seed = [NSString stringWithFormat:@"window.__asRate=%g;", gRate];
            [wv evaluateJavaScript:seed completionHandler:nil];
            [wv evaluateJavaScript:kBoostJS completionHandler:nil];
        } @catch (__unused NSException *e) {}
        ASPushRateToWebView(wv);
    } else if (fabsf(gRate - gPushedRate) > 0.01f) {
        ASPushRateToWebView(wv);
    }
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
    if (result) ASAdoptWebView((WKWebView *)result);
    return result;
}

#pragma mark - 弹窗记录

static IMP gOrigPresent = NULL;

static void ASMyPresent(UIViewController *self, SEL _cmd, UIViewController *vc, BOOL animated, id completion) {
    @try {
        ASRecord([NSString stringWithFormat:@"弹窗: %@ → %@",
                  NSStringFromClass([self class]), NSStringFromClass([vc class])]);
    } @catch (__unused NSException *e) {}
    ((void (*)(id, SEL, id, BOOL, id))gOrigPresent)(self, _cmd, vc, animated, completion);
}

#pragma mark - 广告巡检（自动抓，不用卡时间）

static NSString *ASSnapshotOfView(UIView *v) {
    NSMutableString *s = [NSMutableString string];
    Class cls = [v class];
    [s appendFormat:@"%@  frame=%@\n", NSStringFromClass(cls), NSStringFromCGRect(v.frame)];
    [s appendFormat:@"window: %@  level=%.0f\n",
     NSStringFromClass([v.window class]), v.window.windowLevel];
    [s appendFormat:@"image: %@\n", ASImagePath(cls)];
    [s appendFormat:@"super: %@\n", ASClassChain(cls)];
    [s appendFormat:@"methods: %@\n", ASMethodDigest(cls, 40)];
    NSMutableArray *lines = [NSMutableArray array];
    ASDumpViewTree(v, 0, 10, lines);
    [s appendString:[lines componentsJoinedByString:@"\n"]];
    return s;
}

static void ASScanOnce(void) {
    if (!ASIsAlipay()) return;
    NSArray<UIWindow *> *wins = ASAllWindows();
    if (!gSeenAdClasses) gSeenAdClasses = [NSMutableSet set];
    NSMutableArray<UIView *> *ads = [NSMutableArray array];
    NSMutableArray<UIView *> *visibleAds = [NSMutableArray array];

    for (UIWindow *w in wins) {
        if (ASIsOwnWindow(w)) continue;
        BOOL winVisible = !w.hidden && w.alpha > 0.01;
        ASWalkViews(w, 0, ^(UIView *v, int d) {
            if ([v isKindOfClass:[WKWebView class]]) ASAdoptWebView((WKWebView *)v);
            if (ASLooksLikeAdName(NSStringFromClass([v class]))) {
                [ads addObject:v];
                if (winVisible && !v.hidden && v.alpha > 0.01) [visibleAds addObject:v];
            }
        });
        ASWalkLayers(w.layer, 0, ^(CALayer *l, int d) {
            if ([l isKindOfClass:NSClassFromString(@"AVPlayerLayer")]) {
                AVPlayer *p = [(AVPlayerLayer *)l player];
                if (p) ASRegisterPlayer(p);
            }
        });
    }

    for (UIView *v in ads) {
        NSString *cn = NSStringFromClass([v class]);
        if ([gSeenAdClasses containsObject:cn]) continue;
        [gSeenAdClasses addObject:cn];
        ASRecord([NSString stringWithFormat:@"出现广告视图: %@  %@", cn,
                  ASImagePath([v class])]);
        // 新广告类出现，说明新 SDK 模块可能刚加载，补一轮通用 hook
        ASInstallGenericRateHooks();
    }

    // 快照只抓"正在展示"的那一个，广告关掉后不会被隐藏视图污染
    if (visibleAds.count > 0) {
        gAdSeenAt = [NSDate timeIntervalSinceReferenceDate];
        static NSTimeInterval lastSnap = 0;
        NSTimeInterval now = gAdSeenAt;
        if (now - lastSnap > 2.0) {
            lastSnap = now;
            UIView *best = visibleAds.lastObject;
            for (UIView *v in visibleAds) {
                if (v.window.windowLevel >= 1000) { best = v; break; }
            }
            gLastAdSnapshot = ASSnapshotOfView(best);
        }
    }
}

#pragma mark - 广告倒计时压缩

// 自研广告 SDK 的"还剩 15 秒"通常是 NSTimer 每秒减一，跟视频进度无关。
// 只在广告视图出现后的 6 秒窗口内、且 interval 在 0.5~3 秒的重复计时器上动手，
// 避免影响支付宝自身的常驻计时器（那些在广告之前就创建好了）。
static NSTimeInterval ASCompressInterval(NSTimeInterval ti, BOOL repeats) {
    if (!ASEngineOn() || !repeats) return ti;
    if (gAdSeenAt <= 0) return ti;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - gAdSeenAt > 6.0) return ti;
    if (ti < 0.5 || ti > 3.0) return ti;
    float div = gRate / 2.0f;
    if (div < 2.0f) div = 2.0f;
    if (div > 10.0f) div = 10.0f;
    gTimerHits++;
    return ti / div;
}

static IMP gOrigTimerTarget = NULL;
static IMP gOrigTimerBlock = NULL;
static IMP gOrigTimerTarget2 = NULL;
static IMP gOrigTimerBlock2 = NULL;

static id ASMyScheduledTimerTarget(id self, SEL _cmd, NSTimeInterval ti, id target, SEL sel, id info, BOOL repeats) {
    return ((id (*)(id, SEL, NSTimeInterval, id, SEL, id, BOOL))gOrigTimerTarget)
        (self, _cmd, ASCompressInterval(ti, repeats), target, sel, info, repeats);
}

static id ASMyScheduledTimerBlock(id self, SEL _cmd, NSTimeInterval ti, BOOL repeats, id block) {
    return ((id (*)(id, SEL, NSTimeInterval, BOOL, id))gOrigTimerBlock)
        (self, _cmd, ASCompressInterval(ti, repeats), repeats, block);
}

static id ASMyTimerTarget(id self, SEL _cmd, NSTimeInterval ti, id target, SEL sel, id info, BOOL repeats) {
    return ((id (*)(id, SEL, NSTimeInterval, id, SEL, id, BOOL))gOrigTimerTarget2)
        (self, _cmd, ASCompressInterval(ti, repeats), target, sel, info, repeats);
}

static id ASMyTimerBlock(id self, SEL _cmd, NSTimeInterval ti, BOOL repeats, id block) {
    return ((id (*)(id, SEL, NSTimeInterval, BOOL, id))gOrigTimerBlock2)
        (self, _cmd, ASCompressInterval(ti, repeats), repeats, block);
}

static void ASInstallTimerHooks(void) {
    Class t = objc_getClass("NSTimer");
    if (!t) return;
    Class meta = object_getClass(t);
    if (!gOrigTimerTarget) {
        ASSwizzleClass(meta, @selector(scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:),
                       (IMP)ASMyScheduledTimerTarget, &gOrigTimerTarget);
    }
    if (!gOrigTimerBlock) {
        ASSwizzleClass(meta, @selector(scheduledTimerWithTimeInterval:repeats:block:),
                       (IMP)ASMyScheduledTimerBlock, &gOrigTimerBlock);
    }
    if (!gOrigTimerTarget2) {
        ASSwizzleClass(meta, @selector(timerWithTimeInterval:target:selector:userInfo:repeats:),
                       (IMP)ASMyTimerTarget, &gOrigTimerTarget2);
    }
    if (!gOrigTimerBlock2) {
        ASSwizzleClass(meta, @selector(timerWithTimeInterval:repeats:block:),
                       (IMP)ASMyTimerBlock, &gOrigTimerBlock2);
    }
}

static void ASStartAdMonitor(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSTimer *t = [NSTimer timerWithTimeInterval:0.4 repeats:YES block:^(NSTimer *timer) {
            @try { ASScanOnce(); } @catch (__unused NSException *e) {}
        }];
        [[NSRunLoop mainRunLoop] addTimer:t forMode:NSRunLoopCommonModes];
    });
}

#pragma mark - 秒过当前广告

static int ASForceFinishPlayers(NSMutableString *detail) {
    NSMutableArray<AVPlayer *> *players = [NSMutableArray array];
    @synchronized (gPlayers) { [players addObjectsFromArray:gPlayers.allObjects]; }
    for (UIWindow *w in ASAllWindows()) {
        ASWalkLayers(w.layer, 0, ^(CALayer *l, int d) {
            if ([l isKindOfClass:NSClassFromString(@"AVPlayerLayer")]) {
                AVPlayer *p = [(AVPlayerLayer *)l player];
                if (p && ![players containsObject:p]) [players addObject:p];
            }
        });
    }

    int hit = 0;
    for (AVPlayer *p in players) {
        AVPlayerItem *item = p.currentItem;
        if (!item) continue;
        Float64 dur = CMTimeGetSeconds(item.duration);
        CMTime target;
        if (isfinite(dur) && dur > 0) {
            if (dur > kAdMaxDuration) continue;   // 不是广告，别乱跳
            target = CMTimeMakeWithSeconds(MAX(0.0, dur - 0.15), 600);
        } else {
            target = CMTimeMakeWithSeconds(3600.0, 600);  // 时长未知：直接怼到片尾
        }
        @try {
            p.muted = YES;
            [p seekToTime:target];
            p.rate = ASEngineOn() ? gRate : 1.0f;
            hit++;
            if (detail) [detail appendFormat:@"AVPlayer %.0fx  seek→%.1fs (总长 %.1fs)\n",
                         p.rate, CMTimeGetSeconds(target), dur];
        } @catch (__unused NSException *e) {}
    }
    if (hit == 0 && detail) {
        [detail appendString:@"没有找到 AVPlayer。说明这条广告不是系统播放器渲染的，\n"];
        [detail appendString:@"需要看「🧬 广告类方法」里的类名，改成 hook 广告 SDK 自己。\n"];
    }
    ASRecord([NSString stringWithFormat:@"秒过：处理了 %d 个播放器", hit]);
    return hit;
}

#pragma mark - 诊断报告

static NSString *ASBuildInterfaceReport(void) {
    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"AdSpeeder 诊断 v3\n倍速: %gx (%@)   通用hook: %lu   计时器压缩: %d\n\n",
     gRate, ASEngineOn() ? @"开" : @"关", (unsigned long)gGenHooked.count, gTimerHits];

    if (gLastAdSnapshot.length) {
        [out appendFormat:@"== 最近抓到的广告视图 ==\n%@\n\n", gLastAdSnapshot];
    }

    NSArray<UIWindow *> *wins = ASAllWindows();
    [out appendFormat:@"== 窗口 %lu 个 ==\n", (unsigned long)wins.count];

    NSMutableArray<NSString *> *trees = [NSMutableArray array];
    for (UIWindow *w in wins) {
        if (ASIsOwnWindow(w)) {
            [out appendString:@"Lv--- ASOverlayWindow (悬浮球自己，忽略)\n"];
            continue;
        }
        NSMutableArray<UIView *> *ads = [NSMutableArray array];
        ASCollectAdViews(w, ads);
        int pl = ASCountPlayerLayers(w.layer);
        [out appendFormat:@"Lv%.0f %@  广告视图=%lu 播放层=%d  key=%d\n",
         w.windowLevel, NSStringFromClass([w class]), (unsigned long)ads.count, pl,
         (int)w.isKeyWindow];

        BOOL interesting = (ads.count > 0 || pl > 0 || w.windowLevel >= 1000);
        if (interesting && w.rootViewController.view) {
            NSMutableArray<NSString *> *lines = [NSMutableArray array];
            [lines addObject:[NSString stringWithFormat:@"-- %@ 的视图树 --", NSStringFromClass([w class])]];
            ASDumpViewTree(w.rootViewController.view, 0, 12, lines);
            [trees addObject:[lines componentsJoinedByString:@"\n"]];
        }
    }
    if (trees.count) {
        [out appendString:@"\n"];
        [out appendFormat:@"%@\n", [trees componentsJoinedByString:@"\n\n"]];
    }
    return out;
}

static int ASAdNameScore(NSString *n) {
    NSString *l = n.lowercaseString;
    if ([n hasPrefix:@"Ad"] && n.length > 2 &&
        [[NSCharacterSet uppercaseLetterCharacterSet] characterIsMember:[n characterAtIndex:2]]) return 0;
    if ([l containsString:@"reward"] || [l containsString:@"interstitial"]) return 1;
    if ([l containsString:@"adview"] || [l containsString:@"admanager"] ||
        [l containsString:@"adplayer"] || [l containsString:@"adcontroller"]) return 1;
    if ([n hasPrefix:@"BEE"] || [l containsString:@"tinyapp"]) return 2;
    return 3;
}

static NSString *ASBuildAdClassReport(void) {
    NSMutableString *out = [NSMutableString string];
    [out appendString:@"广告类方法（用来定位真正的关闭/回调入口）\n\n"];

    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (unsigned int i = 0; i < count; i++) {
        const char *nm = class_getName(classes[i]);
        if (!nm) continue;
        NSString *s = [NSString stringWithUTF8String:nm];
        if (!ASLooksLikeAdName(s)) continue;
        if ([s hasPrefix:@"_"]) continue;
        [names addObject:s];
    }
    if (classes) free(classes);

    // 按"像不像自家广告 SDK"排序，别让系统类（AFInterstitial、PK…）把名额占满
    NSArray *sorted = [names sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        int sa = ASAdNameScore(a), sb = ASAdNameScore(b);
        if (sa != sb) return sa < sb ? NSOrderedAscending : NSOrderedDescending;
        return [a compare:b];
    }];

    NSUInteger limit = MIN(sorted.count, (NSUInteger)45);
    for (NSUInteger i = 0; i < limit; i++) {
        NSString *n = sorted[i];
        Class cls = NSClassFromString(n);
        if (!cls) continue;
        [out appendFormat:@"%@\n  image: %@\n  super: %@\n  %@\n",
         n, ASImagePath(cls), ASClassChain(cls), ASMethodDigest(cls, 18)];
    }
    if (sorted.count > limit) [out appendFormat:@"\n… 还有 %lu 个，已省略\n",
                               (unsigned long)(sorted.count - limit)];
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
    tv.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
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
    for (UIView *v in self.view.subviews) {
        if ([v isKindOfClass:[UIButton class]]) {
            [(UIButton *)v setTitle:@"已复制 ✓" forState:UIControlStateNormal];
            break;
        }
    }
}

- (void)doClose { [self dismissViewControllerAnimated:YES completion:nil]; }

@end

#pragma mark - 悬浮球

static const float kSpeedSteps[] = {0.0f, 2.0f, 4.0f, 8.0f, 16.0f, 32.0f};
static const int   kSpeedCount   = 6;

@interface ASOverlayWindow : UIWindow
@end

@implementation ASOverlayWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *v = [super hitTest:point withEvent:event];
    if (v == self || v == self.rootViewController.view) return nil;
    return v;
}
@end

@interface ASFloatingView : UIView
@property (nonatomic, strong) UILabel *label;
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

    [sheet addAction:[UIAlertAction actionWithTitle:@"⚡ 秒过当前广告" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSMutableString *detail = [NSMutableString string];
        (void)ASForceFinishPlayers(detail);
        ASDiagController *vc = [[ASDiagController alloc] init];
        vc.heading = @"秒过结果";
        vc.body = detail.length ? detail : @"(无输出)";
        [root presentViewController:vc animated:YES completion:nil];
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"🔍 抓取当前界面" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        ASDiagController *vc = [[ASDiagController alloc] init];
        vc.heading = @"界面 / 窗口 / 播放层";
        vc.body = ASBuildInterfaceReport();
        [root presentViewController:vc animated:YES completion:nil];
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"🧬 广告类方法" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        ASDiagController *vc = [[ASDiagController alloc] init];
        vc.heading = @"广告类自省";
        vc.body = ASBuildAdClassReport();
        [root presentViewController:vc animated:YES completion:nil];
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"📋 事件记录" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
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
    gSeenAdClasses = [NSMutableSet set];
    gAdoptedWebViews = [NSMutableSet set];
    ASLoadPrefs();

    Class avPlayer = objc_getClass("AVPlayer");
    if (avPlayer) {
        ASSwizzle(avPlayer, @selector(setRate:), (IMP)ASMySetRate, &gOrigSetRate);
        ASSwizzle(avPlayer, @selector(play), (IMP)ASMyPlay, &gOrigPlay);
        ASSwizzle(avPlayer, @selector(playImmediatelyAtRate:), (IMP)ASMyPlayAtRate, &gOrigPlayAtRate);
        ASSwizzle(avPlayer, @selector(setRate:time:atHostTime:), (IMP)ASMySetRateTime, &gOrigSetRateTime);
    }

    Class avpvc = objc_getClass("AVPlayerViewController");
    if (avpvc) {
        ASSwizzle(avpvc, @selector(setPlayer:), (IMP)ASMySetPVPlayer, &gOrigSetPVPlayer);
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
    ASStartAdMonitor();
    ASInstallTimerHooks();

    NSLog(@"[AdSpeeder] v3 installed (setRate=%d, play=%d, atRate=%d, setRateTime=%d, pvc=%d, wk=%d, present=%d, rate=%gx)",
          gOrigSetRate != NULL, gOrigPlay != NULL, gOrigPlayAtRate != NULL,
          gOrigSetRateTime != NULL, gOrigSetPVPlayer != NULL,
          gOrigInitWithFrameConfig != NULL, gOrigPresent != NULL, gRate);

    // 通用倍速 hook：模块可能在启动后才加载，分几轮补
    for (NSNumber *delay in @[@0.5, @2.0, @5.0, @10.0]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            @try { ASInstallGenericRateHooks(); } @catch (__unused NSException *e) {}
        });
    }

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
