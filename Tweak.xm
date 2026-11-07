// language: Objective-C, file: Tweak.x
// Painuzz FF — single-fil build. Credit: Painuzz Mobile.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <sys/sysctl.h>
#import <QuartzCore/QuartzCore.h>
#include <math.h>
#include <string.h>

// ============================================================
// SECTION 1 — CONFIG (class + method names, per-patch verify)
// ============================================================
#define FF_PLAYERMGR_CLASS      "PlayerManager"
#define FF_PLAYERMGR_INSTANCE   "get_Instance"
#define FF_PLAYERMGR_PLAYERS    "get_AllPlayers"

#define FF_PLAYER_CLASS         "Player"
#define FF_PLAYER_HEAD_M        "get_HeadPos"
#define FF_PLAYER_DEAD_M        "get_IsDead"
#define FF_PLAYER_TEAM_M        "get_TeamId"

#define FF_GAMEFACADE_CLASS     "GameFacade"
#define FF_GAMEFACADE_LOCAL     "get_LocalPlayer"

static BOOL  gAimEnabled  = NO;
static BOOL  gEspEnabled  = NO;
static float gAimFOV      = 200.0f;
static float gAimSmooth   = 0.35f;
static float gEspDistance = 400.0f;

// ============================================================
// SECTION 2 — UNITY TYPES
// ============================================================
typedef struct { float x, y, z; }    Vec3;
typedef struct { float x, y, z, w; } Quat;

// ============================================================
// SECTION 3 — IL2CPP API
// ============================================================
typedef void* (*il2cpp_domain_get_t)(void);
typedef void* (*il2cpp_domain_get_assemblies_t)(void*, size_t*);
typedef void* (*il2cpp_assembly_get_image_t)(void*);
typedef void* (*il2cpp_class_from_name_t)(void*, const char*, const char*);
typedef void* (*il2cpp_class_get_method_from_name_t)(void*, const char*, int);
typedef void* (*il2cpp_method_get_pointer_t)(void*);
typedef void* (*il2cpp_class_get_field_from_name_t)(void*, const char*);
typedef size_t(*il2cpp_field_get_offset_t)(void*);

static il2cpp_domain_get_t                 fn_domain_get = NULL;
static il2cpp_domain_get_assemblies_t      fn_domain_get_assemblies = NULL;
static il2cpp_assembly_get_image_t         fn_assembly_get_image = NULL;
static il2cpp_class_from_name_t            fn_class_from_name = NULL;
static il2cpp_class_get_method_from_name_t fn_class_get_method_from_name = NULL;
static il2cpp_method_get_pointer_t         fn_method_get_pointer = NULL;
static il2cpp_class_get_field_from_name_t  fn_class_get_field_from_name = NULL;
static il2cpp_field_get_offset_t           fn_field_get_offset = NULL;

#define RESOLVE(n) fn_##n = (void*)dlsym(RTLD_DEFAULT, "il2cpp_" #n)

static int painuzz_il2cpp_init(void) {
    dlopen(NULL, RTLD_NOW);
    RESOLVE(domain_get);
    RESOLVE(domain_get_assemblies);
    RESOLVE(assembly_get_image);
    RESOLVE(class_from_name);
    RESOLVE(class_get_method_from_name);
    RESOLVE(method_get_pointer);
    RESOLVE(class_get_field_from_name);
    RESOLVE(field_get_offset);
    return (fn_domain_get && fn_class_from_name && fn_class_get_method_from_name
            && fn_method_get_pointer) ? 1 : 0;
}

static void* painuzz_find_class(const char* ns, const char* name) {
    if (!fn_domain_get || !fn_class_from_name) return NULL;
    void* dom = fn_domain_get();
    size_t n = 0;
    void** asms = (void**)fn_domain_get_assemblies(dom, &n);
    for (size_t i = 0; i < n; i++) {
        void* img = fn_assembly_get_image(asms[i]);
        if (!img) continue;
        void* k = fn_class_from_name(img, ns ? ns : "", name);
        if (k) return k;
    }
    return NULL;
}

static void* painuzz_method_ptr(void* klass, const char* name, int argc) {
    if (!klass || !fn_class_get_method_from_name || !fn_method_get_pointer) return NULL;
    void* m = fn_class_get_method_from_name(klass, name, argc);
    return m ? fn_method_get_pointer(m) : NULL;
}

