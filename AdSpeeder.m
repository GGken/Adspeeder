// AdSpeeder v9 - Alipay mini-game rewarded-video ad accelerator
// 纯 objc runtime swizzling，不带 substrate / logos 依赖，TrollFools 注入可加载。
//
// v9：截图证实这是"激励浏览"广告（浏览14秒得奖励）——没有视频、只有一条停留计时，
//      所以倍速和跳片尾都碰不到它。改从"关广告 + 改结果"两头夹：
//   1. ASAutoCloseDwellAd：直通模式下找到"关闭"按钮并点掉（同窗口只点一次，广告撤了会重置）
//   2. 点完 1.2s 从 JS 补一发 __asFireAdClose()，让游戏认为"看完了"
//   3. onClose 改写成通杀：原生真回调进来也强制 isEnded=true（只改这一层，游戏逻辑不动）
//   4. JS 补发了防重（__asAdFired），避免二次发奖/逻辑错乱
//   5. 每个页面装 shim 时打印 fake=? 和 URL，能立刻看出开关有没有推进那个 WebView
//
// v8：日志证明 JS 接管成功、倍速真的生效（2.00x）、跳片尾也生效，但
//      "顶部倒计时"还在走，奖励卡在那条独立计时上。
//   1. gAdSeenAt 改由"BEE 播放器在屏"触发（之前只认 Ad* 类名，这条链上没有）——
//      NSTimer 压缩终于有机会生效；窗口 6s→15s、interval 0.2~5s
//   2. 新增倒计时文案扫描：把"12 秒 / 跳过 5"这类 UILabel 的宿主类名记下来，
//      有它就说明倒计时是原生的（可按宿主类精准 hook），没有就是 H5 画的
//   3. 弹窗文案改从实例读 title/message（swizzle 工厂方法没抓到）
//   4. JS 直通改成"等 onClose 注册了再回"，先 show 后注册的游戏也能吃到
//
// v7：日志证明"跳片尾"确实生效（广告 1.5s 内就关），但奖励可能仍被 JS 侧判定为未完成
//   1. JS 层接管 my.createRewardedAd：记录 onClose 回调，可直通 isEnded=true（菜单开关）
//   2. 新增 WKScriptMessageHandler「aslog」，JS 侧日志直接进事件记录
//   3. hook +[UIAlertController alertControllerWithTitle:message:] 抓弹窗文案
//      —— "未完成观看" 还是 "奖励已发放"，一行字就能定论
//   4. 设完倍速读回当前值，报告"生效/被拒"，确认 setPlaybackRate: 这枪打没打中
//   5. 「自动跳片尾」独立开关：关掉后只靠倍速自然播完，看会不会更容易发奖
//
// v6：时间线实测广告是 BeeVideoPlayerView（小程序视频组件），不是 Ad* 那套
//   1. 新增 ASDriveBeePlayers：每 0.4s 对在屏 Bee 播放器补倍速
//   2. +1.2s seekToTime:duration 跳片尾、+2.6s 二次推、+3.6s 给 delegate 模拟 BeeVideoPlayerFinished
//   3. 播放器第一次出现时把它"可用的 API"打进事件记录（有没有 setRate:/seekToTime:）
//   4. 🎯 广告实例报告增加"在屏 BEE 播放器"段：类名、frame、时长、可用方法
//
// v5：
//   1. 「🧾 视图时间线」：窗口里新冒出来的 Ad*/video/player/webview 自动留痕，
//      广告播完再看也能还原当时到底谁在渲染（不用抢时间截图）
//   2. 自动秒过加了 BEE 播放器兜底：从播放器往上找 countDownEnd 的宿主视图
//   3. setPlayTime: / playedTime: 双路推进度，countDownEnd 前先把 playTime 顶满
//   4. 诊断面板改成打开即自动复制，另加醒目复制按钮 + "已复制" 提示
//
// v4：拿到真实类名后改成对着 mPaaS BEE 广告 SDK 打
//   1. 主入口 -[AdRewardedVideoView countDownEnd]：倒计时归零 = 发奖 + 关闭
//   2. -[AdRewardedVideoView BeeVideoPlayerView:playedTime:] 进度放大 gRate 倍
//   3. 广告露出 1.2s 自动推进度、3s 补 didFinishPlay，不做强制关闭
//   4. 「🎯 广告实例」报告：活着的广告视图 + 可调用方法 + BEE 播放器完整方法/属性表
//   5. 悬浮球菜单加「自动秒过」开关
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
static NSString *const kPrefSeek    = @"adspeeder.seek";      // 自动跳片尾
static NSString *const kPrefFakeAd  = @"adspeeder.fakead";    // JS 侧直通广告回调
static NSString *const kPrefInstant = @"adspeeder.instant";   // 极速直通：广告出现即消失

// 自动跳片尾：实测有效（广告 1.5 秒内就关），默认开
static BOOL gSeekToEnd = YES;
// JS 侧直通：拦截 my.createRewardedAd，让 onClose 直接回"看完了"
static BOOL gFakeAd = NO;
// 极速直通：发现广告就立刻藏画面 + 点关闭 + 补 JS 回调，用户基本看不到广告
static BOOL gInstant = YES;
// 菜单里手点"秒关"时为真：忽略直通开关，强制动作
static BOOL gForceClose = NO;

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
static int  ASAutoSkipVisibleAds(void);
static int  ASForceSkipNow(NSMutableString *detail);
static void ASDriveBeePlayers(void);
static NSString *ASProbeBeePlayer(id p);
static double ASBeePlayerDuration(id p);
static void ASFireJsAdClose(void);
static int  ASAutoCloseDwellAd(void);
static int  ASInstantKillAd(void);
static void ASAutoConfirmExitAlert(UIAlertController *ac, int tries);
static BOOL ASIsAdExitAlert(UIAlertController *ac);

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
    if ([d objectForKey:kPrefSeek] != nil) gSeekToEnd = [d boolForKey:kPrefSeek];
    if ([d objectForKey:kPrefFakeAd] != nil) gFakeAd = [d boolForKey:kPrefFakeAd];
    if ([d objectForKey:kPrefInstant] != nil) gInstant = [d boolForKey:kPrefInstant];
}

static void ASSavePrefs(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setBool:ASEngineOn() forKey:kPrefEnabled];
    [d setFloat:(ASEngineOn() ? gRate : 16.0f) forKey:kPrefRate];
    [d setBool:gSeekToEnd forKey:kPrefSeek];
    [d setBool:gFakeAd forKey:kPrefFakeAd];
    [d setBool:gInstant forKey:kPrefInstant];
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

