# GhostVM Makefile
# Builds vmctl CLI and the SwiftUI app via xcodebuild

CODESIGN_ID ?= -

# Xcode project settings (generated via xcodegen)
XCODE_PROJECT = GhostVM.xcodeproj
XCODE_CONFIG ?= Release
BUILD_DIR = build/xcode
APP_NAME = GhostVM

.PHONY: all cli app clean help run launch generate test framework dist tools dmg

all: help

# Generate Xcode project from project.yml
generate: $(XCODE_PROJECT)

$(XCODE_PROJECT): project.yml
	xcodegen generate

# Build the GhostVMKit framework
framework: $(XCODE_PROJECT)
	xcodebuild -project $(XCODE_PROJECT) \
		-scheme GhostVMKit \
		-configuration $(XCODE_CONFIG) \
		-derivedDataPath $(BUILD_DIR) \
		build

# Build the vmctl CLI (depends on framework)
cli: $(XCODE_PROJECT)
	xcodebuild -project $(XCODE_PROJECT) \
		-scheme vmctl \
		-configuration $(XCODE_CONFIG) \
		-derivedDataPath $(BUILD_DIR) \
		build
	@echo "vmctl built at: $(BUILD_DIR)/Build/Products/$(XCODE_CONFIG)/vmctl"

# Build the SwiftUI app via xcodebuild (includes GhostTools.dmg)
app: $(XCODE_PROJECT) dmg
	xcodebuild -project $(XCODE_PROJECT) \
		-scheme $(APP_NAME) \
		-configuration $(XCODE_CONFIG) \
		-derivedDataPath $(BUILD_DIR) \
		build
	@# Copy icons into app bundle Resources
	@mkdir -p "$(BUILD_DIR)/Build/Products/$(XCODE_CONFIG)/$(APP_NAME).app/Contents/Resources"
	@cp GhostVM/Resources/ghostvm.png "$(BUILD_DIR)/Build/Products/$(XCODE_CONFIG)/$(APP_NAME).app/Contents/Resources/"
	@cp GhostVM/Resources/ghostvm-dark.png "$(BUILD_DIR)/Build/Products/$(XCODE_CONFIG)/$(APP_NAME).app/Contents/Resources/"
	@cp build/GhostVMIcon.icns "$(BUILD_DIR)/Build/Products/$(XCODE_CONFIG)/$(APP_NAME).app/Contents/Resources/GhostVMIcon.icns"
	@# Copy GhostTools.dmg into app bundle Resources
	@cp "$(GHOSTTOOLS_DMG)" "$(BUILD_DIR)/Build/Products/$(XCODE_CONFIG)/$(APP_NAME).app/Contents/Resources/"
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
	xcodebuild test -project $(XCODE_PROJECT) -scheme GhostVMTests -destination 'platform=macOS'

# GhostTools settings
GHOSTTOOLS_DIR = GhostTools
GHOSTTOOLS_BUILD_DIR = $(BUILD_DIR)/GhostTools
GHOSTTOOLS_DMG = $(BUILD_DIR)/GhostTools.dmg

# Build GhostTools guest agent
tools:
	@echo "Building GhostTools..."
	cd $(GHOSTTOOLS_DIR) && swift build -c release
	@echo "GhostTools built at: $(GHOSTTOOLS_DIR)/.build/release/GhostTools"

# Create GhostTools.app bundle and package into DMG
dmg: tools
	@echo "Creating GhostTools.app bundle..."
	@rm -rf "$(GHOSTTOOLS_BUILD_DIR)"
	@mkdir -p "$(GHOSTTOOLS_BUILD_DIR)/dmg-stage/GhostTools.app/Contents/MacOS"
	@mkdir -p "$(GHOSTTOOLS_BUILD_DIR)/dmg-stage/GhostTools.app/Contents/Resources"
	@# Copy executable
	@cp "$(GHOSTTOOLS_DIR)/.build/release/GhostTools" "$(GHOSTTOOLS_BUILD_DIR)/dmg-stage/GhostTools.app/Contents/MacOS/"
	@# Copy Info.plist
	@cp "$(GHOSTTOOLS_DIR)/Sources/GhostTools/Resources/Info.plist" "$(GHOSTTOOLS_BUILD_DIR)/dmg-stage/GhostTools.app/Contents/"
	@# Copy README to DMG root
	@cp "$(GHOSTTOOLS_DIR)/README.txt" "$(GHOSTTOOLS_BUILD_DIR)/dmg-stage/"
	@# Ad-hoc sign the app
	codesign --force --deep -s "-" "$(GHOSTTOOLS_BUILD_DIR)/dmg-stage/GhostTools.app"
	@# Create the DMG
	@rm -f "$(GHOSTTOOLS_DMG)"
	hdiutil makehybrid -o "$(GHOSTTOOLS_DMG)" \
		-hfs \
		-hfs-volume-name "GhostTools" \
		"$(GHOSTTOOLS_BUILD_DIR)/dmg-stage"
	@rm -rf "$(GHOSTTOOLS_BUILD_DIR)/dmg-stage"
	@echo "GhostTools.dmg created at: $(GHOSTTOOLS_DMG)"

