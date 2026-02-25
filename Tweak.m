#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreImage/CoreImage.h>
#import <CoreLocation/CoreLocation.h>
#import <MapKit/MapKit.h>
#import <CoreTelephony/CTCarrier.h>
#import <CoreTelephony/CTTelephonyNetworkInfo.h>
#import <objc/runtime.h>
#import <objc/message.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
#pragma clang diagnostic ignored "-Wavailability"

// ============================================================================
// 【0. 极致安全的 C 语言静态缓存 (杜绝启动死锁)】
// ============================================================================
static BOOL g_envSpoofingEnabled = NO;
static double g_fakeLat = 0.0;
static double g_fakeLon = 0.0;
static NSString *g_fakeMCC = nil;
static NSString *g_fakeMNC = nil;
static NSString *g_fakeISO = nil;
static NSString *g_fakeCarrierName = nil;
static NSString *g_fakeTZ = nil;
static NSString *g_fakeLocale = nil;

// ============================================================================
// 【1. 伪装系统大管家 (类名已混淆伪装)】
// ============================================================================
@class AVCaptureHUDWindow, AVCaptureMapWindow, AVStreamCoreProcessor;

@interface AVStreamManager : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)sharedManager;
@property (nonatomic, assign) BOOL isEnabled;
@property (nonatomic, assign) BOOL isHUDVisible; 
@property (nonatomic, assign) NSInteger currentSlot;
@property (nonatomic, strong) NSHashTable *displayLayers;
@property (nonatomic, strong) AVStreamCoreProcessor *processor;

- (void)updateDisplayLayers;
@end

@interface AVCaptureHUDWindow : UIWindow <UIImagePickerControllerDelegate, UINavigationControllerDelegate>
+ (instancetype)sharedHUD;
@end

@interface AVCaptureMapWindow : UIWindow <MKMapViewDelegate, UIGestureRecognizerDelegate> // 🌟 修复：手势代理
+ (instancetype)sharedMap;
- (void)showMapSecurely; // 🌟 修复：安全弹出方法
@end

// ============================================================================
// 【2. 异步视频去重洗稿引擎】
// ============================================================================
@interface AVStreamPreprocessor : NSObject
+ (void)processVideoAtURL:(NSURL *)sourceURL toDestination:(NSString *)destPath brightness:(CGFloat)brightness contrast:(CGFloat)contrast saturation:(CGFloat)saturation completion:(void(^)(BOOL success, NSError *error))completion;
@end

@implementation AVStreamPreprocessor
+ (void)processVideoAtURL:(NSURL *)sourceURL toDestination:(NSString *)destPath brightness:(CGFloat)brightness contrast:(CGFloat)contrast saturation:(CGFloat)saturation completion:(void(^)(BOOL success, NSError *error))completion {
    AVAsset *asset = [AVAsset assetWithURL:sourceURL];
    AVAssetTrack *videoTrack = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    if (!videoTrack) { if (completion) completion(NO, nil); return; }

    AVMutableVideoComposition *videoComposition = [AVMutableVideoComposition videoCompositionWithAsset:asset applyingCIFiltersWithHandler:^(AVAsynchronousCIImageFilteringRequest * _Nonnull request) {
        CIImage *sourceImage = request.sourceImage;
        CIFilter *colorFilter = [CIFilter filterWithName:@"CIColorControls"];
        [colorFilter setValue:sourceImage forKey:kCIInputImageKey];
        [colorFilter setValue:@(brightness) forKey:kCIInputBrightnessKey];
        [colorFilter setValue:@(contrast) forKey:kCIInputContrastKey];
        [colorFilter setValue:@(saturation) forKey:kCIInputSaturationKey];
        CIImage *outputImage = colorFilter.outputImage;
        if (outputImage) { [request finishWithImage:outputImage context:nil]; } 
        else { [request finishWithImage:sourceImage context:nil]; }
    }];
    
    AVAssetExportSession *exportSession = [[AVAssetExportSession alloc] initWithAsset:asset presetName:AVAssetExportPresetHighestQuality];
    exportSession.outputURL = [NSURL fileURLWithPath:destPath];
    exportSession.outputFileType = AVFileTypeMPEG4;
    exportSession.videoComposition = videoComposition;
    exportSession.shouldOptimizeForNetworkUse = YES; 
    exportSession.metadata = @[]; 

    [exportSession exportAsynchronouslyWithCompletionHandler:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            if (exportSession.status == AVAssetExportSessionStatusCompleted) { if (completion) completion(YES, nil); } 
            else { if (completion) completion(NO, exportSession.error); }
        });
    }];
}
@end

// ============================================================================
// 【3. 极致安全底层推流引擎】
// ============================================================================
@interface AVStreamDecoder : NSObject
- (instancetype)initWithVideoPath:(NSString *)path;
- (CVPixelBufferRef)copyNextPixelBuffer;
@end
@implementation AVStreamDecoder { AVAssetReader *_assetReader; AVAssetReaderOutput *_trackOutput; NSString *_videoPath; }
- (instancetype)initWithVideoPath:(NSString *)path { if (self = [super init]) { _videoPath = path; [self setupReader]; } return self; }
- (void)setupReader {
    if (!_videoPath) return;
    if (_assetReader) { [_assetReader cancelReading]; _assetReader = nil; _trackOutput = nil; }
    if (![[NSFileManager defaultManager] fileExistsAtPath:_videoPath]) return;
    AVAsset *asset = [AVAsset assetWithURL:[NSURL fileURLWithPath:_videoPath]];
    _assetReader = [AVAssetReader assetReaderWithAsset:asset error:nil];
    AVAssetTrack *videoTrack = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    if (!videoTrack || !_assetReader) return;
    NSDictionary *settings = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)};
    AVMutableVideoComposition *videoComp = nil;
    @try { videoComp = (AVMutableVideoComposition *)[AVVideoComposition videoCompositionWithPropertiesOfAsset:asset]; } @catch (NSException *e) {}
    if (videoComp) { AVAssetReaderVideoCompositionOutput *compOut = [AVAssetReaderVideoCompositionOutput assetReaderVideoCompositionOutputWithVideoTracks:@[videoTrack] videoSettings:settings]; compOut.videoComposition = videoComp; _trackOutput = (AVAssetReaderOutput *)compOut;
    } else { _trackOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:videoTrack outputSettings:settings]; }
    if ([_assetReader canAddOutput:_trackOutput]) { [_assetReader addOutput:_trackOutput]; [_assetReader startReading]; }
}
- (CVPixelBufferRef)copyNextPixelBuffer {
    if (!_assetReader) return NULL;
    if (_assetReader.status == AVAssetReaderStatusCompleted) [self setupReader];
    if (_assetReader.status == AVAssetReaderStatusReading) { CMSampleBufferRef sbuf = [_trackOutput copyNextSampleBuffer]; if (sbuf) { CVPixelBufferRef pix = CMSampleBufferGetImageBuffer(sbuf); if (pix) CVPixelBufferRetain(pix); CFRelease(sbuf); return pix; } }
    return NULL;
}
@end