// 更宽的"这玩意儿是广告容器"判定，用于"出现即隐藏"。
// 只用来找画面容器，不用于改行为，误判最多是白藏一帧，有 2.5 秒自动恢复兜底。
static BOOL ASNameAdish(NSString *name) {
    if (name.length < 4) return NO;
    NSString *l = name.lowercaseString;
    NSArray *kw = @[@"reward", @"interstitial", @"adview", @"advideo", @"adplayer",
                    @"adcontainer", @"adwindow", @"adpage", @"splashad", @"beereward",
                    @"beead", @"beevideoplayer", @"advideoplayer", @"promotion"];
    for (NSString *k in kw) if ([l containsString:k]) return YES;
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

// 小程序/小游戏里的激励视频走 my.createRewardedAd，奖励判定在 JS 的 onClose(isEnded)。
// 原生把视频跳完并不能让它认为"看完了"，所以这里在 JS 层接管这个 API：
//   1) 记下游戏注册的 onClose 回调
//   2) window.__asFakeAd 为真时，show() 之后直接回 isEnded=true，原生广告根本不播
static NSString *const kAdShimJS =
@"(function(){"
 "if(window.__asAdShim)return;window.__asAdShim=1;"
 "function log(m){try{window.webkit.messageHandlers.aslog.postMessage('[JS] '+m);}catch(e){}}"
 "var U='';try{U=String(location.href).slice(0,70);}catch(e){}"
 "log('shim 装好 fake='+(window.__asFakeAd?1:0)+' '+U);"
 "window.__asFireAdClose=function(){var cb=window.__asAdCloseCb;if(!cb)return 'no-cb';"
 "if(window.__asAdFired)return 'already';window.__asAdFired=1;"
 "try{cb({isEnded:true,count:1,completed:true,reward:true});}catch(e){return 'err:'+e;}return 'ok';};"
 "function targets(){var a=[];try{if(window.my)a.push(window.my);}catch(e){}"
 "try{if(window.antgame){a.push(window.antgame);if(window.antgame.ad)a.push(window.antgame.ad);"
 "if(window.antgame.my)a.push(window.antgame.my);}}catch(e){}"
 "try{if(window.ap&&window.ap.my)a.push(window.ap.my);}catch(e){}return a;}"
 "var KNOWN=['createRewardedAd','createRewardedVideoAd','createInterstitialAd'];"
 "function hook(ad,src){if(!ad)return;var k='__asHooked';try{if(ad[k])return;ad[k]=1;}catch(e){return;}"
 "var oc=null;try{oc=ad.onClose;}catch(e){}"
 "try{ad.onClose=function(cb){window.__asAdCloseCb=cb;log('onClose 注册('+src+')');"
 "if(!oc)return;"
 "var w=function(res){if(window.__asAdFired)return;window.__asAdFired=1;"
 "var out={isEnded:true,count:1,completed:true,reward:true};"
 "try{if(res&&typeof res==='object'){for(var kk in res)out[kk]=res[kk];}out.isEnded=true;out.count=1;"
 "if(out.completed===false)out.completed=true;}catch(e){}"
 "log('原生 onClose 被改写 isEnded=true');"
 "try{cb&&cb(out);}catch(e){log('cb 抛错 '+e);}};"
 "return oc.call(ad,w);};}catch(e){log('onClose 接管失败 '+e);}"
 "var os=null;try{os=ad.show;}catch(e){}"
 "try{ad.show=function(){window.__asAdFired=0;var fake=!!window.__asFakeAd;"
 "log('show() fake='+(fake?1:0)+' ('+src+')');"
 "if(fake){var tries=0;(function fire(){var cb=window.__asAdCloseCb;"
 "if(!cb&&++tries<20){setTimeout(fire,300);return;}"
 "if(window.__asAdFired)return;window.__asAdFired=1;"
 "log('直接回 onClose isEnded=true cb='+(cb?'有':'无'));"
 "try{if(cb)cb({isEnded:true,count:1,completed:true,reward:true});}catch(e){log('cb 抛错 '+e);}})();"
 "try{return Promise.resolve();}catch(e){return;}}"
 "return os?os.apply(ad,arguments):undefined;};}catch(e){log('show 接管失败 '+e);}"
 "var ol=null;try{ol=ad.load;}catch(e){}"
 "try{ad.load=function(){var r=null;try{r=ol?ol.apply(ad,arguments):null;}catch(e){}"
 "return (r&&r.then)?r:Promise.resolve();};}catch(e){}}"
 "var tries=0;"
 "function scan(){var t=targets(),n=0;"
 "for(var i=0;i<t.length;i++){var o=t[i];if(!o)continue;"
 "for(var j=0;j<KNOWN.length;j++){var name=KNOWN[j],f=null;"
 "try{f=o[name];}catch(e){}if(typeof f!=='function')continue;"
 "if(o['__as_wrapped_'+name])continue;"
 "try{(function(obj,nm,orig){var w=function(){var ad=null;"
 "try{ad=orig.apply(obj,arguments);}catch(e){log('调用 '+nm+' 抛错 '+e);return null;}"
 "try{hook(ad,nm);}catch(e){}return ad;};obj[nm]=w;"
 "if(obj[nm]===w){obj['__as_wrapped_'+nm]=1;log('已接管 '+nm);n++;}"
 "else log('接管失败(只读) '+nm);})(o,name,f);}catch(e){log('接管失败 '+name+' '+e);}}}"
 "if(n===0){if(++tries<40)setTimeout(scan,250);"
 "else log('没找到广告 API（my='+(typeof window.my)+'）');}}"
 "scan();})();";

static IMP gOrigInitWithFrameConfig = NULL;

@interface ASJSBridge : NSObject <WKScriptMessageHandler>
@end

@implementation ASJSBridge
- (void)userContentController:(WKUserContentController *)ucc didReceiveScriptMessage:(WKScriptMessage *)message {
    NSString *body = nil;
    @try { if (message.body) body = [NSString stringWithFormat:@"%@", message.body]; }
    @catch (__unused NSException *e) {}
    if (body.length) ASRecord(body);
}
@end

static ASJSBridge *gBridge = nil;

static float gPushedRate = -1.0f;   // 上次推给 JS 的倍速，避免每 0.4 秒重复 eval

static void ASPushFakeAdToWebViews(void) {
    NSArray *snapshot = nil;
    @synchronized (gWebViews) { snapshot = gWebViews.allObjects; }
    NSString *js = [NSString stringWithFormat:@"window.__asFakeAd=%@;", gFakeAd ? @"true" : @"false"];
    int ok = 0;
    for (WKWebView *w in snapshot) {
        @try {
            [w evaluateJavaScript:js completionHandler:nil];
            // 页面可能比 dylib 更早加载（那时 shim 还没注入），这里补一次；脚本本身幂等
            [w evaluateJavaScript:kAdShimJS completionHandler:nil];
            ok++;
        } @catch (__unused NSException *e) {}
    }
    ASRecord([NSString stringWithFormat:@"直通=%@，已推送到 %d/%lu 个 WebView",
              gFakeAd ? @"开" : @"关", ok, (unsigned long)snapshot.count]);
}

static void ASPushRateToWebView(WKWebView *webView) {
    if (!webView) return;
    NSString *js = [NSString stringWithFormat:@"window.__asRate=%g;window.__asFakeAd=%@;",
                    gRate, gFakeAd ? @"true" : @"false"];
    @try { [webView evaluateJavaScript:js completionHandler:nil]; } @catch (__unused NSException *e) {}
    gPushedRate = gRate;
}

static void ASAdoptWebView(WKWebView *wv) {
    if (!wv) return;
    @synchronized (gWebViews) { [gWebViews addObject:wv]; }
    if (!gAdoptedWebViews) gAdoptedWebViews = [NSMutableSet set];
    NSString *key = [NSString stringWithFormat:@"%p", (__bridge void *)wv];
    BOOL first = ![gAdoptedWebViews containsObject:key];
    if (first) {
        [gAdoptedWebViews addObject:key];
        @try {
            NSString *seed = [NSString stringWithFormat:@"window.__asRate=%g;window.__asFakeAd=%@;",
                              gRate, gFakeAd ? @"true" : @"false"];
            [wv evaluateJavaScript:seed completionHandler:nil];
            [wv evaluateJavaScript:kAdShimJS completionHandler:nil];
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
        if (!gBridge) gBridge = [[ASJSBridge alloc] init];
        @try { [ucc addScriptMessageHandler:gBridge name:@"aslog"]; }
        @catch (__unused NSException *e) {}
        NSString *seed = [NSString stringWithFormat:@"window.__asRate=%g;window.__asFakeAd=%@;",
                          gRate, gFakeAd ? @"true" : @"false"];
        [ucc addUserScript:[[WKUserScript alloc] initWithSource:seed
                                                    injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                                 forMainFrameOnly:NO]];
        [ucc addUserScript:[[WKUserScript alloc] initWithSource:kAdShimJS
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
        // 从实例上直接读文案，比 swizzle 工厂方法可靠（类和子类都可能建 alert）
        if ([vc isKindOfClass:[UIAlertController class]]) {
            UIAlertController *ac = (UIAlertController *)vc;
            ASRecord([NSString stringWithFormat:@"[弹窗文案] %@ | %@",
                      ac.title.length ? ac.title : @"(无标题)", ac.message ?: @""]);
        }
    } @catch (__unused NSException *e) {}

    ((void (*)(id, SEL, id, BOOL, id))gOrigPresent)(self, _cmd, vc, animated, completion);

    // 广告页是"present 出来的"：上来就先藏掉，用户看不到内容
    @try {
        if ((gFakeAd || gForceClose) && vc && !ASIsOwnWindow(vc.view.window) &&
            ASNameAdish(NSStringFromClass([vc class]))) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.02 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                @try { vc.view.alpha = 0.0; } @catch (__unused NSException *e) {}
                ASRecord([NSString stringWithFormat:@"广告页出现即隐藏: %@", NSStringFromClass([vc class])]);
                ASInstantKillAd();
            });
        }
    } @catch (__unused NSException *e) {}
}

// 弹窗的标题/正文往往直接写着"未完成观看"或"奖励已发放"，
// 这是判断奖励到底给没给的最直接证据，所以单独记一条。
static id (*gOrigAlert)(id, SEL, NSString *, NSString *, NSInteger) = NULL;

static id ASMyAlert(id self, SEL _cmd, NSString *title, NSString *message, NSInteger style) {
    if (!gOrigAlert) return nil;
    @try {
        if (![title isEqualToString:@"AdSpeeder"]) {
            ASRecord([NSString stringWithFormat:@"[弹窗文案] %@ | %@",
                      title.length ? title : @"(无标题)", message ?: @""]);
        }
    } @catch (__unused NSException *e) {}
    id ac = gOrigAlert(self, _cmd, title, message, style);
    // 广告 SDK 的"再看 N 秒？坚持退出 / 继续观看"——自动替用户选退出
    @try {
        if (ac && [ac isKindOfClass:[UIAlertController class]] && ASIsAdExitAlert((UIAlertController *)ac)) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.03 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                ASAutoConfirmExitAlert((UIAlertController *)ac, 0);
            });
        }
    } @catch (__unused NSException *e) {}
    return ac;
}

// 广告窗口常是独立 UIWindow（BEEAlertManagedWindow 之类），makeKeyAndVisible 时就能拦：
// 直接 alpha=0 → 一帧都不渲染；2.5 秒后恢复，避免把窗口永久弄瞎。
static IMP gOrigMakeVisible = NULL;