// ============================================================
// SECTION 4 — UNITY HELPERS
// ============================================================
static void* k_camClass       = NULL;
static void* k_transformClass = NULL;
static void* k_quatClass      = NULL;
static void* k_camMain        = NULL;
static void* k_camW2S         = NULL;
static void* k_camTransform   = NULL;
static void* k_transPos       = NULL;
static void* k_transRot       = NULL;
static void* k_transSetRot    = NULL;
static void* k_quatLook       = NULL;
static void* k_quatSlerp      = NULL;

static void unity_cache_resolve(void) {
    if (k_camMain) return;
    k_camClass       = painuzz_find_class("UnityEngine", "Camera");
    k_transformClass = painuzz_find_class("UnityEngine", "Transform");
    k_quatClass      = painuzz_find_class("UnityEngine", "Quaternion");
    if (!k_camClass || !k_transformClass || !k_quatClass) return;

    k_camMain      = painuzz_method_ptr(k_camClass, "get_main", 0);
    k_camW2S       = painuzz_method_ptr(k_camClass, "WorldToScreenPoint", 1);
    k_camTransform = painuzz_method_ptr(k_camClass, "get_transform", 0);

    k_transPos    = painuzz_method_ptr(k_transformClass, "get_position", 0);
    k_transRot    = painuzz_method_ptr(k_transformClass, "get_rotation", 0);
    k_transSetRot = painuzz_method_ptr(k_transformClass, "set_rotation", 1);

    k_quatLook  = painuzz_method_ptr(k_quatClass, "LookRotation", 2);
    k_quatSlerp = painuzz_method_ptr(k_quatClass, "Slerp", 3);
}

static Vec3 unity_vec3_sub(Vec3 a, Vec3 b) { return (Vec3){a.x-b.x, a.y-b.y, a.z-b.z}; }
static float unity_vec3_len(Vec3 v)         { return sqrtf(v.x*v.x + v.y*v.y + v.z*v.z); }
static Vec3 unity_vec3_norm(Vec3 v) {
    float m = unity_vec3_len(v);
    if (m < 1e-6f) return (Vec3){0,0,0};
    return (Vec3){v.x/m, v.y/m, v.z/m};
}
static Vec3 unity_quat_rotate(Quat q, Vec3 v) {
    Vec3 u = {q.x, q.y, q.z};
    float s = q.w;
    Vec3 uv  = {u.y*v.z - u.z*v.y, u.z*v.x - u.x*v.z, u.x*v.y - u.y*v.x};
    Vec3 uuv = {u.y*uv.z - u.z*uv.y, u.z*uv.x - u.x*uv.z, u.x*uv.y - u.y*uv.x};
    return (Vec3){v.x + 2.0f*(s*uv.x + uuv.x),
                  v.y + 2.0f*(s*uv.y + uuv.y),
                  v.z + 2.0f*(s*uv.z + uuv.z)};
}

static void* unity_camera_main(void) {
    if (!k_camMain) return NULL;
    return ((void*(*)(void))k_camMain)();
}
static void* unity_camera_transform(void* cam) {
    if (!k_camTransform || !cam) return NULL;
    return ((void*(*)(void*))k_camTransform)(cam);
}
static Vec3 unity_transform_position(void* t) {
    if (!k_transPos || !t) return (Vec3){0,0,0};
    return ((Vec3(*)(void*))k_transPos)(t);
}
static Quat unity_transform_rotation(void* t) {
    if (!k_transRot || !t) return (Quat){0,0,0,1};
    return ((Quat(*)(void*))k_transRot)(t);
}
static Vec3 unity_camera_w2s(void* cam, Vec3 w) {
    if (!k_camW2S || !cam) return (Vec3){0,0,-1};
    return ((Vec3(*)(void*, Vec3))k_camW2S)(cam, w);
}
static Quat unity_quat_lookrotation(Vec3 f, Vec3 u) {
    if (!k_quatLook) return (Quat){0,0,0,1};
    return ((Quat(*)(Vec3, Vec3))k_quatLook)(f, u);
}
static Quat unity_quat_slerp(Quat a, Quat b, float t) {
    if (!k_quatSlerp) return b;
    return ((Quat(*)(Quat, Quat, float))k_quatSlerp)(a, b, t);
}

