ARCHS = arm64
TARGET = iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES = TikTok WeChat QQ

include $(THEOS)/makefiles/common.mk
TWEAK_NAME = VCAM
VCAM_FILES = Tweak.m
# 开启最高级别编译优化，降低发热
VCAM_CFLAGS = -fobjc-arc -O3 -flto
export DEBUG = 0
export STRIP = 1
# 仅保留最核心的硬件加速框架
VCAM_FRAMEWORKS = Foundation UIKit AVFoundation CoreMedia CoreVideo VideoToolbox

include $(THEOS_MAKE_PATH)/tweak.mk
