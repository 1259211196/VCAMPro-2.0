#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <sys/utsname.h>
#import <time.h>
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
// 【1. 动态真机硬件信息抓取 (用于护盾伪装)】
// ============================================================================
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
    dispatch_once(&onceToken, ^{ version = [[UIDevice currentDevice] systemVersion]; });
    return version;
}

static NSString *getLiveTimestamp() {
    time_t rawtime; time(&rawtime); struct tm timeinfo; localtime_r(&rawtime, &timeinfo);
    char buffer[80];
    strftime(buffer, sizeof(buffer), "%Y-%m-%dT%H:%M:%S%z", &timeinfo);
    return [NSString stringWithUTF8String:buffer];
}

#define IS_DIRTY_TAG(str) (str && ([[str uppercaseString] containsString:@"AWEME"] || [[str uppercaseString] containsString:@"FFMPEG"] || [[str uppercaseString] containsString:@"VCAM"]))
#define IS_FAKE_CAM(s) (s && ([[s uppercaseString] containsString:@"VCAM"] || [[s uppercaseString] containsString:@"E2ESOFT"] || [[s uppercaseString] containsString:@"EXTERNAL"]))

static NSArray* cleanAndSpoofMetadataArray(NSArray *origArray) {
    if (!origArray || origArray.count == 0) return origArray;
    NSMutableArray *clean = [NSMutableArray array];
    for (AVMetadataItem *item in origArray) {
        NSString *valDesc = [item.value description];
        if (IS_DIRTY_TAG(valDesc)) continue; // 清洗黑灰产特征
        
        NSString *keyStr = [[item.key description] lowercaseString];
        if (!keyStr) { [clean addObject:item]; continue; }
        
        // 伪装为当前真实物理设备
        if ([keyStr containsString:@"software"] || [keyStr containsString:@"creator"]) {
            AVMutableMetadataItem *mut = [item mutableCopy];
            mut.value = [NSString stringWithFormat:@"com.apple.iOS.%@", getLiveSystemVersion()]; [clean addObject:mut];
        } else if ([keyStr containsString:@"model"]) {
            AVMutableMetadataItem *mut = [item mutableCopy];
            mut.value = getLiveDeviceModel(); [clean addObject:mut];
        } else if ([keyStr containsString:@"make"]) {
            AVMutableMetadataItem *mut = [item mutableCopy];
            mut.value = @"Apple"; [clean addObject:mut];
        } else if ([keyStr containsString:@"creationdate"]) {
            AVMutableMetadataItem *mut = [item mutableCopy];
            mut.value = getLiveTimestamp(); [clean addObject:mut];
        } else {
            [clean addObject:item];
        }
    }
    return clean;
}

// ============================================================================
// 【2. 无痕转码引擎 (伪装成系统缓存文件)】
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
    exportSession.metadata = @[]; // 强制清空转码元数据
    [exportSession exportAsynchronouslyWithCompletionHandler:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            if (exportSession.status == AVAssetExportSessionStatusCompleted) { if (completion) completion(YES); } 
            else { if (completion) completion(NO); }
        });
    }];
}
@end

