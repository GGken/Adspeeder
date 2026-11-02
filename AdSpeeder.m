//
//  AdSpeeder lite
//  只做一件事：支付宝里的小游戏点"看广告"时，不再播广告，直接把"看完了"回调给游戏。
//
//  两层，互为备份：
//    1) JS 层（主力）：在小游戏 WebView 里接管 my.createRewardedAd / createRewardedVideoAd，
//       show() 不发原生请求，直接回调 onClose({isEnded:true}) → 游戏自己发奖。
//    2) 原生层（兜底）：某条广告没走上面这条路时，一露头就把画面 alpha 抹成 0，
//       顺手点掉"关闭 / 坚持退出"，1.6 秒后自动恢复，不会卡死。
//
//  没有悬浮球、没有倍速、没有菜单、没有诊断页 —— 装上就是开着的。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#include <stdarg.h>

#pragma mark - 基础

static void ASLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[AdSpeeder] %@", msg);
}

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

#pragma mark - 窗口 / 视图

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

static void ASWalkViews(UIView *v, int depth, void (^visit)(UIView *, int)) {
    if (!v || depth > 30) return;
    visit(v, depth);
    for (UIView *s in [v.subviews copy]) ASWalkViews(s, depth + 1, visit);
}

// 名字像"广告容器"的，才允许动它的画面
static BOOL ASNameAdish(NSString *name) {
    if (name.length < 4) return NO;
    NSString *l = name.lowercaseString;
    NSArray *kw = @[@"reward", @"interstitial", @"adview", @"advideo", @"adplayer",
                    @"adcontainer", @"adwindow", @"adpage", @"splashad", @"beereward",
                    @"beead", @"beevideoplayer", @"advideoplayer", @"promotion",
                    @"advert", @"adweb", @"adlanding", @"adfullscreen", @"adfull"];
    for (NSString *k in kw) if ([l containsString:k]) return YES;
    return NO;
}

