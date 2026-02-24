ARCHS = arm64
TARGET = iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES = TikTok WeChat QQ

include $(THEOS)/makefiles/common.mk
TWEAK_NAME = VCAM
VCAM_FILES = Tweak.m
VCAM_CFLAGS = -fobjc-arc -O3 -flto
export DEBUG = 0
export STRIP = 1
# 🌟 新增了 CoreLocation, MapKit, CoreTelephony 三大底层环境框架
VCAM_FRAMEWORKS = Foundation UIKit AVFoundation CoreMedia CoreVideo VideoToolbox CoreLocation MapKit CoreTelephony

include $(THEOS_MAKE_PATH)/tweak.mk
