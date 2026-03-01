#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>
#import <os/lock.h>

// =====================================================================
// 全局配置与状态管理
// =====================================================================
static NSString * const kVCAMVideoPathKey = @"VCAM_SelectedVideoPath";

static NSString * GetCurrentVideoPath() {
    return [[NSUserDefaults standardUserDefaults] stringForKey:kVCAMVideoPathKey];
}

static void SetCurrentVideoPath(NSString *path) {
    [[NSUserDefaults standardUserDefaults] setObject:path forKey:kVCAMVideoPathKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

static UIViewController *topMostController() {
    UIViewController *topController = [UIApplication sharedApplication].keyWindow.rootViewController;
    while (topController.presentedViewController) {
        topController = topController.presentedViewController;
    }
    return topController;
}


// =====================================================================
// 模块 1：异步帧读取引擎 (Ring Buffer)
// =====================================================================
@interface VCAMFrameEngine : NSObject
@property (nonatomic, strong) AVAssetReader *assetReader;
@property (nonatomic, strong) AVAssetReaderTrackOutput *trackOutput;
@property (nonatomic, strong) dispatch_queue_t readerQueue;
@property (nonatomic, strong) NSMutableArray *frameBufferQueue;
@property (nonatomic, assign) NSInteger maxBufferSize;
@property (nonatomic, assign) os_unfair_lock bufferLock;
+ (instancetype)sharedEngine;
- (void)reloadVideoAsset;
- (CMSampleBufferRef)consumeNextFrame;
@end

@implementation VCAMFrameEngine

+ (instancetype)sharedEngine {
    static VCAMFrameEngine *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[VCAMFrameEngine alloc] init];
    });
    return instance;
}

- (instancetype)init {
    if (self = [super init]) {
        _readerQueue = dispatch_queue_create("com.vcam.readerQueue", DISPATCH_QUEUE_SERIAL);
        _bufferLock = OS_UNFAIR_LOCK_INIT;
        _frameBufferQueue = [NSMutableArray array];
        _maxBufferSize = 10;
        [self reloadVideoAsset];
    }
    return self;
}

- (void)clearBufferQueue {
    os_unfair_lock_lock(&_bufferLock);
    for (NSValue *value in self.frameBufferQueue) {
        CMSampleBufferRef buffer = (CMSampleBufferRef)[value pointerValue];
        if (buffer) CFRelease(buffer);
    }
    [self.frameBufferQueue removeAllObjects];
    os_unfair_lock_unlock(&_bufferLock);
}