static void ASMyMakeVisible(UIWindow *self, SEL _cmd) {
    @try {
        if ((gFakeAd || gForceClose) && gInstant && !ASIsOwnWindow(self) &&
            (ASNameAdish(NSStringFromClass([self class])) ||
             ASNameAdish(NSStringFromClass([self.rootViewController class])))) {
            self.alpha = 0.0;
            ASRecord([NSString stringWithFormat:@"广告窗口一出现就藏起来: %@",
                      NSStringFromClass([self class])]);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ ASInstantKillAd(); });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (self.alpha < 0.05) self.alpha = 1.0;
            });
        }
    } @catch (__unused NSException *e) {}
    ((void (*)(id, SEL))gOrigMakeVisible)(self, _cmd);
}

#pragma mark - 广告巡检（自动抓，不用卡时间）static NSString *ASSnapshotOfView(UIView *v) {
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

#pragma mark - 出现即留痕（不用抢在广告播放时截图）

// 光看类是否存在没用（二进制里本来就有一堆 Ad* 类），要看广告出现那一刻
// 屏幕上"新冒出来"的是什么。这里对窗口里每个新出现的相关视图/网页记一条时间线，
// 广告播完再看也能还原当时到底是谁在渲染。

static NSMutableArray<NSString *> *gTimeline = nil;
static NSMutableSet<NSString *> *gTimelineSeen = nil;
static NSTimeInterval gTimelineStart = 0;

static BOOL ASIsInterestingName(NSString *name) {
    if (name.length < 4) return NO;
    NSString *l = name.lowercaseString;
    NSArray *kw = @[@"reward", @"video", @"player", @"bee", @"cdp", @"tinyapp",
                    @"nebula", @"h5", @"webview", @"interstitial", @"promotion"];
    for (NSString *k in kw) if ([l containsString:k]) return YES;
    if ([name hasPrefix:@"Ad"] && name.length > 2 &&
        [[NSCharacterSet uppercaseLetterCharacterSet] characterIsMember:[name characterAtIndex:2]]) return YES;
    return NO;
}

static void ASTimelineAdd(NSString *line) {
    if (!gTimeline) {
        gTimeline = [NSMutableArray array];
        gTimelineSeen = [NSMutableSet set];
        gTimelineStart = [NSDate timeIntervalSinceReferenceDate];
    }
    if (gTimeline.count >= 400) return;
    double el = [NSDate timeIntervalSinceReferenceDate] - gTimelineStart;
    [gTimeline addObject:[NSString stringWithFormat:@"+%.1fs %@", el, line]];
}

static void ASTimelineScan(void) {
    if (!gTimeline) {
        gTimeline = [NSMutableArray array];
        gTimelineSeen = [NSMutableSet set];
        gTimelineStart = [NSDate timeIntervalSinceReferenceDate];
    }

    for (UIWindow *w in ASAllWindows()) {
        if (ASIsOwnWindow(w)) continue;
        if (w.hidden || w.alpha < 0.01) continue;
        double lv = w.windowLevel;

        ASWalkViews(w, 0, ^(UIView *v, int d) {
            NSString *cn = NSStringFromClass([v class]);

            if ([v isKindOfClass:[WKWebView class]]) {
                NSString *url = ((WKWebView *)v).URL.absoluteString ?: @"(about:blank)";
                NSString *key = [@"WEB " stringByAppendingString:url];
                if (![gTimelineSeen containsObject:key]) {
                    [gTimelineSeen addObject:key];
                    ASTimelineAdd([NSString stringWithFormat:@"Lv%.0f WEB  %@", lv, url]);
                }
                return;
            }

            if (!ASIsInterestingName(cn)) return;
            NSString *key = [NSString stringWithFormat:@"V%.0f-%@", lv, cn];
            if ([gTimelineSeen containsObject:key]) return;
            [gTimelineSeen addObject:key];
            CGRect f = v.frame;
            ASTimelineAdd([NSString stringWithFormat:@"Lv%.0f %@  %.0fx%.0f", lv, cn, f.size.width, f.size.height]);
        });
    }
}

static NSString *ASBuildTimelineReport(void) {
    if (!gTimeline || gTimeline.count == 0) {
        return @"(还没记录到任何视图)\n\n先把广告播一次，再回来看这里。";
    }
    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"视图时间线（共 %lu 条，从注入时刻起算）\n\n",
     (unsigned long)gTimeline.count];
    NSUInteger from = gTimeline.count > 120 ? gTimeline.count - 120 : 0;
    for (NSUInteger i = from; i < gTimeline.count; i++) {
        [out appendFormat:@"%@\n", gTimeline[i]];
    }
    return out;
}

static void ASScanOnce(void) {
    if (!ASIsAlipay()) return;
    @try { ASTimelineScan(); } @catch (__unused NSException *e) {}
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

    // 自动秒过：自己会再扫一遍，不依赖上面的广告视图判定
    @try { ASAutoSkipVisibleAds(); } @catch (__unused NSException *e) {}

    // 小程序视频组件（BeeVideoPlayerView）这条路单独驱动
    @try { ASDriveBeePlayers(); } @catch (__unused NSException *e) {}

    // 激励浏览型广告没有播放器，单独处理
    @try { ASAutoCloseDwellAd(); } @catch (__unused NSException *e) {}
}

#pragma mark - 广告倒计时压缩

// 自研广告 SDK 的"还剩 15 秒"通常是 NSTimer 每秒减一，跟视频进度无关。
// 只在广告视图出现后的 6 秒窗口内、且 interval 在 0.5~3 秒的重复计时器上动手，
// 避免影响支付宝自身的常驻计时器（那些在广告之前就创建好了）。
static NSTimeInterval ASCompressInterval(NSTimeInterval ti, BOOL repeats) {
    if (!ASEngineOn() || !repeats) return ti;
    if (gAdSeenAt <= 0) return ti;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - gAdSeenAt > 15.0) return ti;
    if (ti < 0.2 || ti > 5.0) return ti;
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

#pragma mark - mPaaS BEE 激励视频（支付宝自研广告 SDK）

// 调用链（从「广告类方法」诊断里真实类名反推）：
//   AdRewardedVideoView  —— 激励视频主视图，同时是 BeeVideoPlayerView 的 delegate
//     - BeeVideoPlayerView:playedTime:      进度回调，倒计时/进度条按它走
//     - BeeVideoPlayerView:willChangeState: 播放 / 暂停 / 缓冲状态
//     - BeeVideoPlayerViewDidFinishPlay:    播放结束
//     - countDownEnd                        倒计时归零 —— 发奖 + 关闭的真正入口
//     - closeView / banPlay / continuePlayer: / pausePlayer: / setPlayTime:
//   AdRewardView —— 外层容器
//     - countDownFinish / didCloseView / pasueTimer: / resumeTimer:
//
// 结论：这家的倒计时跟"视频播到第几秒"无关，只改倍速永远等不到它结束，
// 必须直接把它推到"倒计时归零"那一步（countDownEnd），才会走发奖 + 关闭。

static NSMutableDictionary<NSString *, NSNumber *> *gAdFirstSeen = nil;
static NSMutableSet<NSString *> *gAdStepsDone = nil;
static BOOL gAutoSkip = YES;

static NSString *ASPtrKey(id o) {
    return [NSString stringWithFormat:@"%p", (__bridge void *)o];
}

static BOOL ASResponds(id o, NSString *selName) {
    return o != nil && [o respondsToSelector:NSSelectorFromString(selName)];
}

// BEE 播放器：激励视频的画面由它渲染，didFinishPlay 需要它做参数
static UIView *ASFindBeePlayer(UIView *root) {
    UIView *base = root.window ?: root;
    __block UIView *found = nil;
    ASWalkViews(base, 0, ^(UIView *v, int d) {
        NSString *cn = NSStringFromClass([v class]);
        if ([cn containsString:@"BeeVideoPlayer"] || [cn containsString:@"BEEVideoPlayer"]) found = v;
    });
    return found;
}

// 只认"能自己结束自己"的视图，避免把 AdVideoModel 这类数据对象算进来
static BOOL ASIsRewardAdView(id v) {
    if (![v isKindOfClass:[UIView class]]) return NO;
    if (ASResponds(v, @"countDownEnd")) return YES;
    if (ASResponds(v, @"BeeVideoPlayerViewDidFinishPlay:")) return YES;
    if (ASResponds(v, @"countDownFinish")) return YES;
    if (ASResponds(v, @"closeView") && ASResponds(v, @"banPlay")) return YES;
    if (ASResponds(v, @"didCloseView")) return YES;
    return NO;
}

