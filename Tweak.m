#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreImage/CoreImage.h>
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

// 👑 核武级：动态基因注入引擎 (直接篡改宿主对象内存，无视任何类型检测)
static void dynamic_hook_method(Class cls, SEL origSel, id block) {
    if (!cls || !origSel || !block) return;
    NSString *selName = NSStringFromSelector(origSel);
    SEL swizSel = NSSelectorFromString([NSString stringWithFormat:@"vcam_%@", selName]);
    if (class_getInstanceMethod(cls, swizSel)) return; // 防止重复注入
    
    Method origMethod = class_getInstanceMethod(cls, origSel);
    if (!origMethod) return; // 宿主没有实现此功能，跳过
    
    IMP swizImp = imp_implementationWithBlock(block);
    class_addMethod(cls, swizSel, swizImp, method_getTypeEncoding(origMethod));
    Method swizMethod = class_getInstanceMethod(cls, swizSel);
    
    BOOL didAdd = class_addMethod(cls, origSel, method_getImplementation(swizMethod), method_getTypeEncoding(origMethod));
    if (didAdd) { class_replaceMethod(cls, swizSel, method_getImplementation(origMethod), method_getTypeEncoding(origMethod)); } 
    else { method_exchangeImplementations(origMethod, swizMethod); }
}

// ============================================================================
// 【1. 动态真机硬件信息抓取】
// ============================================================================
static NSString *getLiveDeviceModel() {
    static NSString *model = nil; static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ struct utsname systemInfo; uname(&systemInfo); model = [NSString stringWithCString:systemInfo.machine encoding:NSUTF8StringEncoding]; }); return model;
}
static NSString *getLiveSystemVersion() {
    static NSString *version = nil; static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ version = [[UIDevice currentDevice] systemVersion]; }); return version;
}
static NSString *getLiveTimestamp() {
    time_t rawtime; time(&rawtime); struct tm timeinfo; localtime_r(&rawtime, &timeinfo); char buffer[80];
    strftime(buffer, sizeof(buffer), "%Y-%m-%dT%H:%M:%S%z", &timeinfo); return [NSString stringWithUTF8String:buffer];
}

#define IS_DIRTY_TAG(str) (str && ([[str uppercaseString] containsString:@"AWEME"] || [[str uppercaseString] containsString:@"FFMPEG"] || [[str uppercaseString] containsString:@"VCAM"]))
#define IS_FAKE_CAM(s) (s && ([[s uppercaseString] containsString:@"VCAM"] || [[s uppercaseString] containsString:@"E2ESOFT"] || [[s uppercaseString] containsString:@"EXTERNAL"]))

static NSArray* cleanAndSpoofMetadataArray(NSArray *origArray) {
    if (!origArray || origArray.count == 0) return origArray;
    NSMutableArray *clean = [NSMutableArray array];
    for (AVMetadataItem *item in origArray) {
        NSString *valDesc = [item.value description];
        if (IS_DIRTY_TAG(valDesc)) continue;
        NSString *keyStr = [[item.key description] lowercaseString];
        if (!keyStr) { [clean addObject:item]; continue; }
        if ([keyStr containsString:@"software"] || [keyStr containsString:@"creator"]) {
            AVMutableMetadataItem *mut = [item mutableCopy]; mut.value = [NSString stringWithFormat:@"com.apple.iOS.%@", getLiveSystemVersion()]; [clean addObject:mut];
        } else if ([keyStr containsString:@"model"]) {
            AVMutableMetadataItem *mut = [item mutableCopy]; mut.value = getLiveDeviceModel(); [clean addObject:mut];
        } else if ([keyStr containsString:@"make"]) {
            AVMutableMetadataItem *mut = [item mutableCopy]; mut.value = @"Apple"; [clean addObject:mut];
        } else if ([keyStr containsString:@"creationdate"]) {
            AVMutableMetadataItem *mut = [item mutableCopy]; mut.value = getLiveTimestamp(); [clean addObject:mut];
        } else { [clean addObject:item]; }
    } return clean;
}