// 支付宝小程序自身的界面（顶栏胶囊 ··· / ×、导航栏、工具栏）——碰一下用户就没法关小程序了，
// 所以给它们单独贴个"禁碰"标记，任何 hide / 点击都要先过这道闸。
static BOOL ASIsProtectedChrome(UIView *v) {
    if (!v) return NO;
    NSString *cn = NSStringFromClass([v class]) ?: @"";
    NSString *lower = cn.lowercaseString;
    NSArray *clsKw = @[@"capsule", @"navbar", @"navigationbar", @"titlebar",
                       @"titleview", @"toolbar", @"tabbar", @"padtool", @"padview",
                       @"beepad", @"h5titlebar", @"appbanner", @"optionmenu"];
    for (NSString *k in clsKw) if ([lower containsString:k]) return YES;

    NSString *al = v.accessibilityLabel ?: @"";
    NSString *idf = v.accessibilityIdentifier ?: @"";
    NSString *all = [NSString stringWithFormat:@"%@ %@", al, idf];
    if (all.length > 2) {
        NSArray *alKw = @[@"关闭小程序", @"小程序", @"更多", @"胶囊",
                          @"close mini", @"more", @"capsule"];
        for (NSString *k in alKw) {
            if ([all rangeOfString:k options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
        }
    }
    return NO;
}

// 整棵子树里有没有上面那些东西（藏容器之前必须先问一遍）
static BOOL ASSubtreeHasProtectedChrome(UIView *root) {
    if (!root) return NO;
    __block BOOL found = NO;
    ASWalkViews(root, 0, ^(UIView *v, int d) {
        if (found) return;
        if (ASIsProtectedChrome(v)) found = YES;
    });
    return found;
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

#pragma mark - JS 直通

// 页面一开始就注入（所有 frame），开关值直接写死成 1：
// 之前用 window.__asFakeAd 传开关，实测游戏页会把 window 上的自定义属性弄丢，
// 导致 show() 时读到 0、广告照样播。写死在源码里最稳。
static NSString *const kShimJS =
@"(function(){"
 "if(window.__asShim)return;window.__asShim=1;"
 "function log(m){try{window.webkit.messageHandlers.aslog.postMessage('[JS] '+m);}catch(e){}}"
 "var U='';try{U=String(location.href).slice(0,60);}catch(e){}"
 "log('shim '+U);"
 "window.__asFireAdClose=function(){var cb=window.__asAdCloseCb;if(!cb)return 'no-cb';"
 "if(window.__asFired)return 'already';window.__asFired=1;"
 "try{cb({isEnded:true,count:1,completed:true,reward:true});}catch(e){return 'err';}return 'ok';};"
 "function targets(){var a=[];"
 "try{if(window.my)a.push(window.my);}catch(e){}"
 "try{if(window.antgame){a.push(window.antgame);"
 "if(window.antgame.ad)a.push(window.antgame.ad);"
 "if(window.antgame.my)a.push(window.antgame.my);}}catch(e){}"
 "try{if(window.ap&&window.ap.my)a.push(window.ap.my);}catch(e){}"
 "return a;}"
 "var KNOWN=['createRewardedAd','createRewardedVideoAd','createInterstitialAd'];"
 "function hook(ad,src){if(!ad)return;"
 "try{if(ad.__asHooked)return;ad.__asHooked=1;}catch(e){return;}"
 "var oc=null;try{oc=ad.onClose;}catch(e){}"
 "try{ad.onClose=function(cb){window.__asAdCloseCb=cb;log('onClose 注册('+src+')');"
 "if(!oc)return;"
 "var w=function(res){if(window.__asFired)return;window.__asFired=1;"
 "var out={isEnded:true,count:1,completed:true,reward:true};"
 "try{if(res&&typeof res==='object'){for(var k in res)out[k]=res[k];}"
 "out.isEnded=true;out.count=1;out.completed=true;}catch(e){}"
 "log('原生 onClose 改写 isEnded=true');"
 "try{cb&&cb(out);}catch(e){log('cb 抛错 '+e);}};"
 "return oc.call(ad,w);};}catch(e){log('onClose 接管失败 '+e);}"
 "var os=null;try{os=ad.show;}catch(e){}"
 "try{ad.show=function(){window.__asFired=0;log('show 直通 ('+src+')');"
 "var n=0;(function fire(){var cb=window.__asAdCloseCb;"
 "if(!cb&&++n<25){setTimeout(fire,200);return;}"
 "if(window.__asFired)return;window.__asFired=1;"
 "log('直接回 onClose isEnded=true cb='+(cb?'有':'无'));"
 "try{if(cb)cb({isEnded:true,count:1,completed:true,reward:true});}catch(e){log('cb 抛错 '+e);}})();"
 "try{return Promise.resolve();}catch(e){return;}};}catch(e){log('show 接管失败 '+e);}"
 "var ol=null;try{ol=ad.load;}catch(e){}"
 "try{ad.load=function(){var r=null;try{r=ol?ol.apply(ad,arguments):null;}catch(e){}"
 "return (r&&r.then)?r:Promise.resolve();};}catch(e){}}"
 "var tries=0;"
 "function scan(){var t=targets(),n=0;"
 "for(var i=0;i<t.length;i++){var o=t[i];if(!o)continue;"
 "for(var j=0;j<KNOWN.length;j++){var nm=KNOWN[j],f=null;"
 "try{f=o[nm];}catch(e){}if(typeof f!=='function')continue;"
 "if(o['__asW_'+nm])continue;"
 "try{(function(obj,name,orig){var w=function(){var ad=null;"
 "try{ad=orig.apply(obj,arguments);}catch(e){log('调用 '+name+' 抛错 '+e);return null;}"
 "try{hook(ad,name);}catch(e){}return ad;};obj[name]=w;"
 "if(obj[name]===w){obj['__asW_'+name]=1;log('已接管 '+name);n++;}"
 "else log('接管失败(只读) '+name);})(o,nm,f);}catch(e){log('接管失败 '+nm+' '+e);}}}"
 "if(n===0){if(++tries<240)setTimeout(scan,250);"
 "else log('没找到广告 API（my='+(typeof window.my)+'）');}}"
 "scan();})();";

@interface ASJSBridge : NSObject <WKScriptMessageHandler>
@end

@implementation ASJSBridge
- (void)userContentController:(WKUserContentController *)ucc didReceiveScriptMessage:(WKScriptMessage *)message {
    @try {
        if (message.body) ASLog(@"%@", message.body);
    } @catch (__unused NSException *e) {}
}
@end

static ASJSBridge *gBridge = nil;
static NSHashTable<WKWebView *> *gWebViews = nil;
static NSMutableSet<NSString *> *gAdopted = nil;
static IMP gOrigInitWithFrameConfig = NULL;

static void ASAdoptWebView(WKWebView *wv) {
    if (!wv) return;
    if (!gWebViews) gWebViews = [NSHashTable weakObjectsHashTable];
    if (!gAdopted) gAdopted = [NSMutableSet set];
    @synchronized (gWebViews) { [gWebViews addObject:wv]; }

    NSString *key = [NSString stringWithFormat:@"%p", (__bridge void *)wv];
    if ([gAdopted containsObject:key]) return;
    [gAdopted addObject:key];

    @try {
        [wv evaluateJavaScript:kShimJS completionHandler:nil];
    } @catch (__unused NSException *e) {}
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
        // forMainFrameOnly:NO —— 小游戏跑在 iframe 里，子 frame 也必须拿到脚本
        [ucc addUserScript:[[WKUserScript alloc] initWithSource:kShimJS
                                                    injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                                 forMainFrameOnly:NO]];
    }
    id result = ((id (*)(id, SEL, CGRect, id))gOrigInitWithFrameConfig)(self, _cmd, frame, config);
    if (result) ASAdoptWebView((WKWebView *)result);
    return result;
}

// 有些 WebView 在建 dylib 之后才出现，定期扫窗口把漏掉的补上（脚本本身幂等）
static void ASScanWebViews(void) {
    if (!ASIsAlipay()) return;
    for (UIWindow *w in ASAllWindows()) {
        ASWalkViews(w, 0, ^(UIView *v, int d) {
            if ([v isKindOfClass:[WKWebView class]]) ASAdoptWebView((WKWebView *)v);
        });
    }
}

#pragma mark - 兜底：广告露头就抹掉

static NSTimeInterval gLastKill = 0;
static NSMutableArray<UIWindow *> *gHiddenWins = nil;
static NSMutableArray<UIView *> *gHiddenViews = nil;

static int ASKillAdNow(void) {
    if (!ASIsAlipay()) return 0;
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return 0;

    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - gLastKill < 0.6) return 0;

    NSMutableArray<UIWindow *> *adWins = [NSMutableArray array];
    NSMutableArray<UIView *> *panels = [NSMutableArray array];
    NSMutableArray<UIButton *> *closeBtns = [NSMutableArray array];
    NSMutableArray<UIButton *> *exitBtns = [NSMutableArray array];

    for (UIWindow *w in ASAllWindows()) {
        BOOL winAd = ASNameAdish(NSStringFromClass([w class])) ||
                     ASNameAdish(NSStringFromClass([w.rootViewController class]));

        __block BOOL signal = NO;
        __block BOOL chrome = NO;
        __block UIView *panel = nil;
        NSMutableArray<UIButton *> *winClose = [NSMutableArray array];
        NSMutableArray<UIButton *> *winExit = [NSMutableArray array];
        CGRect winB = w.bounds;

        ASWalkViews(w, 0, ^(UIView *v, int d) {
            if (!v.window) return;
            if (ASIsProtectedChrome(v)) { chrome = YES; return; }   // 胶囊/顶栏：连看都不看
            if (ASNameAdish(NSStringFromClass([v class]))) signal = YES;

            if ([v isKindOfClass:[UILabel class]] && ASIsAdCountdownText(((UILabel *)v).text)) {
                signal = YES;
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
                if (b.hidden || b.alpha < 0.01) return;
                NSString *t = [b titleForState:UIControlStateNormal] ?: @"";
                if (t.length && ([t containsString:@"关闭"] || [t isEqualToString:@"×"] ||
                                 [t isEqualToString:@"X"] || [t containsString:@"跳过"])) {
                    [winClose addObject:b];
                }
                if (t.length && ([t containsString:@"退出"] || [t containsString:@"放弃"] ||
                                 [t containsString:@"坚持"])) {
                    [winExit addObject:b];
                }
                // 以前这里会"盲点右上角那颗 ✕"，正好点中支付宝关小程序的胶囊 —— 已删除
            }
        });

        // 两条铁律：
        //   ① 窗口里出现胶囊/顶栏 → 这是宿主小程序窗口，整窗放过，一个控件都不碰
        //   ② 只有窗口名字明确像广告时才动手（宿主窗口即使有广告信号也不动）
        if (chrome || !winAd) continue;
        if (!signal) continue;                       // 名字像广告但里面什么都没抓到，不动
        if (panel && ASSubtreeHasProtectedChrome(panel)) panel = nil;
        if (!ASSubtreeHasProtectedChrome(w)) [adWins addObject:w];
        if (panel) [panels addObject:panel];
        [closeBtns addObjectsFromArray:winClose];
        [exitBtns addObjectsFromArray:winExit];
    }

    if (adWins.count == 0 && panels.count == 0 && closeBtns.count == 0 && exitBtns.count == 0) return 0;

    gLastKill = now;
    if (!gHiddenWins) gHiddenWins = [NSMutableArray array];
    if (!gHiddenViews) gHiddenViews = [NSMutableArray array];

    for (UIWindow *w in adWins) {
        if (ASSubtreeHasProtectedChrome(w)) continue;      // 动手前再确认一遍
        if (w.alpha > 0.05) { [gHiddenWins addObject:w]; w.alpha = 0.0; }
    }
    for (UIView *v in panels) {
        if (ASSubtreeHasProtectedChrome(v)) continue;
        if (v.alpha > 0.05) { [gHiddenViews addObject:v]; v.alpha = 0.0; }
    }

    BOOL clicked = NO;
    for (UIButton *b in exitBtns) { [b sendActionsForControlEvents:UIControlEventTouchUpInside]; clicked = YES; break; }
    if (!clicked) for (UIButton *b in closeBtns) { [b sendActionsForControlEvents:UIControlEventTouchUpInside]; clicked = YES; break; }

    // 再从 JS 层补一发，双保险
    NSArray *all = nil;
    @synchronized (gWebViews) { all = gWebViews.allObjects; }
    for (WKWebView *wv in all) {
        @try { [wv evaluateJavaScript:@"(window.__asFireAdClose?window.__asFireAdClose():'no')" completionHandler:nil]; }
        @catch (__unused NSException *e) {}
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        for (UIWindow *w in gHiddenWins) { if (w.alpha < 0.05) w.alpha = 1.0; }
        for (UIView *v in gHiddenViews) { if (v.alpha < 0.05) v.alpha = 1.0; }
        [gHiddenWins removeAllObjects];
        [gHiddenViews removeAllObjects];
    });

    ASLog(@"兜底处理：藏 %lu 窗 / %lu 面板，点按钮=%@",
          (unsigned long)adWins.count, (unsigned long)panels.count, clicked ? @"是" : @"否");
    return 1;
}

