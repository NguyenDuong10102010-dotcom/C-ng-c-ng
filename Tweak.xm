// Auto Nhập Ảnh v5 — VideoStar (com.frontierdesign.videostar)
// Thêm ảnh vào tool -> nhập code xong (hoặc bấm Bắt đầu) -> tool tự thay ảnh vào các layer.
// Log: Documents/AutoNhapAnh.log  (có nút "Sao chép log" trong panel)

#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#pragma clang diagnostic ignored "-Wunused-function"
#pragma clang diagnostic ignored "-Wunused-variable"
#pragma clang diagnostic ignored "-Wunused-parameter"
#pragma clang diagnostic ignored "-Wlogical-op-parentheses"
#pragma clang diagnostic ignored "-Wformat"
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
#pragma clang diagnostic ignored "-Wunknown-pragmas"
#pragma clang diagnostic ignored "-Wincomplete-implementation"

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>

#define CREDIT_TEXT @"Ng Hoang Minh Duong  •  Painuzz"
#define ANA_VER @"[v5]"
static NSString *const kEnabledKey = @"ANA_Enabled_v1";

static BOOL gEnabled = YES;
static BOOL gReplaying = NO;
static BOOL gBusy = NO;
static void (*gOrigPicked)(id, SEL, id) = NULL;
static SEL gPickedSel;
static id gTemplate = nil;                         // response mẫu bắt được từ lần thay ảnh thường
static NSMutableArray<UIImage *> *gImages = nil;   // ảnh người dùng thêm vào tool

#pragma mark - Log

static void ANALog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static NSString *ANALogPath(void) {
    NSString *dir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return dir ? [dir stringByAppendingPathComponent:@"AutoNhapAnh.log"] : nil;
}
static void ANALog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *m = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *path = ANALogPath(); if (!path) return;
    NSDictionary *at = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    if ([at fileSize] > 300 * 1024) [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], m];
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!h) { [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]; return; }
    @try { [h seekToEndOfFile]; [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; } @catch (...) {}
    [h closeFile];
}

#pragma mark - Safe messaging helpers

