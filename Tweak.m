#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreImage/CoreImage.h>
#import <objc/runtime.h>
#import <dlfcn.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
#pragma clang diagnostic ignored "-Wavailability"

// ============================================================================
// 【1. 全局声明与去重引擎】
// ============================================================================
@class VCAMHUDWindow;
@class VCAMCoreProcessor;

@interface VCAMManager : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)sharedManager;
@property (nonatomic, assign) BOOL isEnabled;
@property (nonatomic, assign) BOOL isHUDVisible; 
@property (nonatomic, assign) NSInteger currentSlot;
@property (nonatomic, strong) NSHashTable *displayLayers;
@property (nonatomic, strong) VCAMCoreProcessor *processor;
- (void)updateDisplayLayers;
@end

@interface VCAMHUDWindow : UIWindow <UIImagePickerControllerDelegate, UINavigationControllerDelegate>
+ (instancetype)sharedHUD;
@end

@interface VCAMVideoPreprocessor : NSObject
+ (void)processVideoAtURL:(NSURL *)sourceURL toDestination:(NSString *)destPath brightness:(CGFloat)brightness contrast:(CGFloat)contrast saturation:(CGFloat)saturation completion:(void(^)(BOOL success, NSError *error))completion;
@end

@implementation VCAMVideoPreprocessor
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
    exportSession.metadata = @[]; // 抹除硬件元数据

    [exportSession exportAsynchronouslyWithCompletionHandler:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            if (exportSession.status == AVAssetExportSessionStatusCompleted) { if (completion) completion(YES, nil); } 
            else { if (completion) completion(NO, exportSession.error); }
        });
    }];
}
@end

// ============================================================================
// 【2. 极致安全底层推流引擎】
// ============================================================================
@interface VCAMDecoder : NSObject
- (instancetype)initWithVideoPath:(NSString *)path;
- (CVPixelBufferRef)copyNextPixelBuffer;
@end

@implementation VCAMDecoder {
    AVAssetReader *_assetReader; AVAssetReaderOutput *_trackOutput; NSString *_videoPath;
}
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
    if (videoComp) {
        AVAssetReaderVideoCompositionOutput *compOut = [AVAssetReaderVideoCompositionOutput assetReaderVideoCompositionOutputWithVideoTracks:@[videoTrack] videoSettings:settings];
        compOut.videoComposition = videoComp; _trackOutput = (AVAssetReaderOutput *)compOut;
    } else { _trackOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:videoTrack outputSettings:settings]; }
    if ([_assetReader canAddOutput:_trackOutput]) { [_assetReader addOutput:_trackOutput]; [_assetReader startReading]; }
}
- (CVPixelBufferRef)copyNextPixelBuffer {
    if (!_assetReader) return NULL;
    if (_assetReader.status == AVAssetReaderStatusCompleted) [self setupReader];
    if (_assetReader.status == AVAssetReaderStatusReading) {
        CMSampleBufferRef sbuf = [_trackOutput copyNextSampleBuffer];
        if (sbuf) { CVPixelBufferRef pix = CMSampleBufferGetImageBuffer(sbuf); if (pix) CVPixelBufferRetain(pix); CFRelease(sbuf); return pix; }
    }
    return NULL;
}
@end

@interface VCAMCoreProcessor : NSObject
@property (nonatomic, strong) VCAMDecoder *decoder;
@property (nonatomic, assign) VTPixelTransferSessionRef pixelTransferSession;
@property (nonatomic, strong) NSLock *decoderLock;
- (void)processSampleBuffer:(CMSampleBufferRef)sampleBuffer;
- (void)processDepthBuffer:(AVDepthData *)depthData;
@end

