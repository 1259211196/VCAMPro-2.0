# 1. 编译目标与架构配置 (指定 iOS 13.0 以上，支持所有现代 iPhone 架构)
TARGET := iphone:clang:latest:13.0
ARCHS = arm64 arm64e

# 2. 编译安装完成后，自动重启的目标 App 进程名 (包含抖音国内版和海外版)
INSTALL_TARGET_PROCESSES = Aweme musically

include $(THEOS)/makefiles/common.mk

# 3. 你的插件名称 (⚠️ 注意：请确保这里的名字和你的工程名完全一致)
TWEAK_NAME = VCAM

# 4. 核心：指定需要编译的源文件 (必须包含主文件 Tweak.m 和 C语言库 fishhook.c)
VCAM_FILES = Tweak.m fishhook.c

# 5. 核心：导入底层伪装、网络拦截和视频渲染所需的全部 12 个系统框架
VCAM_FRAMEWORKS = Foundation UIKit AVFoundation CoreMedia CoreVideo VideoToolbox CoreImage CoreLocation MapKit CoreTelephony SystemConfiguration NetworkExtension

# 6. 开启 ARC 内存管理，防止内存泄漏引起的闪退
VCAM_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