static id ANAObj(id o, SEL s) {
    if (!o || ![o respondsToSelector:s]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(o, s);
}
static void *ANAPtr(id o, SEL s) {
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

#pragma mark - Engine / layer

static NSArray *ANAReceivers(id vc) {
    NSMutableArray *r = [NSMutableArray array];
    if (vc) [r addObject:vc];
    UIViewController *v = [vc isKindOfClass:UIViewController.class] ? vc : nil;
    if (v.navigationController) [r addObject:v.navigationController];
    if (v.parentViewController) [r addObject:v.parentViewController];
    if (v.presentingViewController) [r addObject:v.presentingViewController];
    for (UIViewController *c in v.navigationController.viewControllers ?: @[]) if (![r containsObject:c]) [r addObject:c];
    return r;
}
static id ANAEngine(id vc) {
    SEL s = sel_registerName("getMultiLayerEngine");
    for (id r in ANAReceivers(vc)) { id e = ANAObj(r, s); if (e) return e; }
    return nil;
}
static NSInteger ANALayerCount(id engine, id vc) {
    SEL s = sel_registerName("numActiveLayers");
    NSInteger n = ANAInt(engine, s);
    if (n <= 0) for (id r in ANAReceivers(vc)) { n = ANAInt(r, s); if (n > 0) break; }
    if (n < 0) n = 0;
    return MIN(n, 64);
}
static id ANALayer(id engine, id vc, NSInteger i) {
    SEL s = sel_registerName("layerAtLayerNum:");
    NSMutableArray *rs = [NSMutableArray array];
    if (engine) [rs addObject:engine];
    [rs addObjectsFromArray:ANAReceivers(vc)];
    for (id r in rs) if ([r respondsToSelector:s]) return ((id (*)(id, SEL, NSInteger))objc_msgSend)(r, s, i);
    return nil;
}
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

#pragma mark - Windows / view controllers

@class ANAPassWindow;
static ANAPassWindow *gWin = nil;

static NSArray<UIWindow *> *ANAAppWindows(void) {
    NSMutableArray *w = [NSMutableArray array];
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *x in ((UIWindowScene *)s).windows) if (x != (UIWindow *)gWin) [w addObject:x];
    }
    if (!w.count) for (UIWindow *x in UIApplication.sharedApplication.windows) if (x != (UIWindow *)gWin) [w addObject:x];
    return w;
}
static UIViewController *ANATopVC(void) {
    UIWindow *kw = nil;
    for (UIWindow *w in ANAAppWindows()) { if (w.isKeyWindow) { kw = w; break; } }
    if (!kw) kw = ANAAppWindows().firstObject;
    UIViewController *v = kw.rootViewController;
    while (v.presentedViewController) v = v.presentedViewController;
    return v;
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
    return [b titleForState:UIControlStateNormal] ?: b.titleLabel.text;
}
static UIButton *ANAFindReplaceButton(UIView **popupOut) {
    NSArray *tokens = @[@"thay noi dung", @"replace content", @"replace", @"thay"];
    for (UIWindow *w in ANAAppWindows()) {
        NSMutableArray *popups = [NSMutableArray array];
        ANAFindViews(w, @"CustomPopup", popups, 0);
        for (UIView *p in popups) {
            NSMutableArray *btns = [NSMutableArray array];
            ANAAllButtons(p, btns, 0);
            for (NSString *tok in tokens)
                for (UIButton *b in btns) {
                    NSString *t = ANAFold(ANAButtonTitle(b));
                    if (t.length && [t rangeOfString:tok].location != NSNotFound) { if (popupOut) *popupOut = p; return b; }
                }
        }
    }
    return nil;
}
static UIViewController *ANAFindEditorIn(UIViewController *v, int d) {
    if (!v || d > 10) return nil;
    if ([NSStringFromClass(v.class) hasSuffix:@"MultiLayerWizEffectVC"] && v.viewIfLoaded.window) return v;
    NSMutableArray *kids = [NSMutableArray arrayWithArray:v.childViewControllers];
    if (v.presentedViewController) [kids addObject:v.presentedViewController];
    if ([v isKindOfClass:UINavigationController.class]) [kids addObjectsFromArray:((UINavigationController *)v).viewControllers];
    for (UIViewController *c in kids) { UIViewController *r = ANAFindEditorIn(c, d + 1); if (r) return r; }
    return nil;
}
static UIViewController *ANAFindEditor(void) {
    for (UIWindow *w in ANAAppWindows()) { UIViewController *r = ANAFindEditorIn(w.rootViewController, 0); if (r) return r; }
    return nil;
}

#pragma mark - Overlay UI (cửa sổ riêng, không đụng cửa sổ chính)

@interface ANAOverlay : UIView
@property (nonatomic, strong) UIButton *logo, *addBtn, *clearBtn, *startBtn, *logBtn;
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) UISwitch *sw;
@property (nonatomic, strong) UILabel *status;
@property (nonatomic) BOOL open;
+ (instancetype)shared;
+ (void)setStatus:(NSString *)s;
- (void)refreshCount;
@end

@interface ANAPassWindow : UIWindow @end
@implementation ANAPassWindow
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e {
    UIView *v = [super hitTest:p withEvent:e];
    if (v == self || v == self.rootViewController.view) return nil;
    return v;
}
@end

@interface ANARootVC : UIViewController @end
@implementation ANARootVC
- (void)loadView { self.view = [[UIView alloc] initWithFrame:UIScreen.mainScreen.bounds]; self.view.backgroundColor = UIColor.clearColor; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }
- (BOOL)shouldAutorotate { return YES; }
@end