# Distribution settings
DIST_DIR = build/dist
DMG_NAME = GhostVM
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo "dev")

# Create signed distribution DMG
# Note: If you get "Operation not permitted", grant Terminal Full Disk Access in
# System Preferences > Privacy & Security > Full Disk Access
dist: app cli
	@echo "Creating distribution DMG (version $(VERSION))..."
	@rm -rf "$(DIST_DIR)"
	@mkdir -p "$(DIST_DIR)/dmg-stage"
	@# Stage app bundle
	cp -R "$(BUILD_DIR)/Build/Products/$(XCODE_CONFIG)/$(APP_NAME).app" "$(DIST_DIR)/dmg-stage/"
	@# Embed vmctl CLI inside the app bundle
	cp "$(BUILD_DIR)/Build/Products/$(XCODE_CONFIG)/vmctl" "$(DIST_DIR)/dmg-stage/$(APP_NAME).app/Contents/MacOS/"
	@# Re-sign the app bundle after adding vmctl
	codesign --entitlements GhostVM/entitlements.plist --force -s "$(CODESIGN_ID)" "$(DIST_DIR)/dmg-stage/$(APP_NAME).app"
	@# Add Applications symlink for drag-to-install
	ln -s /Applications "$(DIST_DIR)/dmg-stage/Applications"
	@# Create hybrid ISO/HFS+ image (avoids mounting during creation)
	hdiutil makehybrid -o "$(DIST_DIR)/$(DMG_NAME)-$(VERSION).dmg" \
		-hfs \
		-hfs-volume-name "$(DMG_NAME)" \
		"$(DIST_DIR)/dmg-stage"
	@rm -rf "$(DIST_DIR)/dmg-stage"
	@# Sign the DMG if using a real identity
	@if [ "$(CODESIGN_ID)" != "-" ]; then \
		codesign --force -s "$(CODESIGN_ID)" "$(DIST_DIR)/$(DMG_NAME)-$(VERSION).dmg"; \
		echo "DMG signed with: $(CODESIGN_ID)"; \
	fi
	@echo "Distribution created: $(DIST_DIR)/$(DMG_NAME)-$(VERSION).dmg"
	@echo "vmctl is at: $(APP_NAME).app/Contents/MacOS/vmctl"

clean:
	rm -rf $(BUILD_DIR)
	rm -rf $(XCODE_PROJECT)
	rm -rf $(DIST_DIR)
	cd $(GHOSTTOOLS_DIR) && swift package clean 2>/dev/null || true

help:
	@echo "GhostVM Build Targets:"
	@echo "  make          - Show this help"
	@echo "  make framework- Build GhostVMKit framework"
	@echo "  make cli      - Build vmctl CLI"
	@echo "  make generate - Generate Xcode project from project.yml"
	@echo "  make app      - Build SwiftUI app via xcodebuild"
	@echo "  make run      - Build and run attached to terminal"
	@echo "  make launch   - Build and launch detached"
	@echo "  make test     - Run unit tests"
	@echo "  make tools    - Build GhostTools guest agent"
	@echo "  make dmg      - Create GhostTools.dmg"
	@echo "  make dist     - Create distribution DMG with app + vmctl"
	@echo "  make clean    - Remove build artifacts and generated project"
	@echo ""
	@echo "Variables:"
	@echo "  CODESIGN_ID   - Code signing identity (default: - for ad-hoc)"
	@echo "  XCODE_CONFIG  - Xcode build configuration (default: Release)"
	@echo "  VERSION       - Version for DMG (default: git describe)"
	@echo ""
	@echo "Requires: xcodegen (brew install xcodegen)"
