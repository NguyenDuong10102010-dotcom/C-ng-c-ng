// Auto Nhập Ảnh — VideoStar (com.frontierdesign.videostar)
// Dylib thuần Objective-C runtime (không cần Theos / MobileSubstrate).
// Khi bạn thay ảnh ở 1 layer, tool tự điền cùng ảnh đó vào các layer còn lại
// (chỉ layer đang có media, bỏ qua layer trống / 3D / GIF / vẽ / overlay / particles).
// Log lỗi: Documents/AutoNhapAnh.log

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#define CREDIT_TEXT @"Ng Hoang Minh Duong  •  Painuzz"
static NSString *const kEnabledKey = @"ANA_Enabled_v1";

static BOOL gEnabled = YES;
static BOOL gReplaying = NO;   // đang tự phát lại ảnh -> không bắt lại hook
static BOOL gBusy = NO;        // đang chạy 1 job -> không chạy chồng
static void (*gOrigPicked)(id, SEL, id) = NULL;
static SEL gPickedSel;

#pragma mark - Log

static void ANALog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void ANALog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *m = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *dir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!dir) return;
    NSString *path = [dir stringByAppendingPathComponent:@"AutoNhapAnh.log"];
    NSDictionary *at = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    if ([at fileSize] > 200 * 1024) [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], m];
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!h) { [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]; return; }
    @try { [h seekToEndOfFile]; [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; } @catch (...) {}
    [h closeFile];
}

#pragma mark - Safe messaging helpers (luôn kiểm tra respondsToSelector)

static id ANAObj(id o, SEL s) {
    if (!o || ![o respondsToSelector:s]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(o, s);
}
static void *ANAPtr(id o, SEL s) {           // chỉ lấy con trỏ, không retain
    if (!o || ![o respondsToSelector:s]) return NULL;
    return ((void *(*)(id, SEL))objc_msgSend)(o, s);
}
static NSInteger ANAInt(id o, SEL s) {
    if (!o || ![o respondsToSelector:s]) return 0;
    return ((NSInteger (*)(id, SEL))objc_msgSend)(o, s);
}
static BOOL ANABool(id o, SEL s) {
    if (!o || ![o respondsToSelector:s]) return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)(o, s);
}
static BOOL ANABoolArg(id o, SEL s, NSInteger a) {
    if (!o || ![o respondsToSelector:s]) return NO;
    return ((BOOL (*)(id, SEL, NSInteger))objc_msgSend)(o, s, a);
}
static void ANAAfter(double sec, dispatch_block_t b) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(sec * NSEC_PER_SEC)), dispatch_get_main_queue(), b);
}

#pragma mark - Tìm class / engine / layer

static Class ANAFindClass(NSString *name) {
    Class c = NSClassFromString(name);
    if (c) return c;
    c = NSClassFromString([@"Video_Star." stringByAppendingString:name]);
    if (c) return c;
    const char *want = name.UTF8String; size_t wl = strlen(want);
    unsigned n = 0; Class *list = objc_copyClassList(&n); Class found = Nil;
    for (unsigned i = 0; i < n; i++) {
        const char *nm = class_getName(list[i]); size_t l = strlen(nm);
        if (l < wl || strcmp(nm + l - wl, want) != 0) continue;
        if (l > wl) { char p = nm[l - wl - 1]; if (!(p == '.' || (p >= '0' && p <= '9'))) continue; }
        found = list[i]; break;
    }
    free(list);
    return found;
}