// ============================================================
// SECTION 5 — GAME METHOD CACHE + LIST LAYOUT
// ============================================================
static void* k_pmClass  = NULL;
static void* k_plClass  = NULL;
static void* k_gfClass  = NULL;
static void* k_pmInst   = NULL;
static void* k_pmAll    = NULL;
static void* k_plHead   = NULL;
static void* k_plDead   = NULL;
static void* k_plTeam   = NULL;
static void* k_gfLocal  = NULL;

static void painuzz_resolve_game(void) {
    if (k_pmInst) return;
    k_pmClass = painuzz_find_class("", FF_PLAYERMGR_CLASS);
    k_plClass = painuzz_find_class("", FF_PLAYER_CLASS);
    k_gfClass = painuzz_find_class("", FF_GAMEFACADE_CLASS);
    if (!k_pmClass || !k_plClass) return;
    k_pmInst = painuzz_method_ptr(k_pmClass, FF_PLAYERMGR_INSTANCE, 0);
    k_pmAll  = painuzz_method_ptr(k_pmClass, FF_PLAYERMGR_PLAYERS,  0);
    k_plHead = painuzz_method_ptr(k_plClass, FF_PLAYER_HEAD_M,      0);
    k_plDead = painuzz_method_ptr(k_plClass, FF_PLAYER_DEAD_M,      0);
    k_plTeam = painuzz_method_ptr(k_plClass, FF_PLAYER_TEAM_M,      0);
    if (k_gfClass)
        k_gfLocal = painuzz_method_ptr(k_gfClass, FF_GAMEFACADE_LOCAL, 0);
}

// runtime detect List<T> layout: 0 = Unity 2019+ (0x10/0x18), 1 = 2018 (0x18/0x20)
static int detect_layout(void* list, void*** out_items, int32_t* out_size) {
    int32_t sz = *(int32_t*)((uint8_t*)list + 0x18);
    void** it  = *(void***)((uint8_t*)list + 0x10);
    if (sz > 0 && sz < 200 && it) { *out_items = it; *out_size = sz; return 0; }
    sz = *(int32_t*)((uint8_t*)list + 0x20);
    it = *(void***)((uint8_t*)list + 0x18);
    if (sz > 0 && sz < 200 && it) { *out_items = it; *out_size = sz; return 1; }
    return -1;
}

// ============================================================
// SECTION 6 — AIM STATE (dùng bởi hook set_rotation)
// ============================================================
static Quat  gPendingRotation = {0,0,0,1};
static BOOL  gHasPending      = NO;
static void* gCamTransform    = NULL;

// ============================================================
// SECTION 7 — AIMBOT
// ============================================================
@interface PainuzzAimbot : NSObject
+ (instancetype)shared;
- (void)install;
@end

static PainuzzAimbot *gAimInst = nil;

@implementation PainuzzAimbot

+ (instancetype)shared {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gAimInst = [PainuzzAimbot new]; });
    return gAimInst;
}

