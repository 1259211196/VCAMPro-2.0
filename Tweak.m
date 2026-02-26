#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreLocation/CoreLocation.h>
#import <MapKit/MapKit.h>
#import <CoreTelephony/CTCarrier.h>
#import <CoreTelephony/CTTelephonyNetworkInfo.h>
#import <sys/utsname.h> 
#import <time.h>
#import <objc/runtime.h>
#import <objc/message.h>

// 🌟 终极防御 (Wi-Fi 伪装): 引入网络层核心头文件
#import <SystemConfiguration/CaptiveNetwork.h>
#import <NetworkExtension/NetworkExtension.h>

// 🌟 Fishhook 整合: 引入免越狱 C 函数符号重绑定库
#import "fishhook.h"

#ifdef __cplusplus
extern "C" {
#endif
    int rebind_symbols(struct rebinding rebindings[], size_t rebindings_nel);
    int rebind_symbols_image(void *header, intptr_t slide, struct rebinding rebindings[], size_t rebindings_nel);
#ifdef __cplusplus
}
#endif

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
#pragma clang diagnostic ignored "-Wavailability"
#pragma clang diagnostic ignored "-Wdeprecated-declarations" 

// ============================================================================
// 【0. 工业级安全交换算法 (防止 AVAsset 类簇穿透)】
// ============================================================================
static void safe_swizzle(Class cls, SEL originalSelector, SEL swizzledSelector) {
    if (!cls) return;
    Method originalMethod = class_getInstanceMethod(cls, originalSelector);
    Method swizzledMethod = class_getInstanceMethod(cls, swizzledSelector);
    if (!originalMethod || !swizzledMethod) return;
    
    BOOL didAddMethod = class_addMethod(cls, originalSelector, method_getImplementation(swizzledMethod), method_getTypeEncoding(swizzledMethod));
    if (didAddMethod) {
        class_replaceMethod(cls, swizzledSelector, method_getImplementation(originalMethod), method_getTypeEncoding(originalMethod));
    } else {
        method_exchangeImplementations(originalMethod, swizzledMethod);
    }
}

// ============================================================================
// 【1. 极致安全的 C 语言静态缓存 & 动态真机硬件抓取】
// ============================================================================
static BOOL g_envSpoofingEnabled = NO;
static double g_fakeLat = 0.0;
static double g_fakeLon = 0.0;
static double g_driftLat = 0.0; 
static double g_driftLon = 0.0;

static NSString *g_fakeMCC = nil;
static NSString *g_fakeMNC = nil;
static NSString *g_fakeISO = nil;
static NSString *g_fakeCarrierName = nil;
static NSString *g_fakeTZ = nil;
static NSString *g_fakeLocale = nil;
static NSString *g_fakeSSID = nil;
static NSString *g_fakeBSSID = nil;

// 🌟 动态真机硬件抓取 (带缓存优化)
static NSString *getLiveDeviceModel() {
    static NSString *model = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        struct utsname systemInfo;
        uname(&systemInfo);
        model = [NSString stringWithCString:systemInfo.machine encoding:NSUTF8StringEncoding];
    });
    return model;
}

static NSString *getLiveSystemVersion() {
    static NSString *version = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        version = [[UIDevice currentDevice] systemVersion];
    });
    return version;
}

static NSString *getLiveTimestamp() {
    time_t rawtime; time(&rawtime); struct tm timeinfo; localtime_r(&rawtime, &timeinfo);
    char buffer[80]; strftime(buffer, sizeof(buffer), "%Y-%m-%dT%H:%M:%S%z", &timeinfo);
    return [NSString stringWithUTF8String:buffer];
}

// 脏数据特征库
#define IS_DIRTY_TAG(str) (str && ([[str uppercaseString] containsString:@"AWEME"] || [[str uppercaseString] containsString:@"FFMPEG"] || [[str uppercaseString] containsString:@"VCAM"]))

// 内部核心清洗逻辑 (Block 封装复用)
static NSArray* cleanAndSpoofMetadataArray(NSArray *origArray) {
    if (!origArray || origArray.count == 0) return origArray;
    NSMutableArray *clean = [NSMutableArray array];
    for (AVMetadataItem *item in origArray) {
        NSString *valDesc = [item.value description];
        if (IS_DIRTY_TAG(valDesc)) continue; // 发现脏数据，直接丢弃
        
        NSString *keyStr = [[item.key description] lowercaseString];
        if (!keyStr) { [clean addObject:item]; continue; }
        
        // 发现设备信息字段，篡改为实时真机数据
        if ([keyStr containsString:@"software"] || [keyStr containsString:@"creator"]) {
            AVMutableMetadataItem *mut = [item mutableCopy]; mut.value = [NSString stringWithFormat:@"com.apple.iOS.%@", getLiveSystemVersion()]; [clean addObject:mut];
        } else if ([keyStr containsString:@"model"]) {
            AVMutableMetadataItem *mut = [item mutableCopy]; mut.value = getLiveDeviceModel(); [clean addObject:mut];
        } else if ([keyStr containsString:@"make"]) {
            AVMutableMetadataItem *mut = [item mutableCopy]; mut.value = @"Apple"; [clean addObject:mut];
        } else if ([keyStr containsString:@"creationdate"]) {
            AVMutableMetadataItem *mut = [item mutableCopy]; mut.value = getLiveTimestamp(); [clean addObject:mut];
        } else {
            [clean addObject:item]; // 安全字段原样保留
        }
    }
    return clean;
}