@implementation VCAMCoreProcessor
- (instancetype)init {
    if (self = [super init]) {
        _decoderLock = [[NSLock alloc] init];
        VTPixelTransferSessionCreate(kCFAllocatorDefault, &_pixelTransferSession);
        if (_pixelTransferSession) VTSessionSetProperty(_pixelTransferSession, kVTPixelTransferPropertyKey_ScalingMode, kVTScalingMode_CropSourceToCleanAperture);
        [self loadVideoForCurrentSlot];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(loadVideoForCurrentSlot) name:@"VCAMChannelDidChangeNotification" object:nil];
    }
    return self;
}
- (void)loadVideoForCurrentSlot {
    NSString *docPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *videoPath = [docPath stringByAppendingPathComponent:[NSString stringWithFormat:@"test%ld.mp4", (long)[VCAMManager sharedManager].currentSlot]];
    [self.decoderLock lock]; self.decoder = [[VCAMDecoder alloc] initWithVideoPath:videoPath]; [self.decoderLock unlock];
}
- (void)processSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    if (![VCAMManager sharedManager].isEnabled) return;
    [self.decoderLock lock]; CVPixelBufferRef srcPix = [self.decoder copyNextPixelBuffer]; [self.decoderLock unlock];
    if (srcPix) {
        CVImageBufferRef dstPix = CMSampleBufferGetImageBuffer(sampleBuffer);
        if (dstPix && self.pixelTransferSession) VTPixelTransferSessionTransferImage(self.pixelTransferSession, srcPix, dstPix);
        CVPixelBufferRelease(srcPix);
    }
    @synchronized ([VCAMManager sharedManager].displayLayers) {
        for (AVSampleBufferDisplayLayer *layer in [[VCAMManager sharedManager].displayLayers allObjects]) {
            if (!layer.hidden && layer.isReadyForMoreMediaData) {
                if (layer.status == AVQueuedSampleBufferRenderingStatusFailed) [layer flush]; [layer enqueueSampleBuffer:sampleBuffer];
            }
        }
    }
}
- (void)processDepthBuffer:(AVDepthData *)depthData {
    if (!depthData) return;
    CVPixelBufferRef depthMap = [depthData depthDataMap];
    if (!depthMap) return;
    if (CVPixelBufferLockBaseAddress(depthMap, 0) == kCVReturnSuccess) {
        void *baseAddress = CVPixelBufferGetBaseAddress(depthMap);
        if (baseAddress) { size_t size = CVPixelBufferGetBytesPerRow(depthMap) * CVPixelBufferGetHeight(depthMap); memset(baseAddress, 0, size); }
        CVPixelBufferUnlockBaseAddress(depthMap, 0);
    }
}
- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; if (_pixelTransferSession) { VTPixelTransferSessionInvalidate(_pixelTransferSession); CFRelease(_pixelTransferSession); } }
@end

@implementation VCAMManager
+ (instancetype)sharedManager {
    static VCAMManager *mgr = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ mgr = [[VCAMManager alloc] init]; mgr.isEnabled = YES; mgr.isHUDVisible = NO; mgr.currentSlot = 1; mgr.displayLayers = [NSHashTable weakObjectsHashTable]; mgr.processor = [[VCAMCoreProcessor alloc] init]; });
    return mgr;
}
- (void)updateDisplayLayers {
    BOOL shouldHide = (!self.isHUDVisible || !self.isEnabled);
    dispatch_async(dispatch_get_main_queue(), ^{ @synchronized (self.displayLayers) { for (AVSampleBufferDisplayLayer *layer in self.displayLayers.allObjects) { layer.hidden = shouldHide; if (shouldHide) [layer flush]; } } });
}
- (void)handleTwoFingerLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) { self.isHUDVisible = YES; [VCAMHUDWindow sharedHUD].hidden = NO; [self updateDisplayLayers]; UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium]; [feedback impactOccurred]; }
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer { return YES; }
@end

// ============================================================================
// 【3. 隐形环境伪装万能代理】
// ============================================================================
@interface VCAMUnifiedProxy : NSProxy <AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureDataOutputSynchronizerDelegate, AVCaptureMetadataOutputObjectsDelegate>
@property (nonatomic, weak) id target;
+ (instancetype)proxyWithTarget:(id)target;
@end

