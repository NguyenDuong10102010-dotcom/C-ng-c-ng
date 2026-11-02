#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>

static BOOL gAutoImport = NO;
static UIImage *gFirstImage = nil;
static NSMutableArray<NSString *> *gVCLog;
static UIWindow *gWin;

#define SA_HEAD 44.0
#define SA_FULL 178.0
#define SA_UD NSUserDefaults.standardUserDefaults

static UILabel *SALabel(NSString *t, CGFloat sz, UIFontWeight w, UIColor *c, CGRect f) {
  UILabel *l = [[UILabel alloc] initWithFrame:f];
  l.text = t; l.textColor = c;
  l.font = [UIFont systemFontOfSize:sz weight:w];
  return l;
}

#pragma mark - Chẩn đoán
static UIViewController *SATop(UIViewController *v) {
  for (int i = 0; i < 20 && v; i++) {
    if (v.presentedViewController) v = v.presentedViewController;
    else if ([v isKindOfClass:UINavigationController.class] && ((UINavigationController *)v).topViewController) v = ((UINavigationController *)v).topViewController;
    else if ([v isKindOfClass:UITabBarController.class] && ((UITabBarController *)v).selectedViewController) v = ((UITabBarController *)v).selectedViewController;
    else break;
  }
  return v;
}
static void SAViews(UIView *v, int d, NSMutableSet *set) {
  NSString *n = NSStringFromClass(v.class);
  if (![n hasPrefix:@"_"] && ![n hasPrefix:@"UI"]) [set addObject:n];
  if (d >= 5) return;
  for (UIView *s in v.subviews) SAViews(s, d + 1, set);
}
static NSString *SADiag(void) {
  NSMutableString *s = [NSMutableString string];
  [s appendString:@"== VC LOG (cu -> moi) ==\n"];
  for (NSString *c in gVCLog) [s appendFormat:@"%@\n", c];

  UIViewController *root = nil;
  for (UIScene *sc in UIApplication.sharedApplication.connectedScenes)
    if ([sc isKindOfClass:UIWindowScene.class])
      for (UIWindow *w in ((UIWindowScene *)sc).windows)
        if (w != gWin && !w.hidden && w.rootViewController) root = w.rootViewController;
  UIViewController *top = SATop(root);
  if (top) {
    [s appendFormat:@"\n== TOP VC ==\n%@\n", NSStringFromClass(top.class)];
    NSMutableSet *vs = [NSMutableSet set];
    SAViews(top.view, 0, vs);
    [s appendFormat:@"\n== VIEWS ==\n%@\n", [vs.allObjects componentsJoinedByString:@"\n"]];
    unsigned int mc = 0;
    Method *ms = class_copyMethodList(top.class, &mc);
    [s appendString:@"\n== METHODS ==\n"];
    for (unsigned int i = 0; i < mc && i < 80; i++)
      [s appendFormat:@"%s\n", sel_getName(method_getName(ms[i]))];
    free(ms);
  }

  unsigned int n = 0;
  const char **names = objc_copyClassNamesForImage(_dyld_get_image_name(0), &n);
  NSArray *keys = @[@"layer", @"import", @"picker", @"photo", @"asset", @"media", @"gallery", @"replace", @"code", @"template"];
  NSMutableArray *kw = [NSMutableArray array], *dl = [NSMutableArray array];
  for (unsigned int i = 0; i < n; i++) {
    NSString *c = @(names[i]);
    Class k = objc_getClass(names[i]);
    if (k && (class_getInstanceMethod(k, @selector(imagePickerController:didFinishPickingMediaWithInfo:)) ||
              class_getInstanceMethod(k, @selector(picker:didFinishPicking:)))) [dl addObject:c];
    for (NSString *key in keys)
      if ([c.lowercaseString containsString:key]) { if (kw.count < 300) [kw addObject:c]; break; }
  }
  free(names);
  [s appendFormat:@"\n== PICKER DELEGATE ==\n%@\n", [dl componentsJoinedByString:@"\n"]];
  [s appendFormat:@"\n== CLASSES ==\n%@\n", [kw componentsJoinedByString:@"\n"]];
  return s;
}

#pragma mark - Panel
@interface SARootVC : UIViewController @end
@implementation SARootVC
- (void)loadView { self.view = [UIView new]; self.view.backgroundColor = UIColor.clearColor; }
@end

