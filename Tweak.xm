#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreImage/CoreImage.h> // 【修改点】：换用向下兼容到 iOS 9 的 CoreImage
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
// 模块 1：异步帧读取引擎
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
// 模块 2：Delegate Proxy (CoreImage 硬件渲染覆写引擎)
// =====================================================================
@interface VCAMDelegateProxy : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic, weak) id originalDelegate; 
// 【新增】：CoreImage GPU 渲染上下文
@property (nonatomic, strong) CIContext *ciContext; 
@end

@implementation VCAMDelegateProxy

- (instancetype)init {
    self = [super init];
    if (self) {
        // 初始化基于 GPU (Metal) 的渲染上下文，禁用软解，速度极快
        _ciContext = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @(NO)}];
    }
    return self;
}

- (BOOL)respondsToSelector:(SEL)aSelector {
    return [self.originalDelegate respondsToSelector:aSelector] || [super respondsToSelector:aSelector];
}

- (id)forwardingTargetForSelector:(SEL)aSelector {
    return self.originalDelegate;
}

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)realSampleBuffer fromConnection:(AVCaptureConnection *)connection {
    
    CMSampleBufferRef virtualBuffer = [[VCAMFrameEngine sharedEngine] consumeNextFrame];
    
    if (virtualBuffer) {
        CVPixelBufferRef realPixelBuffer = CMSampleBufferGetImageBuffer(realSampleBuffer);
        CVPixelBufferRef virtualPixelBuffer = CMSampleBufferGetImageBuffer(virtualBuffer);
        
        if (realPixelBuffer && virtualPixelBuffer && self.ciContext) {
            // 1. 将我们选好的视频帧转化为 CIImage
            CIImage *virtualImage = [CIImage imageWithCVPixelBuffer:virtualPixelBuffer];
            
            // 2. 动态计算缩放比例 (如果视频分辨率与摄像头不一致，自动拉伸铺满，防止崩溃)
            CGFloat realWidth = CVPixelBufferGetWidth(realPixelBuffer);
            CGFloat realHeight = CVPixelBufferGetHeight(realPixelBuffer);
            CGFloat virtualWidth = CVPixelBufferGetWidth(virtualPixelBuffer);
            CGFloat virtualHeight = CVPixelBufferGetHeight(virtualPixelBuffer);
            
            if (realWidth != virtualWidth || realHeight != virtualHeight) {
                CGFloat scaleX = realWidth / virtualWidth;
                CGFloat scaleY = realHeight / virtualHeight;
                virtualImage = [virtualImage imageByApplyingTransform:CGAffineTransformMakeScale(scaleX, scaleY)];
            }
            
            // 3. 【终极画笔】：调用 GPU 直接将画面“画”在真实摄像头的内存里！
            // 因为使用的是真实的 Buffer 壳子，抖音的渲染管线绝对不会崩溃！
            [self.ciContext render:virtualImage toCVPixelBuffer:realPixelBuffer bounds:CGRectMake(0, 0, realWidth, realHeight) colorSpace:nil];
        }
        
        if ([self.originalDelegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
            [self.originalDelegate captureOutput:output didOutputSampleBuffer:realSampleBuffer fromConnection:connection];
        }
        
        CFRelease(virtualBuffer);
    } else {
        if ([self.originalDelegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
            [self.originalDelegate captureOutput:output didOutputSampleBuffer:realSampleBuffer fromConnection:connection];
        }
    }
}
@end


// =====================================================================
// 模块 3：UI 交互 (系统相册)
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
                    
                    UIAlertController *successAlert = [UIAlertController alertControllerWithTitle:@"注入成功" message:@"相册视频导入完毕，随时可录制！" preferredStyle:UIAlertControllerStyleAlert];
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
// 模块 4：注入点 (使用关联对象保证生命周期)
// =====================================================================
%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)sampleBufferDelegate queue:(dispatch_queue_t)sampleBufferCallbackQueue {
    
    [VCAMFrameEngine sharedEngine];

    if (!sampleBufferDelegate) {
        %orig(nil, sampleBufferCallbackQueue);
        return;
    }

    if ([sampleBufferDelegate isKindOfClass:NSClassFromString(@"VCAMDelegateProxy")]) {
        %orig(sampleBufferDelegate, sampleBufferCallbackQueue);
        return;
    }

    VCAMDelegateProxy *proxy = [[VCAMDelegateProxy alloc] init];
    proxy.originalDelegate = sampleBufferDelegate;

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
