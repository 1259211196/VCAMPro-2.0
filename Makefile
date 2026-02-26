TARGET := iphone:clang:latest:13.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

# 👑 核心隐身伪装：将工程名改为系统级的名字
TWEAK_NAME = AVMediaSupport

# 编译源文件
AVMediaSupport_FILES = Tweak.m

# 依赖的系统原生框架
AVMediaSupport_FRAMEWORKS = Foundation UIKit AVFoundation CoreMedia CoreVideo VideoToolbox

AVMediaSupport_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