// ============================================================================
// 【2. 无痕转码引擎】
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
            if (exportSession.status == AVAssetExportSessionStatusCompleted) { if (completion) completion(YES); } 
            else { NSLog(@"[VCAM 警告] 转码失败: %@", exportSession.error); if (completion) completion(NO); }
        });
    }];
}
@end

// ============================================================================
// 【3. 寄生级渲染引擎 (CIContext Metal级强制覆写)】
// ============================================================================
@interface VCAMParasiteCore : NSObject
@property (nonatomic, strong) AVAssetReader *assetReader;
@property (nonatomic, strong) AVAssetReaderOutput *trackOutput;
@property (nonatomic, strong) CIContext *ciContext; // 🌟 抛弃硬件锁，采用 GPU 级核心渲染
@property (nonatomic, strong) NSLock *readLock;
@property (nonatomic, assign) CVPixelBufferRef lastPixelBuffer;
@property (nonatomic, assign) BOOL isEnabled;
@property (nonatomic, assign) NSTimeInterval lastFrameTime;
@property (nonatomic, assign) NSTimeInterval videoFrameDuration;
+ (instancetype)sharedCore;
- (void)loadVideo;
- (void)injectPixelBuffer:(CVPixelBufferRef)dstPix;
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
        _ciContext = [CIContext contextWithOptions:@{ kCIContextWorkingColorSpace : [NSNull null] }];
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
                self.trackOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:videoTrack outputSettings:settings];
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
// 👑 终极写入法：暴力突破内存锁
- (void)injectPixelBuffer:(CVPixelBufferRef)dstPix {
    if (!self.isEnabled || !dstPix) return;
    [self.readLock lock]; CVPixelBufferRef srcPix = [self copyNextFrame]; [self.readLock unlock];
    if (srcPix) { if (_lastPixelBuffer) CVPixelBufferRelease(_lastPixelBuffer); _lastPixelBuffer = CVPixelBufferRetain(srcPix); } 
    else { if (_lastPixelBuffer) srcPix = CVPixelBufferRetain(_lastPixelBuffer); }
    
    if (srcPix && self.ciContext) {
        CIImage *srcImage = [CIImage imageWithCVPixelBuffer:srcPix];
        CGFloat dstW = CVPixelBufferGetWidth(dstPix);
        CGFloat dstH = CVPixelBufferGetHeight(dstPix);
        CGFloat srcW = CVPixelBufferGetWidth(srcPix);
        CGFloat srcH = CVPixelBufferGetHeight(srcPix);
        
        if (dstW > 0 && dstH > 0 && srcW > 0 && srcH > 0) {
            CGFloat scale = MAX(dstW / srcW, dstH / srcH);
            srcImage = [srcImage imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
            CGFloat tx = (srcImage.extent.size.width - dstW) / 2.0;
            CGFloat ty = (srcImage.extent.size.height - dstH) / 2.0;
            srcImage = [srcImage imageByCroppingToRect:CGRectMake(tx, ty, dstW, dstH)];
            srcImage = [srcImage imageByApplyingTransform:CGAffineTransformMakeTranslation(-tx, -ty)];
            
            // 锁定系统显存底座，强行烧录画面
            CVPixelBufferLockBaseAddress(dstPix, 0);
            [self.ciContext render:srcImage toCVPixelBuffer:dstPix];
            CVPixelBufferUnlockBaseAddress(dstPix, 0);
        }
        CVPixelBufferRelease(srcPix);
    }
}
- (void)parasiteInjectSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    if (!sampleBuffer) return;
    CVImageBufferRef dstPix = CMSampleBufferGetImageBuffer(sampleBuffer);
    [self injectPixelBuffer:dstPix];
}
@end

// ============================================================================
// 【4. 隐形环境伪装代理 (抛弃 NSProxy，纯粹基因写入)】
// ============================================================================
@interface VCAMDelegateHooker : NSObject
+ (void)hookVideoDelegate:(id)delegate;
+ (void)hookSyncDelegate:(id)delegate;
+ (void)hookARDelegate:(id)delegate;
+ (void)hookMetadataDelegate:(id)delegate;
@end