// ============================================================================
// 【2. 环境配置窗口 (离线一键预设 + 物理防线控制)】
// ============================================================================
@interface AVCaptureMapWindow : UIWindow <MKMapViewDelegate, UIGestureRecognizerDelegate>
+ (instancetype)sharedMap;
- (void)showMapSecurely; 
@end

@implementation AVCaptureMapWindow { 
    MKMapView *_mapView; UILabel *_infoLabel; UISwitch *_envSwitch; 
    double _pendingLat; double _pendingLon;
    NSString *_pMCC; NSString *_pMNC; NSString *_pCarrier; NSString *_pTZ; NSString *_pLocale;
    NSString *_pISO; NSString *_pSSID; NSString *_pBSSID;
}
+ (instancetype)sharedMap { static AVCaptureMapWindow *map = nil; static dispatch_once_t once; dispatch_once(&once, ^{ map = [[AVCaptureMapWindow alloc] initWithFrame:CGRectMake(10, 100, 310, 480)]; }); return map; }
- (instancetype)initWithFrame:(CGRect)f { if (self = [super initWithFrame:f]) { self.windowLevel = UIWindowLevelStatusBar + 110; self.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.98]; self.layer.cornerRadius = 16; self.layer.masksToBounds = YES; self.hidden = YES; self.userInteractionEnabled = YES; UIViewController *root = [[UIViewController alloc] init]; root.view.frame = self.bounds; root.view.userInteractionEnabled = YES; self.rootViewController = root; [self setupUI]; UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)]; pan.delegate = self; [self addGestureRecognizer:pan]; } return self; }
- (BOOL)canBecomeKeyWindow { return YES; }
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event { UIView *hitView = [super hitTest:point withEvent:event]; if (hitView) return hitView; return nil; }
- (void)showMapSecurely { if (@available(iOS 13.0, *)) { if (!self.windowScene) { for (UIWindowScene *s in (NSArray *)[UIApplication sharedApplication].connectedScenes) { if (s.activationState == UISceneActivationStateForegroundActive) { self.windowScene = s; break; } } } } self.hidden = NO; [self makeKeyAndVisible]; }
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch { if ([touch.view isDescendantOfView:_mapView] || [touch.view isKindOfClass:[UIButton class]] || [touch.view isKindOfClass:[UISwitch class]]) { return NO; } return YES; }

- (void)setupUI {
    UIView *container = self.rootViewController.view;
    _pendingLat = g_fakeLat != 0.0 ? g_fakeLat : 50.1109; _pendingLon = g_fakeLon != 0.0 ? g_fakeLon : 8.6821; 
    _pMCC = g_fakeMCC ?: @"262"; _pMNC = g_fakeMNC ?: @"01"; _pCarrier = g_fakeCarrierName ?: @"Telekom.de"; 
    _pTZ = g_fakeTZ ?: @"Europe/Berlin"; _pLocale = g_fakeLocale ?: @"de_DE";
    _pISO = g_fakeISO ?: @"de"; _pSSID = g_fakeSSID ?: @"FritzBox-7590"; _pBSSID = g_fakeBSSID ?: @"c4:9f:4c:11:2b:7a";
    
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(15, 15, 200, 20)]; title.text = @"🌍 环境硬件伪装引擎"; title.textColor = [UIColor whiteColor]; title.font = [UIFont boldSystemFontOfSize:16]; [container addSubview:title];
    _envSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(245, 10, 50, 30)]; _envSwitch.on = g_envSpoofingEnabled; [container addSubview:_envSwitch];
    
    // 🌟 离线一键预设矩阵（飞行模式专用）
    NSArray *flags = @[@"🇺🇸 美", @"🇬🇧 英", @"🇫🇷 法", @"🇩🇪 德", @"🇮🇹 意"];
    for (int i = 0; i < 5; i++) {
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem]; btn.frame = CGRectMake(12 + i * (54 + 2), 45, 54, 32); btn.backgroundColor = [UIColor colorWithWhite:0.25 alpha:1.0]; btn.layer.cornerRadius = 6; btn.titleLabel.font = [UIFont systemFontOfSize:13]; [btn setTitle:flags[i] forState:UIControlStateNormal]; [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal]; btn.tag = i; [btn addTarget:self action:@selector(quickSelectCountry:) forControlEvents:UIControlEventTouchUpInside]; [container addSubview:btn];
    }
    
    _mapView = [[MKMapView alloc] initWithFrame:CGRectMake(12, 85, 286, 215)]; _mapView.layer.cornerRadius = 8; _mapView.delegate = self; _mapView.userInteractionEnabled = YES; 
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(dropPin:)]; lp.minimumPressDuration = 0.5; [_mapView addGestureRecognizer:lp]; [container addSubview:_mapView];
    _infoLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 310, 286, 60)]; _infoLabel.numberOfLines = 3; _infoLabel.textColor = [UIColor greenColor]; _infoLabel.font = [UIFont systemFontOfSize:11]; _infoLabel.textAlignment = NSTextAlignmentCenter; [self updateLabel]; [container addSubview:_infoLabel];
    UIButton *save = [UIButton buttonWithType:UIButtonTypeSystem]; save.frame = CGRectMake(12, 385, 286, 44); save.backgroundColor = [UIColor colorWithRed:0.2 green:0.6 blue:1.0 alpha:1.0]; save.layer.cornerRadius = 8; [save setTitle:@"保存环境并热更新" forState:UIControlStateNormal]; [save setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal]; [save addTarget:self action:@selector(saveAndClose) forControlEvents:UIControlEventTouchUpInside]; [container addSubview:save];
    [_mapView setRegion:MKCoordinateRegionMake(CLLocationCoordinate2DMake(_pendingLat, _pendingLon), MKCoordinateSpanMake(5, 5)) animated:NO];
}
- (void)updateLabel { _infoLabel.text = [NSString stringWithFormat:@"坐标: %.4f, %.4f\n运营商: %@ (%@-%@)\n时区: %@ | Wi-Fi: %@", _pendingLat, _pendingLon, _pCarrier?:@"-", _pMCC?:@"-", _pMNC?:@"-", _pTZ?:@"-", _pSSID?:@"-"]; }

