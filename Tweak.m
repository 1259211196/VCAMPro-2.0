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
#import <dlfcn.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
#pragma clang diagnostic ignored "-Wavailability"

// ============================================================================
// 【1. 全局环境大管家】
// ============================================================================
@class VCAMHUDWindow, VCAMMapWindow, VCAMCoreProcessor;

@interface VCAMManager : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)sharedManager;
@property (nonatomic, assign) BOOL isEnabled;
@property (nonatomic, assign) BOOL isHUDVisible; 
@property (nonatomic, assign) NSInteger currentSlot;
@property (nonatomic, strong) NSHashTable *displayLayers;
@property (nonatomic, strong) VCAMCoreProcessor *processor;

@property (nonatomic, assign) BOOL isEnvSpoofingEnabled;
@property (nonatomic, assign) CLLocationCoordinate2D fakeCoordinate;
@property (nonatomic, copy) NSString *fakeMCC;
@property (nonatomic, copy) NSString *fakeMNC;
@property (nonatomic, copy) NSString *fakeISO;
@property (nonatomic, copy) NSString *fakeCarrierName;

- (void)updateDisplayLayers;
- (void)saveEnvironmentSettings;
- (void)loadEnvironmentSettings;
@end

@interface VCAMHUDWindow : UIWindow <UIImagePickerControllerDelegate, UINavigationControllerDelegate>
+ (instancetype)sharedHUD;
@end

@interface VCAMMapWindow : UIWindow <MKMapViewDelegate>
+ (instancetype)sharedMap;
@end

// ============================================================================
// 【2. 异步视频去重洗稿引擎】
// ============================================================================
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
@interface VCAMDecoder : NSObject
- (instancetype)initWithVideoPath:(NSString *)path;
- (CVPixelBufferRef)copyNextPixelBuffer;
@end
@implementation VCAMDecoder { AVAssetReader *_assetReader; AVAssetReaderOutput *_trackOutput; NSString *_videoPath; }
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

@implementation VCAMManager
+ (instancetype)sharedManager {
    static VCAMManager *mgr = nil; static dispatch_once_t once;
    dispatch_once(&once, ^{ 
        mgr = [[VCAMManager alloc] init]; mgr.isEnabled = YES; mgr.isHUDVisible = NO; mgr.currentSlot = 1; mgr.displayLayers = [NSHashTable weakObjectsHashTable]; mgr.processor = [[VCAMCoreProcessor alloc] init]; 
        [mgr loadEnvironmentSettings];
    });
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
- (void)saveEnvironmentSettings {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:self.isEnvSpoofingEnabled forKey:@"vcam_env_enabled"];
    [defaults setDouble:self.fakeCoordinate.latitude forKey:@"vcam_env_lat"];
    [defaults setDouble:self.fakeCoordinate.longitude forKey:@"vcam_env_lon"];
    if (self.fakeMCC) [defaults setObject:self.fakeMCC forKey:@"vcam_env_mcc"];
    if (self.fakeMNC) [defaults setObject:self.fakeMNC forKey:@"vcam_env_mnc"];
    if (self.fakeISO) [defaults setObject:self.fakeISO forKey:@"vcam_env_iso"];
    if (self.fakeCarrierName) [defaults setObject:self.fakeCarrierName forKey:@"vcam_env_carrier"];
    [defaults synchronize];
}
- (void)loadEnvironmentSettings {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    self.isEnvSpoofingEnabled = [defaults boolForKey:@"vcam_env_enabled"];
    self.fakeCoordinate = CLLocationCoordinate2DMake([defaults doubleForKey:@"vcam_env_lat"], [defaults doubleForKey:@"vcam_env_lon"]);
    self.fakeMCC = [defaults stringForKey:@"vcam_env_mcc"] ?: @"262";
    self.fakeMNC = [defaults stringForKey:@"vcam_env_mnc"] ?: @"01";
    self.fakeISO = [defaults stringForKey:@"vcam_env_iso"] ?: @"de";
    self.fakeCarrierName = [defaults stringForKey:@"vcam_env_carrier"] ?: @"Telekom.de";
}
@end

// ============================================================================
// 【4. 隐形环境伪装代理 (拦截视频与GPS)】
// ============================================================================
@interface VCAMUnifiedProxy : NSProxy <AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureDataOutputSynchronizerDelegate, AVCaptureMetadataOutputObjectsDelegate, CLLocationManagerDelegate>
@property (nonatomic, weak) id target;
+ (instancetype)proxyWithTarget:(id)target;
@end
@implementation VCAMUnifiedProxy
+ (instancetype)proxyWithTarget:(id)target { VCAMUnifiedProxy *proxy = [VCAMUnifiedProxy alloc]; proxy.target = target; return proxy; }
- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel { NSMethodSignature *sig = [self.target methodSignatureForSelector:sel]; if (!sig) sig = [NSMethodSignature signatureWithObjCTypes:"v@:"]; return sig; }
- (void)forwardInvocation:(NSInvocation *)invocation { if (self.target && [self.target respondsToSelector:invocation.selector]) [invocation invokeWithTarget:self.target]; }
- (BOOL)respondsToSelector:(SEL)aSelector {
    if (aSelector == @selector(captureOutput:didOutputSampleBuffer:fromConnection:) || aSelector == @selector(dataOutputSynchronizer:didOutputSynchronizedDataCollection:) || aSelector == @selector(captureOutput:didOutputMetadataObjects:fromConnection:) || aSelector == @selector(locationManager:didUpdateLocations:)) return YES;
    return [self.target respondsToSelector:aSelector];
}
- (Class)class { return [self.target class]; }
- (Class)superclass { return [self.target superclass]; }
- (BOOL)isKindOfClass:(Class)aClass {