// step 0: countDownEnd             倒计时归零（首选，等价于"用户看完了"）
// step 1: didFinishPlay:           播放结束回调
// step 2: closeView / didCloseView 兜底关掉（只在手动"秒过"时用，自动模式不碰）
static int ASRunSkipStep(UIView *v, int step, NSMutableString *log) {
    if (!v || !v.window || v.hidden || v.alpha < 0.01) return 0;
    if (!gAdStepsDone) gAdStepsDone = [NSMutableSet set];

    NSString *key = [NSString stringWithFormat:@"%@#%d", ASPtrKey(v), step];
    if ([gAdStepsDone containsObject:key]) return 0;

    SEL sel = NULL;
    NSString *what = nil;
    UIView *player = nil;

    if (step == 0) {
        if (!ASResponds(v, @"countDownEnd")) return 0;
        sel = NSSelectorFromString(@"countDownEnd");
        what = @"countDownEnd";

        // 先把 playTime 顶到 duration，让 SDK 自己的判断也认为"看完了"
        if (ASResponds(v, @"setPlayTime:") && ASResponds(v, @"duration")) {
            @try {
                double dur = ((double (*)(id, SEL))objc_msgSend)(v, NSSelectorFromString(@"duration"));
                if (dur > 0) {
                    ((void (*)(id, SEL, double))objc_msgSend)(v, NSSelectorFromString(@"setPlayTime:"), dur);
                    what = @"setPlayTime:(满) + countDownEnd";
                }
            } @catch (__unused NSException *e) {}
        }
    } else if (step == 1) {
        if (!ASResponds(v, @"BeeVideoPlayerViewDidFinishPlay:")) return 0;
        player = ASFindBeePlayer(v);
        if (!player) return 0;   // 没有播放器就别传 nil，免得 SDK 内部判空失败
        sel = NSSelectorFromString(@"BeeVideoPlayerViewDidFinishPlay:");
        what = @"BeeVideoPlayerViewDidFinishPlay:";
    } else {
        if (ASResponds(v, @"closeView")) {
            sel = NSSelectorFromString(@"closeView"); what = @"closeView";
        } else if (ASResponds(v, @"didCloseView")) {
            sel = NSSelectorFromString(@"didCloseView"); what = @"didCloseView";
        } else {
            return 0;
        }
    }

    [gAdStepsDone addObject:key];
    @try {
        if (player) {
            ((void (*)(id, SEL, id))objc_msgSend)(v, sel, player);
            if (log) [log appendFormat:@"→ %@(%@)\n", what, NSStringFromClass([player class])];
        } else {
            ((void (*)(id, SEL))objc_msgSend)(v, sel);
            if (log) [log appendFormat:@"→ %@\n", what];
        }
        ASRecord([NSString stringWithFormat:@"秒过 %@ %@", NSStringFromClass([v class]), what]);
        return 1;
    } @catch (__unused NSException *e) {
        if (log) [log appendFormat:@"→ %@ 抛异常，已放弃\n", what];
        return 0;
    }
}

// 由 0.4 秒巡检调用：广告露出 1.2 秒后推进度，3 秒后补一次 didFinishPlay。
// 不做"强制关闭"，避免真正发奖流程还没跑完就把视图拆了。
static int ASAutoSkipVisibleAds(void) {
    if (!gAutoSkip || !ASEngineOn()) return 0;
    if (!gAdFirstSeen) gAdFirstSeen = [NSMutableDictionary dictionary];

    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    NSMutableArray<UIView *> *live = [NSMutableArray array];

    for (UIWindow *w in ASAllWindows()) {
        if (ASIsOwnWindow(w)) continue;
        ASWalkViews(w, 0, ^(UIView *v, int d) {
            if (![v isKindOfClass:[UIView class]]) return;
            if (!v.window || v.hidden || v.alpha < 0.01) return;

            if (ASIsRewardAdView(v)) { [live addObject:v]; return; }

            // 兜底：只认播放器，往上找能 countDownEnd 的宿主视图。
            // 万一广告外层不是 AdRewardedVideoView，这条路也能对上。
            NSString *cn = NSStringFromClass([v class]);
            if ([cn containsString:@"BeeVideoPlayer"]) {
                for (UIView *p = v.superview; p; p = p.superview) {
                    if (ASResponds(p, @"countDownEnd")) {
                        if (![live containsObject:p]) [live addObject:p];
                        break;
                    }
                }
            }
        });
    }

    int hit = 0;
    for (UIView *v in live) {
        NSString *k = ASPtrKey(v);
        NSNumber *t0 = gAdFirstSeen[k];
        if (!t0) {
            gAdFirstSeen[k] = @(now);
            ASRecord([NSString stringWithFormat:@"广告露出: %@", NSStringFromClass([v class])]);
            continue;
        }
        NSTimeInterval el = now - t0.doubleValue;
        if (el >= 1.2) hit += ASRunSkipStep(v, 0, nil);
        if (el >= 3.0) hit += ASRunSkipStep(v, 1, nil);
    }

    if (gAdFirstSeen.count > 200) {
        [gAdFirstSeen removeAllObjects];
        [gAdStepsDone removeAllObjects];
    }
    return hit;
}

// 手动"秒过"：三级全上，最后退回 AVPlayer 方案
static int ASForceSkipNow(NSMutableString *detail) {
    __block int hit = 0;
    __block int seen = 0;

    for (UIWindow *w in ASAllWindows()) {
        if (ASIsOwnWindow(w)) continue;
        ASWalkViews(w, 0, ^(UIView *v, int d) {
            if (![v isKindOfClass:[UIView class]]) return;
            if (!ASIsRewardAdView(v)) return;
            if (!v.window || v.hidden || v.alpha < 0.01) return;
            seen++;
            [detail appendFormat:@"%@  %@\n", NSStringFromClass([v class]),
             NSStringFromCGRect(v.frame)];
            for (int step = 0; step < 3; step++) {
                if (ASRunSkipStep(v, step, detail)) hit++;
            }
        });
    }

    if (seen == 0) {
        [detail appendString:@"没有找到活着的广告视图，退回 AVPlayer 方案：\n"];
        hit += ASForceFinishPlayers(detail);
    } else if (hit == 0) {
        [detail appendString:@"\n广告视图在，但没有一个方法调用成功。\n"];
        [detail appendString:@"点「🎯 广告实例」把方法/属性列表发我，改精准 hook。\n"];
    }
    return hit;
}

static NSString *ASDumpClassFull(NSString *name) {
    Class cls = NSClassFromString(name);
    if (!cls) return [NSString stringWithFormat:@"%@ —— 类不存在\n", name];

    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"%@\n  image: %@\n  super: %@\n", name, ASImagePath(cls), ASClassChain(cls)];

    unsigned int mc = 0;
    Method *ms = class_copyMethodList(cls, &mc);
    NSMutableArray *methods = [NSMutableArray array];
    for (unsigned int i = 0; i < mc; i++) {
        [methods addObject:[NSString stringWithFormat:@"%s(%s)",
                            sel_getName(method_getName(ms[i])),
                            method_getTypeEncoding(ms[i])]];
    }
    if (ms) free(ms);
    [methods sortUsingSelector:@selector(compare:)];
    [s appendFormat:@"  方法 %u 个:\n    %@\n", mc, [methods componentsJoinedByString:@"\n    "]];

    unsigned int ic = 0;
    Ivar *ivs = class_copyIvarList(cls, &ic);
    NSMutableArray *ivars = [NSMutableArray array];
    for (unsigned int i = 0; i < ic; i++) {
        [ivars addObject:[NSString stringWithFormat:@"%s : %s",
                          ivar_getName(ivs[i]), ivar_getTypeEncoding(ivs[i])]];
    }
    if (ivs) free(ivs);
    [s appendFormat:@"  属性 %u 个: %@\n", ic, [ivars componentsJoinedByString:@", "]];
    return s;
}

static NSString *ASBuildAdInstanceReport(void) {
    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"自动秒过: %@   倍速: %gx\n\n", gAutoSkip ? @"开" : @"关", gRate];

    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    __block int n = 0;

    for (UIWindow *w in ASAllWindows()) {
        if (ASIsOwnWindow(w)) continue;
        ASWalkViews(w, 0, ^(UIView *v, int d) {
            if (![v isKindOfClass:[UIView class]]) return;
            if (!ASIsRewardAdView(v)) return;
            if (!v.window || v.hidden) return;

            n++;
            NSString *k = ASPtrKey(v);
            NSNumber *t0 = gAdFirstSeen[k];
            [out appendFormat:@"#%d %@\n  地址 %@  frame=%@\n  在屏 %.1fs   Lv%.0f %@\n",
             n, NSStringFromClass([v class]), k, NSStringFromCGRect(v.frame),
             t0 ? now - t0.doubleValue : 0.0,
             w.windowLevel, NSStringFromClass([w class])];

            NSMutableArray *can = [NSMutableArray array];
            NSArray *probe = @[@"countDownEnd", @"BeeVideoPlayerViewDidFinishPlay:",
                               @"BeeVideoPlayerView:playedTime:", @"closeView",
                               @"didCloseView", @"countDownFinish", @"banPlay",
                               @"continuePlayer:", @"pausePlayer:", @"setPlayTime:"];
            for (NSString *sel in probe) if (ASResponds(v, sel)) [can addObject:sel];
            [out appendFormat:@"  可调用: %@\n", [can componentsJoinedByString:@", "]];

            UIView *p = ASFindBeePlayer(v);
            if (p) [out appendFormat:@"  播放器: %@ %@\n",
                    NSStringFromClass([p class]), NSStringFromCGRect(p.frame)];
        });
    }

    if (n == 0) [out appendString:@"(当前没有活着的广告视图)\n"];

    // 时间线证明广告走的是小程序视频组件，这条单独列，没有 Ad* 视图时也能看到
    NSMutableArray<UIView *> *bees = [NSMutableArray array];
    for (UIWindow *w in ASAllWindows()) {
        if (ASIsOwnWindow(w)) continue;
        ASWalkViews(w, 0, ^(UIView *v, int d) {
            if (!v.window || v.hidden) return;
            if ([NSStringFromClass([v class]) containsString:@"BeeVideoPlayer"]) [bees addObject:v];
        });
    }
    [out appendFormat:@"\n== 在屏 BEE 播放器 %lu 个 ==\n", (unsigned long)bees.count];
    for (UIView *p in bees) {
        double d = ASBeePlayerDuration(p);
        [out appendFormat:@"%@  %@  时长 %.1fs\n  可用: %@\n",
         NSStringFromClass([p class]), NSStringFromCGRect(p.frame), d, ASProbeBeePlayer(p)];
    }

    [out appendString:@"\n"];
    [out appendString:ASDumpClassFull(@"AdRewardedVideoView")];
    [out appendString:@"\n"];
    [out appendString:ASDumpClassFull(@"BeeVideoPlayerView")];
    return out;
}