- (void)quickSelectCountry:(UIButton *)sender {
    NSArray *codes = @[@"us", @"gb", @"fr", @"de", @"it"]; NSString *cc = codes[sender.tag];
    if ([cc isEqualToString:@"us"]) { _pendingLat = 40.7128; _pendingLon = -74.0060; } else if ([cc isEqualToString:@"gb"]) { _pendingLat = 51.5074; _pendingLon = -0.1278; } else if ([cc isEqualToString:@"fr"]) { _pendingLat = 48.8566; _pendingLon = 2.3522; } else if ([cc isEqualToString:@"de"]) { _pendingLat = 50.1109; _pendingLon = 8.6821; } else if ([cc isEqualToString:@"it"]) { _pendingLat = 41.9028; _pendingLon = 12.4964; }
    [self setFakeCountry:cc];
    [_mapView removeAnnotations:_mapView.annotations]; MKPointAnnotation *ann = [[MKPointAnnotation alloc] init]; ann.coordinate = CLLocationCoordinate2DMake(_pendingLat, _pendingLon); [_mapView addAnnotation:ann]; [_mapView setCenterCoordinate:ann.coordinate animated:YES];
    _infoLabel.text = @"✅ 离线预设已加载，请打开开关并保存"; _infoLabel.textColor = [UIColor greenColor]; [self updateLabel]; UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium]; [feedback impactOccurred];
}

- (void)setFakeCountry:(NSString *)cc {
    self->_pMCC = @"262"; self->_pMNC = @"01"; self->_pCarrier = @"Telekom.de"; self->_pTZ = @"Europe/Berlin"; self->_pLocale = @"de_DE"; self->_pISO = @"de"; self->_pSSID = @"FritzBox-7590"; self->_pBSSID = @"c4:9f:4c:11:2b:7a";
    if ([cc isEqualToString:@"us"]) { self->_pMCC = @"310"; self->_pMNC = @"410"; self->_pCarrier = @"AT&T"; self->_pTZ = @"America/New_York"; self->_pLocale = @"en_US"; self->_pISO = @"us"; self->_pSSID = @"AT&T-WIFI-5G"; self->_pBSSID = @"00:1c:10:a5:b1:22"; }
    else if ([cc isEqualToString:@"fr"]) { self->_pMCC = @"208"; self->_pMNC = @"01"; self->_pCarrier = @"Orange F"; self->_pTZ = @"Europe/Paris"; self->_pLocale = @"fr_FR"; self->_pISO = @"fr"; self->_pSSID = @"Livebox-9a2c"; self->_pBSSID = @"e4:9e:12:44:1a:0b"; }
    else if ([cc isEqualToString:@"it"]) { self->_pMCC = @"222"; self->_pMNC = @"01"; self->_pCarrier = @"TIM"; self->_pTZ = @"Europe/Rome"; self->_pLocale = @"it_IT"; self->_pISO = @"it"; self->_pSSID = @"TIM-Fibra"; self->_pBSSID = @"a0:1b:29:f1:4c:88"; }
    else if ([cc isEqualToString:@"gb"]) { self->_pMCC = @"234"; self->_pMNC = @"15"; self->_pCarrier = @"Vodafone UK"; self->_pTZ = @"Europe/London"; self->_pLocale = @"en_GB"; self->_pISO = @"gb"; self->_pSSID = @"BT-Hub6-2X9P"; self->_pBSSID = @"00:1e:8c:11:22:33"; }
}