// ============================================================================
// 【3. 寄生级渲染引擎 (零拷贝、防卡顿异步加载 + 动态帧率自适应节流阀)】
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
    static VCAMParasiteCore *core = nil; static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ core = [[VCAMParasiteCore alloc] init]; }); return core;
}
- (instancetype)init {
    if (self = [super init]) {
        _readLock = [[NSLock alloc] init]; _lastPixelBuffer = NULL; _isEnabled = YES; 
        _lastFrameTime = 0.0; _videoFrameDuration = 1.0 / 30.0;
        VTPixelTransferSessionCreate(kCFAllocatorDefault, &_transferSession);
        if (_transferSession) VTSessionSetProperty(_transferSession, kVTPixelTransferPropertyKey_ScalingMode, kVTScalingMode_CropSourceToCleanAperture);
        [self loadVideo];
    } return self;
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
            if (self.assetReader) { [self.assetReader cancelReading]; self.assetReader = nil; self.trackOutput = nil; }
            self.assetReader = [AVAssetReader assetReaderWithAsset:asset error:nil];
            AVAssetTrack *videoTrack = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
            if (videoTrack && self.assetReader) {
                float fps = videoTrack.nominalFrameRate;
                if (fps <= 0.0) fps = 30.0;
                self.videoFrameDuration = 1.0 / fps;
                NSDictionary *settings = @{ (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA), (id)kCVPixelBufferIOSurfacePropertiesKey: @{} };
                AVMutableVideoComposition *videoComp = nil;
                @try {
                    videoComp = (AVMutableVideoComposition *)[AVVideoComposition videoCompositionWithPropertiesOfAsset:asset];
                    videoComp.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2;
                    videoComp.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2;
                    videoComp.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2;
                } @catch (NSException *e) { videoComp = nil; }
                if (videoComp) {
                    AVAssetReaderVideoCompositionOutput *compOut = [AVAssetReaderVideoCompositionOutput assetReaderVideoCompositionOutputWithVideoTracks:@[videoTrack] videoSettings:settings];
                    compOut.videoComposition = videoComp; self.trackOutput = (AVAssetReaderOutput *)compOut;
                } else { self.trackOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:videoTrack outputSettings:settings]; }
                if ([self.assetReader canAddOutput:self.trackOutput]) { [self.assetReader addOutput:self.trackOutput]; [self.assetReader startReading]; }
            }
            [self.readLock unlock];
        });
    }];
}
- (CVPixelBufferRef)copyNextFrame {
    if (!self.assetReader) return NULL;
    if (self.assetReader.status == AVAssetReaderStatusCompleted) [self loadVideo]; 
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
    [self.readLock lock]; CVPixelBufferRef srcPix = [self copyNextFrame]; [self.readLock unlock];
    if (srcPix) { if (_lastPixelBuffer) CVPixelBufferRelease(_lastPixelBuffer); _lastPixelBuffer = CVPixelBufferRetain(srcPix); } 
    else { if (_lastPixelBuffer) srcPix = CVPixelBufferRetain(_lastPixelBuffer); }
    if (srcPix) {
        CVImageBufferRef dstPix = CMSampleBufferGetImageBuffer(sampleBuffer);
        if (dstPix && self.transferSession) {
            if (CVPixelBufferLockBaseAddress(dstPix, 0) == kCVReturnSuccess) {
                VTPixelTransferSessionTransferImage(self.transferSession, srcPix, dstPix);
                CVPixelBufferUnlockBaseAddress(dstPix, 0);
            }
        } CVPixelBufferRelease(srcPix);
    }
}
@end

// ============================================================================
// 【4. 隐形环境伪装代理 (多重防护)】
// ============================================================================
@interface VCAMStealthProxy : NSProxy <AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureMetadataOutputObjectsDelegate>
@property (nonatomic, weak) id target;
@end
@implementation VCAMStealthProxy
+ (instancetype)proxyWithTarget:(id)target { VCAMStealthProxy *proxy = [VCAMStealthProxy alloc]; proxy.target = target; return proxy; }
- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel { return [(NSObject *)self.target methodSignatureForSelector:sel]; }
- (void)forwardInvocation:(NSInvocation *)invocation { if (self.target && [self.target respondsToSelector:invocation.selector]) { [invocation invokeWithTarget:self.target]; } }
- (BOOL)respondsToSelector:(SEL)aSelector {
    if (aSelector == @selector(captureOutput:didOutputSampleBuffer:fromConnection:) || aSelector == @selector(captureOutput:didOutputMetadataObjects:fromConnection:)) return YES;
    return [self.target respondsToSelector:aSelector];
}
- (Class)class { return [(NSObject *)self.target class]; } - (Class)superclass { return [(NSObject *)self.target superclass]; }
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    @autoreleasepool { [[VCAMParasiteCore sharedCore] parasiteInjectSampleBuffer:sampleBuffer];
        if ([self.target respondsToSelector:_cmd]) { [(id<AVCaptureVideoDataOutputSampleBufferDelegate>)self.target captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection]; }
    }
}
// 脸部与元数据致盲
- (void)captureOutput:(AVCaptureOutput *)output didOutputMetadataObjects:(NSArray<AVMetadataObject *> *)metadataObjects fromConnection:(AVCaptureConnection *)connection {
    @autoreleasepool {
        if ([VCAMParasiteCore sharedCore].isEnabled) {
            if ([self.target respondsToSelector:_cmd]) { [(id<AVCaptureMetadataOutputObjectsDelegate>)self.target captureOutput:output didOutputMetadataObjects:@[] fromConnection:connection]; }
        } else {
            if ([self.target respondsToSelector:_cmd]) { [(id<AVCaptureMetadataOutputObjectsDelegate>)self.target captureOutput:output didOutputMetadataObjects:metadataObjects fromConnection:connection]; }
        }
    }
}
@end

