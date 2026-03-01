#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <objc/runtime.h>
#import <objc/message.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

// ============================================================================
// 【0. 工业级安全交换算法】
// ============================================================================
static void safe_swizzle(Class cls, SEL originalSelector, SEL swizzledSelector) {
    if (!cls) return;
    Method originalMethod = class_getInstanceMethod(cls, originalSelector);
    Method swizzledMethod = class_getInstanceMethod(cls, swizzledSelector);
    if (!originalMethod || !swizzledMethod) return;
    BOOL didAddMethod = class_addMethod(cls, originalSelector, method_getImplementation(swizzledMethod), method_getTypeEncoding(swizzledMethod));
    if (didAddMethod) { class_replaceMethod(cls, swizzledSelector, method_getImplementation(originalMethod), method_getTypeEncoding(originalMethod)); } 
    else { method_exchangeImplementations(originalMethod, swizzledMethod); }
}

// ============================================================================
// 【1. 无痕转码引擎】
// ============================================================================
@interface VCAMStealthPreprocessor : NSObject
+ (void)processVideoAtURL:(NSURL *)sourceURL completion:(void(^)(BOOL success))completion;
@end

@implementation VCAMStealthPreprocessor
+ (void)processVideoAtURL:(NSURL *)sourceURL completion:(void(^)(BOOL success))completion {
    NSString *destPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"com.apple.avfoundation.videocache.tmp"];
    [[NSFileManager defaultManager] removeItemAtPath:destPath error:nil];
    
    AVAsset *asset = [AVAsset assetWithURL:sourceURL];
    AVAssetExportSession *exportSession = [[AVAssetExportSession alloc] initWithAsset:asset presetName:AVAssetExportPresetHighestQuality];
    exportSession.outputURL = [NSURL fileURLWithPath:destPath];
    exportSession.outputFileType = AVFileTypeMPEG4;
    exportSession.shouldOptimizeForNetworkUse = YES;

    [exportSession exportAsynchronouslyWithCompletionHandler:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            if (exportSession.status == AVAssetExportSessionStatusCompleted) {
                if (completion) completion(YES);
            } else {
                if (completion) completion(NO);
            }
        });
    }];
}
@end

// ============================================================================
// 【2. 寄生级渲染引擎 (👑 恢复 32BGRA，依靠硬件转换器自动适配 WebRTC)】
// ============================================================================
@interface VCAMParasiteCore : NSObject
@property (nonatomic, strong) AVAssetReader *assetReader;
@property (nonatomic, strong) AVAssetReaderOutput *trackOutput;
@property (nonatomic, assign) VTPixelTransferSessionRef transferSession;
@property (nonatomic, strong) NSLock *readLock;
@property (nonatomic, assign) CVPixelBufferRef lastPixelBuffer;
@property (nonatomic, assign) BOOL isEnabled;
@property (nonatomic, assign) NSTimeInterval lastFrameTime;
@property (nonatomic, assign) NSTimeInterval videoFrameDuration;
+ (instancetype)sharedCore;
- (void)loadVideo;
- (void)parasiteInjectSampleBuffer:(CMSampleBufferRef)sampleBuffer;
@end

@implementation VCAMParasiteCore
+ (instancetype)sharedCore {
    static VCAMParasiteCore *core = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ core = [[VCAMParasiteCore alloc] init]; });
    return core;
}

- (instancetype)init {
    if (self = [super init]) {
        _readLock = [[NSLock alloc] init];
        _lastPixelBuffer = NULL;
        _isEnabled = YES; 
        _lastFrameTime = 0.0;
        _videoFrameDuration = 1.0 / 30.0;
        
        VTPixelTransferSessionCreate(kCFAllocatorDefault, &_transferSession);
        if (_transferSession) {
            // 完美无缝缩放，保证转移到不同格式内存时不会花屏
            VTSessionSetProperty(_transferSession, kVTPixelTransferPropertyKey_ScalingMode, kVTScalingMode_CropSourceToCleanAperture);
        }
        [self loadVideo];
    }
    return self;
}