- (void)install {
    CADisplayLink *l = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick)];
    l.preferredFramesPerSecond = 60;
    [l addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)tick {
    gHasPending = NO;
    if (!gAimEnabled) return;
    painuzz_resolve_game();
    if (!k_pmInst) return;

    void* cam = unity_camera_main();
    if (!cam) return;
    void* camTrans = unity_camera_transform(cam);
    if (!camTrans) return;
    gCamTransform = camTrans;

    void* mgr = ((void*(*)(void))k_pmInst)();
    if (!mgr) return;
    void* list = ((void*(*)(void*))k_pmAll)(mgr);
    if (!list) return;

    void** items = NULL; int32_t sz = 0;
    if (detect_layout(list, &items, &sz) < 0) return;

    void* local = NULL; int32_t localTeam = -1;
    if (k_gfLocal) {
        local = ((void*(*)(void))k_gfLocal)();
        if (local && k_plTeam) localTeam = ((int32_t(*)(void*))k_plTeam)(local);
    }

    Vec3 camPos = unity_transform_position(camTrans);
    Quat camRot = unity_transform_rotation(camTrans);

    CGRect scr = [UIScreen mainScreen].bounds;
    CGPoint center = CGPointMake(scr.size.width / 2.0, scr.size.height / 2.0);

    void* best = NULL;
    float bestDist = gAimFOV;
    Vec3 bestHead = {0,0,0};

    for (int32_t i = 0; i < sz; i++) {
        void* p = items[i];
        if (!p || p == local) continue;
        if (k_plDead && ((bool(*)(void*))k_plDead)(p)) continue;
        if (k_plTeam && localTeam >= 0 &&
            ((int32_t(*)(void*))k_plTeam)(p) == localTeam) continue;

        Vec3 h = ((Vec3(*)(void*))k_plHead)(p);
        Vec3 s = unity_camera_w2s(cam, h);
        if (s.z <= 0.1f) continue;
        if (s.z > gEspDistance) continue;

        float dx = s.x - center.x, dy = s.y - center.y;
        float d = sqrtf(dx*dx + dy*dy);
        if (d < bestDist) { bestDist = d; best = p; bestHead = h; }
    }
    if (!best) return;

    Vec3 fwd = unity_vec3_norm(unity_vec3_sub(bestHead, camPos));
    if (fwd.x == 0 && fwd.y == 0 && fwd.z == 0) return;
    Vec3 up = unity_quat_rotate(camRot, (Vec3){0, 1, 0});
    Quat target = unity_quat_lookrotation(fwd, up);

    gPendingRotation = (gAimSmooth <= 0.001f)
        ? target
        : unity_quat_slerp(camRot, target, 1.0f - gAimSmooth);
    gHasPending = YES;
}

@end

// ============================================================
// SECTION 8 — ESP
// ============================================================
@interface PainuzzESP : UIView
+ (instancetype)shared;
- (void)install;
@end

static PainuzzESP *gEspInst = nil;
static UIWindow   *gEspWin  = nil;

@interface PainuzzESP () {
    NSMutableArray *boxes;
    NSMutableArray *labels;
}
@end

@implementation PainuzzESP

+ (instancetype)shared {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gEspInst = [[PainuzzESP alloc] initWithFrame:[UIScreen mainScreen].bounds];
        gEspInst.userInteractionEnabled = NO;
        gEspInst.backgroundColor = [UIColor clearColor];
    });
    return gEspInst;
}

- (void)install {
    gEspWin = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    gEspWin.windowLevel = UIWindowLevelAlert + 50;
    gEspWin.backgroundColor = [UIColor clearColor];
    gEspWin.rootViewController = [UIViewController new];
    [gEspWin addSubview:self];
    gEspWin.hidden = NO;
    boxes  = [NSMutableArray new];
    labels = [NSMutableArray new];
    CADisplayLink *l = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick)];
    l.preferredFramesPerSecond = 30;
    [l addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)clear {
    for (CALayer *l in boxes)  [l removeFromSuperlayer];
    for (CALayer *l in labels) [l removeFromSuperlayer];
    [boxes removeAllObjects];
    [labels removeAllObjects];
}

- (void)tick {
    if (!gEspEnabled) { [self clear]; return; }
    painuzz_resolve_game();
    if (!k_pmInst) return;

    void* mgr = ((void*(*)(void))k_pmInst)();
    if (!mgr) return;
    void* list = ((void*(*)(void*))k_pmAll)(mgr);
    if (!list) return;
    void** items = NULL; int32_t sz = 0;
    if (detect_layout(list, &items, &sz) < 0) return;

    void* cam = unity_camera_main();
    if (!cam) return;

    void* local = NULL; int32_t localTeam = -1;
    if (k_gfLocal) {
        local = ((void*(*)(void))k_gfLocal)();
        if (local && k_plTeam) localTeam = ((int32_t(*)(void*))k_plTeam)(local);
    }

    [self clear];
    CGRect scr = [UIScreen mainScreen].bounds;

    for (int32_t i = 0; i < sz; i++) {
        void* p = items[i];
        if (!p || p == local) continue;
        if (k_plDead && ((bool(*)(void*))k_plDead)(p)) continue;
        if (k_plTeam && localTeam >= 0 &&
            ((int32_t(*)(void*))k_plTeam)(p) == localTeam) continue;

        Vec3 head = ((Vec3(*)(void*))k_plHead)(p);
        Vec3 s = unity_camera_w2s(cam, head);
        if (s.z <= 0.1f) continue;
        if (s.z > gEspDistance) continue;
        if (s.x < 0 || s.x > scr.size.width)  continue;
        if (s.y < 0 || s.y > scr.size.height) continue;

        CGFloat bx = s.x - 24, by = s.y - 48, bw = 48, bh = 96;
        UIBezierPath *path = [UIBezierPath bezierPathWithRect:CGRectMake(bx, by, bw, bh)];
        CAShapeLayer *box = [CAShapeLayer layer];
        box.path        = path.CGPath;
        box.strokeColor = [UIColor colorWithRed:0.2 green:0.9 blue:0.4 alpha:1].CGColor;
        box.fillColor   = [UIColor clearColor].CGColor;
        box.lineWidth   = 1.5;
        [self.layer addSublayer:box];
        [boxes addObject:box];

        CATextLayer *t = [CATextLayer layer];
        t.string          = [NSString stringWithFormat:@"%.0fm", s.z];
        t.foregroundColor = [UIColor colorWithRed:0.2 green:0.9 blue:0.4 alpha:1].CGColor;
        t.fontSize        = 11;
        t.alignmentMode   = kCAAlignmentCenter;
        t.frame           = CGRectMake(bx, by + bh + 2, bw, 14);
        t.contentsScale   = [UIScreen mainScreen].scale;
        [self.layer addSublayer:t];
        [labels addObject:t];
    }
}