@interface AVStreamCoreProcessor : NSObject
@property (nonatomic, strong) AVStreamDecoder *decoder;
@property (nonatomic, assign) VTPixelTransferSessionRef pixelTransferSession;
@property (nonatomic, strong) NSLock *decoderLock;
- (void)processSampleBuffer:(CMSampleBufferRef)sampleBuffer;
- (void)processDepthBuffer:(AVDepthData *)depthData;
- (void)loadVideoForCurrentSlot:(NSInteger)slot;
@end
@implementation AVStreamCoreProcessor
- (instancetype)init {
    if (self = [super init]) {
        _decoderLock = [[NSLock alloc] init];
        VTPixelTransferSessionCreate(kCFAllocatorDefault, &_pixelTransferSession);
        if (_pixelTransferSession) VTSessionSetProperty(_pixelTransferSession, kVTPixelTransferPropertyKey_ScalingMode, kVTScalingMode_CropSourceToCleanAperture);
        
        // 🌟 修复死锁：移除这里的自我加载，转由通知和 Manager 驱动
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleChannelChange:) name:@"AVSChannelDidChangeNotification" object:nil];
    }
    return self;
}
- (void)loadVideoForCurrentSlot:(NSInteger)slot {
    NSString *docPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *videoPath = [docPath stringByAppendingPathComponent:[NSString stringWithFormat:@"test%ld.mp4", (long)slot]];
    [self.decoderLock lock]; self.decoder = [[AVStreamDecoder alloc] initWithVideoPath:videoPath]; [self.decoderLock unlock];
}
- (void)handleChannelChange:(NSNotification *)note {
    [self loadVideoForCurrentSlot:[AVStreamManager sharedManager].currentSlot];
}
- (void)processSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    if (![AVStreamManager sharedManager].isEnabled) return;
    [self.decoderLock lock]; CVPixelBufferRef srcPix = [self.decoder copyNextPixelBuffer]; [self.decoderLock unlock];
    if (srcPix) {
        CVImageBufferRef dstPix = CMSampleBufferGetImageBuffer(sampleBuffer);
        if (dstPix && self.pixelTransferSession) VTPixelTransferSessionTransferImage(self.pixelTransferSession, srcPix, dstPix);
        CVPixelBufferRelease(srcPix);
    }
    @synchronized ([AVStreamManager sharedManager].displayLayers) {
        for (AVSampleBufferDisplayLayer *layer in [[AVStreamManager sharedManager].displayLayers allObjects]) {
            if (!layer.hidden && layer.isReadyForMoreMediaData) { if (layer.status == AVQueuedSampleBufferRenderingStatusFailed) [layer flush]; [layer enqueueSampleBuffer:sampleBuffer]; }
        }
    }
}
- (void)processDepthBuffer:(AVDepthData *)depthData {
    if (!depthData) return; CVPixelBufferRef depthMap = [depthData depthDataMap]; if (!depthMap) return;
    if (CVPixelBufferLockBaseAddress(depthMap, 0) == kCVReturnSuccess) { void *baseAddress = CVPixelBufferGetBaseAddress(depthMap); if (baseAddress) { size_t size = CVPixelBufferGetBytesPerRow(depthMap) * CVPixelBufferGetHeight(depthMap); memset(baseAddress, 0, size); } CVPixelBufferUnlockBaseAddress(depthMap, 0); }
}
- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; if (_pixelTransferSession) { VTPixelTransferSessionInvalidate(_pixelTransferSession); CFRelease(_pixelTransferSession); } }
@end

@implementation AVStreamManager
+ (instancetype)sharedManager {
    static AVStreamManager *mgr = nil; static dispatch_once_t once;
    dispatch_once(&once, ^{ 
        mgr = [[AVStreamManager alloc] init]; mgr.isEnabled = YES; mgr.isHUDVisible = NO; mgr.currentSlot = 1; mgr.displayLayers = [NSHashTable weakObjectsHashTable]; mgr.processor = [[AVStreamCoreProcessor alloc] init]; 
        [mgr.processor loadVideoForCurrentSlot:mgr.currentSlot]; // 🌟 安全加载
    });
    return mgr;
}
- (void)updateDisplayLayers {
    BOOL shouldHide = (!self.isHUDVisible || !self.isEnabled);
    dispatch_async(dispatch_get_main_queue(), ^{ @synchronized (self.displayLayers) { for (AVSampleBufferDisplayLayer *layer in self.displayLayers.allObjects) { layer.hidden = shouldHide; if (shouldHide) [layer flush]; } } });
}
- (void)handleTwoFingerLongPress:(UIGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateRecognized || gesture.state == UIGestureRecognizerStateBegan) { 
        self.isHUDVisible = YES; [AVCaptureHUDWindow sharedHUD].hidden = NO; [self updateDisplayLayers]; 
        UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium]; [feedback impactOccurred]; 
    }
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer { return YES; }
@end

