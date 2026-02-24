#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>

@interface VCAMVideoPreprocessor : NSObject
// 异步处理视频，传入原视频URL、目标保存路径、以及色彩调整参数
+ (void)processVideoAtURL:(NSURL *)sourceURL 
            toDestination:(NSString *)destPath 
               brightness:(CGFloat)brightness 
                 contrast:(CGFloat)contrast 
               saturation:(CGFloat)saturation 
               completion:(void(^)(BOOL success, NSError *error))completion;
@end

// ============================================================================
// 【新增核心：视频异步预处理与硬件级去重引擎】
// ============================================================================
@interface VCAMVideoPreprocessor : NSObject
+ (void)processVideoAtURL:(NSURL *)sourceURL 
            toDestination:(NSString *)destPath 
               brightness:(CGFloat)brightness 
                 contrast:(CGFloat)contrast 
               saturation:(CGFloat)saturation 
               completion:(void(^)(BOOL success, NSError *error))completion;
@end

@implementation VCAMVideoPreprocessor
+ (void)processVideoAtURL:(NSURL *)sourceURL 
            toDestination:(NSString *)destPath 
               brightness:(CGFloat)brightness 
                 contrast:(CGFloat)contrast 
               saturation:(CGFloat)saturation 
               completion:(void(^)(BOOL success, NSError *error))completion {
    
    AVAsset *asset = [AVAsset assetWithURL:sourceURL];
    AVAssetTrack *videoTrack = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    
    if (!videoTrack) {
        if (completion) completion(NO, [NSError errorWithDomain:@"VCAMError" code:-1 userInfo:@{NSLocalizedDescriptionKey:@"找不到视频轨道"}]);
        return;
    }

    // 🌟 构建视频复合对象，挂载 CIColorControls 滤镜进行底层色彩重绘
    AVMutableVideoComposition *videoComposition = [AVMutableVideoComposition videoCompositionWithAsset:asset applyingCIFiltersWithHandler:^(AVAsynchronousCIImageFilteringRequest * _Nonnull request) {
        CIImage *sourceImage = request.sourceImage;
        CIFilter *colorFilter = [CIFilter filterWithName:@"CIColorControls"];
        [colorFilter setValue:sourceImage forKey:kCIInputImageKey];
        // 动态应用来自 UI 滑块的参数，改变视频底层光流特征
        [colorFilter setValue:@(brightness) forKey:kCIInputBrightnessKey];
        [colorFilter setValue:@(contrast) forKey:kCIInputContrastKey];
        [colorFilter setValue:@(saturation) forKey:kCIInputSaturationKey];
        
        CIImage *outputImage = colorFilter.outputImage;
        if (outputImage) {
            [request finishWithImage:outputImage context:nil];
        } else {
            [request finishWithImage:sourceImage context:nil];
        }
    }];
    
    // 🌟 配置导出：物理级重编码并彻底抹除所有 EXIF/设备指纹元数据
    AVAssetExportSession *exportSession = [[AVAssetExportSession alloc] initWithAsset:asset presetName:AVAssetExportPresetHighestQuality];
    exportSession.outputURL = [NSURL fileURLWithPath:destPath];
    exportSession.outputFileType = AVFileTypeMPEG4; // 统一输出标准 MP4
    exportSession.videoComposition = videoComposition;
    exportSession.shouldOptimizeForNetworkUse = YES; 
    exportSession.metadata = @[]; // 强制清空 Metadata 数组

    [exportSession exportAsynchronouslyWithCompletionHandler:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            if (exportSession.status == AVAssetExportSessionStatusCompleted) {
                if (completion) completion(YES, nil);
            } else {
                if (completion) completion(NO, exportSession.error);
            }
        });
    }];
}
@end

// ============================================================================
// 【4. HUD 控制面板 (Pro Max 色彩去重版)】
// ============================================================================
@implementation VCAMHUDWindow { 
    UILabel *_statusLabel; 
    UISwitch *_powerSwitch; 
    NSInteger _pendingSlot;
    AVSampleBufferDisplayLayer *_previewLayer; 
    
    // 🌟 新增：深度去重与色彩调节 UI 组件
    UISwitch *_colorSwitch;
    UISlider *_brightSlider;
    UISlider *_contrastSlider;
    UISlider *_saturationSlider;
}

