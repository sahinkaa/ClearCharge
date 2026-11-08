THEOS_PACKAGE_SCHEME ?= rootless
ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:16.0

ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
CLEAR_CHARGE_PATH_LIBRARY = roothide
else ifneq ($(THEOS_PACKAGE_SCHEME),rootless)
$(error Choose THEOS_PACKAGE_SCHEME=rootless or roothide)
endif

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ClearCharge
ClearCharge_FILES = ClearCharge.m
ClearCharge_FRAMEWORKS = Foundation CoreGraphics QuartzCore UIKit
ClearCharge_LIBRARIES = substrate $(CLEAR_CHARGE_PATH_LIBRARY)
ClearCharge_CFLAGS = -fobjc-arc -Wall -Wextra -Werror

include $(THEOS_MAKE_PATH)/tweak.mk