// ============================================================================
// 【4. 隐形环境伪装代理 (修复野指针)】
// ============================================================================
@interface AVCameraSessionProxy : NSProxy <AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureDataOutputSynchronizerDelegate, AVCaptureMetadataOutputObjectsDelegate, CLLocationManagerDelegate>
@property (nonatomic, weak) id target;
+ (instancetype)proxyWithTarget:(id)target;
@end
@implementation AVCameraSessionProxy
+ (instancetype)proxyWithTarget:(id)target { AVCameraSessionProxy *proxy = [AVCameraSessionProxy alloc]; proxy.target = target; return proxy; }
- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel { return [self.target methodSignatureForSelector:sel]; }
- (void)forwardInvocation:(NSInvocation *)invocation { 
    if (self.target && [self.target respondsToSelector:invocation.selector]) { [invocation invokeWithTarget:self.target]; }
    else { void *nullPointer = NULL; [invocation setReturnValue:&nullPointer]; }
}
- (BOOL)respondsToSelector:(SEL)aSelector {
    if (aSelector == @selector(captureOutput:didOutputSampleBuffer:fromConnection:) || aSelector == @selector(dataOutputSynchronizer:didOutputSynchronizedDataCollection:) || aSelector == @selector(captureOutput:didOutputMetadataObjects:fromConnection:) || aSelector == @selector(locationManager:didUpdateLocations:)) return YES;
    return [self.target respondsToSelector:aSelector];
}
- (Class)class { return [self.target class]; }
- (Class)superclass { return [self.target superclass]; }
- (BOOL)isKindOfClass:(Class)aClass { return [self.target isKindOfClass:aClass]; }
- (BOOL)conformsToProtocol:(Protocol *)aProtocol { return [self.target conformsToProtocol:aProtocol]; }

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    @autoreleasepool { [[AVStreamManager sharedManager].processor processSampleBuffer:sampleBuffer]; if ([self.target respondsToSelector:_cmd]) [self.target captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection]; }
}
- (void)dataOutputSynchronizer:(AVCaptureDataOutputSynchronizer *)synchronizer didOutputSynchronizedDataCollection:(AVCaptureSynchronizedDataCollection *)synchronizedDataCollection {
    @autoreleasepool {
        for (AVCaptureOutput *out in synchronizer.dataOutputs) {
            if ([out isKindOfClass:NSClassFromString(@"AVCaptureVideoDataOutput")]) { AVCaptureSynchronizedData *syncData = [synchronizedDataCollection synchronizedDataForCaptureOutput:out]; if ([syncData respondsToSelector:@selector(sampleBuffer)]) { CMSampleBufferRef sbuf = ((CMSampleBufferRef (*)(id, SEL))objc_msgSend)(syncData, @selector(sampleBuffer)); if (sbuf) [[AVStreamManager sharedManager].processor processSampleBuffer:sbuf]; } } 
            else if ([out isKindOfClass:NSClassFromString(@"AVCaptureDepthDataOutput")] && [AVStreamManager sharedManager].isEnabled) { AVCaptureSynchronizedData *syncData = [synchronizedDataCollection synchronizedDataForCaptureOutput:out]; if ([syncData respondsToSelector:@selector(depthData)]) { AVDepthData *depthData = ((AVDepthData *(*)(id, SEL))objc_msgSend)(syncData, @selector(depthData)); [[AVStreamManager sharedManager].processor processDepthBuffer:depthData]; } }
        }
        if ([self.target respondsToSelector:_cmd]) [self.target dataOutputSynchronizer:synchronizer didOutputSynchronizedDataCollection:synchronizedDataCollection];
    }
}
- (void)captureOutput:(AVCaptureOutput *)output didOutputMetadataObjects:(NSArray *)metadataObjects fromConnection:(AVCaptureConnection *)connection {
    @autoreleasepool { NSMutableArray *filtered = [NSMutableArray arrayWithCapacity:metadataObjects.count]; BOOL shouldFilter = ([AVStreamManager sharedManager].isEnabled && [AVStreamManager sharedManager].isHUDVisible); for (AVMetadataObject *obj in metadataObjects) { if (shouldFilter && [obj.type isEqualToString:AVMetadataObjectTypeFace]) continue; [filtered addObject:obj]; } if ([self.target respondsToSelector:_cmd]) [self.target captureOutput:output didOutputMetadataObjects:filtered fromConnection:connection]; }
}
- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locations {
    if (g_envSpoofingEnabled && locations.count > 0) {
        double jitterLat = (arc4random_uniform(100) - 50) / 1000000.0;
        double jitterLon = (arc4random_uniform(100) - 50) / 1000000.0;
        double jitterAlt = (arc4random_uniform(100) - 50) / 10.0;
        CLLocationCoordinate2D c = CLLocationCoordinate2DMake(g_fakeLat + jitterLat, g_fakeLon + jitterLon);
        CLLocation *fakeLoc = [[CLLocation alloc] initWithCoordinate:c altitude:(120.0 + jitterAlt) horizontalAccuracy:5.0 verticalAccuracy:5.0 timestamp:[NSDate date]];
        if ([self.target respondsToSelector:_cmd]) [self.target locationManager:manager didUpdateLocations:@[fakeLoc]];
    } else {
        if ([self.target respondsToSelector:_cmd]) [self.target locationManager:manager didUpdateLocations:locations];
    }
}
@end