- (void)dropPin:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    CGPoint p = [g locationInView:_mapView]; CLLocationCoordinate2D c = [_mapView convertPoint:p toCoordinateFromView:_mapView];
    [_mapView removeAnnotations:_mapView.annotations]; MKPointAnnotation *ann = [[MKPointAnnotation alloc] init]; ann.coordinate = c; [_mapView addAnnotation:ann];
    _pendingLat = c.latitude; _pendingLon = c.longitude;
    double jLat = (arc4random_uniform(200) - 100) / 10000000.0; double jLon = (arc4random_uniform(200) - 100) / 10000000.0;
    g_driftLat = jLat; g_driftLon = jLon;
    _infoLabel.text = @"⏳ 正在解析该国家基站与时区..."; _infoLabel.textColor = [UIColor orangeColor];
    CLGeocoder *geo = [[CLGeocoder alloc] init];
    [geo reverseGeocodeLocation:[[CLLocation alloc] initWithLatitude:c.latitude longitude:c.longitude] completionHandler:^(NSArray *pls, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{ 
            if (err || pls.count == 0) {
                if (c.longitude < -60) { [self setFakeCountry:@"us"]; } else if (c.longitude > -5 && c.longitude < 8 && c.latitude < 51) { [self setFakeCountry:@"fr"]; } else if (c.longitude > 6 && c.longitude < 18 && c.latitude < 47) { [self setFakeCountry:@"it"]; } else if (c.longitude > -10 && c.longitude < 2 && c.latitude > 50) { [self setFakeCountry:@"gb"]; } else { [self setFakeCountry:@"de"]; } 
            } else { CLPlacemark *pl = pls.firstObject; [self setFakeCountry:pl.ISOcountryCode.lowercaseString]; }
            self->_infoLabel.textColor = [UIColor greenColor]; [self updateLabel]; UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleHeavy]; [feedback impactOccurred]; 
        });
    }];
}

- (void)saveAndClose {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults]; [ud setBool:_envSwitch.on forKey:@"avs_env_enabled"]; [ud setDouble:_pendingLat forKey:@"avs_env_lat"]; [ud setDouble:_pendingLon forKey:@"avs_env_lon"];
    if (_pMCC) [ud setObject:_pMCC forKey:@"avs_env_mcc"]; if (_pMNC) [ud setObject:_pMNC forKey:@"avs_env_mnc"]; if (_pCarrier) [ud setObject:_pCarrier forKey:@"avs_env_carrier"]; if (_pTZ) [ud setObject:_pTZ forKey:@"avs_env_tz"]; if (_pLocale) [ud setObject:_pLocale forKey:@"avs_env_locale"]; if (_pISO) [ud setObject:_pISO forKey:@"avs_env_iso"]; if (_pSSID) [ud setObject:_pSSID forKey:@"avs_env_ssid"]; if (_pBSSID) [ud setObject:_pBSSID forKey:@"avs_env_bssid"];
    [ud synchronize];
    
    g_envSpoofingEnabled = _envSwitch.on; g_fakeLat = _pendingLat; g_fakeLon = _pendingLon; 
    if (_pMCC) g_fakeMCC = _pMCC; if (_pMNC) g_fakeMNC = _pMNC; if (_pCarrier) g_fakeCarrierName = _pCarrier; if (_pTZ) g_fakeTZ = _pTZ; if (_pLocale) g_fakeLocale = _pLocale; if (_pISO) g_fakeISO = _pISO; if (_pSSID) g_fakeSSID = _pSSID; if (_pBSSID) g_fakeBSSID = _pBSSID;
    
    [self makeKeyWindow]; UIAlertController *a = [UIAlertController alertControllerWithTitle:@"保存成功" message:@"系统级环境伪装已独立更新！" preferredStyle:UIAlertControllerStyleAlert]; [a addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(id x){ self.hidden = YES; }]]; [self.rootViewController presentViewController:a animated:YES completion:nil];
}
- (void)handlePan:(UIPanGestureRecognizer *)p { CGPoint t = [p translationInView:self]; self.center = CGPointMake(self.center.x+t.x, self.center.y+t.y); [p setTranslation:CGPointZero inView:self]; }
@end

// ============================================================================
// 【提前声明所有系统与护盾接口】
// ============================================================================
@interface CTCarrier (AVStreamHook)
- (NSString *)avs_carrierName; - (NSString *)avs_isoCountryCode; - (NSString *)avs_mobileCountryCode; - (NSString *)avs_mobileNetworkCode;
@end
@interface CTTelephonyNetworkInfo (AVStreamHook)
- (NSDictionary<NSString *,CTCarrier *> *)avs_serviceSubscriberCellularProviders;
@end
@interface CLLocationManager (AVStreamHook)
- (CLLocation *)avs_location; - (void)avs_startUpdatingLocation; - (void)avs_requestLocation;
@end
@interface CLLocation (AVStreamHook)
- (CLLocationCoordinate2D)avs_coordinate; - (CLLocationDistance)avs_altitude; - (CLLocationAccuracy)avs_horizontalAccuracy; - (CLLocationAccuracy)avs_verticalAccuracy; - (CLLocationSpeed)avs_speed; - (CLLocationDirection)avs_course;
@end
@interface NSTimeZone (AVStreamHook)
+ (NSTimeZone *)avs_systemTimeZone; + (NSTimeZone *)avs_defaultTimeZone; + (NSTimeZone *)avs_localTimeZone; 
@end
@interface NSLocale (AVStreamHook)
+ (NSLocale *)avs_currentLocale; + (NSLocale *)avs_autoupdatingCurrentLocale; + (NSArray<NSString *> *)avs_preferredLanguages;
@end
@interface UIWindow (AVStreamHook)
- (void)avs_becomeKeyWindow; - (void)avs_makeKeyAndVisible; - (void)avs_setupGestures;
@end
@interface NEHotspotNetwork (AVStreamHook)
+ (void)avs_fetchCurrentWithCompletionHandler:(void (^)(NEHotspotNetwork * _Nullable currentNetwork))completionHandler;
- (NSString *)avs_SSID; - (NSString *)avs_BSSID;
@end