- (void)loadVideo {
    NSString *videoPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"com.apple.avfoundation.videocache.tmp"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:videoPath]) return;
    
    NSURL *videoURL = [NSURL fileURLWithPath:videoPath];
    AVAsset *asset = [AVAsset assetWithURL:videoURL];
    
    [asset loadValuesAsynchronouslyForKeys:@[@"tracks"] completionHandler:^{
        NSError *error = nil;
        AVKeyValueStatus status = [asset statusOfValueForKey:@"tracks" error:&error];
        if (status != AVKeyValueStatusLoaded) return;
        
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
            [self.readLock lock];
            
            if (self.assetReader) {
                [self.assetReader cancelReading]; self.assetReader = nil; self.trackOutput = nil;
            }
            
            self.assetReader = [AVAssetReader assetReaderWithAsset:asset error:nil];
            AVAssetTrack *videoTrack = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
            
            if (videoTrack && self.assetReader) {
                float fps = videoTrack.nominalFrameRate;
                if (fps <= 0.0) fps = 30.0;
                self.videoFrameDuration = 1.0 / fps;
                
                // 👑 必须使用 32BGRA，否则 AVVideoComposition 会交白卷导致没画面
                NSDictionary *settings = @{
                    (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
                    (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
                };
                
                AVMutableVideoComposition *videoComp = nil;
                @try {
                    videoComp = (AVMutableVideoComposition *)[AVVideoComposition videoCompositionWithPropertiesOfAsset:asset];
                    if (!CGSizeEqualToSize(videoComp.renderSize, CGSizeZero)) {
                        videoComp.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2;
                        videoComp.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2;
                        videoComp.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2;
                    } else { videoComp = nil; }
                } @catch (NSException *e) { videoComp = nil; }
                
                if (videoComp) {
                    AVAssetReaderVideoCompositionOutput *compOut = [AVAssetReaderVideoCompositionOutput assetReaderVideoCompositionOutputWithVideoTracks:@[videoTrack] videoSettings:settings];
                    compOut.videoComposition = videoComp; self.trackOutput = (AVAssetReaderOutput *)compOut;
                } else {
                    self.trackOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:videoTrack outputSettings:settings];
                }
                
                if ([self.assetReader canAddOutput:self.trackOutput]) {
                    [self.assetReader addOutput:self.trackOutput]; [self.assetReader startReading];
                }
            }
            [self.readLock unlock];
        });
    }];
}

- (CVPixelBufferRef)copyNextFrame {
    if (!self.assetReader) return NULL;
    if (self.assetReader.status == AVAssetReaderStatusCompleted) { [self loadVideo]; }
    
    NSTimeInterval currentTime = [[NSDate date] timeIntervalSince1970];
    if (currentTime - self.lastFrameTime < self.videoFrameDuration) return NULL;
    
    if (self.assetReader.status == AVAssetReaderStatusReading) {
        CMSampleBufferRef sbuf = [self.trackOutput copyNextSampleBuffer];
        if (sbuf) {
            CVPixelBufferRef pix = CMSampleBufferGetImageBuffer(sbuf);
            if (pix) CVPixelBufferRetain(pix);
            CFRelease(sbuf);
            self.lastFrameTime = currentTime;
            return pix;
        } else { [self loadVideo]; }
    }
    return NULL;
}

