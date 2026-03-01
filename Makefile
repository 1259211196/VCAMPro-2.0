# 目标 iOS 版本与架构
TARGET := iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES = TikTok

# 指定为 rootless / TrollStore 环境编译
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = VCAMTroll

VCAMTroll_FILES = Tweak.xm
VCAMTroll_FRAMEWORKS = UIKit AVFoundation CoreMedia
# 开启 ARC 内存管理
VCAMTroll_CFLAGS = -fobjc-arc -Wno-deprecated-declarations

include $(THEOS_MAKE_PATH)/tweak.mk