// 广告 SDK 的"再看 N 秒？坚持退出 / 继续观看"，自动替用户选退出
static IMP gOrigAlertFactory = NULL;

static void ASAutoConfirm(UIAlertController *ac, int tries) {
    if (!ac || tries > 40) return;
    if (ac.view.window == nil) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.06 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ ASAutoConfirm(ac, tries + 1); });
        return;
    }
    UIAlertAction *pick = nil;
    for (UIAlertAction *a in ac.actions) {
        NSString *t = a.title ?: @"";
        if ([t containsString:@"退出"] || [t containsString:@"放弃"] || [t containsString:@"坚持"]) { pick = a; break; }
    }
    if (!pick) return;
    ASLog(@"自动点掉确认框：%@", pick.title ?: @"");
    id handler = nil;
    @try { handler = [pick valueForKey:@"handler"]; } @catch (__unused NSException *e) {}
    if (handler) { ((void (^)(UIAlertAction *))handler)(pick); }
}

static id ASMyAlertFactory(id self, SEL _cmd, NSString *title, NSString *message, NSInteger style) {
    if (!gOrigAlertFactory) return nil;
    id ac = gOrigAlertFactory(self, _cmd, title, message, style);
    @try {
        NSString *s = [NSString stringWithFormat:@"%@ %@", title ?: @"", message ?: @""];
        if (ac && [ac isKindOfClass:[UIAlertController class]] &&
            ([s containsString:@"离开"] || [s containsString:@"再看"] || [s containsString:@"退出"])) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.03 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ ASAutoConfirm((UIAlertController *)ac, 0); });
        }
    } @catch (__unused NSException *e) {}
    return ac;
}

