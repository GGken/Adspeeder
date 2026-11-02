//
//  AdSpeeder  (clean rebuild)
//
//  作用域：只有支付宝（com.alipay.*）。
//  作用：小游戏点「观看广告」时，不播放广告，直接把「看完了」回调交给游戏，游戏自己发奖。
//
//  实现分两层：
//    1) JS 层（主力）—— 在小游戏 WebView 文档开始时就注入脚本，
//       接管 my.createRewardedAd / createRewardedVideoAd / createInterstitialAd，
//       show() 不发原生请求，直接回调 onClose({isEnded:true, count:1, completed:true})。
//       开关值在注入时写死为 1，不依赖页面上的任何变量，避免被游戏页覆盖。
//    2) 原生层（兜底）—— 极少数不走上面那条路的广告，才会出现原生容器。
//       只处理「类名明确像广告」的窗口：把画面 alpha 抹掉、点掉带「关闭/跳过/退出」字样的按钮、
//       再从 JS 层补一次 onClose，1.6 秒后自动恢复，避免卡黑屏。
//       宿主小程序窗口（装着顶栏 ··· / × 的那个）永远不在处理范围内，不做任何隐藏或点击。
//
//  没有悬浮球、没有菜单、没有倍速、没有诊断页 —— 装上去就是开着的。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#include <stdarg.h>

#pragma mark - 基础工具

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

static BOOL ASSwizzleInstance(Class cls, SEL sel, IMP newImp, IMP *outOrig) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    if (outOrig) *outOrig = method_getImplementation(m);
    method_setImplementation(m, newImp);
    return YES;
}

#pragma mark - 窗口 / 视图

static NSArray<UIWindow *> *ASAllWindows(void) {
    NSMutableArray<UIWindow *> *out = [NSMutableArray array];
    @try {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (![out containsObject:w]) [out addObject:w];
            }
        }
    } @catch (__unused NSException *e) {}
    return out;
}

static void ASWalkViews(UIView *root, int depth, void (^visit)(UIView *, int)) {
    if (!root || depth > 30) return;
    visit(root, depth);
    for (UIView *sub in [root.subviews copy]) ASWalkViews(sub, depth + 1, visit);
}

// 只有类名明确写着"广告"的才认，避免误伤其它界面
static BOOL ASAdLikeName(NSString *name) {
    if (name.length < 4) return NO;
    NSString *lower = name.lowercaseString;
    NSArray<NSString *> *keys = @[@"reward", @"interstitial", @"advert", @"adview",
                                  @"advideo", @"adplayer", @"adcontainer", @"adwindow",
                                  @"adpage", @"adweb", @"adfull", @"splashad"];
    for (NSString *k in keys) {
        if ([lower containsString:k]) return YES;
    }
    return NO;
}

// 广告页上的计时文案："浏览14秒得奖励" / "再看9秒" / "观看广告得奖励"
static BOOL ASIsAdCountdownText(NSString *text) {
    if (text.length == 0) return NO;
    if ([text containsString:@"得奖励"]) return YES;
    if ([text containsString:@"秒"] &&
        ([text containsString:@"浏览"] || [text containsString:@"观看"] ||
         [text containsString:@"再看"] || [text containsString:@"广告"])) return YES;
    return NO;
}

#pragma mark - JS 直通（主力）

