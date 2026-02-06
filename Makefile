# GhostVM Makefile
# Builds vmctl CLI and the SwiftUI app via xcodebuild

# Load .env for notarization credentials (NOTARY_APPLE_ID, NOTARY_TEAM_ID, NOTARY_PASSWORD)
-include .env
export

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
	@rm -rf "$(GHOSTTOOLS_BUILD_DIR)/dmg-stage"
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
	@echo "GhostTools.dmg created at: $(GHOSTTOOLS_DMG)"

# Distribution settings
DIST_DIR = build/dist
DMG_NAME = GhostVM
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo "dev")

# Auto-detect Developer ID Application identity for distribution
DIST_CODESIGN_ID := $(shell security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)".*/\1/')

# Create signed distribution DMG
# Note: If you get "Operation not permitted", grant Terminal Full Disk Access in
# System Preferences > Privacy & Security > Full Disk Access
dist: app cli
	@# Verify we have a real signing identity for distribution
	@if [ -z "$(DIST_CODESIGN_ID)" ]; then \
		echo "Error: No 'Developer ID Application' identity found in keychain."; \
		echo "Notarization requires a Developer ID certificate from Apple."; \
		echo "Install one via Xcode > Settings > Accounts > Manage Certificates."; \
		exit 1; \
	fi
	@echo "Creating distribution DMG (version $(VERSION))..."
	@echo "Signing with: $(DIST_CODESIGN_ID)"
	@rm -rf "$(DIST_DIR)"
	@mkdir -p "$(DIST_DIR)/dmg-stage"
	@# Stage app bundle
	cp -R "$(BUILD_DIR)/Build/Products/$(XCODE_CONFIG)/$(APP_NAME).app" "$(DIST_DIR)/dmg-stage/"
	@# Embed vmctl CLI inside the app bundle
	cp "$(BUILD_DIR)/Build/Products/$(XCODE_CONFIG)/vmctl" "$(DIST_DIR)/dmg-stage/$(APP_NAME).app/Contents/MacOS/"
	@# --- Inside-out code signing for notarization ---
	@echo "Signing nested components (inside-out)..."
	@# 1. Sign all embedded frameworks (GhostVMKit, NIO, etc.) in GhostVMHelper.app
	@for fw in "$(DIST_DIR)/dmg-stage/$(APP_NAME).app/Contents/PlugIns/Helpers/GhostVMHelper.app/Contents/Frameworks/"*.framework; do \
		if [ -d "$$fw" ]; then \
			echo "  Signing $$(basename $$fw) (in Helper)"; \
			codesign --force --options runtime --timestamp -s "$(DIST_CODESIGN_ID)" "$$fw"; \
		fi; \
	done
	@# 1b. Sign all embedded dylibs in GhostVMHelper.app
	@for dylib in "$(DIST_DIR)/dmg-stage/$(APP_NAME).app/Contents/PlugIns/Helpers/GhostVMHelper.app/Contents/Frameworks/"*.dylib; do \
		if [ -f "$$dylib" ]; then \
			echo "  Signing $$(basename $$dylib) (in Helper)"; \
			codesign --force --options runtime --timestamp -s "$(DIST_CODESIGN_ID)" "$$dylib"; \
		fi; \
	done
	@# 2. Sign GhostVMHelper.app (with its own entitlements)
	@echo "  Signing GhostVMHelper.app"
	codesign --force --options runtime --timestamp \
		--entitlements GhostVMHelper/entitlements.plist \
		-s "$(DIST_CODESIGN_ID)" \
		"$(DIST_DIR)/dmg-stage/$(APP_NAME).app/Contents/PlugIns/Helpers/GhostVMHelper.app"
	@# 3. Sign all embedded frameworks in the main app
	@for fw in "$(DIST_DIR)/dmg-stage/$(APP_NAME).app/Contents/Frameworks/"*.framework; do \
		if [ -d "$$fw" ]; then \
			echo "  Signing $$(basename $$fw)"; \
			codesign --force --options runtime --timestamp -s "$(DIST_CODESIGN_ID)" "$$fw"; \
		fi; \
	done
	@# 4. Sign embedded dylibs (NIO, etc.)
	@for dylib in "$(DIST_DIR)/dmg-stage/$(APP_NAME).app/Contents/Frameworks/"*.dylib; do \
		if [ -f "$$dylib" ]; then \
			echo "  Signing $$(basename $$dylib)"; \
			codesign --force --options runtime --timestamp -s "$(DIST_CODESIGN_ID)" "$$dylib"; \
		fi; \
	done
	@# 5. Sign vmctl binary
	@echo "  Signing vmctl"
	codesign --force --options runtime --timestamp \
		--entitlements GhostVM/entitlements.plist \
		-s "$(DIST_CODESIGN_ID)" \
		"$(DIST_DIR)/dmg-stage/$(APP_NAME).app/Contents/MacOS/vmctl"
	@# 5b. Re-create GhostTools.dmg with Developer ID signing for notarization
	@echo "  Re-signing GhostTools for distribution..."
	@rm -rf "$(DIST_DIR)/ghosttools-stage"
	@mkdir -p "$(DIST_DIR)/ghosttools-stage/GhostTools.app/Contents/MacOS"
	@mkdir -p "$(DIST_DIR)/ghosttools-stage/GhostTools.app/Contents/Resources"
	@cp "$(GHOSTTOOLS_DIR)/.build/release/GhostTools" "$(DIST_DIR)/ghosttools-stage/GhostTools.app/Contents/MacOS/"
	@cp "$(GHOSTTOOLS_DIR)/Sources/GhostTools/Resources/Info.plist" "$(DIST_DIR)/ghosttools-stage/GhostTools.app/Contents/"
	@cp "$(GHOSTTOOLS_DIR)/README.txt" "$(DIST_DIR)/ghosttools-stage/"
	codesign --force --options runtime --timestamp --deep -s "$(DIST_CODESIGN_ID)" "$(DIST_DIR)/ghosttools-stage/GhostTools.app"
	@rm -f "$(DIST_DIR)/dmg-stage/$(APP_NAME).app/Contents/Resources/GhostTools.dmg"
	hdiutil makehybrid -o "$(DIST_DIR)/dmg-stage/$(APP_NAME).app/Contents/Resources/GhostTools.dmg" \
		-hfs -hfs-volume-name "GhostTools" \
		"$(DIST_DIR)/ghosttools-stage"
	@rm -rf "$(DIST_DIR)/ghosttools-stage"
	@# 6. Sign the main app bundle (top-level, with entitlements)
	@echo "  Signing $(APP_NAME).app"
	codesign --force --options runtime --timestamp \
		--entitlements GhostVM/entitlements.plist \
		-s "$(DIST_CODESIGN_ID)" \
		"$(DIST_DIR)/dmg-stage/$(APP_NAME).app"
	@# Add Applications symlink for drag-to-install
	ln -s /Applications "$(DIST_DIR)/dmg-stage/Applications"
	@# Create disk image (two-step: makehybrid avoids mounting, then convert to UDZO for notarization)
	hdiutil makehybrid -o "$(DIST_DIR)/$(DMG_NAME)-$(VERSION)-tmp.dmg" \
		-hfs -hfs-volume-name "$(DMG_NAME)" \
		"$(DIST_DIR)/dmg-stage"
	hdiutil convert "$(DIST_DIR)/$(DMG_NAME)-$(VERSION)-tmp.dmg" \
		-format UDZO -o "$(DIST_DIR)/$(DMG_NAME)-$(VERSION).dmg"
	@rm -f "$(DIST_DIR)/$(DMG_NAME)-$(VERSION)-tmp.dmg"
	@rm -rf "$(DIST_DIR)/dmg-stage"
	@# Sign the DMG itself
	codesign --force --timestamp -s "$(DIST_CODESIGN_ID)" "$(DIST_DIR)/$(DMG_NAME)-$(VERSION).dmg"
	@echo "DMG signed with: $(DIST_CODESIGN_ID)"
	@# --- Notarization ---
	@if [ -n "$(NOTARY_APPLE_ID)" ] && [ -n "$(NOTARY_TEAM_ID)" ] && [ -n "$(NOTARY_PASSWORD)" ]; then \
		echo "Submitting for notarization..."; \
		xcrun notarytool submit "$(DIST_DIR)/$(DMG_NAME)-$(VERSION).dmg" \
			--apple-id "$(NOTARY_APPLE_ID)" \
			--team-id "$(NOTARY_TEAM_ID)" \
			--password "$(NOTARY_PASSWORD)" \
			--wait && \
		echo "Stapling notarization ticket..." && \
		xcrun stapler staple "$(DIST_DIR)/$(DMG_NAME)-$(VERSION).dmg"; \
	else \
		echo "Warning: Skipping notarization (NOTARY_APPLE_ID, NOTARY_TEAM_ID, NOTARY_PASSWORD not all set)"; \
		echo "Create a .env file with these variables to enable notarization."; \
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
	@echo "Notarization (via .env file or environment):"
	@echo "  NOTARY_APPLE_ID  - Apple ID for notarization"
	@echo "  NOTARY_TEAM_ID   - Team ID for notarization"
	@echo "  NOTARY_PASSWORD  - App-specific password for notarization"
	@echo ""
	@echo "Requires: xcodegen (brew install xcodegen)"
