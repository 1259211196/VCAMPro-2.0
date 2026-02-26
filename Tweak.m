#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>
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
    // 伪装文件名，存放在 tmp 目录，看起来像普通的系统多媒体缓存，防止沙盒扫描
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
// 【2. 寄生级渲染引擎 (零拷贝、零元数据破坏)】
// ============================================================================
@interface VCAMParasiteCore : NSObject
@property (nonatomic, strong) AVAssetReader *assetReader;
@property (nonatomic, strong) AVAssetReaderOutput *trackOutput;
@property (nonatomic, assign) VTPixelTransferSessionRef transferSession;
@property (nonatomic, strong) NSLock *readLock;
@property (nonatomic, assign) CVPixelBufferRef lastPixelBuffer;
@property (nonatomic, assign) BOOL isEnabled;
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
        
        // 建立底层 GPU 高速传输通道
        VTPixelTransferSessionCreate(kCFAllocatorDefault, &_transferSession);
        if (_transferSession) {
            // 确保画面完美填充，无黑边，不引起视觉风控怀疑
            VTSessionSetProperty(_transferSession, kVTPixelTransferPropertyKey_ScalingMode, kVTScalingMode_CropSourceToCleanAperture);
        }
        [self loadVideo];
    }
    return self;
}

- (void)loadVideo {
    [self.readLock lock];
    if (self.assetReader) { [self.assetReader cancelReading]; self.assetReader = nil; self.trackOutput = nil; }
    
    NSString *videoPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"com.apple.avfoundation.videocache.tmp"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:videoPath]) {
        [self.readLock unlock];
        return;
    }
    
    AVAsset *asset = [AVAsset assetWithURL:[NSURL fileURLWithPath:videoPath]];
    self.assetReader = [AVAssetReader assetReaderWithAsset:asset error:nil];
    AVAssetTrack *videoTrack = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    
    if (videoTrack && self.assetReader) {
        // 强制输出与相机底层相同的 32BGRA 格式，完美贴合
        NSDictionary *settings = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)};
        self.trackOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:videoTrack outputSettings:settings];
        if ([self.assetReader canAddOutput:self.trackOutput]) {
            [self.assetReader addOutput:self.trackOutput];
            [self.assetReader startReading];
        }
    }
    [self.readLock unlock];
}

- (CVPixelBufferRef)copyNextFrame {
    if (!self.assetReader) return NULL;
    
    if (self.assetReader.status == AVAssetReaderStatusCompleted) {
        [self loadVideo]; 
    }
    
    if (self.assetReader.status == AVAssetReaderStatusReading) {
        CMSampleBufferRef sbuf = [self.trackOutput copyNextSampleBuffer];
        if (sbuf) {
            CVPixelBufferRef pix = CMSampleBufferGetImageBuffer(sbuf);
            if (pix) CVPixelBufferRetain(pix);
            CFRelease(sbuf);
            return pix;
        } else {
            [self loadVideo];
        }
    }
    return NULL;
}

// 👑 核心：寄生注入逻辑
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
        // 获取原生相机帧的原始内存地址
        CVImageBufferRef dstPix = CMSampleBufferGetImageBuffer(sampleBuffer);
        
        // 【降维打击点】：我们不新建 Buffer，不修改时间戳。
        // 直接动用 GPU 硬件，把我们准备好的图像像素，硬生生“覆盖”在相机原生内存上！
        // 这样，苹果底层赋予这一帧的所有 ISP 元数据、曝光数据、时间戳 100% 得到了保留！
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
- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel { return [self.target methodSignatureForSelector:sel]; }
- (void)forwardInvocation:(NSInvocation *)invocation {
    if (self.target && [self.target respondsToSelector:invocation.selector]) {
        [invocation invokeWithTarget:self.target];
    }
}
- (BOOL)respondsToSelector:(SEL)aSelector {
    if (aSelector == @selector(captureOutput:didOutputSampleBuffer:fromConnection:)) return YES;
    return [self.target respondsToSelector:aSelector];
}

// 👑 深度类伪装：即使 TikTok 遍历代理的类名，返回的也是原生的类名！
- (Class)class { return [self.target class]; }
- (Class)superclass { return [self.target superclass]; }
- (NSString *)description { return [self.target description]; }
- (NSString *)debugDescription { return [self.target debugDescription]; }
- (BOOL)isEqual:(id)object { return [self.target isEqual:object]; }
- (NSUInteger)hash { return [self.target hash]; }

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    @autoreleasepool {
        // 触发寄生渲染
        [[VCAMParasiteCore sharedCore] parasiteInjectSampleBuffer:sampleBuffer];
        // 放行给原生逻辑
        if ([self.target respondsToSelector:_cmd]) {
            [self.target captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection];
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
    
    // 原生 Alert，不添加任何第三方自定义 View，避免被扫描 UI 层级
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
            // 移除了高调的屏幕 Toast，仅使用震动反馈。安全第一。
            UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleRigid];
            [fb impactOccurred];
            
            [VCAMStealthPreprocessor processVideoAtURL:url completion:^(BOOL success) {
                if (success) {
                    [[VCAMParasiteCore sharedCore] loadVideo];
                    // 处理完成，双震动提示
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
        // 三指单点，呼出极其隐蔽的控制台
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
- (void)vcam_setSampleBufferDelegate:(id)delegate queue:(dispatch_queue_t)queue {
    if (delegate && ![delegate isKindOfClass:NSClassFromString(@"VCAMStealthProxy")]) {
        VCAMStealthProxy *proxy = [VCAMStealthProxy proxyWithTarget:delegate];
        objc_setAssociatedObject(self, "_vcam_p", proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [self vcam_setSampleBufferDelegate:proxy queue:queue];
    } else {
        [self vcam_setSampleBufferDelegate:delegate queue:queue];
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
}
@end
#pragma clang diagnostic pop
