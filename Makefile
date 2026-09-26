ARCHS = arm64 arm64e
TARGET = iphone:16.5:14.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ayTELE

$(TWEAK_NAME)_FILES = $(shell find Sources \( -name '*.swift' -o -name '*.m' -o -name '*.xm' -o -name '*.c' \))
$(TWEAK_NAME)_SWIFTFLAGS = -ISources/tgapiC/include
$(TWEAK_NAME)_CFLAGS = -fobjc-arc -ISources/tgapiC/include -Wno-deprecated-declarations
$(TWEAK_NAME)_FRAMEWORKS = CoreServices Security
$(TWEAK_NAME)_LOGOS_DEFAULT_GENERATOR = internal
$(TWEAK_NAME)_RESOURCE_FILES = Sources/tgapi/Resources

# Copy ayTELE.bundle manually during the packaging step
after-stage::
	@echo ">>> Copying ayTELE.bundle into .deb package..."
	@mkdir -p $(THEOS_STAGING_DIR)/Library/Application\ Support/ayTELE
	@cp -a ayTELE.bundle $(THEOS_STAGING_DIR)/Library/Application\ Support/ayTELE

include $(THEOS_MAKE_PATH)/tweak.mk