@end

// ============================================================
// SECTION 9 — MENU
// ============================================================
@interface PainuzzMenu : UIView
+ (instancetype)shared;
- (void)install;
- (void)toggle;
@end

static PainuzzMenu *gMenuInst = nil;
static UIWindow    *gMenuWin  = nil;

@interface PainuzzMenu ()
@property (nonatomic, strong) UILabel *fovLabel;
@property (nonatomic, strong) UILabel *smoothLabel;
@property (nonatomic, strong) UILabel *distLabel;
@end

@implementation PainuzzMenu

+ (instancetype)shared {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gMenuInst = [[PainuzzMenu alloc] initWithFrame:CGRectMake(20, 100, 300, 380)];
    });
    return gMenuInst;
}

- (instancetype)initWithFrame:(CGRect)f {
    self = [super initWithFrame:f];
    if (!self) return nil;
    self.backgroundColor = [UIColor colorWithWhite:0.07 alpha:0.92];
    self.layer.cornerRadius = 14;
    self.layer.borderWidth = 1.5;
    self.layer.borderColor = [UIColor colorWithRed:0.2 green:0.9 blue:0.4 alpha:1].CGColor;
    self.hidden = YES;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(14, 8, 240, 28)];
    title.text = @"Painuzz Mobile";
    title.textColor = [UIColor colorWithRed:0.2 green:0.9 blue:0.4 alpha:1];
    title.font = [UIFont boldSystemFontOfSize:18];
    [self addSubview:title];

    UIButton *x = [UIButton buttonWithType:UIButtonTypeSystem];
    x.frame = CGRectMake(256, 4, 40, 30);
    [x setTitle:@"×" forState:UIControlStateNormal];
    [x setTitleColor:[UIColor redColor] forState:UIControlStateNormal];
    x.titleLabel.font = [UIFont boldSystemFontOfSize:24];
    [x addTarget:self action:@selector(toggle) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:x];

    [self addGestureRecognizer:
        [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)]];

    UISwitch *aimSw = [[UISwitch alloc] initWithFrame:CGRectMake(14, 46, 60, 32)];
    aimSw.on = gAimEnabled;
    [aimSw addTarget:self action:@selector(onAim:) forControlEvents:UIControlEventValueChanged];
    [self addSubview:aimSw];
    UILabel *aimL = [[UILabel alloc] initWithFrame:CGRectMake(90, 50, 200, 24)];
    aimL.text = @"Aimbot (head-lock)";
    aimL.textColor = [UIColor whiteColor];
    aimL.font = [UIFont systemFontOfSize:14];
    [self addSubview:aimL];

    self.fovLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, 88, 280, 20)];
    self.fovLabel.textColor = [UIColor lightGrayColor];
    self.fovLabel.font = [UIFont systemFontOfSize:12];
    self.fovLabel.text = [NSString stringWithFormat:@"FOV: %.0f px", gAimFOV];
    [self addSubview:self.fovLabel];
    UISlider *fovS = [[UISlider alloc] initWithFrame:CGRectMake(14, 108, 280, 30)];
    fovS.minimumValue = 50; fovS.maximumValue = 800; fovS.value = gAimFOV;
    [fovS addTarget:self action:@selector(onFOV:) forControlEvents:UIControlEventValueChanged];
    [self addSubview:fovS];

    self.smoothLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, 148, 280, 20)];
    self.smoothLabel.textColor = [UIColor lightGrayColor];
    self.smoothLabel.font = [UIFont systemFontOfSize:12];
    self.smoothLabel.text = [NSString stringWithFormat:@"Smooth: %.2f", gAimSmooth];
    [self addSubview:self.smoothLabel];
    UISlider *smS = [[UISlider alloc] initWithFrame:CGRectMake(14, 168, 280, 30)];
    smS.minimumValue = 0.0f; smS.maximumValue = 1.0f; smS.value = gAimSmooth;
    [smS addTarget:self action:@selector(onSmooth:) forControlEvents:UIControlEventValueChanged];
    [self addSubview:smS];

    UISwitch *espSw = [[UISwitch alloc] initWithFrame:CGRectMake(14, 210, 60, 32)];
    espSw.on = gEspEnabled;
    [espSw addTarget:self action:@selector(onESP:) forControlEvents:UIControlEventValueChanged];
    [self addSubview:espSw];
    UILabel *espL = [[UILabel alloc] initWithFrame:CGRectMake(90, 214, 200, 24)];
    espL.text = @"ESP (địch + dist)";
    espL.textColor = [UIColor whiteColor];
    espL.font = [UIFont systemFontOfSize:14];
    [self addSubview:espL];

    self.distLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, 256, 280, 20)];
    self.distLabel.textColor = [UIColor lightGrayColor];
    self.distLabel.font = [UIFont systemFontOfSize:12];
    self.distLabel.text = [NSString stringWithFormat:@"ESP dist: %.0f m", gEspDistance];
    [self addSubview:self.distLabel];
    UISlider *dS = [[UISlider alloc] initWithFrame:CGRectMake(14, 276, 280, 30)];
    dS.minimumValue = 50; dS.maximumValue = 1200; dS.value = gEspDistance;
    [dS addTarget:self action:@selector(onDist:) forControlEvents:UIControlEventValueChanged];
    [self addSubview:dS];

    UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(14, 330, 280, 40)];
    hint.text = @"3 ngón chạm để ẩn/hiện menu";
    hint.textColor = [UIColor grayColor];
    hint.font = [UIFont italicSystemFontOfSize:11];
    hint.numberOfLines = 2;
    [self addSubview:hint];

    return self;
}

