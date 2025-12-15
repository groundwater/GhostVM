# GhostVM Makefile
# Builds vmctl CLI and the SwiftUI app via xcodebuild

SWIFTC ?= swiftc
CODESIGN_ID ?= -
TARGET ?= vmctl

# Xcode project settings (generated via xcodegen)
XCODE_PROJECT = GhostVM.xcodeproj
XCODE_SCHEME = GhostVM
XCODE_CONFIG ?= Release
BUILD_DIR = build/xcode
APP_NAME = GhostVM

.PHONY: all cli app clean help run launch generate test

all: help

# Generate Xcode project from project.yml
generate: $(XCODE_PROJECT)

$(XCODE_PROJECT): project.yml
	xcodegen generate

# Build the standalone vmctl CLI
cli: $(TARGET)

$(TARGET): GhostVM/vmctl.swift GhostVM/entitlements.plist
	$(SWIFTC) -O -parse-as-library -o $(TARGET) GhostVM/vmctl.swift \
		-framework Virtualization \
		-framework AppKit \
		-framework CoreGraphics
	codesign --entitlements GhostVM/entitlements.plist --force -s "$(CODESIGN_ID)" $(TARGET)

# Build the SwiftUI app via xcodebuild
app: $(XCODE_PROJECT)
	xcodebuild -project $(XCODE_PROJECT) \
		-scheme $(XCODE_SCHEME) \
		-configuration $(XCODE_CONFIG) \
		-derivedDataPath $(BUILD_DIR) \
		build
	@# Copy icons into app bundle Resources
	@mkdir -p "$(BUILD_DIR)/Build/Products/$(XCODE_CONFIG)/$(APP_NAME).app/Contents/Resources"
	@cp GhostVM/Resources/ghostvm.png "$(BUILD_DIR)/Build/Products/$(XCODE_CONFIG)/$(APP_NAME).app/Contents/Resources/"
	@cp GhostVM/Resources/ghostvm-dark.png "$(BUILD_DIR)/Build/Products/$(XCODE_CONFIG)/$(APP_NAME).app/Contents/Resources/"
	@cp build/GhostVMIcon.icns "$(BUILD_DIR)/Build/Products/$(XCODE_CONFIG)/$(APP_NAME).app/Contents/Resources/GhostVMIcon.icns"
	@# Re-sign after adding resources
	codesign --entitlements GhostVM/entitlements.plist --force -s "$(CODESIGN_ID)" "$(BUILD_DIR)/Build/Products/$(XCODE_CONFIG)/$(APP_NAME).app"
	@echo "App built at: $(BUILD_DIR)/Build/Products/$(XCODE_CONFIG)/$(APP_NAME).app"

# Build and run the app (attached to terminal)
run: app
	"$(BUILD_DIR)/Build/Products/$(XCODE_CONFIG)/$(APP_NAME).app/Contents/MacOS/$(APP_NAME)"

# Build and launch the app (detached)
launch: app
	open "$(BUILD_DIR)/Build/Products/$(XCODE_CONFIG)/$(APP_NAME).app"

# Run unit tests
test: $(XCODE_PROJECT)
	xcodebuild test -scheme GhostVMTests -destination 'platform=macOS'

clean:
	rm -f $(TARGET)
	rm -rf $(BUILD_DIR)
	rm -rf $(XCODE_PROJECT)

help:
	@echo "GhostVM Build Targets:"
	@echo "  make          - Show this help"
	@echo "  make cli      - Build vmctl CLI"
	@echo "  make generate - Generate Xcode project from project.yml"
	@echo "  make app      - Build SwiftUI app via xcodebuild"
	@echo "  make run      - Build and run attached to terminal"
	@echo "  make launch   - Build and launch detached"
	@echo "  make test     - Run unit tests"
	@echo "  make clean    - Remove build artifacts and generated project"
	@echo ""
	@echo "Variables:"
	@echo "  CODESIGN_ID   - Code signing identity (default: - for ad-hoc)"
	@echo "  XCODE_CONFIG  - Xcode build configuration (default: Release)"
	@echo ""
	@echo "Requires: xcodegen (brew install xcodegen)"