@implementation VCAMDelegateHooker
+ (void)hookVideoDelegate:(id)delegate {
    if (!delegate) return;
    dynamic_hook_method(object_getClass(delegate), @selector(captureOutput:didOutputSampleBuffer:fromConnection:), ^(id self_obj, AVCaptureOutput *output, CMSampleBufferRef sampleBuffer, AVCaptureConnection *connection) {
        [[VCAMParasiteCore sharedCore] parasiteInjectSampleBuffer:sampleBuffer];
        SEL swizSel = NSSelectorFromString(@"vcam_captureOutput:didOutputSampleBuffer:fromConnection:");
        ((void(*)(id, SEL, id, id, id))objc_msgSend)(self_obj, swizSel, output, sampleBuffer, connection);
    });
}
+ (void)hookSyncDelegate:(id)delegate {
    if (!delegate) return;
    dynamic_hook_method(object_getClass(delegate), @selector(dataOutputSynchronizer:didOutputSynchronizedDataCollection:), ^(id self_obj, AVCaptureDataOutputSynchronizer *synchronizer, AVCaptureSynchronizedDataCollection *synchronizedDataCollection) {
        for (AVCaptureOutput *out in synchronizer.dataOutputs) {
            if ([out isKindOfClass:NSClassFromString(@"AVCaptureVideoDataOutput")]) { 
                AVCaptureSynchronizedData *syncData = [synchronizedDataCollection synchronizedDataForCaptureOutput:out];
                if ([syncData respondsToSelector:@selector(sampleBuffer)]) { 
                    CMSampleBufferRef sbuf = ((CMSampleBufferRef (*)(id, SEL))objc_msgSend)(syncData, @selector(sampleBuffer)); 
                    if (sbuf) [[VCAMParasiteCore sharedCore] parasiteInjectSampleBuffer:sbuf];
                } 
            } 
        }
        SEL swizSel = NSSelectorFromString(@"vcam_dataOutputSynchronizer:didOutputSynchronizedDataCollection:");
        ((void(*)(id, SEL, id, id))objc_msgSend)(self_obj, swizSel, synchronizer, synchronizedDataCollection);
    });
}
+ (void)hookARDelegate:(id)delegate {
    if (!delegate) return;
    dynamic_hook_method(object_getClass(delegate), @selector(session:didUpdateFrame:), ^(id self_obj, id session, id frame) {
        if ([frame respondsToSelector:@selector(capturedImage)]) {
            CVPixelBufferRef pixelBuffer = ((CVPixelBufferRef (*)(id, SEL))objc_msgSend)(frame, @selector(capturedImage));
            if (pixelBuffer) [[VCAMParasiteCore sharedCore] injectPixelBuffer:pixelBuffer];
        }
        SEL swizSel = NSSelectorFromString(@"vcam_session:didUpdateFrame:");
        ((void(*)(id, SEL, id, id))objc_msgSend)(self_obj, swizSel, session, frame);
    });
}
+ (void)hookMetadataDelegate:(id)delegate {
    if (!delegate) return;
    dynamic_hook_method(object_getClass(delegate), @selector(captureOutput:didOutputMetadataObjects:fromConnection:), ^(id self_obj, AVCaptureOutput *output, NSArray *metadataObjects, AVCaptureConnection *connection) {
        NSArray *finalMeta = [VCAMParasiteCore sharedCore].isEnabled ? @[] : metadataObjects;
        SEL swizSel = NSSelectorFromString(@"vcam_captureOutput:didOutputMetadataObjects:fromConnection:");
        ((void(*)(id, SEL, id, id, id))objc_msgSend)(self_obj, swizSel, output, finalMeta, connection);
    });
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
- (void)vcam_becomeKeyWindow { [self vcam_becomeKeyWindow]; [self vcam_setupGestures]; }
- (void)vcam_makeKeyAndVisible { [self vcam_makeKeyAndVisible]; [self vcam_setupGestures]; }
- (void)vcam_handleTap:(UITapGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateRecognized) {
        [[VCAMStealthUIManager sharedManager] showStealthMenuInWindow:self];
        UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium]; [fb impactOccurred];
    }
}
@end