// ============================================================================
// 【5. HUD 控制面板 (视频渲染)】
// ============================================================================
@implementation AVCaptureHUDWindow { 
    UILabel *_statusLabel; UISwitch *_powerSwitch; NSInteger _pendingSlot; AVSampleBufferDisplayLayer *_previewLayer; 
    UISwitch *_colorSwitch; UISlider *_brightSlider; UISlider *_contrastSlider; UISlider *_saturationSlider;
}
+ (instancetype)sharedHUD {
    static AVCaptureHUDWindow *hud = nil; static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (@available(iOS 13.0, *)) { for (UIWindowScene *scene in (NSArray<UIWindowScene *>*)[UIApplication sharedApplication].connectedScenes) { if (scene.activationState == UISceneActivationStateForegroundActive) { hud = [[AVCaptureHUDWindow alloc] initWithWindowScene:scene]; hud.frame = CGRectMake(20, 80, 290, 440); break; } } }
        if (!hud) hud = [[AVCaptureHUDWindow alloc] initWithFrame:CGRectMake(20, 80, 290, 440)];
    }); return hud;
}
- (instancetype)initWithFrame:(CGRect)frame { if (self = [super initWithFrame:frame]) { [self commonInit]; } return self; }
- (instancetype)initWithWindowScene:(UIWindowScene *)windowScene { if (self = [super initWithWindowScene:windowScene]) { [self commonInit]; } return self; }
- (void)commonInit {
    self.windowLevel = UIWindowLevelStatusBar + 100; self.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.85]; self.layer.cornerRadius = 16; self.layer.masksToBounds = YES; self.hidden = YES; 
    [self setupUI]; UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)]; [self addGestureRecognizer:pan];
}
- (void)setupUI {
    _statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 12, 180, 20)]; _statusLabel.textColor = [UIColor greenColor]; _statusLabel.font = [UIFont boldSystemFontOfSize:14]; _statusLabel.text = @"🟢 V-Cam [CH 1]"; [self addSubview:_statusLabel];
    _powerSwitch = [[UISwitch alloc] init]; _powerSwitch.transform = CGAffineTransformMakeScale(0.8, 0.8); _powerSwitch.frame = CGRectMake(230, 7, 50, 31); _powerSwitch.on = YES; [_powerSwitch addTarget:self action:@selector(togglePower:) forControlEvents:UIControlEventValueChanged]; [self addSubview:_powerSwitch];
    CGFloat btnWidth = 40, btnHeight = 38, gap = 8;
    for (int i = 0; i < 4; i++) {
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem]; btn.frame = CGRectMake(12 + i * (btnWidth + gap), 42, btnWidth, btnHeight); btn.backgroundColor = [UIColor colorWithWhite:0.3 alpha:1.0]; btn.layer.cornerRadius = 8; [btn setTitle:[NSString stringWithFormat:@"%d", i+1] forState:UIControlStateNormal]; [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal]; btn.titleLabel.font = [UIFont boldSystemFontOfSize:16]; btn.tag = i + 1;
        [btn addTarget:self action:@selector(channelSwitched:) forControlEvents:UIControlEventTouchUpInside]; UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)]; [btn addGestureRecognizer:lp]; [self addSubview:btn];
    }
    UIButton *clearBtn = [UIButton buttonWithType:UIButtonTypeSystem]; clearBtn.frame = CGRectMake(12 + 4 * (btnWidth + gap), 42, 60, btnHeight); clearBtn.backgroundColor = [UIColor colorWithRed:0.8 green:0.2 blue:0.2 alpha:1.0]; clearBtn.layer.cornerRadius = 8; [clearBtn setTitle:@"隐藏" forState:UIControlStateNormal]; [clearBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal]; clearBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14]; [clearBtn addTarget:self action:@selector(hideHUD) forControlEvents:UIControlEventTouchUpInside]; [self addSubview:clearBtn];
    
    _previewLayer = [[AVSampleBufferDisplayLayer alloc] init]; _previewLayer.frame = CGRectMake(12, 90, 266, 150); _previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill; _previewLayer.backgroundColor = [UIColor blackColor].CGColor; _previewLayer.cornerRadius = 8; _previewLayer.masksToBounds = YES; [self.layer addSublayer:_previewLayer]; [[AVStreamManager sharedManager].displayLayers addObject:_previewLayer];
    
    UILabel *colorLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 250, 150, 20)]; colorLabel.text = @"🎨 导入重编码与去重"; colorLabel.textColor = [UIColor whiteColor]; colorLabel.font = [UIFont boldSystemFontOfSize:14]; [self addSubview:colorLabel];
    _colorSwitch = [[UISwitch alloc] init]; _colorSwitch.transform = CGAffineTransformMakeScale(0.7, 0.7); _colorSwitch.frame = CGRectMake(235, 245, 50, 31); _colorSwitch.on = NO; [self addSubview:_colorSwitch];
    
    UILabel *bLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 280, 40, 20)]; bLabel.text = @"亮度"; bLabel.textColor = [UIColor lightGrayColor]; bLabel.font = [UIFont systemFontOfSize:12]; [self addSubview:bLabel];
    _brightSlider = [[UISlider alloc] initWithFrame:CGRectMake(50, 280, 220, 20)]; _brightSlider.minimumValue = -0.2; _brightSlider.maximumValue = 0.2; _brightSlider.value = 0.0; [self addSubview:_brightSlider];
    
    UILabel *cLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 320, 40, 20)]; cLabel.text = @"对比"; cLabel.textColor = [UIColor lightGrayColor]; cLabel.font = [UIFont systemFontOfSize:12]; [self addSubview:cLabel];
    _contrastSlider = [[UISlider alloc] initWithFrame:CGRectMake(50, 320, 220, 20)]; _contrastSlider.minimumValue = 0.5; _contrastSlider.maximumValue = 1.5; _contrastSlider.value = 1.0; [self addSubview:_contrastSlider];
    
    UILabel *sLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 360, 40, 20)]; sLabel.text = @"饱和"; sLabel.textColor = [UIColor lightGrayColor]; sLabel.font = [UIFont systemFontOfSize:12]; [self addSubview:sLabel];
    _saturationSlider = [[UISlider alloc] initWithFrame:CGRectMake(50, 360, 220, 20)]; _saturationSlider.minimumValue = 0.0; _saturationSlider.maximumValue = 2.0; _saturationSlider.value = 1.0; [self addSubview:_saturationSlider];
}
- (void)hideHUD { self.hidden = YES; [AVStreamManager sharedManager].isHUDVisible = NO; [[AVStreamManager sharedManager] updateDisplayLayers]; UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight]; [feedback impactOccurred]; }
- (void)togglePower:(UISwitch *)sender { [AVStreamManager sharedManager].isEnabled = sender.isOn; [[AVStreamManager sharedManager] updateDisplayLayers]; if (sender.isOn) { _statusLabel.text = [NSString stringWithFormat:@"🟢 V-Cam [CH %ld]", (long)[AVStreamManager sharedManager].currentSlot]; _statusLabel.textColor = [UIColor greenColor]; } else { _statusLabel.text = @"🔴 已禁用"; _statusLabel.textColor = [UIColor redColor]; } UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight]; [feedback impactOccurred]; }
- (void)handlePan:(UIPanGestureRecognizer *)pan { CGPoint trans = [pan translationInView:self]; self.center = CGPointMake(self.center.x + trans.x, self.center.y + trans.y); [pan setTranslation:CGPointZero inView:self]; }
- (void)channelSwitched:(UIButton *)sender { [AVStreamManager sharedManager].currentSlot = sender.tag; if (_powerSwitch.isOn) { _statusLabel.text = [NSString stringWithFormat:@"🟢 V-Cam [CH %ld]", (long)sender.tag]; } [[NSNotificationCenter defaultCenter] postNotificationName:@"AVSChannelDidChangeNotification" object:nil]; UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium]; [feedback impactOccurred]; }
- (void)handleLongPress:(UILongPressGestureRecognizer *)lp { 
    if (lp.state == UIGestureRecognizerStateBegan) { 
        _pendingSlot = lp.view.tag; UIImagePickerController *picker = [[UIImagePickerController alloc] init]; picker.delegate = self; picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary; picker.mediaTypes = @[@"public.movie"]; picker.videoExportPreset = AVAssetExportPresetPassthrough; 
        UIWindow *foundWindow = nil; 
        if (@available(iOS 13.0, *)) { for (UIWindowScene *scene in (NSArray<UIWindowScene *>*)[UIApplication sharedApplication].connectedScenes) { if (scene.activationState == UISceneActivationStateForegroundActive) { for (UIWindow *window in scene.windows) { if (window.isKeyWindow || window.windowLevel == UIWindowLevelNormal) { foundWindow = window; break; } } } if (foundWindow) break; } } 
        UIViewController *root = foundWindow.rootViewController; while (root.presentedViewController) root = root.presentedViewController; 
        if (root) [root presentViewController:picker animated:YES completion:nil]; 
    } 
}
- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary *)info { 
    NSURL *url = info[UIImagePickerControllerMediaURL]; 
    if (url) { 
        NSString *dest = [[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject] stringByAppendingPathComponent:[NSString stringWithFormat:@"test%ld.mp4", (long)self->_pendingSlot]]; 
        [[NSFileManager defaultManager] removeItemAtPath:dest error:nil]; 
        if (_colorSwitch.isOn) {
            self->_statusLabel.text = @"⏳ 滤镜去重渲染中..."; self->_statusLabel.textColor = [UIColor orangeColor];
            CGFloat bVal = _brightSlider.value; CGFloat cVal = _contrastSlider.value; CGFloat sVal = _saturationSlider.value;
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{ 
                [AVStreamPreprocessor processVideoAtURL:url toDestination:dest brightness:bVal contrast:cVal saturation:sVal completion:^(BOOL success, NSError *error) {
                    dispatch_async(dispatch_get_main_queue(), ^{ 
                        if (success) { if ([AVStreamManager sharedManager].currentSlot == self->_pendingSlot) [[NSNotificationCenter defaultCenter] postNotificationName:@"AVSChannelDidChangeNotification" object:nil]; 
                            self->_statusLabel.text = [NSString stringWithFormat:@"🟢 V-Cam [CH %ld]", (long)[AVStreamManager sharedManager].currentSlot]; self->_statusLabel.textColor = [UIColor greenColor];
                        } else { self->_statusLabel.text = @"❌ 去重渲染失败"; self->_statusLabel.textColor = [UIColor redColor]; } 
                    });
                }];
            }); 
        } else {
            self->_statusLabel.text = @"⚡️ 极速载入..."; 
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{ 
                BOOL success = [[NSFileManager defaultManager] copyItemAtURL:url toURL:[NSURL fileURLWithPath:dest] error:nil]; 
                dispatch_async(dispatch_get_main_queue(), ^{ 
                    if (success) { if ([AVStreamManager sharedManager].currentSlot == self->_pendingSlot) [[NSNotificationCenter defaultCenter] postNotificationName:@"AVSChannelDidChangeNotification" object:nil]; 
                        self->_statusLabel.text = [NSString stringWithFormat:@"🟢 V-Cam [CH %ld]", (long)[AVStreamManager sharedManager].currentSlot]; 
                    } else { self->_statusLabel.text = @"❌ 极速导入失败"; } 
                }); 
            });
        }
    } 
    [picker dismissViewControllerAnimated:YES completion:nil]; 
}
@end