@implementation VCAMUnifiedProxy
+ (instancetype)proxyWithTarget:(id)target { VCAMUnifiedProxy *proxy = [VCAMUnifiedProxy alloc]; proxy.target = target; return proxy; }
- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel { NSMethodSignature *sig = [self.target methodSignatureForSelector:sel]; if (!sig) sig = [NSMethodSignature signatureWithObjCTypes:"v@:"]; return sig; }
- (void)forwardInvocation:(NSInvocation *)invocation { if (self.target && [self.target respondsToSelector:invocation.selector]) [invocation invokeWithTarget:self.target]; }
- (BOOL)respondsToSelector:(SEL)aSelector {
    if (aSelector == @selector(captureOutput:didOutputSampleBuffer:fromConnection:) || aSelector == @selector(dataOutputSynchronizer:didOutputSynchronizedDataCollection:) || aSelector == @selector(captureOutput:didOutputMetadataObjects:fromConnection:)) return YES;
    return [self.target respondsToSelector:aSelector];
}
- (Class)class { return [self.target class]; }
- (Class)superclass { return [self.target superclass]; }
- (BOOL)isKindOfClass:(Class)aClass { return [self.target isKindOfClass:aClass]; }
- (BOOL)conformsToProtocol:(Protocol *)aProtocol { return [self.target conformsToProtocol:aProtocol]; }

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    @autoreleasepool { [[VCAMManager sharedManager].processor processSampleBuffer:sampleBuffer]; if ([self.target respondsToSelector:_cmd]) [self.target captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection]; }
}
- (void)dataOutputSynchronizer:(AVCaptureDataOutputSynchronizer *)synchronizer didOutputSynchronizedDataCollection:(AVCaptureSynchronizedDataCollection *)synchronizedDataCollection {
    @autoreleasepool {
        for (AVCaptureOutput *out in synchronizer.dataOutputs) {
            if ([out isKindOfClass:NSClassFromString(@"AVCaptureVideoDataOutput")]) {
                AVCaptureSynchronizedData *syncData = [synchronizedDataCollection synchronizedDataForCaptureOutput:out];
                if ([syncData respondsToSelector:@selector(sampleBuffer)]) { CMSampleBufferRef sbuf = ((CMSampleBufferRef (*)(id, SEL))objc_msgSend)(syncData, @selector(sampleBuffer)); if (sbuf) [[VCAMManager sharedManager].processor processSampleBuffer:sbuf]; }
            } else if ([out isKindOfClass:NSClassFromString(@"AVCaptureDepthDataOutput")] && [VCAMManager sharedManager].isEnabled) {
                AVCaptureSynchronizedData *syncData = [synchronizedDataCollection synchronizedDataForCaptureOutput:out];
                if ([syncData respondsToSelector:@selector(depthData)]) { AVDepthData *depthData = ((AVDepthData *(*)(id, SEL))objc_msgSend)(syncData, @selector(depthData)); [[VCAMManager sharedManager].processor processDepthBuffer:depthData]; }
            }
        }
        if ([self.target respondsToSelector:_cmd]) [self.target dataOutputSynchronizer:synchronizer didOutputSynchronizedDataCollection:synchronizedDataCollection];
    }
}
- (void)captureOutput:(AVCaptureOutput *)output didOutputMetadataObjects:(NSArray *)metadataObjects fromConnection:(AVCaptureConnection *)connection {
    @autoreleasepool {
        NSMutableArray *filtered = [NSMutableArray arrayWithCapacity:metadataObjects.count];
        BOOL shouldFilter = ([VCAMManager sharedManager].isEnabled && [VCAMManager sharedManager].isHUDVisible);
        for (AVMetadataObject *obj in metadataObjects) { if (shouldFilter && [obj.type isEqualToString:AVMetadataObjectTypeFace]) continue; [filtered addObject:obj]; }
        if ([self.target respondsToSelector:_cmd]) [self.target captureOutput:output didOutputMetadataObjects:filtered fromConnection:connection];
    }
}
@end

