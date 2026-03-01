# 1. 架构与目标系统设置
ARCHS = arm64 arm64e
TARGET := iphone:clang:latest:13.0

# 2. 注入目标进程 (编译安装后自动重启 WhatsApp 以生效)
INSTALL_TARGET_PROCESSES = WhatsApp

include $(THEOS)/makefiles/common.mk

# 3. 插件名称 (保持与你之前 GitHub Actions 中的名称一致)
TWEAK_NAME = AVMediaSupport

# 4. 源码文件
AVMediaSupport_FILES = Tweak.m

# 5. 编译参数 (强制开启 ARC，并静默部分旧版 API 弃用警告，防止因为 -Werror 中断编译)
AVMediaSupport_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable -Wno-incompatible-pointer-types

# 6. 👑 核心依赖：必须链接这些苹果底层框架，否则 GPU 和音视频引擎无法启动！
AVMediaSupport_FRAMEWORKS = Foundation UIKit AVFoundation VideoToolbox CoreMedia CoreVideo CoreImage

include $(THEOS_MAKE_PATH)/tweak.mk
