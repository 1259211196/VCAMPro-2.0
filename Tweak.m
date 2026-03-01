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
// 【2. 寄生级渲染引擎 (👑 核心：偷天换日克隆引擎)】
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
- (CMSampleBufferRef)createInjectedSampleBufferFrom:(CMSampleBufferRef)originalBuffer;
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
        if ([asset statusOfValueForKey:@"tracks" error:&error] != AVKeyValueStatusLoaded) return;
        
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

// 👑 终极杀招：绝不触碰原物理锁！动态克隆并转移！
- (CMSampleBufferRef)createInjectedSampleBufferFrom:(CMSampleBufferRef)originalBuffer {
    CVPixelBufferRef origPix = CMSampleBufferGetImageBuffer(originalBuffer);
    if (!origPix) return NULL;

    [self.readLock lock];
    CVPixelBufferRef srcPix = [self copyNextFrame];
    [self.readLock unlock];

    if (srcPix) {
        if (_lastPixelBuffer) CVPixelBufferRelease(_lastPixelBuffer);
        _lastPixelBuffer = CVPixelBufferRetain(srcPix);
    } else {
        if (_lastPixelBuffer) srcPix = CVPixelBufferRetain(_lastPixelBuffer);
    }

    if (!srcPix) return NULL;

    // 1. 抓取 WhatsApp 当前请求的物理格式（动态适配通话降级）
    OSType origFormat = CVPixelBufferGetPixelFormatType(origPix);
    size_t origW = CVPixelBufferGetWidth(origPix);
    size_t origH = CVPixelBufferGetHeight(origPix);

    // 2. 凭空克隆一个毫无硬件锁的全新物理缓冲池，并加上 WebRTC 编码必须的 IOSurface 属性
    CVPixelBufferRef newPix = NULL;
    NSDictionary *pixelAttributes = @{ (id)kCVPixelBufferIOSurfacePropertiesKey: @{} };
    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault, origW, origH, origFormat, (__bridge CFDictionaryRef)pixelAttributes, &newPix);
    
    if (status == kCVReturnSuccess && newPix) {
        // 3. 将我们的视频通过底层 GPU 无缝转移（自动变频、换色、缩放）到新缓冲池
        if (self.transferSession) {
            VTPixelTransferSessionTransferImage(self.transferSession, srcPix, newPix);
        }

        // 4. 将新的缓冲池伪装打包成合法的原生 CMSampleBuffer
        CMSampleBufferRef newSampleBuffer = NULL;
        CMSampleTimingInfo timingInfo;
        if (CMSampleBufferGetSampleTimingInfo(originalBuffer, 0, &timingInfo) == kCMBlockBufferNoErr) {
            CMVideoFormatDescriptionRef videoInfo = NULL;
            CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, newPix, &videoInfo);
            CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, newPix, true, NULL, NULL, videoInfo, &timingInfo, &newSampleBuffer);
            if (videoInfo) CFRelease(videoInfo);
        }
        CVPixelBufferRelease(newPix);
        return newSampleBuffer; // 完美克隆体生成！
    }
    return NULL;
}
@end

// ============================================================================
// 【3. 隐形环境伪装代理 (👑 绝对防崩溃拦截体系)】
// ============================================================================
@interface VCAMStealthProxy : NSProxy <AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate>
@property (nonatomic, weak) id target;
@end

@implementation VCAMStealthProxy
+ (instancetype)proxyWithTarget:(id)target {
    VCAMStealthProxy *proxy = [VCAMStealthProxy alloc];
    proxy.target = target;
    return proxy;
}

// 强制通过 WhatsApp 的类验证探针
- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel { return [self.target methodSignatureForSelector:sel]; }
- (void)forwardInvocation:(NSInvocation *)invocation {
    if (self.target && [self.target respondsToSelector:invocation.selector]) { [invocation invokeWithTarget:self.target]; }
}
- (BOOL)respondsToSelector:(SEL)aSelector {
    if (aSelector == @selector(captureOutput:didOutputSampleBuffer:fromConnection:)) return YES;
    return [self.target respondsToSelector:aSelector];
}
- (BOOL)conformsToProtocol:(Protocol *)aProtocol { return [self.target conformsToProtocol:aProtocol]; }
- (BOOL)isKindOfClass:(Class)aClass { return [self.target isKindOfClass:aClass]; }

// 拦截枢纽
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    @autoreleasepool {
        if ([output isKindOfClass:NSClassFromString(@"AVCaptureVideoDataOutput")]) {
            if ([VCAMParasiteCore sharedCore].isEnabled) {
                // 将克隆的完美假体交给 WhatsApp，丢弃带有读写锁的真实画面！
                CMSampleBufferRef fakeSample = [[VCAMParasiteCore sharedCore] createInjectedSampleBufferFrom:sampleBuffer];
                if (fakeSample) {
                    if ([self.target respondsToSelector:_cmd]) {
                        [(id)self.target captureOutput:output didOutputSampleBuffer:fakeSample fromConnection:connection];
                    }
                    CFRelease(fakeSample); // 释放内存，防内存泄漏
                    return; // 拦截结束
                }
            }
        } 
        else if ([output isKindOfClass:NSClassFromString(@"AVCaptureAudioDataOutput")]) {
            if ([VCAMParasiteCore sharedCore].isEnabled) {
                // 👑 音频极限防挂断法：幽灵丢包法
                // 直接拦截音频帧，不发送给 WebRTC！这等同于网络音频丢包，绝对不会引发内存越界挂断，且完美实现静音。
                return;
            }
        }
        
        // 未开启插件时的常规放行
        if ([self.target respondsToSelector:_cmd]) {
            [(id)self.target captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection];
        }
    }
}
@end

// ============================================================================
// 【4. 隐身控制台】
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
}
@end
#pragma clang diagnostic pop
