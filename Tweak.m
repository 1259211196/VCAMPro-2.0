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
// 【1. 无痕转码引擎 (伪装成系统缓存文件)】
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
// 【2. 寄生级渲染引擎 (零拷贝、防卡顿异步加载 + 帧率节流阀)】
// ============================================================================
@interface VCAMParasiteCore : NSObject
@property (nonatomic, strong) AVAssetReader *assetReader;
@property (nonatomic, strong) AVAssetReaderOutput *trackOutput;
@property (nonatomic, assign) VTPixelTransferSessionRef transferSession;
@property (nonatomic, strong) NSLock *readLock;
@property (nonatomic, assign) CVPixelBufferRef lastPixelBuffer;
@property (nonatomic, assign) BOOL isEnabled;
// 👑 帧率节流阀新增属性
@property (nonatomic, assign) NSTimeInterval lastFrameTime;
+ (instancetype)sharedCore;
- (void)loadVideo;
- (void)parasiteInjectSampleBuffer:(CMSampleBufferRef)sampleBuffer;
@end

@implementation VCAMParasiteCore
+ (instancetype)sharedCore {
    static VCAMParasiteCore *core = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        core = [[VCAMParasiteCore alloc] init];
    });
    return core;
}

- (instancetype)init {
    if (self = [super init]) {
        _readLock = [[NSLock alloc] init];
        _lastPixelBuffer = NULL;
        _isEnabled = YES; 
        _lastFrameTime = 0.0;
        
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
        AVKeyValueStatus status = [asset statusOfValueForKey:@"tracks" error:&error];
        if (status != AVKeyValueStatusLoaded) return;
        
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
            [self.readLock lock];
            
            if (self.assetReader) {
                [self.assetReader cancelReading];
                self.assetReader = nil;
                self.trackOutput = nil;
            }
            
            self.assetReader = [AVAssetReader assetReaderWithAsset:asset error:nil];
            AVAssetTrack *videoTrack = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
            
            if (videoTrack && self.assetReader) {
                NSDictionary *settings = @{
                    (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
                    (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
                };
                
                AVMutableVideoComposition *videoComp = nil;
                @try {
                    videoComp = (AVMutableVideoComposition *)[AVVideoComposition videoCompositionWithPropertiesOfAsset:asset];
                    videoComp.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2;
                    videoComp.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2;
                    videoComp.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2;
                } @catch (NSException *e) {
                    videoComp = nil;
                }
                
                if (videoComp) {
                    AVAssetReaderVideoCompositionOutput *compOut = [AVAssetReaderVideoCompositionOutput assetReaderVideoCompositionOutputWithVideoTracks:@[videoTrack] videoSettings:settings];
                    compOut.videoComposition = videoComp;
                    self.trackOutput = (AVAssetReaderOutput *)compOut;
                } else {
                    self.trackOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:videoTrack outputSettings:settings];
                }
                
                if ([self.assetReader canAddOutput:self.trackOutput]) {
                    [self.assetReader addOutput:self.trackOutput];
                    [self.assetReader startReading];
                }
            }
            [self.readLock unlock];
        });
    }];
}

- (CVPixelBufferRef)copyNextFrame {
    if (!self.assetReader) return NULL;
    
    if (self.assetReader.status == AVAssetReaderStatusCompleted) {
        [self loadVideo]; 
    }
    
    // 👑 帧率节流阀（Frame Throttling）：强制保证视频匀速播放
    // 假设源视频为 30fps，每帧最小间隔约为 0.033 秒
    NSTimeInterval currentTime = [[NSDate date] timeIntervalSince1970];
    if (currentTime - self.lastFrameTime < (1.0 / 30.0)) {
        // 时间未到，拒绝抽取新帧，由外层逻辑复用上一帧
        return NULL;
    }
    
    if (self.assetReader.status == AVAssetReaderStatusReading) {
        CMSampleBufferRef sbuf = [self.trackOutput copyNextSampleBuffer];
        if (sbuf) {
            CVPixelBufferRef pix = CMSampleBufferGetImageBuffer(sbuf);
            if (pix) CVPixelBufferRetain(pix);
            CFRelease(sbuf);
            
            // 记录成功抽帧的时间
            self.lastFrameTime = currentTime;
            return pix;
        } else {
            [self loadVideo];
        }
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
        // 如果节流阀拦截了，复用上一帧，保证帧流连续不黑屏
        if (_lastPixelBuffer) srcPix = CVPixelBufferRetain(_lastPixelBuffer);
    }
    
    if (srcPix) {
        CVImageBufferRef dstPix = CMSampleBufferGetImageBuffer(sampleBuffer);
        if (dstPix && self.transferSession) {
            VTPixelTransferSessionTransferImage(self.transferSession, srcPix, dstPix);
        }
        CVPixelBufferRelease(srcPix);
    }
}
@end