// 🌟 护盾声明
@interface AVAssetExportSession (AVStreamHook)
- (void)vcam_setMetadata:(NSArray<AVMetadataItem *> *)metadata;
@end
@interface AVAsset (AVStreamHook)
- (NSArray<AVMetadataItem *> *)vcam_metadata;
- (NSArray<AVMetadataItem *> *)vcam_commonMetadata;
@end

// ============================================================================
// 【3. 系统底层 Hook 实现 (真机护盾 + 网络位置劫持)】
// ============================================================================

// 🌟 【写护盾】强制覆盖写入真实硬件信息 
@implementation AVAssetExportSession (AVStreamHook)
- (void)vcam_setMetadata:(NSArray<AVMetadataItem *> *)metadata {
    NSMutableArray *pureMetadata = [NSMutableArray array];

    NSString *myModel = getLiveDeviceModel();
    NSString *myVer = [NSString stringWithFormat:@"iOS %@", getLiveSystemVersion()];
    NSString *myDate = getLiveTimestamp();

    void (^addMeta)(NSString *, NSString *, id) = ^(NSString *keySpace, NSString *key, id value) {
        AVMutableMetadataItem *item = [[AVMutableMetadataItem alloc] init];
        item.keySpace = keySpace; item.key = key; item.value = value;
        [pureMetadata addObject:item];
    };

    addMeta(AVMetadataKeySpaceCommon, AVMetadataCommonKeyMake, @"Apple");
    addMeta(AVMetadataKeySpaceCommon, AVMetadataCommonKeyModel, myModel);
    addMeta(AVMetadataKeySpaceCommon, AVMetadataCommonKeySoftware, myVer);
    addMeta(AVMetadataKeySpaceCommon, AVMetadataCommonKeyCreationDate, myDate);
    
    // 补回物理位置对齐
    if (g_envSpoofingEnabled && g_fakeLat != 0.0) {
        addMeta(AVMetadataKeySpaceCommon, AVMetadataCommonKeyLocation, [NSString stringWithFormat:@"%+08.4f%+09.4f/", g_fakeLat, g_fakeLon]);
    }

    [self vcam_setMetadata:pureMetadata];
}
@end

// 🌟 【读护盾】(0消耗版) 精准清洗上传视频的元数据
@implementation AVAsset (AVStreamHook)
- (NSArray<AVMetadataItem *> *)vcam_metadata {
    if ([self isKindOfClass:[AVURLAsset class]]) {
        NSURL *url = [(AVURLAsset *)self URL];
        if (![url isFileURL] || [[url path] containsString:@"/Library/Caches/"] || [[url path] containsString:@"/tmp/aweme"]) {
            return [self vcam_metadata]; // 高速放行网络流与缓存
        }
    }
    return cleanAndSpoofMetadataArray([self vcam_metadata]);
}

- (NSArray<AVMetadataItem *> *)vcam_commonMetadata {
    if ([self isKindOfClass:[AVURLAsset class]]) {
        NSURL *url = [(AVURLAsset *)self URL];
        if (![url isFileURL] || [[url path] containsString:@"/Library/Caches/"] || [[url path] containsString:@"/tmp/aweme"]) {
            return [self vcam_commonMetadata];
        }
    }
    return cleanAndSpoofMetadataArray([self vcam_commonMetadata]);
}
@end

static CFDictionaryRef (*orig_CNCopyCurrentNetworkInfo)(CFStringRef interfaceName);
CFDictionaryRef my_CNCopyCurrentNetworkInfo(CFStringRef interfaceName) {
    if (g_envSpoofingEnabled && g_fakeSSID && g_fakeBSSID) {
        NSDictionary *fakeNetworkInfo = @{ (id)kCNNetworkInfoKeySSID: g_fakeSSID, (id)kCNNetworkInfoKeyBSSID: g_fakeBSSID, (id)kCNNetworkInfoKeySSIDData: [g_fakeSSID dataUsingEncoding:NSUTF8StringEncoding] };
        return CFBridgingRetain(fakeNetworkInfo);
    }
    if (orig_CNCopyCurrentNetworkInfo) { return orig_CNCopyCurrentNetworkInfo(interfaceName); }
    return NULL;
}

@implementation NEHotspotNetwork (AVStreamHook)
+ (void)avs_fetchCurrentWithCompletionHandler:(void (^)(NEHotspotNetwork * _Nullable currentNetwork))completionHandler {
    if (g_envSpoofingEnabled && g_fakeSSID) {
        [self avs_fetchCurrentWithCompletionHandler:^(NEHotspotNetwork * _Nullable currentNetwork) {
            if (completionHandler) completionHandler(currentNetwork); 
        }];
    } else { [self avs_fetchCurrentWithCompletionHandler:completionHandler]; }
}
- (NSString *)avs_SSID { if (g_envSpoofingEnabled && g_fakeSSID) return g_fakeSSID; return [self avs_SSID]; }
- (NSString *)avs_BSSID { if (g_envSpoofingEnabled && g_fakeBSSID) return g_fakeBSSID; return [self avs_BSSID]; }
@end