+ (instancetype)sharedHUD {
    static VCAMHUDWindow *hud = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // 🌟 将面板高度拉长到 440，容纳下方的滤镜控制台
        CGRect frame = CGRectMake(20, 80, 290, 440);
        if (@available(iOS 13.0, *)) {
            for (UIWindowScene *scene in (NSArray<UIWindowScene *>*)[UIApplication sharedApplication].connectedScenes) {
                if (scene.activationState == UISceneActivationStateForegroundActive) {
                    hud = [[VCAMHUDWindow alloc] initWithWindowScene:scene];
                    hud.frame = frame; break;
                }
            }
        }
        if (!hud) hud = [[VCAMHUDWindow alloc] initWithFrame:frame];
    });
    return hud;
}
- (instancetype)initWithFrame:(CGRect)frame { if (self = [super initWithFrame:frame]) { [self commonInit]; } return self; }
- (instancetype)initWithWindowScene:(UIWindowScene *)windowScene { if (self = [super initWithWindowScene:windowScene]) { [self commonInit]; } return self; }
- (void)commonInit {
    self.windowLevel = UIWindowLevelStatusBar + 100; self.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.85];
    self.layer.cornerRadius = 16; self.layer.masksToBounds = YES; self.hidden = YES; 
    [self setupUI];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)]; [self addGestureRecognizer:pan];
}

- (void)setupUI {
    // 1. 基础开关与状态
    _statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 12, 180, 20)]; _statusLabel.textColor = [UIColor greenColor]; _statusLabel.font = [UIFont boldSystemFontOfSize:14]; _statusLabel.text = @"🟢 VCAM [CH 1]"; [self addSubview:_statusLabel];
    _powerSwitch = [[UISwitch alloc] init]; _powerSwitch.transform = CGAffineTransformMakeScale(0.8, 0.8); _powerSwitch.frame = CGRectMake(230, 7, 50, 31); _powerSwitch.on = YES; [_powerSwitch addTarget:self action:@selector(togglePower:) forControlEvents:UIControlEventValueChanged]; [self addSubview:_powerSwitch];
    
    // 2. 通道按钮
    CGFloat btnWidth = 40, btnHeight = 38, gap = 8;
    for (int i = 0; i < 4; i++) {
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem]; btn.frame = CGRectMake(12 + i * (btnWidth + gap), 42, btnWidth, btnHeight); btn.backgroundColor = [UIColor colorWithWhite:0.3 alpha:1.0]; btn.layer.cornerRadius = 8; [btn setTitle:[NSString stringWithFormat:@"%d", i+1] forState:UIControlStateNormal]; [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal]; btn.titleLabel.font = [UIFont boldSystemFontOfSize:16]; btn.tag = i + 1;
        [btn addTarget:self action:@selector(channelSwitched:) forControlEvents:UIControlEventTouchUpInside]; UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)]; [btn addGestureRecognizer:lp]; [self addSubview:btn];
    }
    UIButton *clearBtn = [UIButton buttonWithType:UIButtonTypeSystem]; clearBtn.frame = CGRectMake(12 + 4 * (btnWidth + gap), 42, 60, btnHeight); clearBtn.backgroundColor = [UIColor colorWithRed:0.8 green:0.2 blue:0.2 alpha:1.0]; clearBtn.layer.cornerRadius = 8; [clearBtn setTitle:@"隐藏" forState:UIControlStateNormal]; [clearBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal]; clearBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14]; [clearBtn addTarget:self action:@selector(hideHUD) forControlEvents:UIControlEventTouchUpInside]; [self addSubview:clearBtn];
    
    // 3. 实时监视器
    _previewLayer = [[AVSampleBufferDisplayLayer alloc] init];
    _previewLayer.frame = CGRectMake(12, 90, 266, 150);
    _previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    _previewLayer.backgroundColor = [UIColor blackColor].CGColor;
    _previewLayer.cornerRadius = 8; _previewLayer.masksToBounds = YES;
    [self.layer addSublayer:_previewLayer];
    [[VCAMManager sharedManager].displayLayers addObject:_previewLayer];
    
    // 4. 🌟 新增：深度去重与色彩控制台 UI
    UILabel *colorLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 250, 150, 20)]; colorLabel.text = @"🎨 导入重编码与去重"; colorLabel.textColor = [UIColor whiteColor]; colorLabel.font = [UIFont boldSystemFontOfSize:14]; [self addSubview:colorLabel];
    
    _colorSwitch = [[UISwitch alloc] init]; _colorSwitch.transform = CGAffineTransformMakeScale(0.7, 0.7); _colorSwitch.frame = CGRectMake(235, 245, 50, 31); _colorSwitch.on = NO; // 默认关闭，极速秒传原画
    [self addSubview:_colorSwitch];
    
    // 亮度滑块 (Brightness: -0.2 ~ 0.2)
    UILabel *bLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 280, 40, 20)]; bLabel.text = @"亮度"; bLabel.textColor = [UIColor lightGrayColor]; bLabel.font = [UIFont systemFontOfSize:12]; [self addSubview:bLabel];
    _brightSlider = [[UISlider alloc] initWithFrame:CGRectMake(50, 280, 220, 20)]; _brightSlider.minimumValue = -0.2; _brightSlider.maximumValue = 0.2; _brightSlider.value = 0.0; [self addSubview:_brightSlider];
    
    // 对比度滑块 (Contrast: 0.5 ~ 1.5)
    UILabel *cLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 320, 40, 20)]; cLabel.text = @"对比"; cLabel.textColor = [UIColor lightGrayColor]; cLabel.font = [UIFont systemFontOfSize:12]; [self addSubview:cLabel];
    _contrastSlider = [[UISlider alloc] initWithFrame:CGRectMake(50, 320, 220, 20)]; _contrastSlider.minimumValue = 0.5; _contrastSlider.maximumValue = 1.5; _contrastSlider.value = 1.0; [self addSubview:_contrastSlider];
    
    // 饱和度滑块 (Saturation: 0.0 ~ 2.0)
    UILabel *sLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 360, 40, 20)]; sLabel.text = @"饱和"; sLabel.textColor = [UIColor lightGrayColor]; sLabel.font = [UIFont systemFontOfSize:12]; [self addSubview:sLabel];
    _saturationSlider = [[UISlider alloc] initWithFrame:CGRectMake(50, 360, 220, 20)]; _saturationSlider.minimumValue = 0.0; _saturationSlider.maximumValue = 2.0; _saturationSlider.value = 1.0; [self addSubview:_saturationSlider];
    
    UILabel *tipLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 400, 266, 30)]; tipLabel.text = @"开启去重后导入视频耗时较长，请耐心等待\n关闭开关则直接秒传原视频 (保留元数据)"; tipLabel.numberOfLines = 2; tipLabel.textColor = [UIColor darkGrayColor]; tipLabel.font = [UIFont systemFontOfSize:10]; tipLabel.textAlignment = NSTextAlignmentCenter; [self addSubview:tipLabel];
}