// 注入时机：WKWebView 的 document start，所有 frame 都注入。
// 关键点：整段逻辑里没有任何开关变量，注入即生效；游戏页改 window 也影响不到它。
static NSString *const kShimJS =
@"(function(){"                                                                           // 幂等外壳
 "if(window.__asShim)return;window.__asShim=1;"
 "function log(m){try{window.webkit.messageHandlers.aslog.postMessage('[JS] '+m);}catch(e){}}"
 "log('shim 注入 '+String(location.href||'').slice(0,60));"

 // 原生兜底会用这个函数补一发"看完了"
 "window.__asFireAdClose=function(){"
   "var cb=window.__asAdCloseCb;if(!cb)return 'no-cb';"
   "if(window.__asFired)return 'already';window.__asFired=1;"
   "try{cb({isEnded:true,count:1,completed:true,reward:true});}catch(e){return 'err';}"
   "return 'ok';};"

 // 广告 API 可能挂在 my / antgame / antgame.my / ap.my 上，全都试一遍
 "function targets(){var a=[];"
   "try{if(window.my)a.push(window.my);}catch(e){}"
   "try{if(window.antgame){a.push(window.antgame);"
     "if(window.antgame.ad)a.push(window.antgame.ad);"
     "if(window.antgame.my)a.push(window.antgame.my);}}catch(e){}"
   "try{if(window.ap&&window.ap.my)a.push(window.ap.my);}catch(e){}"
   "return a;}"

 "var NAMES=['createRewardedAd','createRewardedVideoAd','createInterstitialAd'];"

 // 接管一个广告实例：onClose 记下来、show 改成直接回调
 "function hook(ad,src){if(!ad)return;"
   "try{if(ad.__asHooked)return;ad.__asHooked=1;}catch(e){return;}"
   "var origOnClose=null;try{origOnClose=ad.onClose;}catch(e){}"
   "try{ad.onClose=function(cb){window.__asAdCloseCb=cb;log('onClose 注册('+src+')');"
     "if(!origOnClose)return;"
     "var wrap=function(res){if(window.__asFired)return;window.__asFired=1;"
       "var out={isEnded:true,count:1,completed:true,reward:true};"
       "try{if(res&&typeof res==='object'){for(var k in res)out[k]=res[k];}"
         "out.isEnded=true;out.count=1;out.completed=true;}catch(e){}"
       "try{cb&&cb(out);}catch(e){log('cb 抛错 '+e);}};"
     "return origOnClose.call(ad,wrap);};}catch(e){log('onClose 接管失败 '+e);}"
   "try{ad.show=function(){window.__asFired=0;log('show 直通('+src+')，不发原生请求');"
       "var n=0;(function fire(){"
         "var cb=window.__asAdCloseCb;"
         "if(!cb&&++n<25){setTimeout(fire,200);return;}"    // 等游戏把回调注册上
         "if(window.__asFired)return;window.__asFired=1;"
         "log('直接回 onClose isEnded=true cb='+(cb?'有':'无'));"
         "try{if(cb)cb({isEnded:true,count:1,completed:true,reward:true});}"
         "catch(e){log('cb 抛错 '+e);}})();"
       "try{return Promise.resolve();}catch(e){return;}};}catch(e){log('show 接管失败 '+e);}"
   "try{var ol=ad.load;ad.load=function(){var r=null;"
     "try{r=ol?ol.apply(ad,arguments):null;}catch(e){}"
     "return (r&&r.then)?r:Promise.resolve();};}catch(e){}"
 "}"

 // API 可能比脚本更晚挂到 window 上，轮询接管（最多约 60 秒）
 "var tries=0;"
 "function scan(){var t=targets(),hit=0;"
   "for(var i=0;i<t.length;i++){var obj=t[i];if(!obj)continue;"
     "for(var j=0;j<NAMES.length;j++){var nm=NAMES[j],fn=null;"
       "try{fn=obj[nm];}catch(e){}"
       "if(typeof fn!=='function')continue;"
       "if(obj['__asW_'+nm])continue;"
       "try{(function(o,name,orig){"
         "var wrapper=function(){var ad=null;"
           "try{ad=orig.apply(o,arguments);}catch(e){log('调用 '+name+' 抛错 '+e);return null;}"
           "try{hook(ad,name);}catch(e){}"
           "return ad;};"
         "o[name]=wrapper;"
         "if(o[name]===wrapper){o['__asW_'+name]=1;log('已接管 '+name);hit++;}"
         "else{log('接管失败(只读) '+name);}"
       "})(obj,nm,fn);}catch(e){log('接管失败 '+nm+' '+e);}}}"
   "if(hit===0&&++tries<240)setTimeout(scan,250);"
   "else if(hit===0)log('没找到广告 API（my='+(typeof window.my)+'）');}"
 "scan();})();";

#pragma mark - WebView 注入通道

@interface ASBridge : NSObject <WKScriptMessageHandler>
@end

@implementation ASBridge
- (void)userContentController:(WKUserContentController *)ucc
      didReceiveScriptMessage:(WKScriptMessage *)message {
    @try {
        if (message.body) ASLog(@"%@", message.body);
    } @catch (__unused NSException *e) {}
}
@end

