TARGET := iphone:clang:latest:13.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = VCAM
VCAM_FILES = Tweak.m
VCAM_FRAMEWORKS = Foundation UIKit AVFoundation CoreMedia CoreVideo VideoToolbox
VCAM_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
