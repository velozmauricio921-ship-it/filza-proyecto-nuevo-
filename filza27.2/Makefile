# Use the newest SDK bundled with this Theos installation.  ContainerManager
# entry points are resolved at runtime, so private SDK headers are not needed.
TARGET := iphone:clang:latest:15.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = FilzaApplySandboxExt

# This is a plain injected dylib, not a Logos/Substrate tweak. The default
# MobileSubstrate generator would link CydiaSubstrate.framework, which does not
# exist on a normally signed device.
LOGOS_DEFAULT_GENERATOR = internal

FilzaApplySandboxExt_FILES = Tweak.m MCMBridge.m MCMFilzaIntegration.m \
    PosterBoardFeature.m UpdateChecker.m \
    worse_query.m pathleak.m fallback_query.m \
    WQFilzaIntegration.m WQWebDAVServer.m WQStartupUI.m \
    WQTerminal.m WQPackages.m WQSSHServer.m WQRespring.m WQArchive.m WQLSStore.m

# --- Flags ---
FilzaApplySandboxExt_CFLAGS = -I$(PWD)/compat -I$(PWD) -I$(PWD)/XPF/src -I$(PWD)/XPF/external/ChOma/include \
    -fobjc-arc \
    -Wno-unused-function -Wno-unused-variable -Wno-unused-but-set-variable \
    -Wno-incompatible-pointer-types -Wno-incompatible-pointer-types-discards-qualifiers \
    -Wno-deprecated-declarations -Wno-nonportable-include-path -Wno-format
FilzaApplySandboxExt_CFLAGS += -Wno-arc-performSelector-leaks

FilzaApplySandboxExt_CCFLAGS = $(FilzaApplySandboxExt_CFLAGS)
FilzaApplySandboxExt_OBJCFLAGS = $(FilzaApplySandboxExt_CFLAGS)
FilzaApplySandboxExt_OBJCCFLAGS = $(FilzaApplySandboxExt_CFLAGS)

FilzaApplySandboxExt_FRAMEWORKS = UIKit Foundation IOKit CoreFoundation Security AVFoundation QuartzCore WebKit
FilzaApplySandboxExt_PRIVATE_FRAMEWORKS = IOSurface
FilzaApplySandboxExt_LIBRARIES = z sandbox archive
FilzaApplySandboxExt_CFLAGS += -I$(PWD)/vendor/libssh/include
FilzaApplySandboxExt_LDFLAGS += -L$(PWD)/vendor/libssh -weak-lssh

FilzaApplySandboxExt_INSTALL_TARGET_PROCESSES = Filza

include $(THEOS_MAKE_PATH)/tweak.mk