@interface SAWindow : UIWindow @end
@implementation SAWindow
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e {
  UIView *v = [super hitTest:p withEvent:e];
  return (v == self || v == self.rootViewController.view) ? nil : v;
}
@end

@interface SAPanel : UIView
@property (nonatomic, strong) UIView *clip, *head, *body, *dot;
@property (nonatomic, strong) UILabel *arrow;
@property (nonatomic, strong) UIButton *diag;
@property (nonatomic, assign) BOOL collapsed;
@end

@implementation SAPanel
- (instancetype)init {
  self = [super initWithFrame:CGRectMake(16, 110, 220, SA_FULL)];
  if (!self) return nil;
  if ([SA_UD objectForKey:@"sa_x"]) {
    CGRect f = self.frame;
    f.origin = CGPointMake([SA_UD floatForKey:@"sa_x"], [SA_UD floatForKey:@"sa_y"]);
    self.frame = f;
  }
  self.backgroundColor = [UIColor colorWithWhite:0.03 alpha:1];
  self.layer.cornerRadius = 16;
  self.layer.borderWidth = 1;
  self.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.85].CGColor;
  self.layer.shadowColor = UIColor.whiteColor.CGColor;
  self.layer.shadowOffset = CGSizeZero;
  self.layer.shadowRadius = 14;
  self.layer.shadowOpacity = 0.55;
  CABasicAnimation *g = [CABasicAnimation animationWithKeyPath:@"shadowOpacity"];
  g.fromValue = @0.25; g.toValue = @0.85; g.duration = 1.6;
  g.autoreverses = YES; g.repeatCount = HUGE_VALF;
  [self.layer addAnimation:g forKey:@"glow"];

  _clip = [[UIView alloc] initWithFrame:self.bounds];
  _clip.layer.cornerRadius = 16; _clip.clipsToBounds = YES;
  _clip.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  [self addSubview:_clip];

  _head = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 220, SA_HEAD)];
  [_clip addSubview:_head];
  _dot = [[UIView alloc] initWithFrame:CGRectMake(14, 18, 8, 8)];
  _dot.layer.cornerRadius = 4;
  _dot.layer.shadowColor = UIColor.whiteColor.CGColor;
  _dot.layer.shadowOffset = CGSizeZero; _dot.layer.shadowRadius = 5;
  [_head addSubview:_dot];
  UILabel *t = SALabel(@"", 13, UIFontWeightHeavy, UIColor.whiteColor, CGRectMake(30, 0, 140, SA_HEAD));
  t.attributedText = [[NSAttributedString alloc] initWithString:@"PAINUZZ TOOL"
    attributes:@{NSKernAttributeName: @2.2, NSForegroundColorAttributeName: UIColor.whiteColor,
                 NSFontAttributeName: [UIFont systemFontOfSize:13 weight:UIFontWeightHeavy]}];
  [_head addSubview:t];
  _arrow = SALabel(@"▾", 14, UIFontWeightBold, UIColor.whiteColor, CGRectMake(176, 0, 30, SA_HEAD));
  _arrow.textAlignment = NSTextAlignmentRight;
  [_head addSubview:_arrow];
  [_head addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(toggleFold)]];
  [_head addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(drag:)]];

  CAGradientLayer *gl = [CAGradientLayer layer];
  gl.frame = CGRectMake(12, SA_HEAD - 0.5, 196, 1);
  gl.startPoint = CGPointMake(0, .5); gl.endPoint = CGPointMake(1, .5);
  gl.colors = @[(id)[UIColor colorWithWhite:1 alpha:0].CGColor, (id)[UIColor colorWithWhite:1 alpha:.6].CGColor, (id)[UIColor colorWithWhite:1 alpha:0].CGColor];
  [_clip.layer addSublayer:gl];

  _body = [[UIView alloc] initWithFrame:CGRectMake(0, SA_HEAD, 220, SA_FULL - SA_HEAD)];
  [_clip addSubview:_body];

  UIView *row = [[UIView alloc] initWithFrame:CGRectMake(10, 8, 200, 48)];
  row.backgroundColor = [UIColor colorWithWhite:1 alpha:0.06];
  row.layer.cornerRadius = 11; row.layer.borderWidth = 1;
  row.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.14].CGColor;
  [row addSubview:SALabel(@"Auto Nhập Ảnh", 14, UIFontWeightSemibold, UIColor.whiteColor, CGRectMake(12, 7, 125, 20))];
  [row addSubview:SALabel(@"Tự điền ảnh các mục sau", 10, UIFontWeightRegular, [UIColor colorWithWhite:.6 alpha:1], CGRectMake(12, 27, 125, 14))];
  UISwitch *sw = [UISwitch new];
  sw.frame = CGRectMake(139, 8.5, 51, 31);
  sw.onTintColor = UIColor.whiteColor;
  sw.thumbTintColor = [UIColor colorWithWhite:.55 alpha:1];
  sw.backgroundColor = [UIColor colorWithWhite:.18 alpha:1];
  sw.layer.cornerRadius = 15.5;
  sw.on = gAutoImport;
  [sw addTarget:self action:@selector(tog:) forControlEvents:UIControlEventValueChanged];
  [row addSubview:sw];
  [_body addSubview:row];

  _diag = [UIButton buttonWithType:UIButtonTypeSystem];
  _diag.frame = CGRectMake(10, 64, 200, 32);
  _diag.backgroundColor = UIColor.whiteColor;
  _diag.layer.cornerRadius = 9;
  _diag.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
  [_diag setTitle:@"Chẩn đoán (copy log)" forState:UIControlStateNormal];
  [_diag setTitleColor:UIColor.blackColor forState:UIControlStateNormal];
  [_diag addTarget:self action:@selector(doDiag) forControlEvents:UIControlEventTouchUpInside];
  [_body addSubview:_diag];

  UILabel *cr = SALabel(@"cre: Ng Hoang Minh Duong • Painuzz", 9.5, UIFontWeightMedium, [UIColor colorWithWhite:.6 alpha:1], CGRectMake(8, 106, 204, 14));
  cr.textAlignment = NSTextAlignmentCenter;
  cr.adjustsFontSizeToFitWidth = YES; cr.minimumScaleFactor = .7;
  [_body addSubview:cr];

  [self paintDot];
  if ([SA_UD boolForKey:@"sa_collapsed"]) [self setCollapsed:YES animated:NO];
  return self;
}
- (void)layoutSubviews {
  [super layoutSubviews];
  self.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:self.bounds cornerRadius:16].CGPath;
}
- (void)paintDot {
  _dot.backgroundColor = gAutoImport ? UIColor.whiteColor : [UIColor colorWithWhite:.3 alpha:1];
  _dot.layer.shadowOpacity = gAutoImport ? 1 : 0;
}
- (void)tog:(UISwitch *)s {
  gAutoImport = s.on;
  gFirstImage = nil;   // bật/tắt = bắt đầu đợt mới, ảnh đầu tiên chọn tay
  [SA_UD setBool:s.on forKey:@"sa_auto_import"];
  [self paintDot];
}
- (void)toggleFold { [self setCollapsed:!_collapsed animated:YES]; }
- (void)setCollapsed:(BOOL)c animated:(BOOL)a {
  _collapsed = c;
  [SA_UD setBool:c forKey:@"sa_collapsed"];
  CGRect f = self.frame; f.size.height = c ? SA_HEAD : SA_FULL;
  void (^blk)(void) = ^{
    self.frame = f;
    self.body.alpha = c ? 0 : 1;
    self.arrow.text = c ? @"▸" : @"▾";
  };
  self.body.userInteractionEnabled = !c;
  if (a) [UIView animateWithDuration:.25 animations:blk completion:^(BOOL d){ [self clamp]; }];
  else { blk(); [self clamp]; }
}
- (void)clamp {
  UIView *sv = self.superview; if (!sv) return;
  CGRect f = self.frame, b = sv.bounds;
  f.origin.x = MAX(4, MIN(f.origin.x, b.size.width - f.size.width - 4));
  f.origin.y = MAX(sv.safeAreaInsets.top + 4, MIN(f.origin.y, b.size.height - f.size.height - 4));
  self.frame = f;
  [SA_UD setFloat:f.origin.x forKey:@"sa_x"];
  [SA_UD setFloat:f.origin.y forKey:@"sa_y"];
}
- (void)drag:(UIPanGestureRecognizer *)g {
  CGPoint t = [g translationInView:self.superview];
  self.center = CGPointMake(self.center.x + t.x, self.center.y + t.y);
  [g setTranslation:CGPointZero inView:self.superview];
  if (g.state == UIGestureRecognizerStateEnded) [self clamp];
}
- (void)doDiag {
  UIPasteboard.generalPasteboard.string = SADiag();
  [_diag setTitle:@"Đã copy! Dán vào chat" forState:UIControlStateNormal];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2.5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    [self.diag setTitle:@"Chẩn đoán (copy log)" forState:UIControlStateNormal];
  });
}
@end

