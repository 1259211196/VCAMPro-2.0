# 🌟 确保兼容巨魔环境与最新 iOS 设备
ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = VCAM
VCAM_FILES = Tweak.m
VCAM_CFLAGS = -fobjc-arc -O3 -flto
VCAM_FRAMEWORKS = Foundation UIKit AVFoundation CoreMedia CoreVideo VideoToolbox CoreLocation MapKit CoreTelephony

export DEBUG = 0
export STRIP = 1

include $(THEOS_MAKE_PATH)/tweak.mk