static id ANAEngine(id vc) {
    SEL s = sel_registerName("getMultiLayerEngine");
    id e = ANAObj(vc, s);
    if (!e) e = ANAObj(ANAObj(vc, @selector(navigationController)), s);
    return e;
}
static NSInteger ANALayerCount(id engine, id vc) {
    SEL s = sel_registerName("numActiveLayers");
    NSInteger n = ANAInt(engine, s);
    if (n <= 0) n = ANAInt(vc, s);
    if (n < 0) n = 0;
    return MIN(n, 64);
}
static id ANALayer(id engine, id vc, NSInteger i) {
    SEL s = sel_registerName("layerAtLayerNum:");
    if (engine && [engine respondsToSelector:s]) return ((id (*)(id, SEL, NSInteger))objc_msgSend)(engine, s, i);
    if (vc && [vc respondsToSelector:s]) return ((id (*)(id, SEL, NSInteger))objc_msgSend)(vc, s, i);
    return nil;
}
// Khoá nhận diện nội dung layer = con trỏ asset + layerImage
static NSUInteger ANAKey(id layer) {
    if (!layer) return 0;
    NSUInteger a = (NSUInteger)ANAPtr(layer, sel_registerName("asset"));
    NSUInteger b = (NSUInteger)ANAPtr(layer, sel_registerName("layerImage"));
    return a ^ (b << 1) ^ (a ? 0x9E3779B1 : 0);
}
static NSArray<NSNumber *> *ANASnapshot(id engine, id vc, NSInteger n) {
    NSMutableArray *r = [NSMutableArray array];
    for (NSInteger i = 0; i < n; i++) [r addObject:@(ANAKey(ANALayer(engine, vc, i)))];
    return r;
}
static BOOL ANAExcluded(id engine, id vc, id layer, NSInteger i) {
    NSArray<NSString *> *argSels = @[@"isNullLayer:", @"gifExistsOnLayerNum:", @"drawingExistsOnLayerNum:",
                                      @"overlayObjectExistsOnLayerNum:", @"particlesExistOnLayerNum:"];
    for (NSString *n in argSels) {
        SEL s = sel_registerName(n.UTF8String);
        for (id r in @[engine ?: [NSNull null], vc ?: [NSNull null], layer ?: [NSNull null]]) {
            if (r == (id)[NSNull null]) continue;
            if ([r respondsToSelector:s]) { if (ANABoolArg(r, s, i)) return YES; break; }
        }
    }
    if (ANABool(layer, sel_registerName("is3DLayer"))) return YES;
    if (ANABool(layer, sel_registerName("isNullLayer"))) return YES;
    return NO;
}

#pragma mark - UI helpers (tìm popup "Replace Content")

static NSArray<UIWindow *> *ANAWindows(void) {
    NSMutableArray *w = [NSMutableArray array];
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:UIWindowScene.class]) continue;
        [w addObjectsFromArray:((UIWindowScene *)s).windows];
    }
    if (!w.count) [w addObjectsFromArray:UIApplication.sharedApplication.windows];
    return w;
}
static UIWindow *ANAKeyWindow(void) {
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *ws = (UIWindowScene *)s;
        if (ws.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *w in ws.windows) if (w.isKeyWindow) return w;
        if (ws.windows.firstObject) return ws.windows.firstObject;
    }
    return UIApplication.sharedApplication.windows.firstObject;
}
static void ANAFindViews(UIView *v, NSString *needle, NSMutableArray *out, int depth) {
    if (depth > 40) return;
    if ([NSStringFromClass(v.class) rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound) [out addObject:v];
    for (UIView *s in v.subviews) ANAFindViews(s, needle, out, depth + 1);
}
static void ANAAllButtons(UIView *v, NSMutableArray *out, int depth) {
    if (depth > 40) return;
    if ([v isKindOfClass:UIButton.class]) [out addObject:v];
    for (UIView *s in v.subviews) ANAAllButtons(s, out, depth + 1);
}
static NSString *ANAFold(NSString *s) {
    return [(s ?: @"") stringByFoldingWithOptions:NSDiacriticInsensitiveSearch | NSCaseInsensitiveSearch locale:nil];
}
static NSString *ANAButtonTitle(UIButton *b) {
    NSString *t = [b titleForState:UIControlStateNormal] ?: b.titleLabel.text;
    if (!t.length) { if (@available(iOS 15.0, *)) t = b.configuration.title; }
    return t;
}
static UIButton *ANAFindReplaceButton(UIView **popupOut) {
    NSArray *tokens = @[@"replace content", @"thay noi dung", @"replace", @"thay"];
    for (UIWindow *w in ANAWindows()) {
        NSMutableArray *popups = [NSMutableArray array];
        ANAFindViews(w, @"CustomPopup", popups, 0);
        for (UIView *p in popups) {
            NSMutableArray *btns = [NSMutableArray array];
            ANAAllButtons(p, btns, 0);
            for (NSString *tok in tokens) {
                for (UIButton *b in btns) {
                    NSString *t = ANAFold(ANAButtonTitle(b));
                    if (t.length && [t rangeOfString:tok].location != NSNotFound) { if (popupOut) *popupOut = p; return b; }
                }
            }
        }
    }
    return nil;
}

#pragma mark - Overlay UI (đen/trắng, phát sáng, thu gọn nhưng luôn hiện)

@interface ANAOverlay : UIView
@property (nonatomic, strong) UIButton *logo;
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) UISwitch *sw;
@property (nonatomic, strong) UILabel *status;
@property (nonatomic) BOOL open;
+ (instancetype)shared;
+ (void)setStatus:(NSString *)s;
@end

