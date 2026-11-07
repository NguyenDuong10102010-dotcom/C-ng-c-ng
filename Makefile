ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES = FreeFire FreeFireMax

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = PainuzzFF
PainuzzFF_FILES = Tweak.x
PainuzzFF_CFLAGS = -fobjc-arc -O2 -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function
PainuzzFF_FRAMEWORKS = UIKit CoreGraphics QuartzCore Foundation

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 FreeFire || true; killall -9 FreeFireMax || true"