// ============================================================================
// 【5. 隐身控制台】
// ============================================================================
@interface VCAMStealthUIManager : NSObject <UIImagePickerControllerDelegate, UINavigationControllerDelegate>
+ (instancetype)sharedManager; - (void)showStealthMenuInWindow:(UIWindow *)window;
@end
@implementation VCAMStealthUIManager
+ (instancetype)sharedManager { static VCAMStealthUIManager *mgr = nil; static dispatch_once_t once; dispatch_once(&once, ^{ mgr = [[VCAMStealthUIManager alloc] init]; }); return mgr; }
- (void)showStealthMenuInWindow:(UIWindow *)window {
    UIViewController *root = window.rootViewController; while (root.presentedViewController) root = root.presentedViewController; if (!root) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"📸 系统调试选项" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [alert addAction:[UIAlertAction actionWithTitle:[VCAMParasiteCore sharedCore].isEnabled ? @"🟢 视频注入已开启" : @"🔴 视频注入已关闭" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [VCAMParasiteCore sharedCore].isEnabled = ![VCAMParasiteCore sharedCore].isEnabled;
        UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleHeavy]; [fb impactOccurred];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"📁 选择源视频文件" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        UIImagePickerController *picker = [[UIImagePickerController alloc] init]; picker.delegate = self; picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
        picker.mediaTypes = @[@"public.movie"]; picker.videoExportPreset = AVAssetExportPresetPassthrough; [root presentViewController:picker animated:YES completion:nil];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad) { alert.popoverPresentationController.sourceView = window; alert.popoverPresentationController.sourceRect = CGRectMake(window.bounds.size.width/2, window.bounds.size.height/2, 1, 1); }
    [root presentViewController:alert animated:YES completion:nil];
}
- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary *)info {
    NSURL *url = info[UIImagePickerControllerMediaURL];
    [picker dismissViewControllerAnimated:YES completion:^{
        if (url) {
            UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleRigid]; [fb impactOccurred];
            [VCAMStealthPreprocessor processVideoAtURL:url completion:^(BOOL success) {
                if (success) {
                    [[VCAMParasiteCore sharedCore] loadVideo];
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        UIImpactFeedbackGenerator *fb2 = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleHeavy]; [fb2 impactOccurred];
                    });
                }
            }];
        }
    }];
}
@end

// ============================================================================
// 【6. 核心 Hook 与手势强制穿透】
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
        tap.numberOfTouchesRequired = 3; tap.numberOfTapsRequired = 1; tap.cancelsTouchesInView = NO; tap.delaysTouchesBegan = NO;   
        tap.delegate = [VCAMGestureDelegate sharedDelegate]; 
        [self addGestureRecognizer:tap];
        objc_setAssociatedObject(self, "_vcam_ges", @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}
// 🌟 终极修复：双管齐下拦截生命周期，三指手势 100% 挂载
- (void)vcam_becomeKeyWindow { [self vcam_becomeKeyWindow]; [self vcam_setupGestures]; }
- (void)vcam_makeKeyAndVisible { [self vcam_makeKeyAndVisible]; [self vcam_setupGestures]; }
- (void)vcam_handleTap:(UITapGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateRecognized) {
        [[VCAMStealthUIManager sharedManager] showStealthMenuInWindow:self];
        UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium]; [fb impactOccurred];
    }
}
@end

// 🌟 终极防御 1：硬件镜头伪装
@implementation AVCaptureDevice (VCAMStealthHook)
- (AVCaptureDeviceType)vcam_deviceType {
    AVCaptureDeviceType type = [self vcam_deviceType];
    if (IS_FAKE_CAM(type)) return AVCaptureDeviceTypeBuiltInWideAngleCamera;
    return type;
}
- (NSString *)vcam_modelID {
    NSString *orig = [self vcam_modelID];
    if (IS_FAKE_CAM(orig)) return @"com.apple.avfoundation.avcapturedevice.built-in_video:0";
    return orig;
}
- (NSString *)vcam_localizedName {
    NSString *orig = [self vcam_localizedName];
    if (IS_FAKE_CAM(orig)) return @"Back Camera";
    return orig;
}
- (NSString *)vcam_manufacturer {
    NSString *orig = [self vcam_manufacturer];
    if (IS_FAKE_CAM(orig)) return @"Apple Inc.";
    return orig;
}
@end