static void ANAStartFill(id vc, BOOL useImages, id resp, NSInteger src);

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
- (UIButton *)mkBtn:(NSString *)t frame:(CGRect)f action:(SEL)a filled:(BOOL)filled {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = f; b.layer.cornerRadius = 9; b.layer.borderWidth = 1; b.layer.borderColor = UIColor.whiteColor.CGColor;
    b.backgroundColor = filled ? UIColor.whiteColor : UIColor.blackColor;
    [b setTitle:t forState:UIControlStateNormal];
    [b setTitleColor:(filled ? UIColor.blackColor : UIColor.whiteColor) forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    b.titleLabel.adjustsFontSizeToFitWidth = YES;
    [b addTarget:self action:a forControlEvents:UIControlEventTouchUpInside];
    [_panel addSubview:b];
    return b;
}
- (instancetype)initWithFrame:(CGRect)f {
    if (!(self = [super initWithFrame:f])) return nil;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.backgroundColor = UIColor.clearColor;

    _panel = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 250, 232)];
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

    _status = [[UILabel alloc] initWithFrame:CGRectMake(16, 42, 218, 40)];
    _status.numberOfLines = 3; _status.textColor = [UIColor colorWithWhite:0.72 alpha:1];
    _status.font = [UIFont systemFontOfSize:11];
    _status.text = ANA_VER @" Thêm ảnh vào tool, nhập code xong tool tự thay ảnh.";
    [_panel addSubview:_status];

    _addBtn   = [self mkBtn:@"＋ Thêm ảnh (0)" frame:CGRectMake(16, 88, 130, 32) action:@selector(addPhotos) filled:NO];
    _clearBtn = [self mkBtn:@"Xóa ảnh"       frame:CGRectMake(152, 88, 82, 32) action:@selector(clearPhotos) filled:NO];
    _startBtn = [self mkBtn:@"▶  Bắt đầu"    frame:CGRectMake(16, 126, 218, 38) action:@selector(startTap) filled:YES];
    _logBtn   = [self mkBtn:@"Sao chép log"  frame:CGRectMake(16, 170, 218, 26) action:@selector(copyLog) filled:NO];
    _logBtn.titleLabel.font = [UIFont systemFontOfSize:11];

    UILabel *cr = [[UILabel alloc] initWithFrame:CGRectMake(8, 204, 234, 20)];
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
    return v == self ? nil : v;
}
- (void)refreshCount {
    [_addBtn setTitle:[NSString stringWithFormat:@"＋ Thêm ảnh (%lu)", (unsigned long)gImages.count] forState:UIControlStateNormal];
}
- (void)swChanged:(UISwitch *)s {
    gEnabled = s.on;
    [[NSUserDefaults standardUserDefaults] setBool:gEnabled forKey:kEnabledKey];
    _status.text = gEnabled ? ANA_VER @" Đang bật." : ANA_VER @" Đang tắt.";
}
- (void)toggle {
    _open = !_open;
    [self layoutPanel];
    if (_open) { _panel.hidden = NO; [self refreshCount]; }
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

// --- chọn ảnh (PHPicker gọi qua runtime, không cần link PhotosUI) ---
- (void)addPhotos {
    dlopen("/System/Library/Frameworks/PhotosUI.framework/PhotosUI", RTLD_LAZY);
    Class cfgC = NSClassFromString(@"PHPickerConfiguration"), pkC = NSClassFromString(@"PHPickerViewController");
    Class fC = NSClassFromString(@"PHPickerFilter");
    if (!cfgC || !pkC) { [ANAOverlay setStatus:@"Máy không hỗ trợ chọn nhiều ảnh (cần iOS 14+)."]; return; }
    @try {
        id cfg = [[cfgC alloc] init];
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(cfg, sel_registerName("setSelectionLimit:"), 0);
        id filter = ANAObj(fC, sel_registerName("imagesFilter"));
        if (filter) ((void (*)(id, SEL, id))objc_msgSend)(cfg, sel_registerName("setFilter:"), filter);
        id pk = ((id (*)(id, SEL, id))objc_msgSend)([pkC alloc], sel_registerName("initWithConfiguration:"), cfg);
        ((void (*)(id, SEL, id))objc_msgSend)(pk, sel_registerName("setDelegate:"), self);
        UIViewController *top = ANATopVC();
        if (!top) { [ANAOverlay setStatus:@"Không mở được trình chọn ảnh."]; return; }
        [top presentViewController:pk animated:YES completion:nil];
    } @catch (NSException *e) { ANALog(@"picker exception %@", e); }
}
- (void)picker:(id)picker didFinishPicking:(NSArray *)results {
    [(UIViewController *)picker dismissViewControllerAnimated:YES completion:nil];
    NSUInteger cnt = results.count; if (!cnt) return;
    NSMutableArray *slots = [NSMutableArray array];
    for (NSUInteger i = 0; i < cnt; i++) [slots addObject:[NSNull null]];
    __block NSUInteger pending = cnt;
    for (NSUInteger i = 0; i < cnt; i++) {
        NSItemProvider *p = ANAObj(results[i], sel_registerName("itemProvider"));
        if (![p canLoadObjectOfClass:UIImage.class]) { if (--pending == 0) [self commitSlots:slots]; continue; }
        [p loadObjectOfClass:UIImage.class completionHandler:^(id obj, NSError *err) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if ([obj isKindOfClass:UIImage.class]) slots[i] = obj;
                if (--pending == 0) [self commitSlots:slots];
            });
        }];
    }
}
- (void)commitSlots:(NSArray *)slots {
    for (id o in slots) if ([o isKindOfClass:UIImage.class]) [gImages addObject:o];
    [self refreshCount];
    _status.text = [NSString stringWithFormat:ANA_VER @" Đã có %lu ảnh. Nhập code xong tool sẽ tự thay, hoặc bấm Bắt đầu.", (unsigned long)gImages.count];
    ANALog(@"images=%lu", (unsigned long)gImages.count);
}
- (void)clearPhotos { [gImages removeAllObjects]; [self refreshCount]; _status.text = ANA_VER @" Đã xóa ảnh."; }
- (void)copyLog {
    NSString *t = [NSString stringWithContentsOfFile:ANALogPath() encoding:NSUTF8StringEncoding error:nil] ?: @"(log trống)";
    if (t.length > 12000) t = [t substringFromIndex:t.length - 12000];
    UIPasteboard.generalPasteboard.string = t;
    _status.text = ANA_VER @" Đã sao chép log, dán gửi cho mình.";
}
- (void)startTap {
    if (!gImages.count) { _status.text = ANA_VER @" Chưa có ảnh — bấm Thêm ảnh trước."; return; }
    UIViewController *vc = ANAFindEditor();
    if (!vc) { _status.text = ANA_VER @" Không thấy màn hình layer. Mở project nhiều layer trước."; return; }
    if (gBusy) { _status.text = ANA_VER @" Đang chạy…"; return; }
    ANAStartFill(vc, YES, nil, -1);
}
@end