@implementation CTCarrier (AVStreamHook)
- (NSString *)avs_carrierName { return g_envSpoofingEnabled && g_fakeCarrierName ? g_fakeCarrierName : [self avs_carrierName]; }
- (NSString *)avs_isoCountryCode { return g_envSpoofingEnabled && g_fakeISO ? g_fakeISO : [self avs_isoCountryCode]; }
- (NSString *)avs_mobileCountryCode { return g_envSpoofingEnabled && g_fakeMCC ? g_fakeMCC : [self avs_mobileCountryCode]; }
- (NSString *)avs_mobileNetworkCode { return g_envSpoofingEnabled && g_fakeMNC ? g_fakeMNC : [self avs_mobileNetworkCode]; }
@end
@implementation CTTelephonyNetworkInfo (AVStreamHook)
- (NSDictionary<NSString *,CTCarrier *> *)avs_serviceSubscriberCellularProviders {
    if (!g_envSpoofingEnabled) return [self avs_serviceSubscriberCellularProviders];
    CTCarrier *fakeCarrier = [[NSClassFromString(@"CTCarrier") alloc] init]; return @{@"0000000100000001": fakeCarrier};
}
@end

@implementation CLLocation (AVStreamHook)
- (CLLocationCoordinate2D)avs_coordinate { if (g_envSpoofingEnabled && g_fakeLat != 0.0) return CLLocationCoordinate2DMake(g_fakeLat + g_driftLat, g_fakeLon + g_driftLon); return [self avs_coordinate]; }
- (CLLocationDistance)avs_altitude { if (g_envSpoofingEnabled && g_fakeLat != 0.0) return 45.0 + (g_driftLat * 1000); return [self avs_altitude]; }
- (CLLocationAccuracy)avs_horizontalAccuracy { if (g_envSpoofingEnabled && g_fakeLat != 0.0) return 5.0; return [self avs_horizontalAccuracy]; }
- (CLLocationAccuracy)avs_verticalAccuracy { if (g_envSpoofingEnabled && g_fakeLat != 0.0) return 4.0; return [self avs_verticalAccuracy]; }
- (CLLocationSpeed)avs_speed { if (g_envSpoofingEnabled && g_fakeLat != 0.0) return -1.0; return [self avs_speed]; }
- (CLLocationDirection)avs_course { if (g_envSpoofingEnabled && g_fakeLat != 0.0) return -1.0; return [self avs_course]; }
@end

@implementation CLLocationManager (AVStreamHook)
- (CLLocation *)avs_location {
    if (g_envSpoofingEnabled && g_fakeLat != 0.0) {
        return [[CLLocation alloc] initWithCoordinate:CLLocationCoordinate2DMake(g_fakeLat + g_driftLat, g_fakeLon + g_driftLon) altitude:45.0 horizontalAccuracy:5.0 verticalAccuracy:4.0 course:-1.0 speed:-1.0 timestamp:[NSDate date]];
    }
    return [self avs_location];
}
- (void)avs_startUpdatingLocation {
    [self avs_startUpdatingLocation]; 
    if (g_envSpoofingEnabled && self.delegate) {
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (strongSelf && [strongSelf.delegate respondsToSelector:@selector(locationManager:didUpdateLocations:)]) {
                CLLocation *fake = [[CLLocation alloc] initWithCoordinate:CLLocationCoordinate2DMake(g_fakeLat + g_driftLat, g_fakeLon + g_driftLon) altitude:45.0 horizontalAccuracy:5.0 verticalAccuracy:4.0 course:-1.0 speed:-1.0 timestamp:[NSDate date]];
                [strongSelf.delegate locationManager:strongSelf didUpdateLocations:@[fake]];
            }
        });
    }
}
- (void)avs_requestLocation {
    [self avs_requestLocation];
    if (g_envSpoofingEnabled && self.delegate) {
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (strongSelf && [strongSelf.delegate respondsToSelector:@selector(locationManager:didUpdateLocations:)]) {
                CLLocation *fake = [[CLLocation alloc] initWithCoordinate:CLLocationCoordinate2DMake(g_fakeLat + g_driftLat, g_fakeLon + g_driftLon) altitude:45.0 horizontalAccuracy:5.0 verticalAccuracy:4.0 course:-1.0 speed:-1.0 timestamp:[NSDate date]];
                [strongSelf.delegate locationManager:strongSelf didUpdateLocations:@[fake]];
            }
        });
    }
}
@end