#pragma mark - BEE 进度伪造 + 播放器倍速

// -[AdRewardedVideoView BeeVideoPlayerView:playedTime:] 的进度值直接决定倒计时，
// 把回传的秒数放大，倒计时自然就提前归零，跟真实视频解码无关。
static IMP gOrigPlayedTimeF = NULL;
static IMP gOrigPlayedTimeD = NULL;
static IMP gOrigSetPlayTime = NULL;

// setPlayTime: 是进度落到视图上的最后一道：不放大 playedTime 也能从这里把进度推上去
static void ASMySetPlayTime(id self, SEL _cmd, double t) {
    IMP orig = gOrigSetPlayTime;
    if (!orig) return;
    double out = t;
    if (ASEngineOn() && t > 0.0) {
        out = t * (double)gRate;
        @try {
            if ([self respondsToSelector:NSSelectorFromString(@"duration")]) {
                double d = ((double (*)(id, SEL))objc_msgSend)(self, NSSelectorFromString(@"duration"));
                if (d > 0.0 && out > d) out = d;
            }
        } @catch (__unused NSException *e) {}
    }
    ((void (*)(id, SEL, double))orig)(self, _cmd, out);
}

static void ASMyPlayedTimeF(id self, SEL _cmd, id player, float t) {
    IMP orig = gOrigPlayedTimeF;
    if (!orig) return;
    float out = (ASEngineOn() && t > 0.0f) ? t * gRate : t;
    ((void (*)(id, SEL, id, float))orig)(self, _cmd, player, out);
}

static void ASMyPlayedTimeD(id self, SEL _cmd, id player, double t) {
    IMP orig = gOrigPlayedTimeD;
    if (!orig) return;
    double out = (ASEngineOn() && t > 0.0) ? t * (double)gRate : t;
    ((void (*)(id, SEL, id, double))orig)(self, _cmd, player, out);
}

// 取第 nth 个类型字符（1=返回值 2=self 3=_cmd 4=第一个参数 5=第二个参数）
static char ASNthArgType(const char *enc, int nth) {
    if (!enc) return 0;
    const char *c = enc;
    int idx = 0;
    while (*c) {
        while (*c >= '0' && *c <= '9') c++;
        if (!*c) break;
        char t = *c++;
        if (t == '^' || t == 'r' || t == 'n' || t == 'N' ||
            t == 'o' || t == 'O' || t == 'R' || t == 'V') continue;
        idx++;
        if (idx == nth) return t;
    }
    return 0;
}

static void ASInstallBeeHooks(void) {
    Class cls = NSClassFromString(@"AdRewardedVideoView");
    if (!cls) return;

    if (!gOrigSetPlayTime) {
        Method sp = class_getInstanceMethod(cls, NSSelectorFromString(@"setPlayTime:"));
        if (sp) {
            gOrigSetPlayTime = method_getImplementation(sp);
            method_setImplementation(sp, (IMP)ASMySetPlayTime);
            ASRecord(@"BEE setPlayTime hook 挂上");
        }
    }

    SEL sel = NSSelectorFromString(@"BeeVideoPlayerView:playedTime:");
    Method m = class_getInstanceMethod(cls, sel);
    if (!m || gOrigPlayedTimeF || gOrigPlayedTimeD) return;

    char t = ASNthArgType(method_getTypeEncoding(m), 5);
    IMP orig = method_getImplementation(m);
    if (t == 'f') {
        gOrigPlayedTimeF = orig;
        method_setImplementation(m, (IMP)ASMyPlayedTimeF);
    } else if (t == 'd') {
        gOrigPlayedTimeD = orig;
        method_setImplementation(m, (IMP)ASMyPlayedTimeD);
    } else {
        return;
    }
    ASRecord([NSString stringWithFormat:@"BEE playedTime hook 挂上（%c 型参数）", t]);
}

#pragma mark - BEE 播放器直驱（时间线证明广告走的是这条）

// 时间线实测：激励视频出现时是
//   BeeVideoPlayerView 390x844
//     ├ MFCorePlayerView            ← 真正解码渲染的引擎视图
//     ├ BeeVideoTouchesPlugin / StuckDetect / Poster / Watermark
//     └ BeeVideoPlayerToolBar / BeeVideoSlider
// 全程没有 AdRewardedVideoView —— 说明这是小程序自己的视频组件，
// 奖励靠播放器的"播完"回调往 JS 层发。所以只能对它本人下手：
// 改倍速 + 把进度直接怼到片尾，让它自己触发 finished。

static BOOL ASCallVoidDouble(id obj, NSString *selName, double v) {
    if (!obj) return NO;
    SEL s = NSSelectorFromString(selName);
    if (![obj respondsToSelector:s]) return NO;
    Method m = class_getInstanceMethod([obj class], s);
    if (!m) return NO;
    char t = ASNthArgType(method_getTypeEncoding(m), 4);
    @try {
        if (t == 'f') { ((void (*)(id, SEL, float))objc_msgSend)(obj, s, (float)v); return YES; }
        if (t == 'd') { ((void (*)(id, SEL, double))objc_msgSend)(obj, s, v); return YES; }
        if (t == 'q') { ((void (*)(id, SEL, long long))objc_msgSend)(obj, s, (long long)v); return YES; }
        if (t == 'i') { ((void (*)(id, SEL, int))objc_msgSend)(obj, s, (int)v); return YES; }
    } @catch (__unused NSException *e) {}
    return NO;
}

static id ASCallObject(id obj, NSString *selName) {
    if (!obj) return nil;
    SEL s = NSSelectorFromString(selName);
    if (![obj respondsToSelector:s]) return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)(obj, s); }
    @catch (__unused NSException *e) { return nil; }
}

static BOOL ASCallDouble(id obj, NSString *selName, double *out) {
    if (!obj) return NO;
    SEL s = NSSelectorFromString(selName);
    if (![obj respondsToSelector:s]) return NO;
    Method m = class_getInstanceMethod([obj class], s);
    if (!m) return NO;
    char t = ASNthArgType(method_getTypeEncoding(m), 1);
    @try {
        if (t == 'd') { *out = ((double (*)(id, SEL))objc_msgSend)(obj, s); return YES; }
        if (t == 'f') { *out = ((float (*)(id, SEL))objc_msgSend)(obj, s); return YES; }
        if (t == 'q') { *out = (double)((long long (*)(id, SEL))objc_msgSend)(obj, s); return YES; }
        if (t == 'i') { *out = (double)((int (*)(id, SEL))objc_msgSend)(obj, s); return YES; }
    } @catch (__unused NSException *e) {}
    return NO;
}

// 把播放器上"能用的 API"列出来，一次就能看清该走哪条路
static NSString *ASProbeBeePlayer(id p) {
    NSArray *sels = @[@"setRate:", @"rate", @"setPlaybackRate:", @"playbackRate",
                      @"setSpeed:", @"speed", @"playAtRate:", @"seekToTime:",
                      @"seekToTime:completion:", @"seekToTime:toleranceBefore:toleranceAfter:",
                      @"currentPosition", @"duration", @"maxPosition", @"getCurrentTime",
                      @"play", @"pause", @"innerPlay", @"innerStop", @"isPlaying"];
    NSMutableArray *hit = [NSMutableArray array];
    for (NSString *s in sels) if ([p respondsToSelector:NSSelectorFromString(s)]) [hit addObject:s];
    return [hit componentsJoinedByString:@", "];
}

// 返回播放器时长（拿不到返回 0）
static double ASBeePlayerDuration(id p) {
    double d = 0;
    if (ASCallDouble(p, @"duration", &d) && d > 0.05) return d;
    if (ASCallDouble(p, @"maxPosition", &d) && d > 0.05) return d;
    return 0;
}

// 屏幕上"像倒计时"的文案 + 它的宿主类名。
// 找到原生 UILabel → 可以按宿主类写精准 hook；一条都找不到 → 说明倒计时是 H5 画的，
// 原生这边再怎么改都没用，只能回到 JS 路线。
static NSMutableSet<NSString *> *gSeenCountdowns = nil;
static NSTimeInterval gLastCountdownScan = 0;