@implementation ANAOverlay
+ (instancetype)shared {
    static ANAOverlay *o; static dispatch_once_t t;
    dispatch_once(&t, ^{ o = [[ANAOverlay alloc] initWithFrame:UIScreen.mainScreen.bounds]; });
    return o;
}
+ (void)setStatus:(NSString *)s { [ANAOverlay shared].status.text = s; }

static void ANAGlow(CALayer *l, CGFloat r) {
    l.shadowColor = UIColor.whiteColor.CGColor; l.shadowOpacity = 0.75; l.shadowRadius = r; l.shadowOffset = CGSizeZero;
}

- (instancetype)initWithFrame:(CGRect)f {
    if (!(self = [super initWithFrame:f])) return nil;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.backgroundColor = UIColor.clearColor;

    _panel = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 250, 132)];
    _panel.backgroundColor = [UIColor colorWithWhite:0.04 alpha:0.96];
    _panel.layer.cornerRadius = 16; _panel.layer.borderWidth = 1; _panel.layer.borderColor = UIColor.whiteColor.CGColor;
    ANAGlow(_panel.layer, 10);
    _panel.hidden = YES; _panel.alpha = 0;
    [self addSubview:_panel];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, 12, 150, 24)];
    title.text = @"Auto Nhập Ảnh"; title.textColor = UIColor.whiteColor;
    title.font = [UIFont systemFontOfSize:16 weight:UIFontWeightBold];
    [_panel addSubview:title];

    _sw = [[UISwitch alloc] init];
    _sw.center = CGPointMake(250 - 16 - _sw.bounds.size.width / 2, 24);
    _sw.onTintColor = [UIColor colorWithWhite:0.92 alpha:1];
    _sw.thumbTintColor = UIColor.blackColor;
    _sw.on = gEnabled;
    [_sw addTarget:self action:@selector(swChanged:) forControlEvents:UIControlEventValueChanged];
    [_panel addSubview:_sw];

    _status = [[UILabel alloc] initWithFrame:CGRectMake(16, 48, 218, 38)];
    _status.numberOfLines = 2; _status.textColor = [UIColor colorWithWhite:0.7 alpha:1];
    _status.font = [UIFont systemFontOfSize:12];
    _status.text = gEnabled ? @"Đang bật — thay ảnh 1 layer, các layer sau tự điền." : @"Đang tắt.";
    [_panel addSubview:_status];

    UIView *line = [[UIView alloc] initWithFrame:CGRectMake(16, 94, 218, 1)];
    line.backgroundColor = [UIColor colorWithWhite:1 alpha:0.25];
    [_panel addSubview:line];

    UILabel *cr = [[UILabel alloc] initWithFrame:CGRectMake(8, 100, 234, 20)];
    cr.text = CREDIT_TEXT; cr.textAlignment = NSTextAlignmentCenter;
    cr.textColor = [UIColor colorWithWhite:0.85 alpha:1];
    cr.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    [_panel addSubview:cr];

    _logo = [UIButton buttonWithType:UIButtonTypeCustom];
    _logo.frame = CGRectMake(16, 120, 44, 44);
    _logo.backgroundColor = UIColor.blackColor;
    _logo.layer.cornerRadius = 22; _logo.layer.borderWidth = 1.5; _logo.layer.borderColor = UIColor.whiteColor.CGColor;
    ANAGlow(_logo.layer, 9);
    [_logo setTitle:@"★" forState:UIControlStateNormal];
    [_logo setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    _logo.titleLabel.font = [UIFont systemFontOfSize:20];
    [_logo addTarget:self action:@selector(toggle) forControlEvents:UIControlEventTouchUpInside];
    [_logo addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pan:)]];
    [self addSubview:_logo];
    return self;
}
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e {
    UIView *v = [super hitTest:p withEvent:e];
    return v == self ? nil : v;     // chạm xuyên qua phần trống
}
- (void)swChanged:(UISwitch *)s {
    gEnabled = s.on;
    [[NSUserDefaults standardUserDefaults] setBool:gEnabled forKey:kEnabledKey];
    _status.text = gEnabled ? @"Đang bật — thay ảnh 1 layer, các layer sau tự điền." : @"Đang tắt.";
}
- (void)toggle {
    _open = !_open;
    [self layoutPanel];
    if (_open) _panel.hidden = NO;
    [UIView animateWithDuration:0.2 animations:^{ self.panel.alpha = self.open ? 1 : 0; }
                     completion:^(BOOL f) { if (!self.open) self.panel.hidden = YES; }];
}
- (void)pan:(UIPanGestureRecognizer *)g {
    CGPoint t = [g translationInView:self];
    CGSize s = self.bounds.size; UIEdgeInsets ins = self.safeAreaInsets;
    CGFloat x = MIN(MAX(_logo.center.x + t.x, 24), s.width - 24);
    CGFloat y = MIN(MAX(_logo.center.y + t.y, ins.top + 24), s.height - ins.bottom - 24);
    _logo.center = CGPointMake(x, y);
    [g setTranslation:CGPointZero inView:self];
    [self layoutPanel];
}
- (void)layoutPanel {
    CGSize s = self.bounds.size; CGRect lf = _logo.frame; CGSize ps = _panel.bounds.size;
    CGFloat x = MIN(MAX(lf.origin.x, 8), s.width - ps.width - 8);
    CGFloat y = CGRectGetMaxY(lf) + 8;
    if (y + ps.height > s.height - 8) y = lf.origin.y - ps.height - 8;
    _panel.frame = CGRectMake(x, y, ps.width, ps.height);
}
+ (void)ensure {
    UIWindow *w = ANAKeyWindow(); if (!w) return;
    ANAOverlay *o = [ANAOverlay shared];
    if (o.superview != w) { [o removeFromSuperview]; o.frame = w.bounds; [w addSubview:o]; }
    else [w bringSubviewToFront:o];
}
@end