- (void)install {
    gMenuWin = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    gMenuWin.windowLevel = UIWindowLevelAlert + 100;
    gMenuWin.backgroundColor = [UIColor clearColor];
    gMenuWin.rootViewController = [UIViewController new];
    [gMenuWin addSubview:self];
    gMenuWin.hidden = NO;

    UITapGestureRecognizer *tap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onThreeFinger:)];
    tap.numberOfTouchesRequired = 3;
    tap.cancelsTouchesInView = NO;
    [gMenuWin.rootViewController.view addGestureRecognizer:tap];
}

- (void)toggle { self.hidden = !self.hidden; }
- (void)onThreeFinger:(UITapGestureRecognizer*)g {
    if (g.state == UIGestureRecognizerStateEnded) [self toggle];
}
- (void)onPan:(UIPanGestureRecognizer*)g {
    CGPoint t = [g translationInView:self.superview];
    self.center = CGPointMake(self.center.x + t.x, self.center.y + t.y);
    [g setTranslation:CGPointZero inView:self.superview];
}

- (void)onAim:(UISwitch*)s    { gAimEnabled = s.on; }
- (void)onESP:(UISwitch*)s    { gEspEnabled = s.on; }
- (void)onFOV:(UISlider*)s    { gAimFOV = s.value;
    self.fovLabel.text = [NSString stringWithFormat:@"FOV: %.0f px", gAimFOV]; }
- (void)onSmooth:(UISlider*)s { gAimSmooth = s.value;
    self.smoothLabel.text = [NSString stringWithFormat:@"Smooth: %.2f", gAimSmooth]; }