// ============================================================================
// 【6. 环境配置窗口 - 终极触控防拦截与修复版】
// ============================================================================
@implementation AVCaptureMapWindow { 
    MKMapView *_mapView; UILabel *_infoLabel; UISwitch *_envSwitch; 
    double _pendingLat; double _pendingLon;
    NSString *_pMCC; NSString *_pMNC; NSString *_pCarrier; NSString *_pTZ; NSString *_pLocale;
}

+ (instancetype)sharedMap {
    static AVCaptureMapWindow *map = nil; static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = [[AVCaptureMapWindow alloc] initWithFrame:CGRectMake(10, 100, 310, 480)];
    }); 
    return map;
}

- (instancetype)initWithFrame:(CGRect)f { 
    if (self = [super initWithFrame:f]) {
        self.windowLevel = UIWindowLevelStatusBar + 110;
        self.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.98];
        self.layer.cornerRadius = 16;
        self.layer.masksToBounds = YES;
        self.hidden = YES;
        self.userInteractionEnabled = YES; 

        UIViewController *root = [[UIViewController alloc] init];
        root.view.frame = self.bounds;
        root.view.userInteractionEnabled = YES;
        self.rootViewController = root;

        [self setupUI];
        
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        pan.delegate = self; 
        [self addGestureRecognizer:pan];
    }
    return self;
}

- (BOOL)canBecomeKeyWindow { return YES; }

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hitView = [super hitTest:point withEvent:event];
    if (hitView) return hitView;
    return nil;
}

