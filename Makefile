# 目标 iOS 版本与架构
TARGET := iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES = TikTok

# 指定为 rootless / TrollStore 环境编译
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

# 【修改点】：把名字改回您的脚本期望的 AVMediaSupport
TWEAK_NAME = AVMediaSupport

AVMediaSupport_FILES = Tweak.xm
AVMediaSupport_FRAMEWORKS = UIKit AVFoundation CoreMedia
# 开启 ARC 内存管理
AVMediaSupport_CFLAGS = -fobjc-arc -Wno-deprecated-declarations

include $(THEOS_MAKE_PATH)/tweak.mk