static BOOL ASLooksLikeCountdownText(NSString *t, UIView *host) {
    if (!t.length || t.length > 12) return NO;
    BOOL hasDigit = NO;
    for (NSUInteger i = 0; i < t.length; i++) {
        unichar c = [t characterAtIndex:i];
        if (c >= '0' && c <= '9') { hasDigit = YES; break; }
    }
    if (!hasDigit) return NO;
    if ([t containsString:@"秒"] || [t.lowercaseString containsString:@"s"]) return YES;

    NSString *chain = ASClassChain([host class]).lowercaseString;
    NSArray *kw = @[@"count", @"timer", @"skip", @"reward", @"clock", @"progress"];
    for (NSString *k in kw) if ([chain containsString:k]) return YES;
    return NO;
}

static void ASScanCountdownUI(void) {
    if (!gSeenCountdowns) gSeenCountdowns = [NSMutableSet set];
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - gLastCountdownScan < 1.0) return;
    gLastCountdownScan = now;
    if (gSeenCountdowns.count > 24) return;

    for (UIWindow *w in ASAllWindows()) {
        if (ASIsOwnWindow(w)) continue;
        ASWalkViews(w, 0, ^(UIView *v, int d) {
            NSString *text = nil;
            if ([v isKindOfClass:[UILabel class]]) {
                text = ((UILabel *)v).text;
            } else if ([v isKindOfClass:[UIButton class]]) {
                text = [(UIButton *)v titleForState:UIControlStateNormal];
            }
            if (!text.length) return;
            UIView *host = v.superview ?: v;
            if (!ASLooksLikeCountdownText(text, host)) return;

            NSString *desc = [NSString stringWithFormat:@"%@ \"%@\" 宿主 %@",
                              NSStringFromClass([v class]), text,
                              NSStringFromClass([host class])];
            if ([gSeenCountdowns containsObject:desc]) return;
            [gSeenCountdowns addObject:desc];
            ASRecord([NSString stringWithFormat:@"倒计时UI: %@", desc]);
        });
    }
}

// ---- 激励浏览广告（"浏览14秒得奖励"）------------------------------------
// 这种广告没有视频、没有播放器，只有一条停留计时 + 一个关闭按钮。
// 直通模式下：点掉它的关闭按钮，再从 JS 层补一发 onClose(isEnded=true)。

static void ASFireJsAdClose(void) {
    NSArray *snapshot = nil;
    @synchronized (gWebViews) { snapshot = gWebViews.allObjects; }
    for (WKWebView *w in snapshot) {
        @try {
            [w evaluateJavaScript:@"(window.__asFireAdClose?window.__asFireAdClose():'no-fn')"
                 completionHandler:^(id r, NSError *e) {
                if (r) ASRecord([NSString stringWithFormat:@"JS 补发 onClose → %@", r]);
            }];
        } @catch (__unused NSException *e) {}
    }
}

static NSMutableSet<NSString *> *gDwellHandled = nil;
static NSTimeInterval gLastDwellAction = 0;

#pragma mark - 极速直通：广告出现即消失

// 目标：用户"几乎看不到广告"，但游戏照样发奖。
// 思路（四件事同时做，任何一条生效都能拿到奖励）：
//   1) 把广告容器/广告窗口 alpha 直接设 0 —— 画面还没画出来就没了
//   2) 立刻给它的关闭按钮发 sendActions（alpha=0 不影响事件派发）
//   3) SDK 常弹"再看 14 秒？坚持退出/继续观看"，这里自动选"坚持退出"
//   4) 立刻从 JS 层补发 onClose(isEnded=true)，让游戏自己的发奖逻辑跑起来
// 万一没关干净，1.6 秒后会把藏起来的视图恢复，避免把人卡在黑屏。

static NSTimeInterval gLastInstantKill = 0;
static NSMutableArray<UIWindow *> *gHiddenWins  = nil;
static NSMutableArray<UIView *>   *gHiddenViews = nil;

// 只处理"广告类"的确认框，别把游戏自己的弹窗点了
static BOOL ASIsAdExitAlert(UIAlertController *ac) {
    NSString *s = [NSString stringWithFormat:@"%@ %@", ac.title ?: @"", ac.message ?: @""];
    if ([s containsString:@"离开"] || [s containsString:@"再看"] || [s containsString:@"退出"]) return YES;
    __block BOOL hasLeave = NO;
    for (UIAlertAction *a in ac.actions) {
        NSString *t = a.title ?: @"";
        if ([t containsString:@"退出"] || [t containsString:@"放弃"] || [t containsString:@"坚持"]) hasLeave = YES;
    }
    return hasLeave;
}

static void ASAutoConfirmExitAlert(UIAlertController *ac, int tries) {
    if (!ac || tries > 40) return;
    if (!gFakeAd && !gForceClose) return;

    // 还没上屏就先等，等它真的显示出来再点，否则 handler 里 dismiss 会空转
    if (ac.view.window == nil) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.06 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ ASAutoConfirmExitAlert(ac, tries + 1); });
        return;
    }

    UIAlertAction *pick = nil;
    for (UIAlertAction *a in ac.actions) {
        NSString *t = a.title ?: @"";
        if ([t containsString:@"退出"] || [t containsString:@"放弃"] || [t containsString:@"坚持"] ||
            [t containsString:@"不看了"] || [t containsString:@"关闭"]) { pick = a; break; }
    }
    ASRecord([NSString stringWithFormat:@"自动点掉确认框：%@ | %@",
              ac.title ?: @"", pick.title ?: @"(直接关)"]);
    if (!pick) { [ac dismissViewControllerAnimated:NO completion:nil]; return; }

    id handler = nil;
    @try { handler = [pick valueForKey:@"handler"]; } @catch (__unused NSException *e) {}
    if (handler) { ((void (^)(UIAlertAction *))handler)(pick); }
    else { [ac dismissViewControllerAnimated:NO completion:nil]; }
}

// 广告页上的计时文案："浏览14秒得奖励" / "再看9秒" / "观看广告得奖励"
static BOOL ASIsAdCountdownText(NSString *t) {
    if (t.length == 0) return NO;
    if ([t containsString:@"得奖励"]) return YES;
    if ([t containsString:@"秒"] &&
        ([t containsString:@"浏览"] || [t containsString:@"观看"] ||
         [t containsString:@"再看"] || [t containsString:@"广告"])) return YES;
    return NO;
}