- (void)showMapSecurely {
    if (@available(iOS 13.0, *)) {
        if (!self.windowScene) {
            for (UIWindowScene *s in (NSArray *)[UIApplication sharedApplication].connectedScenes) {
                if (s.activationState == UISceneActivationStateForegroundActive) {
                    self.windowScene = s;
                    break;
                }
            }
        }
    }
    self.hidden = NO;
    [self makeKeyAndVisible];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    if ([touch.view isDescendantOfView:_mapView] || 
        [touch.view isKindOfClass:[UIButton class]] || 
        [touch.view isKindOfClass:[UISwitch class]]) {
        return NO; 
    }
    return YES;
}

- (void)setupUI {
    UIView *container = self.rootViewController.view;
    _pendingLat = g_fakeLat; _pendingLon = g_fakeLon;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(15, 15, 200, 20)];
    title.text = @"🌍 环境伪装配置"; title.textColor = [UIColor whiteColor]; title.font = [UIFont boldSystemFontOfSize:16];
    [container addSubview:title];
    
    _envSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(245, 10, 50, 30)];
    _envSwitch.on = g_envSpoofingEnabled;
    [container addSubview:_envSwitch];
    
    _mapView = [[MKMapView alloc] initWithFrame:CGRectMake(12, 50, 286, 250)];
    _mapView.layer.cornerRadius = 8; _mapView.delegate = self;
    _mapView.userInteractionEnabled = YES;
    
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(dropPin:)];
    lp.minimumPressDuration = 0.5; 
    [_mapView addGestureRecognizer:lp];
    [container addSubview:_mapView];
    
    _infoLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 310, 286, 60)];
    _infoLabel.numberOfLines = 3; _infoLabel.textColor = [UIColor greenColor]; _infoLabel.font = [UIFont systemFontOfSize:11]; _infoLabel.textAlignment = NSTextAlignmentCenter;
    [self updateLabel];
    [container addSubview:_infoLabel];
    
    UIButton *save = [UIButton buttonWithType:UIButtonTypeSystem];
    save.frame = CGRectMake(12, 385, 286, 44);
    save.backgroundColor = [UIColor colorWithRed:0.2 green:0.6 blue:1.0 alpha:1.0];
    save.layer.cornerRadius = 8;
    [save setTitle:@"保存配置并关闭" forState:UIControlStateNormal];
    [save setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [save addTarget:self action:@selector(saveAndClose) forControlEvents:UIControlEventTouchUpInside];
    [container addSubview:save];

    CLLocationCoordinate2D coord = CLLocationCoordinate2DMake(_pendingLat ?: 50.11, _pendingLon ?: 8.68);
    [_mapView setRegion:MKCoordinateRegionMake(coord, MKCoordinateSpanMake(5, 5)) animated:NO];
}

- (void)updateLabel {
    _infoLabel.text = [NSString stringWithFormat:@"坐标: %.4f, %.4f\n运营商: %@ (%@-%@)\n时区: %@", _pendingLat, _pendingLon, _pCarrier?:@"-", _pMCC?:@"-", _pMNC?:@"-", _pTZ?:@"-"];
}

- (void)dropPin:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    CGPoint p = [g locationInView:_mapView];
    CLLocationCoordinate2D c = [_mapView convertPoint:p toCoordinateFromView:_mapView];
    [_mapView removeAnnotations:_mapView.annotations];
    MKPointAnnotation *ann = [[MKPointAnnotation alloc] init]; ann.coordinate = c; [_mapView addAnnotation:ann];
    _pendingLat = c.latitude; _pendingLon = c.longitude;
    
    CLGeocoder *geo = [[CLGeocoder alloc] init];
    [geo reverseGeocodeLocation:[[CLLocation alloc] initWithLatitude:c.latitude longitude:c.longitude] completionHandler:^(NSArray *pls, NSError *err) {
        if (pls.count > 0) {
            CLPlacemark *pl = pls.firstObject;
            NSString *cc = pl.ISOcountryCode.lowercaseString;
            self->_pMCC = @"262"; self->_pMNC = @"01"; self->_pCarrier = @"Telekom.de"; self->_pTZ = @"Europe/Berlin"; self->_pLocale = @"de_DE";
            if ([cc isEqualToString:@"us"]) { self->_pMCC = @"310"; self->_pMNC = @"410"; self->_pCarrier = @"AT&T"; self->_pTZ = @"America/New_York"; self->_pLocale = @"en_US"; }
            else if ([cc isEqualToString:@"fr"]) { self->_pMCC = @"208"; self->_pMNC = @"01"; self->_pCarrier = @"Orange F"; self->_pTZ = @"Europe/Paris"; self->_pLocale = @"fr_FR"; }
            else if ([cc isEqualToString:@"it"]) { self->_pMCC = @"222"; self->_pMNC = @"01"; self->_pCarrier = @"TIM"; self->_pTZ = @"Europe/Rome"; self->_pLocale = @"it_IT"; }
            dispatch_async(dispatch_get_main_queue(), ^{ 
                [self updateLabel]; 
                UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleHeavy];
                [feedback impactOccurred]; 
            });
        }
    }];
}

- (void)saveAndClose {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setBool:_envSwitch.on forKey:@"avs_env_enabled"];
    [ud setDouble:_pendingLat forKey:@"avs_env_lat"];
    [ud setDouble:_pendingLon forKey:@"avs_env_lon"];
    if (_pMCC) [ud setObject:_pMCC forKey:@"avs_env_mcc"];
    if (_pMNC) [ud setObject:_pMNC forKey:@"avs_env_mnc"];
    if (_pCarrier) [ud setObject:_pCarrier forKey:@"avs_env_carrier"];
    if (_pTZ) [ud setObject:_pTZ forKey:@"avs_env_tz"];
    if (_pLocale) [ud setObject:_pLocale forKey:@"avs_env_locale"];
    [ud synchronize];
    
    [self makeKeyWindow];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"保存成功" message:@"请彻底上滑划掉 App 并重新打开，使底层伪装生效。" preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(id x){ self.hidden = YES; }]];
    [self.rootViewController presentViewController:a animated:YES completion:nil];
}