@implementation NSTimeZone (AVStreamHook)
+ (NSTimeZone *)avs_systemTimeZone { if (g_envSpoofingEnabled && g_fakeTZ) { NSTimeZone *tz = [NSTimeZone timeZoneWithName:g_fakeTZ]; if (tz) return tz; } return [self avs_systemTimeZone]; }
+ (NSTimeZone *)avs_defaultTimeZone { if (g_envSpoofingEnabled && g_fakeTZ) { NSTimeZone *tz = [NSTimeZone timeZoneWithName:g_fakeTZ]; if (tz) return tz; } return [self avs_defaultTimeZone]; }
+ (NSTimeZone *)avs_localTimeZone { if (g_envSpoofingEnabled && g_fakeTZ) { NSTimeZone *tz = [NSTimeZone timeZoneWithName:g_fakeTZ]; if (tz) return tz; } return [self avs_localTimeZone]; } 
@end
@implementation NSLocale (AVStreamHook)
+ (NSLocale *)avs_currentLocale { if (g_envSpoofingEnabled && g_fakeLocale) { return [NSLocale localeWithLocaleIdentifier:g_fakeLocale]; } return [self avs_currentLocale]; }
+ (NSLocale *)avs_autoupdatingCurrentLocale { if (g_envSpoofingEnabled && g_fakeLocale) { return [NSLocale localeWithLocaleIdentifier:g_fakeLocale]; } return [self avs_autoupdatingCurrentLocale]; } 
+ (NSArray<NSString *> *)avs_preferredLanguages { if (g_envSpoofingEnabled && g_fakeLocale) { return @[g_fakeLocale, @"en-US"]; } return [self avs_preferredLanguages]; }
@end

@implementation UIWindow (AVStreamHook)
- (void)avs_setupGestures {
    if (![self isKindOfClass:NSClassFromString(@"AVCaptureMapWindow")] && !objc_getAssociatedObject(self, "_avs_g")) {
        // 🌟 仅保留绝对安全的四指单点呼出地图面板，彻底绝缘视频功能
        UITapGestureRecognizer *mapTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(showMapPanel:)];
        mapTap.numberOfTouchesRequired = 4; mapTap.numberOfTapsRequired = 1; [self addGestureRecognizer:mapTap];
        objc_setAssociatedObject(self, "_avs_g", @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}
- (void)avs_becomeKeyWindow { [self avs_becomeKeyWindow]; [self avs_setupGestures]; }
- (void)avs_makeKeyAndVisible { [self avs_makeKeyAndVisible]; [self avs_setupGestures]; }
- (void)showMapPanel:(UIGestureRecognizer *)gesture { if (gesture.state == UIGestureRecognizerStateEnded || gesture.state == UIGestureRecognizerStateRecognized) { [[AVCaptureMapWindow sharedMap] showMapSecurely]; UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleHeavy]; [feedback impactOccurred]; } }
@end

