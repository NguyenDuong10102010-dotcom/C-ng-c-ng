TARGET := iphone:clang:latest:14.0
ARCHS = arm64
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = VideoStarAuto
VideoStarAuto_FILES = Tweak.xm
VideoStarAuto_FRAMEWORKS = UIKit Foundation
VideoStarAuto_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