static int ASInstantKillAd(void) {
    if (!ASIsAlipay()) return 0;
    if (!gFakeAd && !gForceClose) return 0;
    if (!gInstant && !gForceClose) return 0;
    if (!gForceClose && UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return 0;

    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - gLastInstantKill < 0.6) return 0;

    NSMutableArray<UIWindow *> *adWins = [NSMutableArray array];
    NSMutableArray<UIView *>   *panels = [NSMutableArray array];
    NSMutableArray<UIButton *> *btns   = [NSMutableArray array];
    NSMutableArray<UIButton *> *corner = [NSMutableArray array];   // 右上角那颗 ✕
    NSMutableArray<UIButton *> *exitBtns = [NSMutableArray array]; // "坚持退出"

    for (UIWindow *w in ASAllWindows()) {
        if (ASIsOwnWindow(w)) continue;
        BOOL winAd = ASNameAdish(NSStringFromClass([w class])) ||
                     ASNameAdish(NSStringFromClass([w.rootViewController class]));

        __block BOOL signal = NO;
        __block UIView *panel = nil;
        NSMutableArray<UIButton *> *winBtns   = [NSMutableArray array];
        NSMutableArray<UIButton *> *winCorner = [NSMutableArray array];
        NSMutableArray<UIButton *> *winExit   = [NSMutableArray array];   // "坚持退出"
        CGRect winB = w.bounds;

        ASWalkViews(w, 0, ^(UIView *v, int d) {
            if (!v.window) return;
            NSString *cn = NSStringFromClass([v class]);
            if (ASNameAdish(cn)) signal = YES;

            if ([v isKindOfClass:[UILabel class]] && ASIsAdCountdownText(((UILabel *)v).text)) {
                signal = YES;
                // 往上找"铺满整屏"的那一层，这才是要藏的广告面板
                UIView *p = v;
                for (int i = 0; i < 10 && p.superview; i++) {
                    p = p.superview;
                    if (CGRectGetWidth(p.bounds) >= CGRectGetWidth(winB) * 0.9 &&
                        CGRectGetHeight(p.bounds) >= CGRectGetHeight(winB) * 0.9) {
                        panel = p;
                        break;
                    }
                }
            }

            if ([v isKindOfClass:[UIButton class]]) {
                UIButton *b = (UIButton *)v;
                if (!b.hidden && b.alpha > 0.01) {
                    NSString *t = [b titleForState:UIControlStateNormal] ?: @"";
                    if (t.length && ([t containsString:@"关闭"] || [t isEqualToString:@"×"] ||
                                     [t isEqualToString:@"X"] || [t containsString:@"跳过"])) {
                        [winBtns addObject:b];
                    }
                    // "再看14秒得奖励  确认离开嘛？[坚持退出][继续观看]" —— 自定义弹窗版
                    if (t.length && ([t containsString:@"退出"] || [t containsString:@"放弃"] ||
                                     [t containsString:@"狠心"] || [t containsString:@"坚持"])) {
                        [winExit addObject:b];
                    }
                    // 右上角大概率是"关闭这条广告"的 ✕（可能没文字）
                    CGRect r = [b convertRect:b.bounds toView:w];
                    if (CGRectGetMaxY(r) < winB.size.height * 0.22 &&
                        r.origin.x > winB.size.width * 0.62 &&
                        CGRectGetWidth(r) > 8 && CGRectGetWidth(r) < winB.size.width * 0.4) {
                        [winCorner addObject:b];
                    }
                }
            }
        });

        if (!signal && !winAd) continue;      // 这个窗口不像广告，里面的按钮一个都不碰
        if (winAd) [adWins addObject:w];
        if (panel) [panels addObject:panel];
        [btns addObjectsFromArray:winBtns];
        [corner addObjectsFromArray:winCorner];
        [exitBtns addObjectsFromArray:winExit];
    }

    if (adWins.count == 0 && panels.count == 0 && btns.count == 0 && exitBtns.count == 0) return 0;

    gLastInstantKill = now;
    if (!gHiddenWins)  gHiddenWins  = [NSMutableArray array];
    if (!gHiddenViews) gHiddenViews = [NSMutableArray array];

    // 1) 先抹掉画面（给按钮发事件不受 alpha 影响）
    for (UIWindow *w in adWins) {
        if (w.alpha > 0.05) { [gHiddenWins addObject:w]; w.alpha = 0.0; }
    }
    for (UIView *v in panels) {
        if (v.alpha > 0.05) { [gHiddenViews addObject:v]; v.alpha = 0.0; }
    }

    // 2) 点按钮：先处理"确认离开"弹窗，再点广告自己的关闭 ✕
    BOOL clicked = NO;
    for (UIButton *b in exitBtns) {
        [b sendActionsForControlEvents:UIControlEventTouchUpInside];
        clicked = YES;
        break;
    }
    if (!clicked) {
        for (UIButton *b in btns) {
            [b sendActionsForControlEvents:UIControlEventTouchUpInside];
            clicked = YES;
            break;
        }
    }
    if (!clicked && corner.count > 0) {
        [corner.firstObject sendActionsForControlEvents:UIControlEventTouchUpInside];
        clicked = YES;
    }

    // 3) 补 JS 关闭（游戏侧 onClose → 发奖），两次，防止第一次还没注册回调
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ ASFireJsAdClose(); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.55 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ ASFireJsAdClose(); });

    // 4) 兜底恢复：真没关掉的话，1.6 秒后把画面放出来，别让人卡住
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        for (UIWindow *w in gHiddenWins) { if (w.alpha < 0.05) w.alpha = 1.0; }
        for (UIView *v in gHiddenViews) { if (v.alpha < 0.05) v.alpha = 1.0; }
        [gHiddenWins removeAllObjects];
        [gHiddenViews removeAllObjects];
    });

    ASRecord([NSString stringWithFormat:@"极速直通：藏 %lu 窗 / %lu 面板，点关闭=%@，已补 JS",
              (unsigned long)adWins.count, (unsigned long)panels.count, clicked ? @"成功" : @"没找到"]);
    return 1;
}

static int ASAutoCloseDwellAd(void) {
    if (!ASIsAlipay()) return 0;
    if (!gFakeAd && !gForceClose) return 0;
    if (gInstant && !gForceClose) return 0;   // 极速直通已经在更早的环节处理了
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - gLastDwellAction < 2.0) return 0;
    if (!gDwellHandled) gDwellHandled = [NSMutableSet set];

    for (UIWindow *w in ASAllWindows()) {
        if (ASIsOwnWindow(w)) continue;
        NSString *key = [NSString stringWithFormat:@"%p", (__bridge void *)w];
        if ([gDwellHandled containsObject:key]) continue;

        __block BOOL dwell = NO;
        NSMutableArray<UIButton *> *btns = [NSMutableArray array];
        ASWalkViews(w, 0, ^(UIView *v, int d) {
            if ([v isKindOfClass:[UILabel class]]) {
                NSString *t = ((UILabel *)v).text;
                if (t.length && ([t containsString:@"得奖励"] || [t containsString:@"浏览"])) dwell = YES;
            } else if ([v isKindOfClass:[UIButton class]]) {
                [btns addObject:(UIButton *)v];
            }
        });
        if (!dwell) { [gDwellHandled removeObject:key]; continue; }

        [gDwellHandled addObject:key];
        UIButton *target = nil;
        for (UIButton *b in btns) {
            if (b.hidden || b.alpha < 0.01) continue;
            NSString *t = [b titleForState:UIControlStateNormal] ?: @"";
            if ([t containsString:@"关闭"] || [t isEqualToString:@"×"] || [t isEqualToString:@"X"]) {
                target = b;
                break;
            }
        }
        if (!target) {
            ASRecord(@"浏览型广告：找到计时文案，但没有可点的关闭按钮");
            return 0;
        }
        gLastDwellAction = now;
        ASRecord([NSString stringWithFormat:@"浏览型广告：点关闭（%@）",
                  [target titleForState:UIControlStateNormal] ?: @"?"]);
        [target sendActionsForControlEvents:UIControlEventTouchUpInside];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ ASFireJsAdClose(); });
        return 1;
    }
    return 0;
}

static void ASDriveBeePlayers(void) {
    if (!ASEngineOn()) return;
    if (!gAdFirstSeen) gAdFirstSeen = [NSMutableDictionary dictionary];
    if (!gAdStepsDone) gAdStepsDone = [NSMutableSet set];

    NSMutableArray<UIView *> *players = [NSMutableArray array];
    for (UIWindow *w in ASAllWindows()) {
        if (ASIsOwnWindow(w)) continue;
        ASWalkViews(w, 0, ^(UIView *v, int d) {
            if (!v.window || v.hidden || v.alpha < 0.01) return;
            NSString *cn = NSStringFromClass([v class]);
            if ([cn containsString:@"BeeVideoPlayer"]) [players addObject:v];
        });
    }
    if (players.count == 0) return;

    // 播放器在屏 = 广告正在播；把"广告窗口"打开，NSTimer 压缩才会真正生效
    // （v7 之前这个时间戳只由 Ad* 视图名触发，而这条链上根本没有 Ad* 类）
    gAdSeenAt = [NSDate timeIntervalSinceReferenceDate];

    @try { ASScanCountdownUI(); } @catch (__unused NSException *e) {}

    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];

    for (UIView *p in players) {
        NSString *key = ASPtrKey(p);
        NSNumber *t0 = gAdFirstSeen[key];
        if (!t0) {
            gAdFirstSeen[key] = @(now);
            ASRecord([NSString stringWithFormat:@"BEE 播放器出现  %@", ASProbeBeePlayer(p)]);
            continue;
        }
        double el = now - t0.doubleValue;

        // 每一轮都补一次倍速：SDK 常把自己被改过的 rate 拨回 1.0
        @try {
            BOOL set = ASCallVoidDouble(p, @"setRate:", gRate);
            if (!set) set = ASCallVoidDouble(p, @"setPlaybackRate:", gRate);
            if (!set) set = ASCallVoidDouble(p, @"setSpeed:", gRate);
            if (!set) set = ASCallVoidDouble(p, @"playAtRate:", gRate);

            // 只报一次：设完读回来，看倍速到底吃进去没有
            NSString *kr = [key stringByAppendingString:@"#rate"];
            if (![gAdStepsDone containsObject:kr]) {
                [gAdStepsDone addObject:kr];
                double back = -1;
                if (ASCallDouble(p, @"playbackRate", &back) ||
                    ASCallDouble(p, @"rate", &back) ||
                    ASCallDouble(p, @"speed", &back)) {
                    ASRecord([NSString stringWithFormat:@"BEE 倍速 设定%gx → 实际%.2fx %@",
                              gRate, back, (back > 1.05 ? @"生效" : @"被拒/无效")]);
                } else {
                    ASRecord([NSString stringWithFormat:@"BEE 倍速 设定%gx，但读不到当前值（%@）",
                              gRate, set ? @"已调用" : @"无可用 setter"]);
                }
            }
        } @catch (__unused NSException *e) {}

        double dur = ASBeePlayerDuration(p);

        // +1.2s：直接把进度怼到片尾，让它自己触发 finished（可在菜单里关掉）
        NSString *k1 = [key stringByAppendingString:@"#seek1"];
        if (gSeekToEnd && el >= 1.2 && ![gAdStepsDone containsObject:k1]) {
            [gAdStepsDone addObject:k1];
            double target = dur > 0 ? dur : 9999.0;
            BOOL ok = ASCallVoidDouble(p, @"seekToTime:", target);
            if (ok) ASRecord([NSString stringWithFormat:@"BEE 跳片尾 %.1fs（时长 %.1fs）", target, dur]);
            else ASRecord(@"BEE seekToTime: 不可用");
        }

        // +2.6s：还没结束就再推一次（越过片尾一点，逼出完成回调）
        NSString *k2 = [key stringByAppendingString:@"#seek2"];
        if (el >= 2.6 && ![gAdStepsDone containsObject:k2]) {
            [gAdStepsDone addObject:k2];
            double target = dur > 0 ? dur + 1.0 : 9999.0;
            if (ASCallVoidDouble(p, @"seekToTime:", target)) {
                ASRecord([NSString stringWithFormat:@"BEE 二次跳片尾 %.1fs", target]);
            }
        }

        // +3.6s：seek 不管用就直接冒充播放器，给它的 delegate 发"播完了"
        NSString *k3 = [key stringByAppendingString:@"#finish"];
        if (el >= 3.6 && ![gAdStepsDone containsObject:k3]) {
            [gAdStepsDone addObject:k3];
            id dg = ASCallObject(p, @"delegate");
            if (!dg) dg = ASCallObject(p, @"videoPlayerDelegate");
            if (!dg) {
                ASRecord(@"BEE 拿不到 delegate，跳过模拟结束");
            } else {
                NSString *dn = NSStringFromClass([dg class]);
                BOOL sent = NO;
                SEL fin = NSSelectorFromString(@"BeeVideoPlayerFinished");
                if ([dg respondsToSelector:fin]) {
                    @try { ((void (*)(id, SEL))objc_msgSend)(dg, fin); sent = YES; } @catch (__unused NSException *e) {}
                }
                SEL pt = NSSelectorFromString(@"BeeVideoPlayerPlayedTime:");
                if ([dg respondsToSelector:pt]) {
                    @try {
                        ((void (*)(id, SEL, double))objc_msgSend)(dg, pt, dur > 0 ? dur : 9999.0);
                        sent = YES;
                    } @catch (__unused NSException *e) {}
                }
                ASRecord([NSString stringWithFormat:@"BEE 模拟结束 → %@ %@", dn, sent ? @"已发送" : @"delegate 无对应方法"]);
            }
        }
    }
}