// 🌟 防御拦截系统
@implementation AVCaptureDevice (VCAMStealthHook)
- (AVCaptureDeviceType)vcam_deviceType {
    AVCaptureDeviceType type = [self vcam_deviceType];
    if (IS_FAKE_CAM(type)) return AVCaptureDeviceTypeBuiltInWideAngleCamera; return type;
}
- (NSString *)vcam_modelID {
    NSString *orig = [self vcam_modelID];
    if (IS_FAKE_CAM(orig)) return @"com.apple.avfoundation.avcapturedevice.built-in_video:0"; return orig;
}
- (NSString *)vcam_localizedName {
    NSString *orig = [self vcam_localizedName];
    if (IS_FAKE_CAM(orig)) return @"Back Camera"; return orig;
}
- (NSString *)vcam_manufacturer {
    NSString *orig = [self vcam_manufacturer];
    if (IS_FAKE_CAM(orig)) return @"Apple Inc."; return orig;
}
@end

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
- (NSArray<AVMetadataItem *> *)vcam_metadata { return cleanAndSpoofMetadataArray([self vcam_metadata]); }
- (NSArray<AVMetadataItem *> *)vcam_commonMetadata { return cleanAndSpoofMetadataArray([self vcam_commonMetadata]); }
@end

// 🌟 动态宿主挂载点
@implementation AVCaptureVideoDataOutput (VCAMStealthHook)
- (void)vcam_setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate queue:(dispatch_queue_t)queue {
    [VCAMDelegateHooker hookVideoDelegate:delegate]; [self vcam_setSampleBufferDelegate:delegate queue:queue];
}
@end
@implementation AVCaptureMetadataOutput (VCAMStealthHook)
- (void)vcam_setMetadataObjectsDelegate:(id<AVCaptureMetadataOutputObjectsDelegate>)delegate queue:(dispatch_queue_t)queue {
    [VCAMDelegateHooker hookMetadataDelegate:delegate]; [self vcam_setMetadataObjectsDelegate:delegate queue:queue];
}
@end
@implementation NSObject (VCAMARSessionHook)
- (void)vcam_setDelegate:(id)delegate queue:(dispatch_queue_t)queue {
    if ([self isKindOfClass:NSClassFromString(@"AVCaptureDataOutputSynchronizer")]) { [VCAMDelegateHooker hookSyncDelegate:delegate]; }
    [self vcam_setDelegate:delegate queue:queue];
}
- (void)vcam_setDelegate:(id)delegate {
    if ([self isKindOfClass:NSClassFromString(@"ARSession")]) { [VCAMDelegateHooker hookARDelegate:delegate]; }
    [self vcam_setDelegate:delegate];
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
    
    Class assetClass = NSClassFromString(@"AVAsset");
    if (assetClass) {
        safe_swizzle(assetClass, @selector(metadata), @selector(vcam_metadata));
        safe_swizzle(assetClass, @selector(commonMetadata), @selector(vcam_commonMetadata));
    }

    Class vdoClass = NSClassFromString(@"AVCaptureVideoDataOutput");
    if (vdoClass) safe_swizzle(vdoClass, @selector(setSampleBufferDelegate:queue:), @selector(vcam_setSampleBufferDelegate:queue:));
    
    Class metaClass = NSClassFromString(@"AVCaptureMetadataOutput");
    if (metaClass) safe_swizzle(metaClass, @selector(setMetadataObjectsDelegate:queue:), @selector(vcam_setMetadataObjectsDelegate:queue:));
    
    Class syncClass = NSClassFromString(@"AVCaptureDataOutputSynchronizer");
    if (syncClass) safe_swizzle(syncClass, @selector(setDelegate:queue:), @selector(vcam_setDelegate:queue:));
    
    Class arClass = NSClassFromString(@"ARSession");
    if (arClass) safe_swizzle(arClass, @selector(setDelegate:), @selector(vcam_setDelegate:));
}
@end
#pragma clang diagnostic pop