static void ANAEnsureWindow(void) {
    if (gWin && !gWin.hidden && gWin.windowScene) return;
    UIWindowScene *ws = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if ([s isKindOfClass:UIWindowScene.class] && s.activationState == UISceneActivationStateForegroundActive) { ws = (UIWindowScene *)s; break; }
    }
    if (!ws) return;
    if (!gWin) {
        gWin = [[ANAPassWindow alloc] initWithWindowScene:ws];
        ANARootVC *root = [ANARootVC new];
        gWin.rootViewController = root;
        gWin.windowLevel = UIWindowLevelAlert + 50;
        gWin.backgroundColor = UIColor.clearColor;
        ANAOverlay *o = [ANAOverlay shared];
        o.frame = root.view.bounds;
        [root.view addSubview:o];
    }
    gWin.hidden = NO;
}

#pragma mark - Tạo ClipPickerResponse từ UIImage

static void ANADumpClass(Class c) {
    static NSMutableSet *done; if (!done) done = [NSMutableSet set];
    NSString *cn = [NSString stringWithUTF8String:class_getName(c)];
    if ([done containsObject:cn]) return; [done addObject:cn];
    NSMutableString *o = [NSMutableString stringWithFormat:@"DUMP %@ (super=%s)\n", cn, class_getName(class_getSuperclass(c))];
    unsigned n = 0;
    Ivar *iv = class_copyIvarList(c, &n);
    for (unsigned i = 0; i < n; i++) [o appendFormat:@"  ivar %s type=%s\n", ivar_getName(iv[i]), ivar_getTypeEncoding(iv[i]) ?: "?"];
    if (iv) free(iv);
    objc_property_t *pr = class_copyPropertyList(c, &n);
    for (unsigned i = 0; i < n; i++) [o appendFormat:@"  prop %s attrs=%s\n", property_getName(pr[i]), property_getAttributes(pr[i]) ?: "?"];
    if (pr) free(pr);
    Method *ml = class_copyMethodList(c, &n);
    for (unsigned i = 0; i < n; i++) [o appendFormat:@"  method %s\n", sel_getName(method_getName(ml[i]))];
    if (ml) free(ml);
    ANALog(@"%@", o);
}