- (void)parasiteInjectSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    if (!self.isEnabled) return;
    
    [self.readLock lock];
    CVPixelBufferRef srcPix = [self copyNextFrame];
    [self.readLock unlock];
    
    if (srcPix) {
        if (_lastPixelBuffer) CVPixelBufferRelease(_lastPixelBuffer);
        _lastPixelBuffer = CVPixelBufferRetain(srcPix);
    } else {
        if (_lastPixelBuffer) srcPix = CVPixelBufferRetain(_lastPixelBuffer);
    }
    
    if (srcPix) {
        CVImageBufferRef dstPix = CMSampleBufferGetImageBuffer(sampleBuffer);
        if (dstPix && self.transferSession) {
            // 硬件转移：将我们的 32BGRA 画面，安全映射到 WhatsApp 要求的任意格式（包括通话中的 NV12）
            if (CVPixelBufferLockBaseAddress(dstPix, 0) == kCVReturnSuccess) {
                VTPixelTransferSessionTransferImage(self.transferSession, srcPix, dstPix);
                CVPixelBufferUnlockBaseAddress(dstPix, 0);
            }
        }
        CVPixelBufferRelease(srcPix);
    }
}
@end

// ============================================================================
// 【3. 隐形环境伪装代理 (👑 采用苹果原生安全抹零法)】
// ============================================================================
@interface VCAMStealthProxy : NSProxy <AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, AVCaptureDataOutputSynchronizerDelegate>
@property (nonatomic, weak) id target;
@end

@implementation VCAMStealthProxy
+ (instancetype)proxyWithTarget:(id)target {
    VCAMStealthProxy *proxy = [VCAMStealthProxy alloc];
    proxy.target = target;
    return proxy;
}
- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel { return [(NSObject *)self.target methodSignatureForSelector:sel]; }
- (void)forwardInvocation:(NSInvocation *)invocation {
    if (self.target && [self.target respondsToSelector:invocation.selector]) { [invocation invokeWithTarget:self.target]; }
}
- (BOOL)respondsToSelector:(SEL)aSelector {
    if (aSelector == @selector(captureOutput:didOutputSampleBuffer:fromConnection:) ||
        aSelector == @selector(dataOutputSynchronizer:didOutputSynchronizedDataCollection:)) return YES;
    return [self.target respondsToSelector:aSelector];
}

- (Class)class { return [(NSObject *)self.target class]; }
- (Class)superclass { return [(NSObject *)self.target superclass]; }

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    @autoreleasepool {
        if ([output isKindOfClass:NSClassFromString(@"AVCaptureVideoDataOutput")]) {
            [[VCAMParasiteCore sharedCore] parasiteInjectSampleBuffer:sampleBuffer];
        } 
        else if ([output isKindOfClass:NSClassFromString(@"AVCaptureAudioDataOutput")]) {
            if ([VCAMParasiteCore sharedCore].isEnabled) {
                CMBlockBufferRef blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
                if (blockBuffer) {
                    // 👑 极度安全的官方抹零 API：绝不触碰指针结构，只静音数据。彻底告别视频通话挂断！
                    CMBlockBufferFillDataBytes(0, blockBuffer, 0, CMBlockBufferGetDataLength(blockBuffer));
                }
            }
        }
        
        if ([self.target respondsToSelector:_cmd]) {
            [(id)self.target captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection];
        }
    }
}

// 拦截 WebRTC 偶尔使用的同步器流
- (void)dataOutputSynchronizer:(AVCaptureDataOutputSynchronizer *)synchronizer didOutputSynchronizedDataCollection:(AVCaptureSynchronizedDataCollection *)synchronizedDataCollection {
    @autoreleasepool {
        for (AVCaptureOutput *out in synchronizer.dataOutputs) {
            if ([out isKindOfClass:NSClassFromString(@"AVCaptureVideoDataOutput")]) { 
                AVCaptureSynchronizedData *syncData = [synchronizedDataCollection synchronizedDataForCaptureOutput:out];
                if ([syncData respondsToSelector:@selector(sampleBuffer)]) { 
                    CMSampleBufferRef sbuf = ((CMSampleBufferRef (*)(id, SEL))objc_msgSend)(syncData, @selector(sampleBuffer)); 
                    if (sbuf) [[VCAMParasiteCore sharedCore] parasiteInjectSampleBuffer:sbuf];
                } 
            } 
        }
        if ([self.target respondsToSelector:_cmd]) { [(id)self.target dataOutputSynchronizer:synchronizer didOutputSynchronizedDataCollection:synchronizedDataCollection]; }
    }
}
@end

