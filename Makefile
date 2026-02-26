# 1. 编译架构设置：支持 iOS 13.0 及以上，包含 arm64 和 arm64e
TARGET := iphone:clang:latest:13.0
ARCHS = arm64 arm64e

# 2. 指定安装后自动杀死的进程 (TikTok 国内版 Aweme / 海外版 musically)
INSTALL_TARGET_PROCESSES = Aweme musically

include $(THEOS)/makefiles/common.mk

# =========================================================================
# ⚠️ 注意：如果你项目文件夹不叫 VCAM，请将下面的 "VCAM" 改成你的项目名
# =========================================================================
TWEAK_NAME = VCAM

# 3. 核心源文件：必须包含 主代码(Tweak.m) 和 钩子库(fishhook.c)
# 漏掉 fishhook.c 会导致 "Undefined symbols" 报错！
VCAM_FILES = Tweak.m fishhook.c

# 4. 系统框架依赖：精准匹配你代码中用到的所有库
# MapKit(地图), CoreTelephony(运营商), NetworkExtension(Wi-Fi), SystemConfiguration(底层网络)
VCAM_FRAMEWORKS = Foundation UIKit AVFoundation CoreLocation MapKit CoreTelephony SystemConfiguration NetworkExtension

# 5. 为了防止头文件引用报错，保留这几个音视频框架 (虽然逻辑已移除，但头文件还在)
VCAM_FRAMEWORKS += CoreMedia CoreVideo VideoToolbox CoreImage

# 6. 开启 ARC 自动内存管理
VCAM_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