static id ANAMakeResponse(UIImage *img) {
    if (!gTemplate || !img) return nil;
    Class rc = object_getClass(gTemplate);
    SEL initS = sel_registerName("initWithClipPickerResponseType:clipIndex:");
    id r = nil;
    @try {
        id a = [rc alloc];
        if ([a respondsToSelector:initS]) {
            NSInteger t = ANAInt(gTemplate, sel_registerName("clipPickerResponseType"));
            NSInteger ci = ANAInt(gTemplate, sel_registerName("clipIndex"));
            r = ((id (*)(id, SEL, NSInteger, NSInteger))objc_msgSend)(a, initS, t, ci);
        } else r = [a init];
        if (!r) return nil;
        unsigned n = 0; objc_property_t *pl = class_copyPropertyList(rc, &n);
        for (unsigned i = 0; i < n; i++) {
            NSString *name = [NSString stringWithUTF8String:property_getName(pl[i])];
            NSString *attrs = [NSString stringWithUTF8String:property_getAttributes(pl[i]) ?: ""];
            id v = nil;
            if ([attrs containsString:@"UIImage"]) v = img;
            else if ([attrs containsString:@"NSData"] && [ANAFold(name) containsString:@"image"]) v = UIImageJPEGRepresentation(img, 0.95);
            else if ([attrs containsString:@"PHAsset"] || [attrs containsString:@"AVAsset"] || [attrs containsString:@"NSURL"]) v = nil;
            else { @try { v = [gTemplate valueForKey:name]; } @catch (...) { continue; } }
            @try { [r setValue:v forKey:name]; } @catch (...) {}
        }
        if (pl) free(pl);
    } @catch (NSException *e) { ANALog(@"makeResponse exception %@", e); return nil; }
    return r;
}

#pragma mark - Job

@interface ANAJob : NSObject
@property (nonatomic, weak) id vc;
@property (nonatomic, strong) id resp, engine;
@property (nonatomic) BOOL useImages;
@property (nonatomic, strong) NSArray<UIImage *> *images;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *targets;
@property (nonatomic) NSUInteger idx, ok, fail, failStreak;
@end
@implementation ANAJob @end

// theo dõi thay đổi để biết "đã nhập code xong"
static __weak id gPollVC = nil;
static NSArray *gPollSig = nil, *gRunSig = nil;
static NSTimeInterval gPollChange = 0;
static BOOL gPendingDiff = NO;

static void ANAProcess(ANAJob *job);