static ASBridge *gBridge = nil;
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

    @try { [wv evaluateJavaScript:kShimJS completionHandler:nil]; }
    @catch (__unused NSException *e) {}
}

static id ASMyInitWithFrameConfig(WKWebView *self, SEL _cmd, CGRect frame, WKWebViewConfiguration *config) {
    if (config) {
        WKUserContentController *ucc = config.userContentController;
        if (!ucc) {
            ucc = [[WKUserContentController alloc] init];
            config.userContentController = ucc;
        }
        if (!gBridge) gBridge = [[ASBridge alloc] init];
        @try { [ucc addScriptMessageHandler:gBridge name:@"aslog"]; }
        @catch (__unused NSException *e) {}
        // 小游戏跑在 iframe 里，所以 forMainFrameOnly:NO
        [ucc addUserScript:[[WKUserScript alloc] initWithSource:kShimJS
                                                    injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                                 forMainFrameOnly:NO]];
    }
    id result = ((id (*)(id, SEL, CGRect, id))gOrigInitWithFrameConfig)(self, _cmd, frame, config);
    if (result) ASAdoptWebView((WKWebView *)result);
    return result;
}

// dylib 加载前就存在的 WebView，靠这里补上
static void ASScanWebViews(void) {
    if (!ASIsAlipay()) return;
    for (UIWindow *w in ASAllWindows()) {
        ASWalkViews(w, 0, ^(UIView *v, int d) {
            if ([v isKindOfClass:[WKWebView class]]) ASAdoptWebView((WKWebView *)v);
        });
    }
}

#pragma mark - 原生兜底（只碰广告自己的窗口）

static NSTimeInterval gLastKill = 0;
static NSMutableArray<UIWindow *> *gHiddenWins = nil;
static NSMutableArray<UIView *> *gHiddenViews = nil;

static void ASRestoreHidden(void) {
    for (UIWindow *w in gHiddenWins) { if (w.alpha < 0.05) w.alpha = 1.0; }
    for (UIView *v in gHiddenViews) { if (v.alpha < 0.05) v.alpha = 1.0; }
    [gHiddenWins removeAllObjects];
    [gHiddenViews removeAllObjects];
}

static void ASFireJsClose(void) {
    NSArray<WKWebView *> *all = nil;
    @synchronized (gWebViews) { all = gWebViews.allObjects; }
    for (WKWebView *wv in all) {
        @try {
            [wv evaluateJavaScript:@"(window.__asFireAdClose?window.__asFireAdClose():'no')"
                 completionHandler:nil];
        } @catch (__unused NSException *e) {}
    }
}