// 广告窗口 makeKeyAndVisible 时就先藏起来，一帧都不给它画
static IMP gOrigMakeVisible = NULL;

static void ASMyMakeVisible(UIWindow *self, SEL _cmd) {
    @try {
        BOOL adLike = ASNameAdish(NSStringFromClass([self class])) ||
                      ASNameAdish(NSStringFromClass([self.rootViewController class]));
        // 就算名字像广告，只要里面装着支付宝的胶囊/顶栏，也一律不藏
        if (ASIsAlipay() && adLike &&
            !ASSubtreeHasProtectedChrome(self.rootViewController.view)) {
            self.alpha = 0.0;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ ASKillAdNow(); });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ if (self.alpha < 0.05) self.alpha = 1.0; });
        }
    } @catch (__unused NSException *e) {}
    ((void (*)(id, SEL))gOrigMakeVisible)(self, _cmd);
}

#pragma mark - 入口

__attribute__((constructor))
static void AdSpeederInit(void) {
    if (!ASIsAlipay()) {
        NSLog(@"[AdSpeeder] 不是支付宝，跳过");
        return;
    }

    Class wk = objc_getClass("WKWebView");
    if (wk) {
        ASSwizzle(wk, @selector(initWithFrame:configuration:),
                  (IMP)ASMyInitWithFrameConfig, &gOrigInitWithFrameConfig);
    }

    Class winCls = objc_getClass("UIWindow");
    if (winCls) {
        ASSwizzle(winCls, @selector(makeKeyAndVisible), (IMP)ASMyMakeVisible, &gOrigMakeVisible);
    }

    Class alertCls = objc_getClass("UIAlertController");
    if (alertCls) {
        Class meta = object_getClass((id)alertCls);
        Method m = class_getInstanceMethod(meta, @selector(alertControllerWithTitle:message:preferredStyle:));
        if (m) {
            gOrigAlertFactory = method_getImplementation(m);
            method_setImplementation(m, (IMP)ASMyAlertFactory);
        }
    }

    // 兜底扫描：0.15 秒一次（只在 App 前台时干活）
    NSTimer *fast = [NSTimer timerWithTimeInterval:0.15 repeats:YES block:^(NSTimer *t) {
        @try { ASKillAdNow(); } @catch (__unused NSException *e) {}
    }];
    [[NSRunLoop mainRunLoop] addTimer:fast forMode:NSRunLoopCommonModes];

    // 补注入：1 秒一次，把后来才出现的 WebView 也接管掉
    NSTimer *adopt = [NSTimer timerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
        @try { ASScanWebViews(); } @catch (__unused NSException *e) {}
    }];
    [[NSRunLoop mainRunLoop] addTimer:adopt forMode:NSRunLoopCommonModes];

    NSLog(@"[AdSpeeder] lite v12 已加载（WebView=%d, makeVisible=%d, alert=%d）",
          gOrigInitWithFrameConfig != NULL, gOrigMakeVisible != NULL, gOrigAlertFactory != NULL);
}