// ============================================================================
// 【4. HUD 控制台 (洗稿配置面板)】
// ============================================================================
@implementation VCAMHUDWindow { 
    UILabel *_statusLabel; UISwitch *_powerSwitch; NSInteger _pendingSlot; AVSampleBufferDisplayLayer *_previewLayer; 
    UISwitch *_colorSwitch; UISlider *_brightSlider; UISlider *_contrastSlider; UISlider *_saturationSlider;
}
+ (instancetype)sharedHUD {
    static VCAMHUDWindow *hud = nil; static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        CGRect frame = CGRectMake(20, 80, 290, 440);
        if (@available(iOS 13.0, *)) { for (UIWindowScene *scene in (NSArray<UIWindowScene *>*)[UIApplication sharedApplication].connectedScenes) { if (scene.activationState == UISceneActivationStateForegroundActive) { hud = [[VCAMHUDWindow alloc] initWithWindowScene:scene]; hud.frame = frame; break; } } }
        if (!hud) hud = [[VCAMHUDWindow alloc] initWithFrame:frame];
    });
    return hud;
}
- (instancetype)initWithFrame:(CGRect)frame { if (self = [super initWithFrame:frame]) { [self commonInit]; } return self; }
- (instancetype)initWithWindowScene:(UIWindowScene *)windowScene { if (self = [super initWithWindowScene:windowScene]) { [self commonInit]; } return self; }
- (void)commonInit {
    self.windowLevel = UIWindowLevelStatusBar + 100; self.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.85]; self.layer.cornerRadius = 16; self.layer.masksToBounds = YES; self.hidden = YES; 
    [self setupUI]; UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)]; [self addGestureRecognizer:pan];
}
- (void)setupUI {
    _statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 12, 180, 20)]; _statusLabel.textColor = [UIColor greenColor]; _statusLabel.font = [UIFont boldSystemFontOfSize:14]; _statusLabel.text = @"🟢 VCAM [CH 1]"; [self addSubview:_statusLabel];
    _powerSwitch = [[UISwitch alloc] init]; _powerSwitch.transform = CGAffineTransformMakeScale(0.8, 0.8); _powerSwitch.frame = CGRectMake(230, 7, 50, 31); _powerSwitch.on = YES; [_powerSwitch addTarget:self action:@selector(togglePower:) forControlEvents:UIControlEventValueChanged]; [self addSubview:_powerSwitch];
    CGFloat btnWidth = 40, btnHeight = 38, gap = 8;
    for (int i = 0; i < 4; i++) {
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem]; btn.frame = CGRectMake(12 + i * (btnWidth + gap), 42, btnWidth, btnHeight); btn.backgroundColor = [UIColor colorWithWhite:0.3 alpha:1.0]; btn.layer.cornerRadius = 8; [btn setTitle:[NSString stringWithFormat:@"%d", i+1] forState:UIControlStateNormal]; [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal]; btn.titleLabel.font = [UIFont boldSystemFontOfSize:16]; btn.tag = i + 1;
        [btn addTarget:self action:@selector(channelSwitched:) forControlEvents:UIControlEventTouchUpInside]; UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)]; [btn addGestureRecognizer:lp]; [self addSubview:btn];
    }
    UIButton *clearBtn = [UIButton buttonWithType:UIButtonTypeSystem]; clearBtn.frame = CGRectMake(12 + 4 * (btnWidth + gap), 42, 60, btnHeight); clearBtn.backgroundColor = [UIColor colorWithRed:0.8 green:0.2 blue:0.2 alpha:1.0]; clearBtn.layer.cornerRadius = 8; [clearBtn setTitle:@"隐藏" forState:UIControlStateNormal]; [clearBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal]; clearBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14]; [clearBtn addTarget:self action:@selector(hideHUD) forControlEvents:UIControlEventTouchUpInside]; [self addSubview:clearBtn];
    
    _previewLayer = [[AVSampleBufferDisplayLayer alloc] init]; _previewLayer.frame = CGRectMake(12, 90, 266, 150); _previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill; _previewLayer.backgroundColor = [UIColor blackColor].CGColor; _previewLayer.cornerRadius = 8; _previewLayer.masksToBounds = YES; [self.layer addSublayer:_previewLayer]; [[VCAMManager sharedManager].displayLayers addObject:_previewLayer];
    
    UILabel *colorLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 250, 150, 20)]; colorLabel.text = @"🎨 导入重编码与去重"; colorLabel.textColor = [UIColor whiteColor]; colorLabel.font = [UIFont boldSystemFontOfSize:14]; [self addSubview:colorLabel];
    _colorSwitch = [[UISwitch alloc] init]; _colorSwitch.transform = CGAffineTransformMakeScale(0.7, 0.7); _colorSwitch.frame = CGRectMake(235, 245, 50, 31); _colorSwitch.on = NO; [self addSubview:_colorSwitch];
    
    UILabel *bLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 280, 40, 20)]; bLabel.text = @"亮度"; bLabel.textColor = [UIColor lightGrayColor]; bLabel.font = [UIFont systemFontOfSize:12]; [self addSubview:bLabel];
    _brightSlider = [[UISlider alloc] initWithFrame:CGRectMake(50, 280, 220, 20)]; _brightSlider.minimumValue = -0.2; _brightSlider.maximumValue = 0.2; _brightSlider.value = 0.0; [self addSubview:_brightSlider];
    
    UILabel *cLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 320, 40, 20)]; cLabel.text = @"对比"; cLabel.textColor = [UIColor lightGrayColor]; cLabel.font = [UIFont systemFontOfSize:12]; [self addSubview:cLabel];
    _contrastSlider = [[UISlider alloc] initWithFrame:CGRectMake(50, 320, 220, 20)]; _contrastSlider.minimumValue = 0.5; _contrastSlider.maximumValue = 1.5; _contrastSlider.value = 1.0; [self addSubview:_contrastSlider];
    
    UILabel *sLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 360, 40, 20)]; sLabel.text = @"饱和"; sLabel.textColor = [UIColor lightGrayColor]; sLabel.font = [UIFont systemFontOfSize:12]; [self addSubview:sLabel];
    _saturationSlider = [[UISlider alloc] initWithFrame:CGRectMake(50, 360, 220, 20)]; _saturationSlider.minimumValue = 0.0; _saturationSlider.maximumValue = 2.0; _saturationSlider.value = 1.0; [self addSubview:_saturationSlider];
    
    UILabel *tipLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 400, 266, 30)]; tipLabel.text = @"开启去重后导入视频耗时较长，请耐心等待\n关闭开关则直接秒传原视频 (保留元数据)"; tipLabel.numberOfLines = 2; tipLabel.textColor = [UIColor darkGrayColor]; tipLabel.font = [UIFont systemFontOfSize:10]; tipLabel.textAlignment = NSTextAlignmentCenter; [self addSubview:tipLabel];
}
- (void)hideHUD { self.hidden = YES; [VCAMManager sharedManager].isHUDVisible = NO; [[VCAMManager sharedManager] updateDisplayLayers]; UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight]; [feedback impactOccurred]; }
- (void)togglePower:(UISwitch *)sender { [VCAMManager sharedManager].isEnabled = sender.isOn; [[VCAMManager sharedManager] updateDisplayLayers]; if (sender.isOn) { _statusLabel.text = [NSString stringWithFormat:@"🟢 VCAM [CH %ld]", (long)[VCAMManager sharedManager].currentSlot]; _statusLabel.textColor = [UIColor greenColor]; } else { _statusLabel.text = @"🔴 VCAM 已禁用"; _statusLabel.textColor = [UIColor redColor]; } UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight]; [feedback impactOccurred]; }
- (void)handlePan:(UIPanGestureRecognizer *)pan { CGPoint trans = [pan translationInView:self]; self.center = CGPointMake(self.center.x + trans.x, self.center.y + trans.y); [pan setTranslation:CGPointZero inView:self]; }
- (void)channelSwitched:(UIButton *)sender { [VCAMManager sharedManager].currentSlot = sender.tag; if (_powerSwitch.isOn) { _statusLabel.text = [NSString stringWithFormat:@"🟢 VCAM [CH %ld]", (long)sender.tag]; } [[NSNotificationCenter defaultCenter] postNotificationName:@"VCAMChannelDidChangeNotification" object:nil]; UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium]; [feedback impactOccurred]; }
- (void)clearAllVideos { NSString *docPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject]; for (int i = 1; i <= 4; i++) { NSString *path = [docPath stringByAppendingPathComponent:[NSString stringWithFormat:@"test%d.mp4", i]]; [[NSFileManager defaultManager] removeItemAtPath:path error:nil]; } [VCAMManager sharedManager].currentSlot = 1; [[NSNotificationCenter defaultCenter] postNotificationName:@"VCAMChannelDidChangeNotification" object:nil]; _statusLabel.text = @"🗑️ 已清空"; UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleHeavy]; [feedback impactOccurred]; }
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
                [VCAMVideoPreprocessor processVideoAtURL:url toDestination:dest brightness:bVal contrast:cVal saturation:sVal completion:^(BOOL success, NSError *error) {
                    dispatch_async(dispatch_get_main_queue(), ^{ 
                        if (success) { if ([VCAMManager sharedManager].currentSlot == self->_pendingSlot) [[NSNotificationCenter defaultCenter] postNotificationName:@"VCAMChannelDidChangeNotification" object:nil]; 
                            self->_statusLabel.text = [NSString stringWithFormat:@"🟢 VCAM [CH %ld]", (long)[VCAMManager sharedManager].currentSlot]; self->_statusLabel.textColor = [UIColor greenColor];
                        } else { self->_statusLabel.text = @"❌ 去重渲染失败"; self->_statusLabel.textColor = [UIColor redColor]; } 
                    });
                }];
            }); 
        } else {
            self->_statusLabel.text = @"⚡️ 原视频极速载入..."; 
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{ 
                BOOL success = [[NSFileManager defaultManager] copyItemAtURL:url toURL:[NSURL fileURLWithPath:dest] error:nil]; 
                dispatch_async(dispatch_get_main_queue(), ^{ 
                    if (success) { if ([VCAMManager sharedManager].currentSlot == self->_pendingSlot) [[NSNotificationCenter defaultCenter] postNotificationName:@"VCAMChannelDidChangeNotification" object:nil]; 
                        self->_statusLabel.text = [NSString stringWithFormat:@"🟢 VCAM [CH %ld]", (long)[VCAMManager sharedManager].currentSlot]; 
                    } else { self->_statusLabel.text = @"❌ 极速导入失败"; } 
                }); 
            });
        }
    } 
    [picker dismissViewControllerAnimated:YES completion:nil]; 
}
@end

