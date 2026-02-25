# 🌟 修复：将双架构声明放在这里，确保兼容巨魔环境
ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES = TikTok WeChat QQ

include $(THEOS)/makefiles/common.mk
TWEAK_NAME = VCAM
VCAM_FILES = Tweak.m
VCAM_CFLAGS = -fobjc-arc -O3 -flto
export DEBUG = 0
export STRIP = 1
VCAM_FRAMEWORKS = Foundation UIKit AVFoundation CoreMedia CoreVideo VideoToolbox CoreLocation MapKit CoreTelephony

include $(THEOS_MAKE_PATH)/tweak.mk