- (void)onDist:(UISlider*)s   { gEspDistance = s.value;
    self.distLabel.text = [NSString stringWithFormat:@"ESP dist: %.0f m", gEspDistance]; }

@end

// ============================================================
// SECTION 10 — HOOKS: AIM (Transform::set_rotation override)
// ============================================================
static void (*orig_set_rotation)(void*, Quat) = NULL;

static void hook_set_rotation(void* self, Quat r) {
    if (gAimEnabled && gHasPending && self == gCamTransform) {
        if (orig_set_rotation) {
            orig_set_rotation(self, gPendingRotation);
            return;
        }
    }
    if (orig_set_rotation) orig_set_rotation(self, r);
}

static void install_aim_hook(void) {
    if (orig_set_rotation) return;
    if (!painuzz_il2cpp_init()) return;
    unity_cache_resolve();
    if (!k_transSetRot) return;
    MSHookFunction(k_transSetRot, (void*)hook_set_rotation, (void**)&orig_set_rotation);
    NSLog(@"[Painuzz] aim hook installed @ %p", k_transSetRot);
}

// ============================================================
// SECTION 11 — ANTI-BAN
// ============================================================
%ctor {
    int (*pt)(int, int, void*, int) =
        (int(*)(int, int, void*, int))dlsym(RTLD_DEFAULT, "ptrace");
    if (pt) pt(31, 0, NULL, 0); // PT_DENY_ATTACH
}

%hook NSFileManager
- (BOOL)fileExistsAtPath:(NSString *)path {
    static NSArray *jb;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        jb = @[@"/Applications/Cydia.app", @"/Library/MobileSubstrate/MobileSubstrate.dylib",
               @"/Library/MobileSubstrate", @"/bin/bash", @"/usr/sbin/sshd",
               @"/etc/apt", @"/private/jailbreak.txt", @"/var/lib/cydia",
               @"/var/cache/apt", @"/usr/bin/ssh", @"/usr/libexec/sftp-server",
               @"/etc/ssh/sshd_config", @"/.installed_unc0ver", @"/.bootstrapped_electra",
               @"/var/jb"];
    });
    if ([jb containsObject:path]) return NO;
    return %orig;
}
%end

%hook NSFileManager
- (BOOL)fileExistsAtPath:(NSString *)path isDirectory:(BOOL*)d {
    static NSArray *jb;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        jb = @[@"/Applications/Cydia.app", @"/Library/MobileSubstrate/MobileSubstrate.dylib",
               @"/Library/MobileSubstrate", @"/bin/bash", @"/usr/sbin/sshd",
               @"/etc/apt", @"/private/jailbreak.txt", @"/var/jb"];
    });
    if ([jb containsObject:path]) { if (d) *d = NO; return NO; }
    return %orig;
}
%end

%hookf(int, sysctl, int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    int r = %orig(name, namelen, oldp, oldlenp, newp, newlen);
    if (r == 0 && name && namelen >= 4 && name[0] == CTL_KERN && name[1] == KERN_PROC
        && name[2] == KERN_PROC_PID && oldp && oldlenp
        && *oldlenp >= sizeof(struct kinfo_proc)) {
        struct kinfo_proc *info = (struct kinfo_proc *)oldp;
        info->kp_proc.p_flag &= ~(0x800 | 0x400); // P_TRACED | P_FLAG
    }
    return r;
}
%end

%hookf(const char*, _dyld_get_image_name, uint32_t idx) {
    const char* name = %orig(idx);
    if (name && strstr(name, "Painuzz")) return "/usr/lib/system/libsystem_kernel.dylib";
    return name;
}
%end

// ============================================================
// SECTION 12 — BOOT
// ============================================================
static void painuzz_bootstrap(void) {
    if (!painuzz_il2cpp_init()) {
        NSLog(@"[Painuzz] il2cpp resolve fail — binary chưa ready.");
        return;
    }
    install_aim_hook();
    [[PainuzzMenu shared] install];
    [[PainuzzESP shared] install];
    [[PainuzzAimbot shared] install];
    NSLog(@"[Painuzz] Painuzz Mobile active — 3-finger tap toggles menu.");
}

%hook UnityAppController
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
    BOOL r = %orig;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{ painuzz_bootstrap(); });
    return r;
}
%end

%ctor {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        if (objc_getClass("UnityAppController")) return;
        painuzz_bootstrap();
    });
}