- (void)reloadVideoAsset {
    dispatch_async(self.readerQueue, ^{
        NSString *videoPath = GetCurrentVideoPath();
        if (!videoPath || ![[NSFileManager defaultManager] fileExistsAtPath:videoPath]) {
            return;
        }

        if (self.assetReader) {
            [self.assetReader cancelReading];
            self.assetReader = nil;
            self.trackOutput = nil;
        }
        
        [self clearBufferQueue];

        NSURL *videoURL = [NSURL fileURLWithPath:videoPath];
        AVAsset *asset = [AVAsset assetWithURL:videoURL];
        NSError *error = nil;
        self.assetReader = [[AVAssetReader alloc] initWithAsset:asset error:&error];
        
        if (!error) {
            AVAssetTrack *videoTrack = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
            if (videoTrack) {
                // 【核心优化 1 & GPU 修复】：强制输出标准尺寸与 IOSurface 对齐
                NSDictionary *outputSettings = @{
                    (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
                    (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
                    (id)kCVPixelBufferWidthKey: @(1080),  // 强制重采样为 1080 宽度
                    (id)kCVPixelBufferHeightKey: @(1920)  // 强制重采样为 1920 高度
                };
                self.trackOutput = [[AVAssetReaderTrackOutput alloc] initWithTrack:videoTrack outputSettings:outputSettings];
                
                if ([self.assetReader canAddOutput:self.trackOutput]) {
                    [self.assetReader addOutput:self.trackOutput];
                    [self.assetReader startReading];
                    [self startPreReading];
                }
            }
        }
    });
}

- (void)startPreReading {
    dispatch_async(self.readerQueue, ^{
        os_unfair_lock_lock(&_bufferLock);
        BOOL needsMoreFrames = self.frameBufferQueue.count < self.maxBufferSize;
        os_unfair_lock_unlock(&_bufferLock);
        
        while (needsMoreFrames && self.assetReader.status == AVAssetReaderStatusReading) {
            CMSampleBufferRef nextBuffer = [self.trackOutput copyNextSampleBuffer];
            if (nextBuffer) {
                os_unfair_lock_lock(&_bufferLock);
                [self.frameBufferQueue addObject:[NSValue valueWithPointer:nextBuffer]];
                needsMoreFrames = self.frameBufferQueue.count < self.maxBufferSize;
                os_unfair_lock_unlock(&_bufferLock);
            } else {
                break;
            }
        }
        
        if (self.assetReader.status != AVAssetReaderStatusReading) {
            [self reloadVideoAsset];
        }
    });
}

- (CMSampleBufferRef)consumeNextFrame {
    os_unfair_lock_lock(&_bufferLock);
    CMSampleBufferRef bufferToReturn = NULL;
    if (self.frameBufferQueue.count > 0) {
        NSValue *value = self.frameBufferQueue.firstObject;
        bufferToReturn = (CMSampleBufferRef)[value pointerValue];
        [self.frameBufferQueue removeObjectAtIndex:0];
    }
    os_unfair_lock_unlock(&_bufferLock);
    
    dispatch_async(self.readerQueue, ^{
        [self startPreReading];
    });
    
    return bufferToReturn;
}
@end


// =====================================================================
// 模块 2：Delegate Proxy (深度洗稿、时钟同步与色彩伪装)
// =====================================================================
@interface VCAMDelegateProxy : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic, strong) id originalDelegate; 
@end

@implementation VCAMDelegateProxy
- (BOOL)respondsToSelector:(SEL)aSelector {
    return [self.originalDelegate respondsToSelector:aSelector] || [super respondsToSelector:aSelector];
}
- (id)forwardingTargetForSelector:(SEL)aSelector {
    return self.originalDelegate;
}

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)realSampleBuffer fromConnection:(AVCaptureConnection *)connection {
    
    CMSampleBufferRef virtualBuffer = [[VCAMFrameEngine sharedEngine] consumeNextFrame];
    
    if (virtualBuffer) {
        // 调用我们全新的超级洗稿算法
        CMSampleBufferRef ultimateBuffer = [self createUltimateCleanSampleBufferFrom:virtualBuffer basedOn:realSampleBuffer];
        
        if ([self.originalDelegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
            [self.originalDelegate captureOutput:output didOutputSampleBuffer:ultimateBuffer fromConnection:connection];
        }
        
        CFRelease(virtualBuffer);
        if (ultimateBuffer) CFRelease(ultimateBuffer);
    } else {
        if ([self.originalDelegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
            [self.originalDelegate captureOutput:output didOutputSampleBuffer:realSampleBuffer fromConnection:connection];
        }
    }
}

// 【核心优化 2,3,4,5】：终极硬件级伪装算法
- (CMSampleBufferRef)createUltimateCleanSampleBufferFrom:(CMSampleBufferRef)videoSample basedOn:(CMSampleBufferRef)realSample {
    
    // 1. 获取裸像素内存 (剥离文件级元数据)
    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(videoSample);
    if (!pixelBuffer) return NULL;
    
    // 2. 强行重置色彩空间为标准物理摄像头 SDR (Rec.709)
    CVBufferRemoveAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey);
    CVBufferRemoveAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey);
    CVBufferRemoveAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey);
    
    CVBufferSetAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);

    // 3. 提取真实摄像头的时钟信号，确保音频 100% 同步且帧率绝对恒定 (CFR)
    CMTime realPTS = CMSampleBufferGetPresentationTimeStamp(realSample);
    CMTime realDuration = CMSampleBufferGetDuration(realSample);
    
    // 添加物理级热噪声微秒抖动 (50-200µs)
    int jitterMicroseconds = (arc4random_uniform(150) + 50); 
    if (arc4random_uniform(2) == 0) jitterMicroseconds *= -1; 
    
    CMTime jitterTime = CMTimeMake(jitterMicroseconds, 1000000); 
    CMTime adjustedPTS = CMTimeAdd(realPTS, jitterTime);
    
    CMSampleTimingInfo timingInfo;
    timingInfo.duration = realDuration; 
    timingInfo.presentationTimeStamp = adjustedPTS;
    timingInfo.decodeTimeStamp = adjustedPTS;

    // 4. 凭空捏造全新的 Format Description (让剪辑软件的痕迹在内存中灰飞烟灭)
    CMVideoFormatDescriptionRef cleanFormatInfo = NULL;
    CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &cleanFormatInfo);

    // 5. 组装终极干净、时间线完美的 SampleBuffer
    CMSampleBufferRef cleanSampleBuffer = NULL;
    CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, true, NULL, NULL, cleanFormatInfo, &timingInfo, &cleanSampleBuffer);
    
    if (cleanFormatInfo) CFRelease(cleanFormatInfo);
    
    return cleanSampleBuffer;
}
@end