static int ASKillAd(void) {
    if (!ASIsAlipay()) return 0;
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return 0;

    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - gLastKill < 0.8) return 0;

    NSMutableArray<UIWindow *> *adWins = [NSMutableArray array];
    NSMutableArray<UIView *> *panels = [NSMutableArray array];
    NSMutableArray<UIButton *> *closeBtns = [NSMutableArray array];
    NSMutableArray<UIButton *> *exitBtns = [NSMutableArray array];

    for (UIWindow *w in ASAllWindows()) {
        // 只处理类名明确像广告的窗口；其它窗口（含宿主小程序窗口）直接跳过，什么都不碰
        if (!ASAdLikeName(NSStringFromClass([w class])) &&
            !ASAdLikeName(NSStringFromClass([w.rootViewController class]))) continue;

        __block BOOL signal = NO;
        __block UIView *panel = nil;
        NSMutableArray<UIButton *> *winClose = [NSMutableArray array];
        NSMutableArray<UIButton *> *winExit = [NSMutableArray array];
        CGRect winB = w.bounds;

        ASWalkViews(w, 0, ^(UIView *v, int d) {
            if (!v.window) return;
            if (ASAdLikeName(NSStringFromClass([v class]))) signal = YES;

            // 找到"满屏"的那一层作为广告面板
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
                if ([t containsString:@"关闭"] || [t containsString:@"跳过"] ||
                    [t isEqualToString:@"×"] || [t isEqualToString:@"X"]) {
                    [winClose addObject:b];
                }
                if ([t containsString:@"退出"] || [t containsString:@"放弃"] || [t containsString:@"坚持"]) {
                    [winExit addObject:b];
                }
            }
        });

        if (!signal) continue;

        [adWins addObject:w];
        if (panel) [panels addObject:panel];
        [closeBtns addObjectsFromArray:winClose];
        [exitBtns addObjectsFromArray:winExit];
    }

    if (adWins.count == 0 && panels.count == 0 &&
        closeBtns.count == 0 && exitBtns.count == 0) return 0;

    gLastKill = now;
    if (!gHiddenWins) gHiddenWins = [NSMutableArray array];
    if (!gHiddenViews) gHiddenViews = [NSMutableArray array];

    for (UIWindow *w in adWins) {
        if (w.alpha > 0.05) { [gHiddenWins addObject:w]; w.alpha = 0.0; }
    }
    for (UIView *v in panels) {
        if (v.alpha > 0.05) { [gHiddenViews addObject:v]; v.alpha = 0.0; }
    }

    BOOL clicked = NO;
    for (UIButton *b in exitBtns) {
        [b sendActionsForControlEvents:UIControlEventTouchUpInside];
        clicked = YES; break;
    }
    if (!clicked) {
        for (UIButton *b in closeBtns) {
            [b sendActionsForControlEvents:UIControlEventTouchUpInside];
            clicked = YES; break;
        }
    }

    ASFireJsClose();

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ ASRestoreHidden(); });

    ASLog(@"兜底：藏 %lu 窗 / %lu 面板，点按钮=%@",
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
        if ([t containsString:@"退出"] || [t containsString:@"放弃"] || [t containsString:@"坚持"]) {
            pick = a; break;
        }
    }
    if (!pick) return;
    ASLog(@"自动点掉确认框：%@", pick.title ?: @"");
    id handler = nil;
    @try { handler = [pick valueForKey:@"handler"]; } @catch (__unused NSException *e) {}
    if (handler) { ((void (^)(UIAlertAction *))handler)(pick); }
}

static id ASMyAlertFactory(id self, SEL _cmd, NSString *title, NSString *message, NSInteger style) {
    if (!gOrigAlertFactory) return nil;
    id ac = ((id (*)(id, SEL, NSString *, NSString *, NSInteger))gOrigAlertFactory)
                (self, _cmd, title, message, style);
    @try {
        NSString *text = [NSString stringWithFormat:@"%@ %@", title ?: @"", message ?: @""];
        if (ac && [ac isKindOfClass:[UIAlertController class]] &&
            ([text containsString:@"离开"] || [text containsString:@"再看"] || [text containsString:@"退出"])) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.03 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ ASAutoConfirm((UIAlertController *)ac, 0); });
        }
    } @catch (__unused NSException *e) {}
    return ac;
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
        ASSwizzleInstance(wk, @selector(initWithFrame:configuration:),
                          (IMP)ASMyInitWithFrameConfig, &gOrigInitWithFrameConfig);
    }

    Class alertCls = objc_getClass("UIAlertController");
    if (alertCls) {
        Method m = class_getInstanceMethod(object_getClass((id)alertCls),
                                           @selector(alertControllerWithTitle:message:preferredStyle:));
        if (m) {
            gOrigAlertFactory = method_getImplementation(m);
            method_setImplementation(m, (IMP)ASMyAlertFactory);
        }
    }

    // 兜底哨兵：0.2 秒一次，只在真的冒出广告窗口时才干活
    NSTimer *kill = [NSTimer timerWithTimeInterval:0.2 repeats:YES block:^(NSTimer *t) {
        @try { ASKillAd(); } @catch (__unused NSException *e) {}
    }];
    [[NSRunLoop mainRunLoop] addTimer:kill forMode:NSRunLoopCommonModes];

    // 补注入：把后来才出现的 WebView 也接管掉
    NSTimer *adopt = [NSTimer timerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
        @try { ASScanWebViews(); } @catch (__unused NSException *e) {}
    }];
    [[NSRunLoop mainRunLoop] addTimer:adopt forMode:NSRunLoopCommonModes];

    NSLog(@"[AdSpeeder] 已加载（WebView hook=%d, alert hook=%d）",
          gOrigInitWithFrameConfig != NULL, gOrigAlertFactory != NULL);
}
