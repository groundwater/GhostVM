SWIFTC ?= swiftc
TARGET ?= vmctl
SOURCES := vmctl.swift
FRAMEWORKS := -framework Virtualization -framework AppKit
SWIFTFLAGS := -parse-as-library
CODESIGN_ID ?=
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
	@if [ -n "$(CODESIGN_ID)" ]; then \
		codesign --force --sign "$(CODESIGN_ID)" --entitlements "$(ENTITLEMENTS)" "$(TARGET)"; \
	else \
		echo "Skipping codesign (set CODESIGN_ID to sign with entitlements)."; \
	fi

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
	@if [ -n "$(CODESIGN_ID)" ]; then \
		codesign --force --sign "$(CODESIGN_ID)" --entitlements "$(ENTITLEMENTS)" "$(APP_BUNDLE)"; \
	else \
		echo "Skipping codesign (set CODESIGN_ID to sign with entitlements)."; \
	fi

clean:
	rm -f $(TARGET)
	rm -rf $(APP_BUNDLE)