static void SAEnsure(void) {
  if (gWin) { gWin.hidden = NO; return; }
  UIWindowScene *sc = nil;
  for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
    if ([s isKindOfClass:UIWindowScene.class] && s.activationState == UISceneActivationStateForegroundActive) { sc = (UIWindowScene *)s; break; }
  if (!sc) return;
  gWin = [[SAWindow alloc] initWithWindowScene:sc];
  gWin.windowLevel = UIWindowLevelAlert + 100;
  gWin.backgroundColor = UIColor.clearColor;
  SARootVC *vc = [SARootVC new];
  gWin.rootViewController = vc;
  gWin.hidden = NO;
  [vc.view addSubview:[SAPanel new]];
}

#pragma mark - Auto Nhập Ảnh (thử nghiệm: chỉ với UIImagePickerController)
static void SAHookPickers(void) {
  unsigned int n = 0;
  const char **names = objc_copyClassNamesForImage(_dyld_get_image_name(0), &n);
  SEL sel = @selector(imagePickerController:didFinishPickingMediaWithInfo:);
  for (unsigned int i = 0; i < n; i++) {
    Class k = objc_getClass(names[i]);
    if (!k) continue;
    unsigned int c = 0;
    Method *own = class_copyMethodList(k, &c);
    Method m = NULL;
    for (unsigned int j = 0; j < c; j++) if (method_getName(own[j]) == sel) m = own[j];
    free(own);
    if (!m) continue;
    IMP orig = method_getImplementation(m);
    IMP neu = imp_implementationWithBlock(^(id s, UIImagePickerController *p, NSDictionary *info) {
      if (gAutoImport && !gFirstImage) {
        UIImage *im = info[UIImagePickerControllerEditedImage] ?: info[UIImagePickerControllerOriginalImage];
        if (im) gFirstImage = im;
      }
      ((void (*)(id, SEL, id, id))orig)(s, sel, p, info);
    });
    method_setImplementation(m, neu);
  }
  free(names);
}