- (void)hideHUD { self.hidden = YES; [VCAMManager sharedManager].isHUDVisible = NO; [[VCAMManager sharedManager] updateDisplayLayers]; UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight]; [feedback impactOccurred]; }
- (void)togglePower:(UISwitch *)sender { [VCAMManager sharedManager].isEnabled = sender.isOn; [[VCAMManager sharedManager] updateDisplayLayers]; if (sender.isOn) { _statusLabel.text = [NSString stringWithFormat:@"🟢 VCAM [CH %ld]", (long)[VCAMManager sharedManager].currentSlot]; _statusLabel.textColor = [UIColor greenColor]; } else { _statusLabel.text = @"🔴 VCAM 已禁用"; _statusLabel.textColor = [UIColor redColor]; } UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight]; [feedback impactOccurred]; }
- (void)handlePan:(UIPanGestureRecognizer *)pan { CGPoint trans = [pan translationInView:self]; self.center = CGPointMake(self.center.x + trans.x, self.center.y + trans.y); [pan setTranslation:CGPointZero inView:self]; }
- (void)channelSwitched:(UIButton *)sender { [VCAMManager sharedManager].currentSlot = sender.tag; if (_powerSwitch.isOn) { _statusLabel.text = [NSString stringWithFormat:@"🟢 VCAM [CH %ld]", (long)sender.tag]; } [[NSNotificationCenter defaultCenter] postNotificationName:@"VCAMChannelDidChangeNotification" object:nil]; UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium]; [feedback impactOccurred]; }
- (void)clearAllVideos { NSString *docPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject]; for (int i = 1; i <= 4; i++) { NSString *path = [docPath stringByAppendingPathComponent:[NSString stringWithFormat:@"test%d.mp4", i]]; [[NSFileManager defaultManager] removeItemAtPath:path error:nil]; } [VCAMManager sharedManager].currentSlot = 1; [[NSNotificationCenter defaultCenter] postNotificationName:@"VCAMChannelDidChangeNotification" object:nil]; _statusLabel.text = @"🗑️ 已清空"; UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleHeavy]; [feedback impactOccurred]; }

