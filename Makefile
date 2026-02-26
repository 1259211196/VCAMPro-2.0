# 1. 编译目标与架构配置 (指定 iOS 13.0 以上，支持所有现代 iPhone 架构)
TARGET := iphone:clang:latest:13.0
ARCHS = arm64 arm64e

# 2. 编译安装完成后，自动重启的目标 App 进程名 (包含抖音国内版和海外版)
INSTALL_TARGET_PROCESSES = Aweme musically

include $(THEOS)/makefiles/common.mk

# =========================================================================
# ⚠️ 注意：请确保这里的名字和你的工程名完全一致 (例如你的 plist 叫 VCAM.plist)
# =========================================================================
TWEAK_NAME = VCAM

# 3. 核心：指定需要编译的源文件 (必须包含主代码 Tweak.m 和 C语言库 fishhook.c)
VCAM_FILES = Tweak.m fishhook.c

# 4. 满血系统框架依赖：精准匹配“有相机替换版”用到的所有 12 个系统库！
# (包含音视频解码、地图、运营商、Wi-Fi、底层网络等)
VCAM_FRAMEWORKS = Foundation UIKit AVFoundation CoreMedia CoreVideo VideoToolbox CoreImage CoreLocation MapKit CoreTelephony SystemConfiguration NetworkExtension

# 5. 开启 ARC 内存管理，防止视频推流时发生内存泄漏闪退
VCAM_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