#pragma mark - Job tự điền ảnh

@interface ANAJob : NSObject
@property (nonatomic, weak) id vc;
@property (nonatomic, strong) id resp;
@property (nonatomic, strong) id engine;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *targets;
@property (nonatomic) NSUInteger idx, ok, fail, failStreak;
@end
@implementation ANAJob @end

static void ANAProcess(ANAJob *job);

static void ANAFinish(ANAJob *job, NSString *why) {
    gReplaying = NO; gBusy = NO;
    NSString *msg = why ?: [NSString stringWithFormat:@"Xong: %lu/%lu layer.", (unsigned long)job.ok, (unsigned long)job.targets.count];
    ANALog(@"finish: %@", msg);
    [ANAOverlay setStatus:msg];
}

static void ANAPollPopup(ANAJob *job, NSInteger tries, void (^done)(UIButton *, UIView *)) {
    UIView *popup = nil; UIButton *b = ANAFindReplaceButton(&popup);
    if (b) { done(b, popup); return; }
    if (tries <= 0) { done(nil, nil); return; }
    ANAAfter(0.15, ^{ ANAPollPopup(job, tries - 1, done); });
}

static void ANAProcess(ANAJob *job) {
    id vc = job.vc;
    if (!vc || !((UIViewController *)vc).view.window) { ANAFinish(job, @"Dừng: màn hình đã đóng."); return; }
    if (job.idx >= job.targets.count) { ANAFinish(job, nil); return; }
    if (job.failStreak >= 2) { ANAFinish(job, @"Dừng: lỗi liên tiếp, xem AutoNhapAnh.log."); return; }

    NSInteger L = job.targets[job.idx].integerValue;
    [ANAOverlay setStatus:[NSString stringWithFormat:@"Đang điền layer %ld (%lu/%lu)…", (long)L + 1,
                           (unsigned long)job.idx + 1, (unsigned long)job.targets.count]];
    id engine = job.engine;
    id layer = ANALayer(engine, vc, L);
    NSUInteger keyBefore = ANAKey(layer);

    @try {
        SEL sel = sel_registerName("selectLayer:bordered:");
        id recv = [engine respondsToSelector:sel] ? engine : ([vc respondsToSelector:sel] ? vc : nil);
        if (recv) ((void (*)(id, SEL, NSInteger, BOOL))objc_msgSend)(recv, sel, L, YES);
        else ANALog(@"selectLayer:bordered: không tìm thấy");
    } @catch (NSException *e) { ANALog(@"select exception %@", e); }

    ANAAfter(0.45, ^{
        @try {
            SEL ps = sel_registerName("presentMLLayerButtonsCollectionViewItemLayerEditTitleViewWithMultiLayerLayer:");
            if ([vc respondsToSelector:ps]) ((void (*)(id, SEL, id))objc_msgSend)(vc, ps, layer);
            else ANALog(@"present edit view không tìm thấy");
        } @catch (NSException *e) { ANALog(@"present exception %@", e); }

        ANAPollPopup(job, 14, ^(UIButton *btn, UIView *popup) {
            if (!btn) {
                ANALog(@"layer %ld: không thấy popup Replace Content", (long)L);
                job.fail++; job.failStreak++; job.idx++;
                ANAAfter(0.5, ^{ ANAProcess(job); });
                return;
            }
            @try {
                [btn sendActionsForControlEvents:UIControlEventTouchUpInside];
                SEL bp = sel_registerName("buttonPressed:");
                if ([popup respondsToSelector:bp] && popup.window) ((void (*)(id, SEL, id))objc_msgSend)(popup, bp, btn);
            } @catch (NSException *e) { ANALog(@"press exception %@", e); }

            ANAAfter(0.8, ^{
                id vc2 = job.vc;
                if (!vc2) { ANAFinish(job, @"Dừng: màn hình đã đóng."); return; }
                gReplaying = YES;
                @try { if (gOrigPicked) gOrigPicked(vc2, gPickedSel, job.resp); }
                @catch (NSException *e) { ANALog(@"replay exception %@", e); }
                ANAAfter(0.3, ^{ gReplaying = NO; });

                ANAAfter(1.2, ^{
                    // dọn picker còn sót (nếu có)
                    @try {
                        UIViewController *p = ((UIViewController *)vc2).presentedViewController;
                        if (p && [NSStringFromClass(p.class) rangeOfString:@"Picker"].location != NSNotFound)
                            [p dismissViewControllerAnimated:NO completion:nil];
                    } @catch (...) {}
                    NSUInteger keyAfter = ANAKey(ANALayer(job.engine, vc2, L));
                    if (keyAfter != keyBefore) { job.ok++; job.failStreak = 0; ANALog(@"layer %ld OK", (long)L); }
                    else { job.fail++; job.failStreak++; ANALog(@"layer %ld: nội dung không đổi", (long)L); }
                    job.idx++;
                    ANAAfter(0.4, ^{ ANAProcess(job); });
                });
            });
        });
    });
}