static void ANAFinish(ANAJob *job, NSString *why) {
    gReplaying = NO; gBusy = NO;
    NSString *msg = why ?: [NSString stringWithFormat:@"Xong: %lu/%lu layer.", (unsigned long)job.ok, (unsigned long)job.targets.count];
    ANALog(@"finish: %@", msg);
    [ANAOverlay setStatus:[ANA_VER stringByAppendingFormat:@" %@", msg]];
    @try {
        id vc = job.vc;
        if (vc && job.engine) {
            NSArray *sig = ANASnapshot(job.engine, vc, ANALayerCount(job.engine, vc));
            gPollSig = sig; gRunSig = sig; gPendingDiff = NO; gPollChange = 0; gPollVC = vc;
        }
    } @catch (...) {}
}

static void ANAPollPopup(ANAJob *job, NSInteger tries, void (^done)(UIButton *, UIView *)) {
    UIView *popup = nil; UIButton *b = ANAFindReplaceButton(&popup);
    if (b) { done(b, popup); return; }
    if (tries <= 0) { done(nil, nil); return; }
    ANAAfter(0.15, ^{ ANAPollPopup(job, tries - 1, done); });
}

static void ANAProcess(ANAJob *job) {
    id vc = job.vc;
    if (!vc || !((UIViewController *)vc).viewIfLoaded.window) { ANAFinish(job, @"Dừng: màn hình đã đóng."); return; }
    if (job.idx >= job.targets.count) { ANAFinish(job, nil); return; }
    if (job.failStreak >= 2) { ANAFinish(job, @"Dừng: lỗi liên tiếp, bấm Sao chép log."); return; }

    NSInteger L = job.targets[job.idx].integerValue;
    [ANAOverlay setStatus:[ANA_VER stringByAppendingFormat:@" Đang điền layer %ld (%lu/%lu)…", (long)L + 1,
                           (unsigned long)job.idx + 1, (unsigned long)job.targets.count]];
    id engine = job.engine;
    id layer = ANALayer(engine, vc, L);
    NSUInteger keyBefore = ANAKey(layer);

    id resp = job.resp;
    if (job.useImages) {
        UIImage *img = job.images[job.idx % job.images.count];
        resp = ANAMakeResponse(img);
        if (!resp) { ANAFinish(job, @"Không tạo được dữ liệu ảnh. Bấm Sao chép log gửi mình."); return; }
    }

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
                ANALog(@"layer %ld: không thấy popup Thay Nội dung", (long)L);
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
                @try { if (gOrigPicked) gOrigPicked(vc2, gPickedSel, resp); }
                @catch (NSException *e) { ANALog(@"replay exception %@", e); }
                ANAAfter(0.3, ^{ gReplaying = NO; });

                ANAAfter(1.2, ^{
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

static void ANAStartFill(id vc, BOOL useImages, id resp, NSInteger src) {
    if (!vc || gBusy || !gEnabled) return;
    @try {
        if (useImages && !gTemplate) {
            [ANAOverlay setStatus:[ANA_VER stringByAppendingString:@" Lần đầu: hãy thay ảnh 1 layer bằng cách thường (Thay Nội dung → chọn ảnh) để tool học cách thay, rồi bấm Bắt đầu."]];
            return;
        }
        id engine = ANAEngine(vc);
        if (!engine) { ANALog(@"không lấy được engine"); [ANAOverlay setStatus:[ANA_VER stringByAppendingString:@" Lỗi: không lấy được engine"]]; return; }
        NSInteger n = ANALayerCount(engine, vc);
        NSMutableArray *targets = [NSMutableArray array];
        for (NSInteger i = 0; i < n; i++) {
            if (i == src) continue;
            id layer = ANALayer(engine, vc, i);
            if (!layer || !ANAKey(layer)) continue;
            if (ANAExcluded(engine, vc, layer, i)) continue;
            [targets addObject:@(i)];
        }
        ANALog(@"fill useImages=%d src=%ld n=%ld targets=%@", useImages, (long)src, (long)n, targets);
        if (!targets.count) { [ANAOverlay setStatus:[ANA_VER stringByAppendingString:@" Không có layer nào cần điền."]]; return; }

        ANAJob *job = [ANAJob new];
        job.vc = vc; job.resp = resp; job.engine = engine; job.targets = targets;
        job.useImages = useImages; job.images = [gImages copy];
        gBusy = YES;
        ANAProcess(job);
    } @catch (NSException *e) { gBusy = NO; ANALog(@"start exception %@", e); }
}

#pragma mark - Hook

static void ANAHookPicked(id self, SEL _cmd, id resp) {
    NSArray *before = nil; NSInteger n = 0;
    BOOL fromUser = gEnabled && !gReplaying && !gBusy && resp != nil;
    if (fromUser) {
        gTemplate = resp;   // học cách thay ảnh từ lần thay thường của người dùng
        @try { ANADumpClass(object_getClass(resp)); } @catch (...) {}
    }
    BOOL replicate = fromUser && gImages.count == 0;   // chưa thêm ảnh vào tool -> nhân bản ảnh vừa chọn
    if (replicate) {
        [ANAOverlay setStatus:[ANA_VER stringByAppendingString:@" Đã bắt được thao tác thay ảnh…"]];
        @try {
            id engine = ANAEngine(self);
            n = ANALayerCount(engine, self);
            if (engine && n > 0) before = ANASnapshot(engine, self, n);
        } @catch (NSException *e) { before = nil; ANALog(@"snapshot exception %@", e); }
    } else if (fromUser) {
        [ANAOverlay setStatus:[ANA_VER stringByAppendingString:@" Đã học cách thay ảnh. Bấm Bắt đầu hoặc nhập code."]];
    }
    if (gOrigPicked) gOrigPicked(self, _cmd, resp);
    if (!replicate || !before || n <= 0) return;
    __weak id wvc = self;
    ANAAfter(1.0, ^{
        id vc = wvc; if (!vc || gBusy) return;
        id engine = ANAEngine(vc); if (!engine) return;
        NSArray *after = ANASnapshot(engine, vc, n);
        NSInteger src = -1;
        for (NSInteger i = 0; i < n && i < (NSInteger)after.count && i < (NSInteger)before.count; i++)
            if (![after[i] isEqual:before[i]]) { src = i; break; }
        if (src < 0) { [ANAOverlay setStatus:[ANA_VER stringByAppendingString:@" Lỗi: không nhận ra layer vừa thay"]]; return; }
        ANAStartFill(vc, NO, resp, src);
    });
}

static NSString *gHookInfo = nil;

static BOOL ANAClassHasPicked(Class c) {
    unsigned mc = 0; Method *ml = class_copyMethodList(c, &mc);
    BOOL has = NO;
    for (unsigned j = 0; j < mc; j++) if (method_getName(ml[j]) == gPickedSel) { has = YES; break; }
    if (ml) free(ml);
    return has;
}

static BOOL ANAInstallHook(void) {
    if (gOrigPicked) return YES;
    gPickedSel = sel_registerName("pickedWithClipPickerResponse:");
    Class best = Nil; NSMutableArray *cands = [NSMutableArray array];
    const char *exe = _dyld_get_image_name(0);
    unsigned n = 0; const char **names = exe ? objc_copyClassNamesForImage(exe, &n) : NULL;
    for (unsigned i = 0; i < n; i++) {
        Class c = objc_getClass(names[i]);
        if (!c || !ANAClassHasPicked(c)) continue;
        [cands addObject:[NSString stringWithUTF8String:names[i]]];
        if (!best || (strstr(names[i], "MultiLayer") && !strstr(class_getName(best), "MultiLayer"))) best = c;
    }
    if (names) free(names);
    if (!best) {
        for (NSString *nm in @[@"Video_Star.MultiLayerWizEffectVC", @"MultiLayerWizEffectVC"]) {
            Class c = NSClassFromString(nm);
            if (c && ANAClassHasPicked(c)) { best = c; [cands addObject:nm]; break; }
        }
    }
    ANALog(@"candidates: %@", cands);
    if (!best) { gHookInfo = @"Hook: KHÔNG thấy hàm pickedWithClipPickerResponse: trong app"; return NO; }
    Method m = class_getInstanceMethod(best, gPickedSel);
    if (!m) { gHookInfo = @"Hook: lỗi lấy method"; return NO; }
    IMP orig = method_getImplementation(m);
    if (!class_addMethod(best, gPickedSel, (IMP)ANAHookPicked, method_getTypeEncoding(m)))
        method_setImplementation(m, (IMP)ANAHookPicked);
    gOrigPicked = (void (*)(id, SEL, id))orig;
    gHookInfo = [NSString stringWithFormat:@"Hook OK: %s", class_getName(best)];
    ANALog(@"%@", gHookInfo);
    return YES;
}

#pragma mark - Phát hiện "đã nhập code xong" + khởi động

static void ANAPoll(void) {
    @try {
        if (gEnabled && !gBusy && gImages.count && gOrigPicked && gTemplate) {
            UIViewController *vc = ANAFindEditor();
            if (vc) {
                id engine = ANAEngine(vc); NSInteger n = ANALayerCount(engine, vc);
                if (engine && n > 0) {
                    NSArray *sig = ANASnapshot(engine, vc, n);
                    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
                    if (gPollVC != vc) { gPollVC = vc; gPollSig = sig; gRunSig = sig; gPollChange = 0; gPendingDiff = NO; }
                    else if (![sig isEqual:gPollSig]) {
                        NSUInteger diff = 0;
                        for (NSUInteger i = 0; i < sig.count && i < gPollSig.count; i++) if (![sig[i] isEqual:gPollSig[i]]) diff++;
                        if (diff >= 2 || sig.count != gPollSig.count) gPendingDiff = YES;
                        gPollSig = sig; gPollChange = now;
                    } else if (gPollChange > 0 && now - gPollChange >= 2.0) {
                        gPollChange = 0;
                        BOOL go = gPendingDiff && ![sig isEqual:gRunSig];
                        gPendingDiff = NO;
                        if (go) { ANALog(@"phát hiện nhập code xong -> tự chạy"); ANAStartFill(vc, YES, nil, -1); }
                    }
                }
            }
        }
    } @catch (...) {}
    ANAAfter(1.0, ^{ ANAPoll(); });
}

static int gHookTries = 0;
static NSString *ANAGuardPath(void) {
    NSString *dir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [dir stringByAppendingPathComponent:@".ana_guard"];
}
static void ANATick(void) {
    @try {
        if (!gOrigPicked && gHookTries < 40) {
            NSFileManager *fm = [NSFileManager defaultManager];
            if ([fm fileExistsAtPath:ANAGuardPath()]) {
                [fm removeItemAtPath:ANAGuardPath() error:nil];
                ANALog(@"guard: lần trước crash lúc cài hook, bỏ qua lần này");
                gHookTries = 40;
                [ANAOverlay setStatus:[ANA_VER stringByAppendingString:@" Chế độ an toàn: lần trước lỗi khi cài hook. Mở lại app để thử lại."]];
            } else {
                gHookTries++;
                [@"1" writeToFile:ANAGuardPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
                BOOL ok = ANAInstallHook();
                [fm removeItemAtPath:ANAGuardPath() error:nil];
                if (ok || gHookTries == 40 || gHookTries == 5)
                    [ANAOverlay setStatus:[ANA_VER stringByAppendingFormat:@" %@", gHookInfo ?: @"Hook: chưa tìm thấy"]];
            }
        }
        ANAEnsureWindow();
    } @catch (...) {}
    ANAAfter(2.0, ^{ ANATick(); });
}

__attribute__((constructor)) static void ANAInit(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    gEnabled = [d objectForKey:kEnabledKey] ? [d boolForKey:kEnabledKey] : YES;
    gImages = [NSMutableArray array];
    ANAAfter(1.5, ^{ ANATick(); });
    ANAAfter(3.0, ^{ ANAPoll(); });
}