// ============================================================================
// 【4. 隐身控制台 (UI 防死锁)】
// ============================================================================
@interface VCAMStealthUIManager : NSObject <UIImagePickerControllerDelegate, UINavigationControllerDelegate>
+ (instancetype)sharedManager;
- (void)showStealthMenuInWindow:(UIWindow *)window;
@end

@implementation VCAMStealthUIManager
+ (instancetype)sharedManager {
    static VCAMStealthUIManager *mgr = nil; static dispatch_once_t once;
    dispatch_once(&once, ^{ mgr = [[VCAMStealthUIManager alloc] init]; }); return mgr;
}

- (void)showStealthMenuInWindow:(UIWindow *)window {
    UIViewController *root = window.rootViewController;
    while (root.presentedViewController) root = root.presentedViewController;
    if (!root) return;
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"📸 系统调试选项" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    
    [alert addAction:[UIAlertAction actionWithTitle:[VCAMParasiteCore sharedCore].isEnabled ? @"🟢 视频注入已开启" : @"🔴 视频注入已关闭" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [VCAMParasiteCore sharedCore].isEnabled = ![VCAMParasiteCore sharedCore].isEnabled;
        UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleHeavy]; [fb impactOccurred];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"📁 选择源视频文件" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        UIImagePickerController *picker = [[UIImagePickerController alloc] init];
        picker.delegate = self;
        picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
        picker.mediaTypes = @[@"public.movie"];
        picker.videoExportPreset = AVAssetExportPresetPassthrough;
        [root presentViewController:picker animated:YES completion:nil];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    
    if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad) {
        alert.popoverPresentationController.sourceView = window;
        alert.popoverPresentationController.sourceRect = CGRectMake(window.bounds.size.width/2, window.bounds.size.height/2, 1, 1);
    }
    
    [root presentViewController:alert animated:YES completion:nil];
}

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary *)info {
    NSURL *url = info[UIImagePickerControllerMediaURL];
    UIViewController *root = picker.presentingViewController;
    [picker dismissViewControllerAnimated:YES completion:^{
        if (url) {
            UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleRigid]; [fb impactOccurred];
            [VCAMStealthPreprocessor processVideoAtURL:url completion:^(BOOL success) {
                if (success) {
                    [[VCAMParasiteCore sharedCore] loadVideo];
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        UIImpactFeedbackGenerator *fb2 = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleHeavy]; [fb2 impactOccurred];
                    });
                } else {
                    UIAlertController *err = [UIAlertController alertControllerWithTitle:@"导入失败" message:@"视频格式不兼容。" preferredStyle:UIAlertControllerStyleAlert];
                    [err addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleCancel handler:nil]];
                    [root presentViewController:err animated:YES completion:nil];
                }
            }];
        }
    }];
}
@end

// ============================================================================
// 【5. 核心 Hook 与手势强制穿透】
// ============================================================================
@interface VCAMGestureDelegate : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)sharedDelegate;
@end
@implementation VCAMGestureDelegate
+ (instancetype)sharedDelegate { static VCAMGestureDelegate *instance = nil; static dispatch_once_t onceToken; dispatch_once(&onceToken, ^{ instance = [[VCAMGestureDelegate alloc] init]; }); return instance; }
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer { return YES; }
@end

@implementation UIWindow (VCAMStealthHook)
- (void)vcam_setupGestures {
    if (!objc_getAssociatedObject(self, "_vcam_ges")) {
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(vcam_handleTap:)];
        tap.numberOfTouchesRequired = 3; tap.numberOfTapsRequired = 1; 
        tap.cancelsTouchesInView = NO; tap.delaysTouchesBegan = NO;   
        tap.delegate = [VCAMGestureDelegate sharedDelegate]; 
        [self addGestureRecognizer:tap];
        objc_setAssociatedObject(self, "_vcam_ges", @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}
- (void)vcam_becomeKeyWindow { [self vcam_becomeKeyWindow]; [self vcam_setupGestures]; }
- (void)vcam_makeKeyAndVisible { [self vcam_makeKeyAndVisible]; [self vcam_setupGestures]; }
- (void)vcam_handleTap:(UITapGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateRecognized) {
        [[VCAMStealthUIManager sharedManager] showStealthMenuInWindow:self];
        UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium]; [fb impactOccurred];
    }
}
@end