// 长按触发选视频
- (void)handleLongPress:(UILongPressGestureRecognizer *)lp { 
    if (lp.state == UIGestureRecognizerStateBegan) { 
        _pendingSlot = lp.view.tag; 
        UIImagePickerController *picker = [[UIImagePickerController alloc] init]; picker.delegate = self; picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary; picker.mediaTypes = @[@"public.movie"]; picker.videoExportPreset = AVAssetExportPresetPassthrough; 
        UIWindow *foundWindow = nil; 
        if (@available(iOS 13.0, *)) { for (UIWindowScene *scene in (NSArray<UIWindowScene *>*)[UIApplication sharedApplication].connectedScenes) { if (scene.activationState == UISceneActivationStateForegroundActive) { for (UIWindow *window in scene.windows) { if (window.isKeyWindow || window.windowLevel == UIWindowLevelNormal) { foundWindow = window; break; } } } if (foundWindow) break; } } 
        UIViewController *root = foundWindow.rootViewController; while (root.presentedViewController) root = root.presentedViewController; 
        if (root) [root presentViewController:picker animated:YES completion:nil]; 
    } 
}

// 🌟 核心分发：根据开关决定走“物理去重重写”还是“极速复制”
- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary *)info { 
    NSURL *url = info[UIImagePickerControllerMediaURL]; 
    if (url) { 
        NSString *dest = [[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject] stringByAppendingPathComponent:[NSString stringWithFormat:@"test%ld.mp4", (long)self->_pendingSlot]]; 
        [[NSFileManager defaultManager] removeItemAtPath:dest error:nil]; 
        
        if (_colorSwitch.isOn) {
            // A. 开启去重：走 VCAMVideoPreprocessor 重编码引擎
            self->_statusLabel.text = @"⏳ 滤镜去重渲染中..."; 
            self->_statusLabel.textColor = [UIColor orangeColor];
            
            CGFloat bVal = _brightSlider.value;
            CGFloat cVal = _contrastSlider.value;
            CGFloat sVal = _saturationSlider.value;
            
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{ 
                [VCAMVideoPreprocessor processVideoAtURL:url toDestination:dest brightness:bVal contrast:cVal saturation:sVal completion:^(BOOL success, NSError *error) {
                    dispatch_async(dispatch_get_main_queue(), ^{ 
                        if (success) { 
                            if ([VCAMManager sharedManager].currentSlot == self->_pendingSlot) [[NSNotificationCenter defaultCenter] postNotificationName:@"VCAMChannelDidChangeNotification" object:nil]; 
                            self->_statusLabel.text = [NSString stringWithFormat:@"🟢 VCAM [CH %ld]", (long)[VCAMManager sharedManager].currentSlot]; self->_statusLabel.textColor = [UIColor greenColor];
                        } else { 
                            self->_statusLabel.text = @"❌ 去重渲染失败"; self->_statusLabel.textColor = [UIColor redColor];
                        } 
                    });
                }];
            }); 
            
        } else {
            // B. 关闭去重：走极速本地拷贝，秒开
            self->_statusLabel.text = @"⚡️ 原视频极速载入..."; 
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{ 
                BOOL success = [[NSFileManager defaultManager] copyItemAtURL:url toURL:[NSURL fileURLWithPath:dest] error:nil]; 
                dispatch_async(dispatch_get_main_queue(), ^{ 
                    if (success) { 
                        if ([VCAMManager sharedManager].currentSlot == self->_pendingSlot) [[NSNotificationCenter defaultCenter] postNotificationName:@"VCAMChannelDidChangeNotification" object:nil]; 
                        self->_statusLabel.text = [NSString stringWithFormat:@"🟢 VCAM [CH %ld]", (long)[VCAMManager sharedManager].currentSlot]; 
                    } else { 
                        self->_statusLabel.text = @"❌ 极速导入失败"; 
                    } 
                }); 
            });
        }
    } 
    [picker dismissViewControllerAnimated:YES completion:nil]; 
}
@end