// ============================================================================
// 【3. 极度伪装代理 (防止内存探针扫描)】
// ============================================================================
@interface VCAMStealthProxy : NSProxy <AVCaptureVideoDataOutputSampleBufferDelegate>
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
    if (self.target && [self.target respondsToSelector:invocation.selector]) {
        [invocation invokeWithTarget:self.target];
    }
}
- (BOOL)respondsToSelector:(SEL)aSelector {
    if (aSelector == @selector(captureOutput:didOutputSampleBuffer:fromConnection:)) return YES;
    return [self.target respondsToSelector:aSelector];
}

- (Class)class { return [(NSObject *)self.target class]; }
- (Class)superclass { return [(NSObject *)self.target superclass]; }
- (NSString *)description { return [(NSObject *)self.target description]; }
- (NSString *)debugDescription { return [(NSObject *)self.target debugDescription]; }
- (BOOL)isEqual:(id)object { return [(NSObject *)self.target isEqual:object]; }
- (NSUInteger)hash { return [(NSObject *)self.target hash]; }

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    @autoreleasepool {
        [[VCAMParasiteCore sharedCore] parasiteInjectSampleBuffer:sampleBuffer];
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
            
            // 👑 微信级加固补丁：强行获取系统内存锁！
            // 微信会锁定这块内存防止第三方篡改，我们必须在底层声明“我们要写入这块物理内存”
            CVReturn lockStatus = CVPixelBufferLockBaseAddress(dstPix, 0);
            
            if (lockStatus == kCVReturnSuccess) {
                // 强制 GPU 执行格式转换与寄生覆写
                OSStatus status = VTPixelTransferSessionTransferImage(self.transferSession, srcPix, dstPix);
                
                // 覆写完毕，释放内存锁，还给微信
                CVPixelBufferUnlockBaseAddress(dstPix, 0);
                
                #if DEBUG
                if (status != noErr) {
                    NSLog(@"[VCAM 警告] 微信底层覆写失败，错误码: %d", (int)status);
                }
                #endif
            }
        }
        CVPixelBufferRelease(srcPix);
    }
}

// ============================================================================
// 【3.5 元数据致盲代理 (阻断原生人脸与画面撕裂)】
// ============================================================================
@interface VCAMMetadataProxy : NSProxy <AVCaptureMetadataOutputObjectsDelegate>
@property (nonatomic, weak) id target;
@end

@implementation VCAMMetadataProxy
+ (instancetype)proxyWithTarget:(id)target {
    VCAMMetadataProxy *proxy = [VCAMMetadataProxy alloc];
    proxy.target = target;
    return proxy;
}
- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel { return [(NSObject *)self.target methodSignatureForSelector:sel]; }
- (void)forwardInvocation:(NSInvocation *)invocation {
    if (self.target && [self.target respondsToSelector:invocation.selector]) { [invocation invokeWithTarget:self.target]; }
}
- (BOOL)respondsToSelector:(SEL)aSelector {
    if (aSelector == @selector(captureOutput:didOutputMetadataObjects:fromConnection:)) return YES;
    return [self.target respondsToSelector:aSelector];
}

- (Class)class { return [(NSObject *)self.target class]; }
- (Class)superclass { return [(NSObject *)self.target superclass]; }
- (NSString *)description { return [(NSObject *)self.target description]; }
- (NSString *)debugDescription { return [(NSObject *)self.target debugDescription]; }