- (void)handlePan:(UIPanGestureRecognizer *)p { 
    CGPoint t = [p translationInView:self]; 
    self.center = CGPointMake(self.center.x+t.x, self.center.y+t.y); 
    [p setTranslation:CGPointZero inView:self]; 
}
@end

// ============================================================================
// 【提前声明所有系统接口，杜绝严苛编译器的拦截报错 (找回丢失的接口)】
// ============================================================================
@interface CTCarrier (AVStreamHook)
- (NSString *)avs_carrierName;
- (NSString *)avs_isoCountryCode;
- (NSString *)avs_mobileCountryCode;
- (NSString *)avs_mobileNetworkCode;
@end

@interface CTTelephonyNetworkInfo (AVStreamHook)
- (NSDictionary<NSString *,CTCarrier *> *)avs_serviceSubscriberCellularProviders;
@end

@interface CLLocationManager (AVStreamHook)
- (CLLocation *)avs_location;
- (void)avs_setDelegate:(id<CLLocationManagerDelegate>)delegate;
@end

@interface NSTimeZone (AVStreamHook)
+ (NSTimeZone *)avs_systemTimeZone;
+ (NSTimeZone *)avs_defaultTimeZone;
@end

@interface NSLocale (AVStreamHook)
+ (NSLocale *)avs_currentLocale;
+ (NSArray<NSString *> *)avs_preferredLanguages;
@end

@interface UIWindow (AVStreamHook)
- (void)avs_becomeKeyWindow;
- (void)avs_makeKeyAndVisible;
- (void)avs_setupGestures;
@end

@interface AVCaptureVideoDataOutput (AVStreamHook)
- (void)avs_setSampleBufferDelegate:(id)delegate queue:(dispatch_queue_t)queue;
@end

@interface AVCaptureDataOutputSynchronizer (AVStreamHook)
- (void)avs_setDelegate:(id)delegate queue:(dispatch_queue_t)queue;
@end

@interface AVCaptureMetadataOutput (AVStreamHook)
- (void)avs_setMetadataObjectsDelegate:(id)delegate queue:(dispatch_queue_t)queue;
@end

// ============================================================================
// 【7. 系统底层 Hook 实现】
// ============================================================================
@implementation CTCarrier (AVStreamHook)
- (NSString *)avs_carrierName { return g_envSpoofingEnabled && g_fakeCarrierName ? g_fakeCarrierName : [self avs_carrierName]; }
- (NSString *)avs_isoCountryCode { return g_envSpoofingEnabled && g_fakeISO ? g_fakeISO : [self avs_isoCountryCode]; }
- (NSString *)avs_mobileCountryCode { return g_envSpoofingEnabled && g_fakeMCC ? g_fakeMCC : [self avs_mobileCountryCode]; }
- (NSString *)avs_mobileNetworkCode { return g_envSpoofingEnabled && g_fakeMNC ? g_fakeMNC : [self avs_mobileNetworkCode]; }
@end

@implementation CTTelephonyNetworkInfo (AVStreamHook)
- (NSDictionary<NSString *,CTCarrier *> *)avs_serviceSubscriberCellularProviders {
    if (!g_envSpoofingEnabled) return [self avs_serviceSubscriberCellularProviders];
    CTCarrier *fakeCarrier = [[NSClassFromString(@"CTCarrier") alloc] init];
    return @{@"0000000100000001": fakeCarrier};
}
@end

@implementation CLLocationManager (AVStreamHook)
- (CLLocation *)avs_location {
    if (g_envSpoofingEnabled) { 
        double jitterLat = (arc4random_uniform(100) - 50) / 1000000.0;
        double jitterLon = (arc4random_uniform(100) - 50) / 1000000.0;
        double jitterAlt = (arc4random_uniform(100) - 50) / 10.0;
        CLLocationCoordinate2D c = CLLocationCoordinate2DMake(g_fakeLat + jitterLat, g_fakeLon + jitterLon);
        return [[CLLocation alloc] initWithCoordinate:c altitude:(120.0 + jitterAlt) horizontalAccuracy:5.0 verticalAccuracy:5.0 timestamp:[NSDate date]]; 
    }
    return [self avs_location];
}
- (void)avs_setDelegate:(id<CLLocationManagerDelegate>)delegate {
    if (delegate && ![delegate isKindOfClass:NSClassFromString(@"AVCameraSessionProxy")]) { 
        AVCameraSessionProxy *proxy = [AVCameraSessionProxy proxyWithTarget:delegate]; 
        objc_setAssociatedObject(self, "_avs_loc_p", proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC); 
        [self avs_setDelegate:(id<CLLocationManagerDelegate>)proxy];
    } else { [self avs_setDelegate:delegate]; }
}
@end

@implementation NSTimeZone (AVStreamHook)
+ (NSTimeZone *)avs_systemTimeZone {
    if (g_envSpoofingEnabled && g_fakeTZ) { NSTimeZone *tz = [NSTimeZone timeZoneWithName:g_fakeTZ]; if (tz) return tz; }
    return [self avs_systemTimeZone];
}
+ (NSTimeZone *)avs_defaultTimeZone {
    if (g_envSpoofingEnabled && g_fakeTZ) { NSTimeZone *tz = [NSTimeZone timeZoneWithName:g_fakeTZ]; if (tz) return tz; }
    return [self avs_defaultTimeZone];
}
@end

@implementation NSLocale (AVStreamHook)
+ (NSLocale *)avs_currentLocale {
    if (g_envSpoofingEnabled && g_fakeLocale) { return [NSLocale localeWithLocaleIdentifier:g_fakeLocale]; }
    return [self avs_currentLocale];
}
+ (NSArray<NSString *> *)avs_preferredLanguages {
    if (g_envSpoofingEnabled && g_fakeLocale) { return @[g_fakeLocale, @"en-US"]; }
    return [self avs_preferredLanguages];
}
@end