#pragma mark - Hook
%hook UIViewController
- (void)viewDidAppear:(BOOL)animated {
  %orig;
  NSString *n = NSStringFromClass(self.class);
  if ([n hasPrefix:@"_"] || [n hasPrefix:@"UI"] || [n hasPrefix:@"NS"] || [n hasPrefix:@"SA"]) return;
  if (gVCLog && ![gVCLog.lastObject isEqualToString:n]) {
    [gVCLog addObject:n];
    if (gVCLog.count > 40) [gVCLog removeObjectAtIndex:0];
  }
}
- (void)presentViewController:(UIViewController *)vc animated:(BOOL)a completion:(void (^)(void))done {
  if (gAutoImport && gFirstImage && [vc isKindOfClass:UIImagePickerController.class]) {
    UIImagePickerController *p = (UIImagePickerController *)vc;
    id d = p.delegate;
    if ([p.mediaTypes containsObject:@"public.image"] &&
        [d respondsToSelector:@selector(imagePickerController:didFinishPickingMediaWithInfo:)]) {
      UIImage *im = gFirstImage;
      dispatch_async(dispatch_get_main_queue(), ^{
        @try {
          [d imagePickerController:p didFinishPickingMediaWithInfo:@{
            UIImagePickerControllerOriginalImage: im,
            UIImagePickerControllerEditedImage: im,
            UIImagePickerControllerMediaType: @"public.image" }];
        } @catch (NSException *e) {}
      });
      if (done) done();
      return;
    }
  }
  %orig;
}
%end

%ctor {
  gVCLog = [NSMutableArray array];
  gAutoImport = [SA_UD boolForKey:@"sa_auto_import"];
  %init;
  [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
    object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { SAEnsure(); }];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    SAHookPickers();
    SAEnsure();
    [NSTimer scheduledTimerWithTimeInterval:2 repeats:YES block:^(NSTimer *t) {
      SAEnsure();
      gWin.hidden = NO;
    }];
  });
}
