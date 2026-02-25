# 1. 基础环境配置
# 指定目标平台、编译器、最新的 SDK 以及最低兼容的 iOS 版本 (因为用到了 NEHotspotNetwork 和 UIWindowScene，建议设为 14.0)
TARGET := iphone:clang:latest:14.0
# 指定编译架构，arm64 对应老款全面屏，arm64e 对应 A12 及以上芯片的设备
ARCHS = arm64 arm64e

# 关闭调试模式，开启最终打包模式 (能极大减小 dylib 体积并提升运行性能)
DEBUG = 0
FINALPACKAGE = 1

# 引入 Theos 通用规则
include $(THEOS)/makefiles/common.mk

# 2. 插件核心配置
# 插件的名称，必须与下方变量的前缀保持完全一致
TWEAK_NAME = VCam

# 包含的源文件：你的主代码文件 (假设命名为 Tweak.m) 以及刚刚加入的 fishhook.c
# ⚠️ 注意：如果你的主代码文件不叫 Tweak.m (比如叫 VCam.m)，请将下方的 Tweak.m 改成你实际的文件名
VCam_FILES = Tweak.m fishhook.c

# 3. 框架依赖 (极其重要 🌟)
# 这里必须完整声明你在代码中 #import 的所有系统级 framework，漏掉任何一个都会导致编译失败
VCam_FRAMEWORKS = Foundation \
                  UIKit \
                  AVFoundation \
                  CoreMedia \
                  CoreVideo \
                  VideoToolbox \
                  CoreImage \
                  CoreLocation \
                  MapKit \
                  CoreTelephony \
                  SystemConfiguration \
                  NetworkExtension

# 4. 编译参数
# 开启 ARC (自动引用计数) 以处理 Objective-C 的内存管理
VCam_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable

# 引入 Theos 的 Tweak 编译规则
include $(THEOS_MAKE_PATH)/tweak.mk