@implementation AVCaptureVideoDataOutput (VCAMStealthHook)
- (void)vcam_setSampleBufferDelegate:(id)delegate queue:(dispatch_queue_t)queue {
    if (delegate && ![delegate isKindOfClass:NSClassFromString(@"VCAMStealthProxy")]) {
        VCAMStealthProxy *proxy = [VCAMStealthProxy proxyWithTarget:delegate];
        objc_setAssociatedObject(self, "_vcam_video_p", proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [self vcam_setSampleBufferDelegate:proxy queue:queue];
    } else { [self vcam_setSampleBufferDelegate:delegate queue:queue]; }
}
@end

@implementation AVCaptureAudioDataOutput (VCAMStealthHook)
- (void)vcam_setSampleBufferDelegate:(id)delegate queue:(dispatch_queue_t)queue {
    if (delegate && ![delegate isKindOfClass:NSClassFromString(@"VCAMStealthProxy")]) {
        VCAMStealthProxy *proxy = [VCAMStealthProxy proxyWithTarget:delegate];
        objc_setAssociatedObject(self, "_vcam_audio_p", proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [self vcam_setSampleBufferDelegate:proxy queue:queue];
    } else { [self vcam_setSampleBufferDelegate:delegate queue:queue]; }
}
@end

@interface AVCaptureDataOutputSynchronizer (VCAMStealthHook)
- (void)vcam_setDelegate:(id<AVCaptureDataOutputSynchronizerDelegate>)delegate queue:(dispatch_queue_t)queue;
@end
@implementation AVCaptureDataOutputSynchronizer (VCAMStealthHook)
- (void)vcam_setDelegate:(id<AVCaptureDataOutputSynchronizerDelegate>)delegate queue:(dispatch_queue_t)queue {
    if (delegate && ![delegate isKindOfClass:NSClassFromString(@"VCAMStealthProxy")]) {
        VCAMStealthProxy *proxy = [VCAMStealthProxy proxyWithTarget:delegate];
        objc_setAssociatedObject(self, "_vcam_sync_p", proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [self vcam_setDelegate:proxy queue:queue];
    } else { [self vcam_setDelegate:delegate queue:queue]; }
}
@end

// ============================================================================
// 【6. 启动器】
// ============================================================================
@interface VCAMLoader : NSObject
@end
@implementation VCAMLoader
+ (void)load {
    safe_swizzle([UIWindow class], @selector(becomeKeyWindow), @selector(vcam_becomeKeyWindow));
    safe_swizzle([UIWindow class], @selector(makeKeyAndVisible), @selector(vcam_makeKeyAndVisible));
    
    Class vdoClass = NSClassFromString(@"AVCaptureVideoDataOutput");
    if (vdoClass) safe_swizzle(vdoClass, @selector(setSampleBufferDelegate:queue:), @selector(vcam_setSampleBufferDelegate:queue:));
    
    Class adoClass = NSClassFromString(@"AVCaptureAudioDataOutput");
    if (adoClass) safe_swizzle(adoClass, @selector(setSampleBufferDelegate:queue:), @selector(vcam_setSampleBufferDelegate:queue:));
    
    Class syncClass = NSClassFromString(@"AVCaptureDataOutputSynchronizer");
    if (syncClass) safe_swizzle(syncClass, @selector(setDelegate:queue:), @selector(vcam_setDelegate:queue:));
}
@end
#pragma clang diagnostic pop