// 👑 核心致盲拦截
- (void)captureOutput:(AVCaptureOutput *)output didOutputMetadataObjects:(NSArray<AVMetadataObject *> *)metadataObjects fromConnection:(AVCaptureConnection *)connection {
    @autoreleasepool {
        if ([VCAMParasiteCore sharedCore].isEnabled) {
            // VCAM 开启时，强行切断真实物理相机的人脸与条码数据，返回空数组
            if ([self.target respondsToSelector:_cmd]) {
                [(id<AVCaptureMetadataOutputObjectsDelegate>)self.target captureOutput:output didOutputMetadataObjects:@[] fromConnection:connection];
            }
        } else {
            // VCAM 关闭时，放行真实数据
            if ([self.target respondsToSelector:_cmd]) {
                [(id<AVCaptureMetadataOutputObjectsDelegate>)self.target captureOutput:output didOutputMetadataObjects:metadataObjects fromConnection:connection];
            }
        }
    }
}
@end

// ============================================================================
// 【4. 隐身控制台 (无痕操作)】
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
    
    [alert addAction:[UIAlertAction actionWithTitle:[VCAMParasiteCore sharedCore].isEnabled ? @"🟢 视频注入已开启 (点击关闭)" : @"🔴 视频注入已关闭 (点击开启)" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
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
    [picker dismissViewControllerAnimated:YES completion:^{
        if (url) {
            UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleRigid];
            [fb impactOccurred];
            
            [VCAMStealthPreprocessor processVideoAtURL:url completion:^(BOOL success) {
                if (success) {
                    [[VCAMParasiteCore sharedCore] loadVideo];
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        UIImpactFeedbackGenerator *fb2 = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleHeavy];
                        [fb2 impactOccurred];
                    });
                }
            }];
        }
    }];
}
@end

// ============================================================================
// 【5. 绝对安全的 Hook 注入】
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

@implementation UIWindow (VCAMStealthHook)
- (void)vcam_becomeKeyWindow {
    [self vcam_becomeKeyWindow];
    if (!objc_getAssociatedObject(self, "_vcam_ges")) {
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(vcam_handleTap:)];
        tap.numberOfTouchesRequired = 3; tap.numberOfTapsRequired = 1;
        [self addGestureRecognizer:tap];
        objc_setAssociatedObject(self, "_vcam_ges", @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}
- (void)vcam_handleTap:(UITapGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateRecognized) {
        [[VCAMStealthUIManager sharedManager] showStealthMenuInWindow:self];
        UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium]; [fb impactOccurred];
    }
}
@end

@implementation AVCaptureVideoDataOutput (VCAMStealthHook)
- (void)vcam_setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate queue:(dispatch_queue_t)queue {
    if (delegate && ![delegate isKindOfClass:NSClassFromString(@"VCAMStealthProxy")]) {
        VCAMStealthProxy *proxy = [VCAMStealthProxy proxyWithTarget:delegate];
        objc_setAssociatedObject(self, "_vcam_p", proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [self vcam_setSampleBufferDelegate:proxy queue:queue];
    } else {
        [self vcam_setSampleBufferDelegate:delegate queue:queue];
    }
}
@end

// 🌟 注入元数据致盲代理
@implementation AVCaptureMetadataOutput (VCAMStealthHook)
- (void)vcam_setMetadataObjectsDelegate:(id<AVCaptureMetadataOutputObjectsDelegate>)delegate queue:(dispatch_queue_t)queue {
    if (delegate && ![delegate isKindOfClass:NSClassFromString(@"VCAMMetadataProxy")]) {
        VCAMMetadataProxy *proxy = [VCAMMetadataProxy proxyWithTarget:delegate];
        objc_setAssociatedObject(self, "_vcam_meta_p", proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [self vcam_setMetadataObjectsDelegate:proxy queue:queue];
    } else {
        [self vcam_setMetadataObjectsDelegate:delegate queue:queue];
    }
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
    
    Class vdoClass = NSClassFromString(@"AVCaptureVideoDataOutput");
    if (vdoClass) {
        safe_swizzle(vdoClass, @selector(setSampleBufferDelegate:queue:), @selector(vcam_setSampleBufferDelegate:queue:));
    }
    
    // 🌟 启动元数据 Hook
    Class metaClass = NSClassFromString(@"AVCaptureMetadataOutput");
    if (metaClass) {
        safe_swizzle(metaClass, @selector(setMetadataObjectsDelegate:queue:), @selector(vcam_setMetadataObjectsDelegate:queue:));
    }
}
@end
#pragma clang diagnostic pop