// ============================================================================
// 【5. 最底层启动入口 (+load 绝对稳定方案)】
// ============================================================================
@implementation UIWindow (VCAMHook)
- (void)vcam_becomeKeyWindow {
    [self vcam_becomeKeyWindow];
    if (![self isKindOfClass:NSClassFromString(@"VCAMHUDWindow")] && !objc_getAssociatedObject(self, "_vcam_g")) {
        UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:[VCAMManager sharedManager] action:@selector(handleTwoFingerLongPress:)];
        lp.numberOfTouchesRequired = 3; lp.minimumPressDuration = 0.5; lp.cancelsTouchesInView = NO; lp.delegate = [VCAMManager sharedManager];
        [self addGestureRecognizer:lp];
        objc_setAssociatedObject(self, "_vcam_g", @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}
@end

@implementation AVCaptureVideoDataOutput (VCAMHook)
- (void)vcam_setSampleBufferDelegate:(id)delegate queue:(dispatch_queue_t)queue {
    if (delegate && !object_getClass(delegate) == NSClassFromString(@"VCAMUnifiedProxy")) {
        VCAMUnifiedProxy *proxy = [VCAMUnifiedProxy proxyWithTarget:delegate];
        objc_setAssociatedObject(self, "_vcam_p", proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [self vcam_setSampleBufferDelegate:proxy queue:queue];
    } else { [self vcam_setSampleBufferDelegate:delegate queue:queue]; }
}
@end

@implementation AVCaptureDataOutputSynchronizer (VCAMHook)
- (void)vcam_setDelegate:(id)delegate queue:(dispatch_queue_t)queue {
    if (delegate && !object_getClass(delegate) == NSClassFromString(@"VCAMUnifiedProxy")) {
        VCAMUnifiedProxy *proxy = [VCAMUnifiedProxy proxyWithTarget:delegate];
        objc_setAssociatedObject(self, "_vcam_p", proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [self vcam_setDelegate:proxy queue:queue];
    } else { [self vcam_setDelegate:delegate queue:queue]; }
}
@end

@implementation AVCaptureMetadataOutput (VCAMHook)
- (void)vcam_setMetadataObjectsDelegate:(id)delegate queue:(dispatch_queue_t)queue {
    if (delegate && !object_getClass(delegate) == NSClassFromString(@"VCAMUnifiedProxy")) {
        VCAMUnifiedProxy *proxy = [VCAMUnifiedProxy proxyWithTarget:delegate];
        objc_setAssociatedObject(self, "_vcam_p", proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [self vcam_setMetadataObjectsDelegate:proxy queue:queue];
    } else { [self vcam_setMetadataObjectsDelegate:delegate queue:queue]; }
}
@end

@interface VCAMLoader : NSObject
@end
@implementation VCAMLoader
+ (void)load {
    dlopen("/System/Library/Frameworks/AVFoundation.framework/AVFoundation", RTLD_NOW);
    method_exchangeImplementations(class_getInstanceMethod([UIWindow class], @selector(becomeKeyWindow)), class_getInstanceMethod([UIWindow class], @selector(vcam_becomeKeyWindow)));
    Class vdoClass = NSClassFromString(@"AVCaptureVideoDataOutput");
    if (vdoClass) method_exchangeImplementations(class_getInstanceMethod(vdoClass, @selector(setSampleBufferDelegate:queue:)), class_getInstanceMethod(vdoClass, @selector(vcam_setSampleBufferDelegate:queue:)));
    Class syncClass = NSClassFromString(@"AVCaptureDataOutputSynchronizer");
    if (syncClass) method_exchangeImplementations(class_getInstanceMethod(syncClass, @selector(setDelegate:queue:)), class_getInstanceMethod(syncClass, @selector(vcam_setDelegate:queue:)));
    Class metaClass = NSClassFromString(@"AVCaptureMetadataOutput");
    if (metaClass) method_exchangeImplementations(class_getInstanceMethod(metaClass, @selector(setMetadataObjectsDelegate:queue:)), class_getInstanceMethod(metaClass, @selector(vcam_setMetadataObjectsDelegate:queue:)));
}
@end
#pragma clang diagnostic pop