static void ANAStart(id vc, id resp, NSArray<NSNumber *> *before, NSInteger n) {
    if (!vc || gBusy || !gEnabled) return;
    @try {
        id engine = ANAEngine(vc);
        if (!engine) { ANALog(@"không lấy được engine"); return; }
        NSArray *after = ANASnapshot(engine, vc, n);
        NSInteger src = -1;
        for (NSInteger i = 0; i < n && i < (NSInteger)after.count && i < (NSInteger)before.count; i++)
            if (![after[i] isEqual:before[i]]) { src = i; break; }
        if (src < 0) { ANALog(@"không phát hiện layer vừa thay"); return; }

        NSMutableArray *targets = [NSMutableArray array];
        for (NSInteger i = 0; i < n; i++) {
            if (i == src) continue;
            id layer = ANALayer(engine, vc, i);
            if (!layer || !ANAKey(layer)) continue;              // layer trống
            if (ANAExcluded(engine, vc, layer, i)) continue;     // 3D/GIF/vẽ/overlay/particles
            [targets addObject:@(i)];
        }
        ANALog(@"src=%ld targets=%@", (long)src, targets);
        if (!targets.count) { [ANAOverlay setStatus:@"Không có layer nào cần điền."]; return; }

        ANAJob *job = [ANAJob new];
        job.vc = vc; job.resp = resp; job.engine = engine; job.targets = targets;
        gBusy = YES;
        ANAProcess(job);
    } @catch (NSException *e) { gBusy = NO; ANALog(@"start exception %@", e); }
}

