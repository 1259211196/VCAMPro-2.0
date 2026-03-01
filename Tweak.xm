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
// 模块 1：异步帧读取引擎 (Ring Buffer & GPU IOSurface)
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
                // 确保输出包含 GPU 可读的 IOSurface
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
// 模块 2：Delegate Proxy (底层生命周期管理与时钟同步)
// =====================================================================
@interface VCAMDelegateProxy : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
// 【关键修复】：这里使用 weak 防止宿主应用的 ViewController 被循环引用导致内存泄漏崩溃
@property (nonatomic, weak) id originalDelegate; 
@end

@implementation VCAMDelegateProxy

- (BOOL)respondsToSelector:(SEL)aSelector {
    return [self.originalDelegate respondsToSelector:aSelector] || [super respondsToSelector:aSelector];
}

- (id)forwardingTargetForSelector:(SEL)aSelector {
    return self.originalDelegate;
}

- (BOOL)conformsToProtocol:(Protocol *)aProtocol {
    return [self.originalDelegate conformsToProtocol:aProtocol] || [super conformsToProtocol:aProtocol];
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

// 物理时钟完美对齐算法，保障音画同步与硬件防封
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
    
    // 微秒级硬件抖动模拟
    int jitterMicroseconds = (arc4random_uniform(150) + 50); 
    if (arc4random_uniform(2) == 0) jitterMicroseconds *= -1; 
    
    CMTime jitterTime = CMTimeMake(jitterMicroseconds, 1000000); 
    CMTime adjustedPTS = CMTimeAdd(realPTS, jitterTime);
    
    for (int i = 0; i < count; i++) {
        pInfo[i].decodeTimeStamp = adjustedPTS; 
        pInfo[i].presentationTimeStamp = adjustedPTS;
    }
    
    CMSampleBufferRef sout;
    // 使用这种最原生的方式创建 Buffer，能 100% 完美保留 GPU IOSurface 渲染管线，绝不黑屏！
    CMSampleBufferCreateCopyWithNewTiming(kCFAllocatorDefault, videoSample, count, pInfo, &sout);
    
    if (usedMalloc) free(pInfo);
    
    return sout;
}
@end


// =====================================================================
// 模块 3：UI 交互 (系统相册注入)
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
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"VCAM 控制台" message:@"请从系统相册选择实拍视频" preferredStyle:UIAlertControllerStyleActionSheet];
            
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
                    
                    UIAlertController *successAlert = [UIAlertController alertControllerWithTitle:@"注入成功" message:@"视频替换完毕！相机流已全面接管。" preferredStyle:UIAlertControllerStyleAlert];
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
// 模块 4：注入点 (Hook 入口与生命周期绑定)
// =====================================================================
%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)sampleBufferDelegate queue:(dispatch_queue_t)sampleBufferCallbackQueue {
    
    [VCAMFrameEngine sharedEngine]; // 预热引擎

    if (!sampleBufferDelegate) {
        %orig(nil, sampleBufferCallbackQueue);
        return;
    }

    // 防止被宿主 App 多次包装造成死循环嵌套
    if ([sampleBufferDelegate isKindOfClass:NSClassFromString(@"VCAMDelegateProxy")]) {
        %orig(sampleBufferDelegate, sampleBufferCallbackQueue);
        return;
    }

    VCAMDelegateProxy *proxy = [[VCAMDelegateProxy alloc] init];
    proxy.originalDelegate = sampleBufferDelegate;

    // 【破局核心代码】：将 proxy 的生命周期与相机的 output 对象强行绑定！
    // 只要 AVCaptureVideoDataOutput 存活，我们的 proxy 就绝对不会被 ARC 销毁
    objc_setAssociatedObject(self, @selector(setSampleBufferDelegate:queue:), proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

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