// ============================================================================
// 【4. 加载入口】
// ============================================================================
@interface AVStreamLoader : NSObject
@end
@implementation AVStreamLoader
+ (void)load {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    
    if ([defaults objectForKey:@"avs_env_enabled"] != nil) {
        g_envSpoofingEnabled = [defaults boolForKey:@"avs_env_enabled"];
        g_fakeLat = [defaults doubleForKey:@"avs_env_lat"];
        g_fakeLon = [defaults doubleForKey:@"avs_env_lon"];
        g_fakeMCC = [defaults stringForKey:@"avs_env_mcc"] ?: @"262";
        g_fakeMNC = [defaults stringForKey:@"avs_env_mnc"] ?: @"01";
        g_fakeISO = [defaults stringForKey:@"avs_env_iso"] ?: @"de";
        g_fakeCarrierName = [defaults stringForKey:@"avs_env_carrier"] ?: @"Telekom.de";
        g_fakeTZ = [defaults stringForKey:@"avs_env_tz"] ?: @"Europe/Berlin";
        g_fakeLocale = [defaults stringForKey:@"avs_env_locale"] ?: @"de_DE";
        g_fakeSSID = [defaults stringForKey:@"avs_env_ssid"] ?: @"FritzBox-7590";
        g_fakeBSSID = [defaults stringForKey:@"avs_env_bssid"] ?: @"c4:9f:4c:11:2b:7a";
    } else { 
        g_envSpoofingEnabled = NO; 
    }

    // 🌟 完美融合注入：激活真机硬件读写护盾 (使用 Safe Swizzle)
    Class exportSessionClass = NSClassFromString(@"AVAssetExportSession");
    if (exportSessionClass) safe_swizzle(exportSessionClass, @selector(setMetadata:), @selector(vcam_setMetadata:));
    
    Class urlAssetClass = NSClassFromString(@"AVURLAsset");
    if (urlAssetClass) {
        safe_swizzle(urlAssetClass, @selector(metadata), @selector(vcam_metadata));
        safe_swizzle(urlAssetClass, @selector(commonMetadata), @selector(vcam_commonMetadata));
    }
    Class assetClass = NSClassFromString(@"AVAsset");
    if (assetClass && assetClass != urlAssetClass) {
        safe_swizzle(assetClass, @selector(metadata), @selector(vcam_metadata));
        safe_swizzle(assetClass, @selector(commonMetadata), @selector(vcam_commonMetadata));
    }

    // UI Hook
    method_exchangeImplementations(class_getInstanceMethod([UIWindow class], @selector(becomeKeyWindow)), class_getInstanceMethod([UIWindow class], @selector(avs_becomeKeyWindow)));
    method_exchangeImplementations(class_getInstanceMethod([UIWindow class], @selector(makeKeyAndVisible)), class_getInstanceMethod([UIWindow class], @selector(avs_makeKeyAndVisible)));
    
    // 🌟 【极其重要】与 AVCaptureVideoDataOutput 有关的相机的 Hook 代码已被连根拔起！绝不冲突！
    
    Class locClass = NSClassFromString(@"CLLocationManager"); 
    if (locClass) {
        method_exchangeImplementations(class_getInstanceMethod(locClass, @selector(location)), class_getInstanceMethod(locClass, @selector(avs_location)));
        method_exchangeImplementations(class_getInstanceMethod(locClass, @selector(startUpdatingLocation)), class_getInstanceMethod(locClass, @selector(avs_startUpdatingLocation)));
        method_exchangeImplementations(class_getInstanceMethod(locClass, @selector(requestLocation)), class_getInstanceMethod(locClass, @selector(avs_requestLocation)));
    }
    Class clLocationClass = NSClassFromString(@"CLLocation");
    if (clLocationClass) {
        method_exchangeImplementations(class_getInstanceMethod(clLocationClass, @selector(coordinate)), class_getInstanceMethod(clLocationClass, @selector(avs_coordinate)));
        method_exchangeImplementations(class_getInstanceMethod(clLocationClass, @selector(altitude)), class_getInstanceMethod(clLocationClass, @selector(avs_altitude)));
        method_exchangeImplementations(class_getInstanceMethod(clLocationClass, @selector(horizontalAccuracy)), class_getInstanceMethod(clLocationClass, @selector(avs_horizontalAccuracy)));
        method_exchangeImplementations(class_getInstanceMethod(clLocationClass, @selector(verticalAccuracy)), class_getInstanceMethod(clLocationClass, @selector(avs_verticalAccuracy)));
        method_exchangeImplementations(class_getInstanceMethod(clLocationClass, @selector(speed)), class_getInstanceMethod(clLocationClass, @selector(avs_speed)));
        method_exchangeImplementations(class_getInstanceMethod(clLocationClass, @selector(course)), class_getInstanceMethod(clLocationClass, @selector(avs_course)));
    }

    Class carrierClass = NSClassFromString(@"CTCarrier");
    if (carrierClass) {
        method_exchangeImplementations(class_getInstanceMethod(carrierClass, @selector(carrierName)), class_getInstanceMethod(carrierClass, @selector(avs_carrierName)));
        method_exchangeImplementations(class_getInstanceMethod(carrierClass, @selector(isoCountryCode)), class_getInstanceMethod(carrierClass, @selector(avs_isoCountryCode)));
        method_exchangeImplementations(class_getInstanceMethod(carrierClass, @selector(mobileCountryCode)), class_getInstanceMethod(carrierClass, @selector(avs_mobileCountryCode)));
        method_exchangeImplementations(class_getInstanceMethod(carrierClass, @selector(mobileNetworkCode)), class_getInstanceMethod(carrierClass, @selector(avs_mobileNetworkCode)));
    }
    Class netInfoClass = NSClassFromString(@"CTTelephonyNetworkInfo");
    if (netInfoClass) method_exchangeImplementations(class_getInstanceMethod(netInfoClass, @selector(serviceSubscriberCellularProviders)), class_getInstanceMethod(netInfoClass, @selector(avs_serviceSubscriberCellularProviders)));
    
    Class tzClass = NSClassFromString(@"NSTimeZone");
    if (tzClass) {
        method_exchangeImplementations(class_getClassMethod(tzClass, @selector(systemTimeZone)), class_getClassMethod(tzClass, @selector(avs_systemTimeZone)));
        method_exchangeImplementations(class_getClassMethod(tzClass, @selector(defaultTimeZone)), class_getClassMethod(tzClass, @selector(avs_defaultTimeZone)));
        method_exchangeImplementations(class_getClassMethod(tzClass, @selector(localTimeZone)), class_getClassMethod(tzClass, @selector(avs_localTimeZone)));
    }
    Class loclClass = NSClassFromString(@"NSLocale");
    if (loclClass) {
        method_exchangeImplementations(class_getClassMethod(loclClass, @selector(currentLocale)), class_getClassMethod(loclClass, @selector(avs_currentLocale)));
        method_exchangeImplementations(class_getClassMethod(loclClass, @selector(autoupdatingCurrentLocale)), class_getClassMethod(loclClass, @selector(avs_autoupdatingCurrentLocale)));
        method_exchangeImplementations(class_getClassMethod(loclClass, @selector(preferredLanguages)), class_getClassMethod(loclClass, @selector(avs_preferredLanguages)));
    }

    Class neClass = NSClassFromString(@"NEHotspotNetwork");
    if (neClass) {
        method_exchangeImplementations(class_getClassMethod(neClass, @selector(fetchCurrentWithCompletionHandler:)), class_getClassMethod(neClass, @selector(avs_fetchCurrentWithCompletionHandler:)));
        method_exchangeImplementations(class_getInstanceMethod(neClass, @selector(SSID)), class_getInstanceMethod(neClass, @selector(avs_SSID)));
        method_exchangeImplementations(class_getInstanceMethod(neClass, @selector(BSSID)), class_getInstanceMethod(neClass, @selector(avs_BSSID)));
    }

    struct rebinding cn_rebinding = { "CNCopyCurrentNetworkInfo", (void *)my_CNCopyCurrentNetworkInfo, (void **)&orig_CNCopyCurrentNetworkInfo };
    rebind_symbols((struct rebinding[1]){cn_rebinding}, 1);
}
@end
#pragma clang diagnostic pop