#pragma mark - Hook

static void ANAHookPicked(id self, SEL _cmd, id resp) {
    NSArray *before = nil; NSInteger n = 0;
    BOOL track = gEnabled && !gReplaying && !gBusy && resp != nil;
    if (track) {
        @try {
            id engine = ANAEngine(self);
            n = ANALayerCount(engine, self);
            if (engine && n > 0) before = ANASnapshot(engine, self, n);
        } @catch (NSException *e) { before = nil; ANALog(@"snapshot exception %@", e); }
    }
    if (gOrigPicked) gOrigPicked(self, _cmd, resp);
    if (!track || !before || n <= 0) return;
    __weak id wvc = self;
    ANAAfter(1.0, ^{ ANAStart(wvc, resp, before, n); });
}

static BOOL ANAInstallHook(void) {
    if (gOrigPicked) return YES;
    Class c = ANAFindClass(@"MultiLayerWizEffectVC");
    if (!c) return NO;
    gPickedSel = sel_registerName("pickedWithClipPickerResponse:");
    Method m = class_getInstanceMethod(c, gPickedSel);
    if (!m) { ANALog(@"MultiLayerWizEffectVC không có pickedWithClipPickerResponse:"); return NO; }
    IMP orig = method_getImplementation(m);
    if (!class_addMethod(c, gPickedSel, (IMP)ANAHookPicked, method_getTypeEncoding(m)))
        method_setImplementation(m, (IMP)ANAHookPicked);
    gOrigPicked = (void (*)(id, SEL, id))orig;
    ANALog(@"hook installed on %s", class_getName(c));
    return YES;
}

#pragma mark - Khởi động

static int gHookTries = 0;
static void ANATick(void) {
    @try {
        if (!gOrigPicked && gHookTries < 40) { gHookTries++; ANAInstallHook(); }
        [ANAOverlay ensure];
    } @catch (...) {}
    ANAAfter(2.0, ^{ ANATick(); });
}

__attribute__((constructor)) static void ANAInit(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    gEnabled = [d objectForKey:kEnabledKey] ? [d boolForKey:kEnabledKey] : YES;
    ANAAfter(1.5, ^{ ANATick(); });
}