#pragma mark - 诊断报告

static NSString *ASBuildInterfaceReport(void) {
    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"AdSpeeder 诊断 v9\n倍速: %gx (%@)   自动秒过: %@   跳片尾: %@   直通: %@   通用hook: %lu   计时器压缩: %d\n\n",
     gRate, ASEngineOn() ? @"开" : @"关", gAutoSkip ? @"开" : @"关",
     gSeekToEnd ? @"开" : @"关", gFakeAd ? @"开" : @"关",
     (unsigned long)gGenHooked.count, gTimerHits];

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
    copy.tag = 2001;
    copy.frame = CGRectMake(16, by, (b.size.width - 44) / 2, 44);
    [copy setTitle:@"📋 复制全文" forState:UIControlStateNormal];
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

    // 面板一打开就把全文塞进剪贴板，不用再点
    [self doCopy];
}

- (void)doCopy {
    NSString *text = self.body ?: @"";
    UIPasteboard.generalPasteboard.string = text;

    for (UIView *v in self.view.subviews) {
        if ([v isKindOfClass:[UIButton class]] && v.tag == 2001) {
            UIButton *btn = (UIButton *)v;
            [btn setTitle:[NSString stringWithFormat:@"✓ 已复制 %lu 字", (unsigned long)text.length]
                forState:UIControlStateNormal];
            btn.backgroundColor = [UIColor colorWithRed:0.09 green:0.62 blue:0.35 alpha:1];
        }
    }
    [self showToast:@"已复制到剪贴板，直接去粘贴即可"];
}

- (void)showToast:(NSString *)msg {
    UIView *old = [self.view viewWithTag:2002];
    if (old) [old removeFromSuperview];

    CGRect b = self.view.bounds;
    UILabel *toast = [[UILabel alloc] initWithFrame:CGRectMake(24, b.size.height / 2 - 26,
                                                              b.size.width - 48, 52)];
    toast.tag = 2002;
    toast.text = msg;
    toast.numberOfLines = 2;
    toast.textAlignment = NSTextAlignmentCenter;
    toast.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    toast.textColor = [UIColor whiteColor];
    toast.backgroundColor = [UIColor colorWithRed:0.09 green:0.62 blue:0.35 alpha:0.96];
    toast.layer.cornerRadius = 12;
    toast.layer.masksToBounds = YES;
    toast.alpha = 0;
    [self.view addSubview:toast];

    [UIView animateWithDuration:0.18 animations:^{ toast.alpha = 1; } completion:^(BOOL ok) {
        [UIView animateWithDuration:0.35 delay:1.5 options:0 animations:^{ toast.alpha = 0; }
                         completion:^(BOOL done) { [toast removeFromSuperview]; }];
    }];
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

    [sheet addAction:[UIAlertAction actionWithTitle:(gAutoSkip ? @"✅ 自动秒过：开" : @"⬜️ 自动秒过：关")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        gAutoSkip = !gAutoSkip;
        ASSavePrefs();
        ASRecord([NSString stringWithFormat:@"自动秒过 %@", gAutoSkip ? @"开" : @"关"]);
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:(gSeekToEnd ? @"⏭ 自动跳片尾：开" : @"⏭ 自动跳片尾：关")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        gSeekToEnd = !gSeekToEnd;
        ASSavePrefs();
        ASRecord([NSString stringWithFormat:@"自动跳片尾 %@", gSeekToEnd ? @"开" : @"关"]);
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:(gFakeAd ? @"🎮 直通广告回调：开" : @"🎮 直通广告回调：关")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        gFakeAd = !gFakeAd;
        ASSavePrefs();
        ASPushFakeAdToWebViews();
        ASRecord([NSString stringWithFormat:@"JS 直通广告回调 %@（下次点广告生效）", gFakeAd ? @"开" : @"关"]);
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:(gInstant ? @"⚡ 极速直通（广告一闪就没）：开" : @"⚡ 极速直通（广告一闪就没）：关")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        gInstant = !gInstant;
        ASSavePrefs();
        ASRecord([NSString stringWithFormat:@"极速直通 %@", gInstant ? @"开" : @"关"]);
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"⚡ 秒关当前广告" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        gLastDwellAction = 0;
        gLastInstantKill = 0;
        if (gDwellHandled) [gDwellHandled removeAllObjects];
        gForceClose = YES;
        int hit = ASInstantKillAd();
        if (!hit) hit = ASAutoCloseDwellAd();
        gForceClose = NO;
        ASFireJsAdClose();
        ASRecord([NSString stringWithFormat:@"手动秒关：%@", hit ? @"已点关闭" : @"没找到广告容器"]);
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"⚡ 秒过当前广告" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSMutableString *detail = [NSMutableString string];
        (void)ASForceSkipNow(detail);
        ASDiagController *vc = [[ASDiagController alloc] init];
        vc.heading = @"秒过结果";
        vc.body = detail.length ? detail : @"(无输出)";
        [root presentViewController:vc animated:YES completion:nil];
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"🧾 视图时间线" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        ASDiagController *vc = [[ASDiagController alloc] init];
        vc.heading = @"广告期间冒出来的视图";
        vc.body = ASBuildTimelineReport();
        [root presentViewController:vc animated:YES completion:nil];
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"🎯 广告实例" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        ASDiagController *vc = [[ASDiagController alloc] init];
        vc.heading = @"广告实例 / BEE 播放器";
        vc.body = ASBuildAdInstanceReport();
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

    Class alertCls = objc_getClass("UIAlertController");
    if (alertCls) {
        ASSwizzleClass(object_getClass(alertCls),
                       @selector(alertControllerWithTitle:message:preferredStyle:),
                       (IMP)ASMyAlert, (IMP *)&gOrigAlert);
    }

    Class winCls = objc_getClass("UIWindow");
    if (winCls) {
        ASSwizzle(winCls, @selector(makeKeyAndVisible), (IMP)ASMyMakeVisible, &gOrigMakeVisible);
    }

    ASStartRateWatchdog();
    ASStartAdMonitor();
    ASInstallTimerHooks();

    // 极速直通的"哨兵"：0.15 秒一轮，发现广告就抹掉画面 + 点关闭 + 补 JS
    {
        NSTimer *fast = [NSTimer timerWithTimeInterval:0.15 repeats:YES block:^(NSTimer *timer) {
            @try {
                if (gInstant || gForceClose) ASInstantKillAd();
            } @catch (__unused NSException *e) {}
        }];
        [[NSRunLoop mainRunLoop] addTimer:fast forMode:NSRunLoopCommonModes];
    }

    NSLog(@"[AdSpeeder] v10 installed (setRate=%d, play=%d, atRate=%d, setRateTime=%d, pvc=%d, wk=%d, present=%d, makeVisible=%d, rate=%gx, autoSkip=%d, instant=%d)",
          gOrigSetRate != NULL, gOrigPlay != NULL, gOrigPlayAtRate != NULL,
          gOrigSetRateTime != NULL, gOrigSetPVPlayer != NULL,
          gOrigInitWithFrameConfig != NULL, gOrigPresent != NULL,
          gOrigMakeVisible != NULL, gRate, (int)gAutoSkip, (int)gInstant);

    // 通用倍速 hook + BEE 广告 hook：模块可能在启动后才加载，分几轮补
    for (NSNumber *delay in @[@0.5, @2.0, @5.0, @10.0]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            @try { ASInstallGenericRateHooks(); } @catch (__unused NSException *e) {}
            @try { ASInstallBeeHooks(); } @catch (__unused NSException *e) {}
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