@implementation UIWindow (AVStreamHook)
- (void)avs_setupGestures {
    if (![self isKindOfClass:NSClassFromString(@"AVCaptureHUDWindow")] && ![self isKindOfClass:NSClassFromString(@"AVCaptureMapWindow")] && !objc_getAssociatedObject(self, "_avs_g")) {
        
        UITapGestureRecognizer *videoTap = [[UITapGestureRecognizer alloc] initWithTarget:[AVStreamManager sharedManager] action:@selector(handleTwoFingerLongPress:)];
        videoTap.numberOfTouchesRequired = 3; 
        videoTap.numberOfTapsRequired = 1;
        videoTap.cancelsTouchesInView = NO;
        videoTap.delaysTouchesBegan = NO;
        videoTap.delegate = [AVStreamManager sharedManager]; 
        [self addGestureRecognizer:videoTap];
        
        UITapGestureRecognizer *mapTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(showMapPanel:)];
        mapTap.numberOfTouchesRequired = 4;
        mapTap.numberOfTapsRequired = 1;
        mapTap.cancelsTouchesInView = NO;
        mapTap.delaysTouchesBegan = NO;
        mapTap.delegate = [AVStreamManager sharedManager]; 
        [self addGestureRecognizer:mapTap];
        
        objc_setAssociatedObject(self, "_avs_g", @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

- (void)avs_becomeKeyWindow {
    [self avs_becomeKeyWindow];
    [self avs_setupGestures];
}

- (void)avs_makeKeyAndVisible {
    [self avs_makeKeyAndVisible];
    [self avs_setupGestures];
}

- (void)showMapPanel:(UIGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateEnded || gesture.state == UIGestureRecognizerStateRecognized) { 
        // 🌟 核心：使用安全弹出机制
        [[AVCaptureMapWindow sharedMap] showMapSecurely];
        UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleHeavy]; 
        [feedback impactOccurred]; 
    }
}
@end

// 🌟 修复：找回用于 TikTok 高级同步流的 Hook
@implementation AVCaptureVideoDataOutput (AVStreamHook)
- (void)avs_setSampleBufferDelegate:(id)delegate queue:(dispatch_queue_t)queue {
    if (delegate && ![delegate isKindOfClass:NSClassFromString(@"AVCameraSessionProxy")]) { 
        AVCameraSessionProxy *proxy = [AVCameraSessionProxy proxyWithTarget:delegate]; 
        objc_setAssociatedObject(self, "_avs_p", proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC); 
        [self avs_setSampleBufferDelegate:proxy queue:queue];
    } else { [self avs_setSampleBufferDelegate:delegate queue:queue]; }
}
@end
@implementation AVCaptureDataOutputSynchronizer (AVStreamHook)
- (void)avs_setDelegate:(id)delegate queue:(dispatch_queue_t)queue {
    if (delegate && ![delegate isKindOfClass:NSClassFromString(@"AVCameraSessionProxy")]) { 
        AVCameraSessionProxy *proxy = [AVCameraSessionProxy proxyWithTarget:delegate]; 
        objc_setAssociatedObject(self, "_avs_p", proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC); 
        [self avs_setDelegate:proxy queue:queue];
    } else { [self avs_setDelegate:delegate queue:queue]; }
}
@end
@implementation AVCaptureMetadataOutput (AVStreamHook)
- (void)avs_setMetadataObjectsDelegate:(id)delegate queue:(dispatch_queue_t)queue {
    if (delegate && ![delegate isKindOfClass:NSClassFromString(@"AVCameraSessionProxy")]) { 
        AVCameraSessionProxy *proxy = [AVCameraSessionProxy proxyWithTarget:delegate]; 
        objc_setAssociatedObject(self, "_avs_p", proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC); 
        [self avs_setMetadataObjectsDelegate:proxy queue:queue];
    } else { [self avs_setMetadataObjectsDelegate:delegate queue:queue]; }
}
@end

// ============================================================================
// 【8. 加载入口 (找回丢失的全部 Hook 交换)】
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
    } else {
        g_envSpoofingEnabled = NO;
    }

    method_exchangeImplementations(class_getInstanceMethod([UIWindow class], @selector(becomeKeyWindow)), class_getInstanceMethod([UIWindow class], @selector(avs_becomeKeyWindow)));
    method_exchangeImplementations(class_getInstanceMethod([UIWindow class], @selector(makeKeyAndVisible)), class_getInstanceMethod([UIWindow class], @selector(avs_makeKeyAndVisible)));
    
    Class vdoClass = NSClassFromString(@"AVCaptureVideoDataOutput"); if (vdoClass) method_exchangeImplementations(class_getInstanceMethod(vdoClass, @selector(setSampleBufferDelegate:queue:)), class_getInstanceMethod(vdoClass, @selector(avs_setSampleBufferDelegate:queue:)));
    Class syncClass = NSClassFromString(@"AVCaptureDataOutputSynchronizer"); if (syncClass) method_exchangeImplementations(class_getInstanceMethod(syncClass, @selector(setDelegate:queue:)), class_getInstanceMethod(syncClass, @selector(avs_setDelegate:queue:)));
    Class metaClass = NSClassFromString(@"AVCaptureMetadataOutput"); if (metaClass) method_exchangeImplementations(class_getInstanceMethod(metaClass, @selector(setMetadataObjectsDelegate:queue:)), class_getInstanceMethod(metaClass, @selector(avs_setMetadataObjectsDelegate:queue:)));
    
    Class locClass = NSClassFromString(@"CLLocationManager"); 
    if (locClass) {
        method_exchangeImplementations(class_getInstanceMethod(locClass, @selector(setDelegate:)), class_getInstanceMethod(locClass, @selector(avs_setDelegate:)));
        method_exchangeImplementations(class_getInstanceMethod(locClass, @selector(location)), class_getInstanceMethod(locClass, @selector(avs_location)));
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
    }
    Class loclClass = NSClassFromString(@"NSLocale");
    if (loclClass) {
        method_exchangeImplementations(class_getClassMethod(loclClass, @selector(currentLocale)), class_getClassMethod(loclClass, @selector(avs_currentLocale)));
        method_exchangeImplementations(class_getClassMethod(loclClass, @selector(preferredLanguages)), class_getClassMethod(loclClass, @selector(avs_preferredLanguages)));
    }
}
@end
#pragma clang diagnostic pop