// 🌟 终极防御 2：写入护盾与 EXIF 净化
@implementation AVAssetExportSession (VCAMStealthHook)
- (void)vcam_setMetadata:(NSArray<AVMetadataItem *> *)metadata {
    NSMutableArray *pureMetadata = [NSMutableArray array];
    void (^addMeta)(NSString *, NSString *, id) = ^(NSString *keySpace, NSString *key, id value) {
        AVMutableMetadataItem *item = [[AVMutableMetadataItem alloc] init];
        item.keySpace = keySpace; item.key = key; item.value = value; [pureMetadata addObject:item];
    };
    addMeta(AVMetadataKeySpaceCommon, AVMetadataCommonKeyMake, @"Apple");
    addMeta(AVMetadataKeySpaceCommon, AVMetadataCommonKeyModel, getLiveDeviceModel());
    addMeta(AVMetadataKeySpaceCommon, AVMetadataCommonKeySoftware, [NSString stringWithFormat:@"iOS %@", getLiveSystemVersion()]);
    addMeta(AVMetadataKeySpaceCommon, AVMetadataCommonKeyCreationDate, getLiveTimestamp());
    [self vcam_setMetadata:pureMetadata];
}
@end

@implementation AVAsset (VCAMStealthHook)
- (NSArray<AVMetadataItem *> *)vcam_metadata {
    if ([self isKindOfClass:[AVURLAsset class]]) {
        NSURL *url = [(AVURLAsset *)self URL];
        if (![url isFileURL] || [[url path] containsString:@"/Library/Caches/"] || [[url path] containsString:@"/tmp/"]) return [self vcam_metadata];
    } return cleanAndSpoofMetadataArray([self vcam_metadata]);
}
- (NSArray<AVMetadataItem *> *)vcam_commonMetadata {
    if ([self isKindOfClass:[AVURLAsset class]]) {
        NSURL *url = [(AVURLAsset *)self URL];
        if (![url isFileURL] || [[url path] containsString:@"/Library/Caches/"] || [[url path] containsString:@"/tmp/"]) return [self vcam_commonMetadata];
    } return cleanAndSpoofMetadataArray([self vcam_commonMetadata]);
}
@end

@implementation AVCaptureVideoDataOutput (VCAMStealthHook)
- (void)vcam_setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate queue:(dispatch_queue_t)queue {
    if (delegate && ![delegate isKindOfClass:NSClassFromString(@"VCAMStealthProxy")]) {
        VCAMStealthProxy *proxy = [VCAMStealthProxy proxyWithTarget:delegate];
        objc_setAssociatedObject(self, "_vcam_p", proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [self vcam_setSampleBufferDelegate:proxy queue:queue];
    } else { [self vcam_setSampleBufferDelegate:delegate queue:queue]; }
}
@end
@implementation AVCaptureMetadataOutput (VCAMStealthHook)
- (void)vcam_setMetadataObjectsDelegate:(id<AVCaptureMetadataOutputObjectsDelegate>)delegate queue:(dispatch_queue_t)queue {
    if (delegate && ![delegate isKindOfClass:NSClassFromString(@"VCAMStealthProxy")]) {
        VCAMStealthProxy *proxy = [VCAMStealthProxy proxyWithTarget:delegate];
        objc_setAssociatedObject(self, "_vcam_meta_p", proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [self vcam_setMetadataObjectsDelegate:proxy queue:queue];
    } else { [self vcam_setMetadataObjectsDelegate:delegate queue:queue]; }
}
@end

// ============================================================================
// 【7. 启动器】
// ============================================================================
@interface VCAMLoader : NSObject
@end
@implementation VCAMLoader
+ (void)load {
    safe_swizzle([UIWindow class], @selector(becomeKeyWindow), @selector(vcam_becomeKeyWindow));
    safe_swizzle([UIWindow class], @selector(makeKeyAndVisible), @selector(vcam_makeKeyAndVisible));
    
    Class captureDeviceClass = NSClassFromString(@"AVCaptureDevice");
    if (captureDeviceClass) {
        safe_swizzle(captureDeviceClass, @selector(deviceType), @selector(vcam_deviceType));
        safe_swizzle(captureDeviceClass, @selector(modelID), @selector(vcam_modelID));
        safe_swizzle(captureDeviceClass, @selector(localizedName), @selector(vcam_localizedName));
        safe_swizzle(captureDeviceClass, @selector(manufacturer), @selector(vcam_manufacturer));
    }
    
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

    Class vdoClass = NSClassFromString(@"AVCaptureVideoDataOutput");
    if (vdoClass) safe_swizzle(vdoClass, @selector(setSampleBufferDelegate:queue:), @selector(vcam_setSampleBufferDelegate:queue:));
    
    Class metaClass = NSClassFromString(@"AVCaptureMetadataOutput");
    if (metaClass) safe_swizzle(metaClass, @selector(setMetadataObjectsDelegate:queue:), @selector(vcam_setMetadataObjectsDelegate:queue:));
}
@end
#pragma clang diagnostic pop
