SWIFTC ?= swiftc
TARGET ?= vmctl
SOURCES := vmctl.swift
FRAMEWORKS := -framework Virtualization -framework AppKit
SWIFTFLAGS := -parse-as-library
CODESIGN_ID ?= -
ENTITLEMENTS := entitlements.plist
APP_TARGET ?= VirtualMachineManager
APP_SOURCES := VMApp.swift vmctl.swift
APP_BUNDLE := $(APP_TARGET).app
APP_PLIST := VMApp-Info.plist
APP_DISPLAY_NAME ?= $(APP_TARGET)

.PHONY: all build clean run app

all: build

build:
	$(SWIFTC) $(SWIFTFLAGS) -o $(TARGET) $(SOURCES) $(FRAMEWORKS)
	@if [ "$(CODESIGN_ID)" = "-" ]; then \
		echo "Codesigning $(TARGET) with ad-hoc identity to apply entitlements."; \
	fi
	codesign --force --sign "$(CODESIGN_ID)" --entitlements "$(ENTITLEMENTS)" "$(TARGET)"

run: build
	./$(TARGET)

app: build
	rm -rf $(APP_BUNDLE)
	mkdir -p $(APP_BUNDLE)/Contents/MacOS
	mkdir -p $(APP_BUNDLE)/Contents/Resources
	cp $(APP_PLIST) $(APP_BUNDLE)/Contents/Info.plist
	/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $(APP_TARGET)" $(APP_BUNDLE)/Contents/Info.plist
	/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $(APP_DISPLAY_NAME)" $(APP_BUNDLE)/Contents/Info.plist
	/usr/libexec/PlistBuddy -c "Set :CFBundleName $(APP_DISPLAY_NAME)" $(APP_BUNDLE)/Contents/Info.plist
	$(SWIFTC) $(SWIFTFLAGS) -DVMCTL_APP -o $(APP_BUNDLE)/Contents/MacOS/$(APP_TARGET) $(APP_SOURCES) $(FRAMEWORKS)
	cp $(TARGET) $(APP_BUNDLE)/Contents/MacOS/vmctl
	cp icon.png $(APP_BUNDLE)/Contents/Resources/icon.png
	cp vm.png $(APP_BUNDLE)/Contents/Resources/vm.png
	@if [ "$(CODESIGN_ID)" = "-" ]; then \
		echo "Codesigning $(APP_BUNDLE) with ad-hoc identity to apply entitlements."; \
	fi
	codesign --force --sign "$(CODESIGN_ID)" --entitlements "$(ENTITLEMENTS)" "$(APP_BUNDLE)"

clean:
	rm -f $(TARGET)
	rm -rf $(APP_BUNDLE)