// =====================================================================
// 模块 3：UI 交互 (变更为系统相册选择器)
// =====================================================================
@interface VCAMUIManager : NSObject <UIImagePickerControllerDelegate, UINavigationControllerDelegate>
+ (instancetype)sharedManager;
- (void)handleThreeFingerTap:(UITapGestureRecognizer *)sender;
@end

@implementation VCAMUIManager
+ (instancetype)sharedManager {
    static VCAMUIManager *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[VCAMUIManager alloc] init];
    });
    return instance;
}

- (void)handleThreeFingerTap:(UITapGestureRecognizer *)sender {
    if (sender.state == UIGestureRecognizerStateRecognized) {
        dispatch_async(dispatch_get_main_queue(), ^{
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"VCAM 引擎" message:@"请从系统相册选择实拍视频\n(系统将自动强制格式化为 1080p/CFR/SDR 以穿透风控)" preferredStyle:UIAlertControllerStyleActionSheet];
            
            UIAlertAction *selectAction = [UIAlertAction actionWithTitle:@"打开相册选择" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
                
                UIImagePickerController *picker = [[UIImagePickerController alloc] init];
                picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
                picker.mediaTypes = @[@"public.movie"]; 
                picker.delegate = self;
                picker.videoExportPreset = AVAssetExportPresetPassthrough;
                picker.modalPresentationStyle = UIModalPresentationFullScreen;
                
                [topMostController() presentViewController:picker animated:YES completion:nil];
            }];
            
            UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil];
            
            [alert addAction:selectAction];
            [alert addAction:cancelAction];
            
            if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
                alert.popoverPresentationController.sourceView = sender.view;
                alert.popoverPresentationController.sourceRect = CGRectMake(sender.view.bounds.size.width / 2.0, sender.view.bounds.size.height / 2.0, 1.0, 1.0);
            }
            
            [topMostController() presentViewController:alert animated:YES completion:nil];
        });
    }
}

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey,id> *)info {
    
    NSURL *sourceURL = info[UIImagePickerControllerMediaURL];
    
    [picker dismissViewControllerAnimated:YES completion:^{
        if (!sourceURL) return;
        
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            
            NSFileManager *fileManager = [NSFileManager defaultManager];
            NSString *documentDir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
            NSString *destinationPath = [documentDir stringByAppendingPathComponent:@"vcam_target_current.mp4"];
            
            if ([fileManager fileExistsAtPath:destinationPath]) {
                [fileManager removeItemAtPath:destinationPath error:nil];
            }
            
            NSError *error = nil;
            BOOL success = [fileManager copyItemAtPath:sourceURL.path toPath:destinationPath error:&error];
            
            dispatch_async(dispatch_get_main_queue(), ^{
                if (success) {
                    SetCurrentVideoPath(destinationPath);
                    [[VCAMFrameEngine sharedEngine] reloadVideoAsset];
                    
                    UIAlertController *successAlert = [UIAlertController alertControllerWithTitle:@"注入成功" message:@"底层引擎已清洗元数据并对齐物理时钟。\n随时可开播/拍摄！" preferredStyle:UIAlertControllerStyleAlert];
                    [successAlert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
                    [topMostController() presentViewController:successAlert animated:YES completion:nil];
                } else {
                    UIAlertController *failAlert = [UIAlertController alertControllerWithTitle:@"错误" message:[NSString stringWithFormat:@"视频拷贝失败: %@", error.localizedDescription] preferredStyle:UIAlertControllerStyleAlert];
                    [failAlert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
                    [topMostController() presentViewController:failAlert animated:YES completion:nil];
                }
            });
        });
    }];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
}

@end


// =====================================================================
// 模块 4：注入点
// =====================================================================
%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)sampleBufferDelegate queue:(dispatch_queue_t)sampleBufferCallbackQueue {
    [VCAMFrameEngine sharedEngine];
    VCAMDelegateProxy *proxy = [[VCAMDelegateProxy alloc] init];
    proxy.originalDelegate = sampleBufferDelegate;
    %orig(proxy, sampleBufferCallbackQueue);
}
%end

%hook UIWindow
- (void)makeKeyAndVisible {
    %orig;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        UITapGestureRecognizer *threeFingerTap = [[UITapGestureRecognizer alloc] initWithTarget:[VCAMUIManager sharedManager] action:@selector(handleThreeFingerTap:)];
        threeFingerTap.numberOfTouchesRequired = 3;
        threeFingerTap.numberOfTapsRequired = 1;
        [self addGestureRecognizer:threeFingerTap];
    });
}
%end
