# 指定编译架构，覆盖所有现代 iOS 设备 (A12~A17)
ARCHS = arm64 arm64e
TARGET := iphone:clang:latest:13.0

# 编译安装后自动重启 WhatsApp
INSTALL_TARGET_PROCESSES = WhatsApp

include $(THEOS)/makefiles/common.mk

# 插件名称，必须与你的 .plist 文件名前缀完全一致
TWEAK_NAME = AVMediaSupport

# 源码文件指向
AVMediaSupport_FILES = Tweak.m

# 编译参数：强制 ARC，并放行指针强转警告以适应底层 Hook
AVMediaSupport_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable -Wno-incompatible-pointer-types

# 👑 核心依赖池：缺少任何一个都会导致连接器 (Linker) 报错
AVMediaSupport_FRAMEWORKS = Foundation UIKit AVFoundation VideoToolbox CoreMedia CoreVideo CoreImage

include $(THEOS_MAKE_PATH)/tweak.mk
