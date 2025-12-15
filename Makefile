# GhostVM / FixieVM Makefile
# Builds vmctl CLI and the SwiftUI app via xcodebuild

SWIFTC ?= swiftc
CODESIGN_ID ?= -
TARGET ?= vmctl

# Xcode project settings
XCODE_PROJECT = GhostVMSwiftUI.xcodeproj
XCODE_SCHEME = GhostVMSwiftUI
XCODE_CONFIG ?= Release
BUILD_DIR = build/xcode

.PHONY: all cli app clean help run

all: cli

# Build the standalone vmctl CLI
cli: $(TARGET)

$(TARGET): vmctl.swift entitlements.plist
	$(SWIFTC) -O -parse-as-library -o $(TARGET) vmctl.swift \
		-framework Virtualization \
		-framework AppKit \
		-framework CoreGraphics
	codesign --entitlements entitlements.plist --force -s "$(CODESIGN_ID)" $(TARGET)

# Build the SwiftUI app via xcodebuild
app:
	xcodebuild -project $(XCODE_PROJECT) \
		-scheme $(XCODE_SCHEME) \
		-configuration $(XCODE_CONFIG) \
		-derivedDataPath $(BUILD_DIR) \
		build
	@# Copy icons into app bundle Resources
	@mkdir -p "$(BUILD_DIR)/Build/Products/$(XCODE_CONFIG)/GhostVMSwiftUI.app/Contents/Resources"
	@cp ghostvm.png "$(BUILD_DIR)/Build/Products/$(XCODE_CONFIG)/GhostVMSwiftUI.app/Contents/Resources/"
	@cp ghostvm-dark.png "$(BUILD_DIR)/Build/Products/$(XCODE_CONFIG)/GhostVMSwiftUI.app/Contents/Resources/"
	@cp build/GhostVMIcon.icns "$(BUILD_DIR)/Build/Products/$(XCODE_CONFIG)/GhostVMSwiftUI.app/Contents/Resources/GhostVMIcon.icns"
	@# Re-sign after adding resources
	codesign --entitlements entitlements.plist --force -s "$(CODESIGN_ID)" "$(BUILD_DIR)/Build/Products/$(XCODE_CONFIG)/GhostVMSwiftUI.app"
	@echo "App built at: $(BUILD_DIR)/Build/Products/$(XCODE_CONFIG)/GhostVMSwiftUI.app"

# Build and run the app
run: app
	open "$(BUILD_DIR)/Build/Products/$(XCODE_CONFIG)/GhostVMSwiftUI.app"

clean:
	rm -f $(TARGET)
	rm -rf $(BUILD_DIR)
	xcodebuild -project $(XCODE_PROJECT) -scheme $(XCODE_SCHEME) clean 2>/dev/null || true

help:
	@echo "GhostVM Build Targets:"
	@echo "  make          - Build vmctl CLI (default)"
	@echo "  make cli      - Build vmctl CLI"
	@echo "  make app      - Build SwiftUI app via xcodebuild"
	@echo "  make run      - Build and launch the app"
	@echo "  make clean    - Remove build artifacts"
	@echo ""
	@echo "Variables:"
	@echo "  CODESIGN_ID   - Code signing identity (default: - for ad-hoc)"
	@echo "  XCODE_CONFIG  - Xcode build configuration (default: Release)"
