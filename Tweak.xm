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
                // 【核心修复 1】：必须添加 kCVPixelBufferIOSurfacePropertiesKey 空字典
                // 这行代码强制系统在内存中为视频帧分配 GPU 可读的 IOSurface 内存页
                // 如果没有它，抖音的美颜和 GPU 渲染管线会直接崩溃导致黑屏！
                NSDictionary *outputSettings = @{
                    (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
                    (id)kCVPixelBufferIOSurfacePropertiesKey: @{} 
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
// 模块 2：Delegate Proxy (拦截与 Jitter 模拟)
// =====================================================================
@interface VCAMDelegateProxy : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
// 【核心修复 2】：将 weak 改为 strong
// 严防抖音释放原始 Delegate 导致 originalDelegate 变为 nil，从而断绝帧传递
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
        CMSampleBufferRef adjustedBuffer = [self applyPhysicalJitterToBuffer:virtualBuffer basedOn:realSampleBuffer];
        
        if ([self.originalDelegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
            [self.originalDelegate captureOutput:output didOutputSampleBuffer:adjustedBuffer fromConnection:connection];
        }
        
        CFRelease(virtualBuffer);
        if (adjustedBuffer) CFRelease(adjustedBuffer);
    } else {
        if ([self.originalDelegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
            [self.originalDelegate captureOutput:output didOutputSampleBuffer:realSampleBuffer fromConnection:connection];
        }
    }
}

- (CMSampleBufferRef)applyPhysicalJitterToBuffer:(CMSampleBufferRef)videoSample basedOn:(CMSampleBufferRef)realSample {
    CMItemCount count;
    CMSampleBufferGetSampleTimingInfoArray(videoSample, 0, nil, &count);
    
    if (count == 0) return NULL;

    CMSampleTimingInfo stackInfo;
    CMSampleTimingInfo *pInfo = &stackInfo;
    BOOL usedMalloc = NO;
    
    if (count > 1) {
        pInfo = (CMSampleTimingInfo *)malloc(sizeof(CMSampleTimingInfo) * count);
        usedMalloc = YES;
    }
    
    CMSampleBufferGetSampleTimingInfoArray(videoSample, count, pInfo, &count);
    
    CMTime realPTS = CMSampleBufferGetPresentationTimeStamp(realSample);
    
    int jitterMicroseconds = (arc4random_uniform(150) + 50); 
    if (arc4random_uniform(2) == 0) jitterMicroseconds *= -1; 
    
    CMTime jitterTime = CMTimeMake(jitterMicroseconds, 1000000); 
    CMTime adjustedPTS = CMTimeAdd(realPTS, jitterTime);
    
    for (int i = 0; i < count; i++) {
        pInfo[i].decodeTimeStamp = adjustedPTS; 
        pInfo[i].presentationTimeStamp = adjustedPTS;
    }
    
    CMSampleBufferRef sout;
    CMSampleBufferCreateCopyWithNewTiming(kCFAllocatorDefault, videoSample, count, pInfo, &sout);
    
    if (usedMalloc) free(pInfo);
    
    return sout;
}
@end


// =====================================================================
// 模块 3：UI 交互 (变更为系统相册选择器)
// =====================================================================
// 【核心修复 3】：实现 UIImagePickerController 代理
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
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"VCAM 控制台" message:@"请从系统相册选择要注入的视频" preferredStyle:UIAlertControllerStyleActionSheet];
            
            UIAlertAction *selectAction = [UIAlertAction actionWithTitle:@"打开相册选择视频" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
                
                // 调起系统相册而不是文件管理器
                UIImagePickerController *picker = [[UIImagePickerController alloc] init];
                picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
                // 仅限选择视频类型
                picker.mediaTypes = @[@"public.movie"]; 
                picker.delegate = self;
                // 避免相册对视频进行过度压缩
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

// 相册选择完毕回调
- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey,id> *)info {
    
    NSURL *sourceURL = info[UIImagePickerControllerMediaURL];
    
    // 关闭相册界面
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
            // 相册选取的视频通常位于临时缓存目录，我们将其安全拷贝进应用沙盒
            BOOL success = [fileManager copyItemAtPath:sourceURL.path toPath:destinationPath error:&error];
            
            dispatch_async(dispatch_get_main_queue(), ^{
                if (success) {
                    SetCurrentVideoPath(destinationPath);
                    [[VCAMFrameEngine sharedEngine] reloadVideoAsset];
                    
                    UIAlertController *successAlert = [UIAlertController alertControllerWithTitle:@"成功" message:@"相册视频导入并替换完毕。" preferredStyle:UIAlertControllerStyleAlert];
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

// 取消选择回调
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
