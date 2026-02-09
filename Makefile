# GhostVM Makefile
# Builds vmctl CLI and the SwiftUI app via xcodebuild

# Load .env for notarization credentials (NOTARY_APPLE_ID, NOTARY_TEAM_ID, NOTARY_PASSWORD)
-include .env
export

CODESIGN_ID ?= -

# Xcode project settings (generated via xcodegen)
XCODE_PROJECT = macOS/GhostVM.xcodeproj
XCODE_CONFIG ?= Release
BUILD_DIR = build/xcode
APP_NAME = GhostVM

.PHONY: all cli app clean help run launch generate test framework dist tools debug-tools dmg ghosttools-icon ghostvm-icon debug screenshots website website-build

all: help

# Generate Xcode project from macOS/project.yml
generate: $(XCODE_PROJECT)

$(XCODE_PROJECT): macOS/project.yml
	xcodegen generate --spec macOS/project.yml

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
app: $(XCODE_PROJECT) dmg ghostvm-icon
	xcodebuild -project $(XCODE_PROJECT) \
		-scheme $(APP_NAME) \
		-configuration $(XCODE_CONFIG) \
		-derivedDataPath $(BUILD_DIR) \
		build
	@# Copy icons into app bundle Resources
	@mkdir -p "$(BUILD_DIR)/Build/Products/$(XCODE_CONFIG)/$(APP_NAME).app/Contents/Resources"
	@cp macOS/GhostVM/Resources/ghostvm.png "$(BUILD_DIR)/Build/Products/$(XCODE_CONFIG)/$(APP_NAME).app/Contents/Resources/"
	@cp macOS/GhostVM/Resources/ghostvm-dark.png "$(BUILD_DIR)/Build/Products/$(XCODE_CONFIG)/$(APP_NAME).app/Contents/Resources/"
	@cp build/GhostVMIcon.icns "$(BUILD_DIR)/Build/Products/$(XCODE_CONFIG)/$(APP_NAME).app/Contents/Resources/GhostVMIcon.icns"
	@# Copy GhostTools.dmg into app bundle Resources
	@cp "$(GHOSTTOOLS_DMG)" "$(BUILD_DIR)/Build/Products/$(XCODE_CONFIG)/$(APP_NAME).app/Contents/Resources/"
	@# Re-sign after adding resources
	codesign --entitlements macOS/GhostVM/entitlements.plist --force -s "$(CODESIGN_ID)" "$(BUILD_DIR)/Build/Products/$(XCODE_CONFIG)/$(APP_NAME).app"
	@echo "App built at: $(BUILD_DIR)/Build/Products/$(XCODE_CONFIG)/$(APP_NAME).app"

# Build the SwiftUI app in Debug configuration
debug: $(XCODE_PROJECT) dmg ghostvm-icon
	xcodebuild -project $(XCODE_PROJECT) \
		-scheme $(APP_NAME) \
		-configuration Debug \
		-derivedDataPath $(BUILD_DIR) \
		build
	@# Copy icons into app bundle Resources
	@mkdir -p "$(BUILD_DIR)/Build/Products/Debug/$(APP_NAME).app/Contents/Resources"
	@cp macOS/GhostVM/Resources/ghostvm.png "$(BUILD_DIR)/Build/Products/Debug/$(APP_NAME).app/Contents/Resources/"
	@cp macOS/GhostVM/Resources/ghostvm-dark.png "$(BUILD_DIR)/Build/Products/Debug/$(APP_NAME).app/Contents/Resources/"
	@cp build/GhostVMIcon.icns "$(BUILD_DIR)/Build/Products/Debug/$(APP_NAME).app/Contents/Resources/GhostVMIcon.icns"
	@# Copy GhostTools.dmg into app bundle Resources
	@cp "$(GHOSTTOOLS_DMG)" "$(BUILD_DIR)/Build/Products/Debug/$(APP_NAME).app/Contents/Resources/"
	@# Re-sign after adding resources
	codesign --entitlements macOS/GhostVM/entitlements.plist --force -s "$(CODESIGN_ID)" "$(BUILD_DIR)/Build/Products/Debug/$(APP_NAME).app"
	@echo "Debug app built at: $(BUILD_DIR)/Build/Products/Debug/$(APP_NAME).app"

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
GHOSTTOOLS_DIR = macOS/GhostTools
GHOSTTOOLS_BUILD_DIR = $(BUILD_DIR)/GhostTools
GHOSTTOOLS_DMG = $(BUILD_DIR)/GhostTools.dmg

# Build GhostTools guest agent
tools:
	@echo "Building GhostTools..."
	cd $(GHOSTTOOLS_DIR) && swift build -c release
	@echo "GhostTools built at: $(GHOSTTOOLS_DIR)/.build/release/GhostTools"

# Build GhostTools debug binary for guest VM debugging
debug-tools:
	@echo "Building GhostTools (debug)..."
	cd $(GHOSTTOOLS_DIR) && swift build
	@echo "Patching SDK version for guest compatibility..."
	vtool -set-build-version macos 14.0 15.0 -replace \
		-output $(GHOSTTOOLS_DIR)/.build/debug/GhostTools-debug \
		$(GHOSTTOOLS_DIR)/.build/debug/GhostTools
	codesign --force -s "-" $(GHOSTTOOLS_DIR)/.build/debug/GhostTools-debug
	@echo "Debug binary: $(GHOSTTOOLS_DIR)/.build/debug/GhostTools-debug"
	@echo "Copy to guest and use: lldb GhostTools-debug"

# Generate GhostTools .icns from source PNG
GHOSTTOOLS_ICON_SRC = macOS/GhostVM/GhostToolsIcon.png
GHOSTTOOLS_ICON_ICNS = build/GhostToolsIcon.icns
GHOSTTOOLS_ICONSET = build/GhostToolsIcon.iconset

ghosttools-icon: $(GHOSTTOOLS_ICON_ICNS)

$(GHOSTTOOLS_ICON_ICNS): $(GHOSTTOOLS_ICON_SRC)
	@echo "Generating GhostToolsIcon.icns..."
	@rm -rf "$(GHOSTTOOLS_ICONSET)"
	@mkdir -p "$(GHOSTTOOLS_ICONSET)"
	@sips -z 16 16     "$(GHOSTTOOLS_ICON_SRC)" --out "$(GHOSTTOOLS_ICONSET)/icon_16x16.png"      > /dev/null
	@sips -z 32 32     "$(GHOSTTOOLS_ICON_SRC)" --out "$(GHOSTTOOLS_ICONSET)/icon_16x16@2x.png"   > /dev/null
	@sips -z 32 32     "$(GHOSTTOOLS_ICON_SRC)" --out "$(GHOSTTOOLS_ICONSET)/icon_32x32.png"      > /dev/null
	@sips -z 64 64     "$(GHOSTTOOLS_ICON_SRC)" --out "$(GHOSTTOOLS_ICONSET)/icon_32x32@2x.png"   > /dev/null
	@sips -z 128 128   "$(GHOSTTOOLS_ICON_SRC)" --out "$(GHOSTTOOLS_ICONSET)/icon_128x128.png"    > /dev/null
	@sips -z 256 256   "$(GHOSTTOOLS_ICON_SRC)" --out "$(GHOSTTOOLS_ICONSET)/icon_128x128@2x.png" > /dev/null
	@sips -z 256 256   "$(GHOSTTOOLS_ICON_SRC)" --out "$(GHOSTTOOLS_ICONSET)/icon_256x256.png"    > /dev/null
	@sips -z 512 512   "$(GHOSTTOOLS_ICON_SRC)" --out "$(GHOSTTOOLS_ICONSET)/icon_256x256@2x.png" > /dev/null
	@sips -z 512 512   "$(GHOSTTOOLS_ICON_SRC)" --out "$(GHOSTTOOLS_ICONSET)/icon_512x512.png"    > /dev/null
	@sips -z 1024 1024 "$(GHOSTTOOLS_ICON_SRC)" --out "$(GHOSTTOOLS_ICONSET)/icon_512x512@2x.png" > /dev/null
	iconutil -c icns "$(GHOSTTOOLS_ICONSET)" -o "$(GHOSTTOOLS_ICON_ICNS)"
	@rm -rf "$(GHOSTTOOLS_ICONSET)"
	@echo "GhostToolsIcon.icns created at: $(GHOSTTOOLS_ICON_ICNS)"

# Generate GhostVM app .icns from source PNG
GHOSTVM_ICON_SRC = macOS/GhostVM/Resources/GhostVMIcon.png
GHOSTVM_ICON_ICNS = build/GhostVMIcon.icns
GHOSTVM_ICONSET = build/GhostVMIcon.iconset

ghostvm-icon: $(GHOSTVM_ICON_ICNS)

$(GHOSTVM_ICON_ICNS): $(GHOSTVM_ICON_SRC)
	@echo "Generating GhostVMIcon.icns..."
	@rm -rf "$(GHOSTVM_ICONSET)"
	@mkdir -p "$(GHOSTVM_ICONSET)"
	@sips -z 16 16     "$(GHOSTVM_ICON_SRC)" --out "$(GHOSTVM_ICONSET)/icon_16x16.png"      > /dev/null
	@sips -z 32 32     "$(GHOSTVM_ICON_SRC)" --out "$(GHOSTVM_ICONSET)/icon_16x16@2x.png"   > /dev/null
	@sips -z 32 32     "$(GHOSTVM_ICON_SRC)" --out "$(GHOSTVM_ICONSET)/icon_32x32.png"      > /dev/null
	@sips -z 64 64     "$(GHOSTVM_ICON_SRC)" --out "$(GHOSTVM_ICONSET)/icon_32x32@2x.png"   > /dev/null
	@sips -z 128 128   "$(GHOSTVM_ICON_SRC)" --out "$(GHOSTVM_ICONSET)/icon_128x128.png"    > /dev/null
	@sips -z 256 256   "$(GHOSTVM_ICON_SRC)" --out "$(GHOSTVM_ICONSET)/icon_128x128@2x.png" > /dev/null
	@sips -z 256 256   "$(GHOSTVM_ICON_SRC)" --out "$(GHOSTVM_ICONSET)/icon_256x256.png"    > /dev/null
	@sips -z 512 512   "$(GHOSTVM_ICON_SRC)" --out "$(GHOSTVM_ICONSET)/icon_256x256@2x.png" > /dev/null
	@sips -z 512 512   "$(GHOSTVM_ICON_SRC)" --out "$(GHOSTVM_ICONSET)/icon_512x512.png"    > /dev/null
	@sips -z 1024 1024 "$(GHOSTVM_ICON_SRC)" --out "$(GHOSTVM_ICONSET)/icon_512x512@2x.png" > /dev/null
	iconutil -c icns "$(GHOSTVM_ICONSET)" -o "$(GHOSTVM_ICON_ICNS)"
	@rm -rf "$(GHOSTVM_ICONSET)"
	@echo "GhostVMIcon.icns created at: $(GHOSTVM_ICON_ICNS)"

# Create GhostTools.app bundle and package into DMG
dmg: tools ghosttools-icon
	@echo "Creating GhostTools.app bundle..."
	@rm -rf "$(GHOSTTOOLS_BUILD_DIR)/dmg-stage"
	@mkdir -p "$(GHOSTTOOLS_BUILD_DIR)/dmg-stage/GhostTools.app/Contents/MacOS"
	@mkdir -p "$(GHOSTTOOLS_BUILD_DIR)/dmg-stage/GhostTools.app/Contents/Resources"
	@# Copy executable (patch SDK version for guest compatibility)
	@cp "$(GHOSTTOOLS_DIR)/.build/release/GhostTools" "$(GHOSTTOOLS_BUILD_DIR)/dmg-stage/GhostTools.app/Contents/MacOS/"
	vtool -set-build-version macos 14.0 15.0 -replace -output "$(GHOSTTOOLS_BUILD_DIR)/dmg-stage/GhostTools.app/Contents/MacOS/GhostTools" "$(GHOSTTOOLS_BUILD_DIR)/dmg-stage/GhostTools.app/Contents/MacOS/GhostTools"
	@# Copy Info.plist
	@cp "$(GHOSTTOOLS_DIR)/Sources/GhostTools/Resources/Info.plist" "$(GHOSTTOOLS_BUILD_DIR)/dmg-stage/GhostTools.app/Contents/"
	@# Copy app icon
	@cp "$(GHOSTTOOLS_ICON_ICNS)" "$(GHOSTTOOLS_BUILD_DIR)/dmg-stage/GhostTools.app/Contents/Resources/"
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
VERSION ?= $(shell git describe --tags --always 2>/dev/null || echo "dev")

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
		--entitlements macOS/GhostVMHelper/entitlements.plist \
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
		--entitlements macOS/GhostVM/entitlements.plist \
		-s "$(DIST_CODESIGN_ID)" \
		"$(DIST_DIR)/dmg-stage/$(APP_NAME).app/Contents/MacOS/vmctl"
	@# 5b. Re-create GhostTools.dmg with Developer ID signing for notarization
	@echo "  Re-signing GhostTools for distribution..."
	@rm -rf "$(DIST_DIR)/ghosttools-stage"
	@mkdir -p "$(DIST_DIR)/ghosttools-stage/GhostTools.app/Contents/MacOS"
	@mkdir -p "$(DIST_DIR)/ghosttools-stage/GhostTools.app/Contents/Resources"
	@cp "$(GHOSTTOOLS_DIR)/.build/release/GhostTools" "$(DIST_DIR)/ghosttools-stage/GhostTools.app/Contents/MacOS/"
	@cp "$(GHOSTTOOLS_DIR)/Sources/GhostTools/Resources/Info.plist" "$(DIST_DIR)/ghosttools-stage/GhostTools.app/Contents/"
	@cp "$(GHOSTTOOLS_ICON_ICNS)" "$(DIST_DIR)/ghosttools-stage/GhostTools.app/Contents/Resources/"
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
		--entitlements macOS/GhostVM/entitlements.plist \
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

# Capture XCUITest screenshots for the website
screenshots: $(XCODE_PROJECT)
	./scripts/capture-screenshots.sh

# Run the Next.js dev server
website:
	cd Website && npm run dev

# Build the Next.js site for production
website-build:
	cd Website && npm run build

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
	@echo "  make generate - Generate Xcode project from macOS/project.yml"
	@echo "  make app      - Build SwiftUI app via xcodebuild"
	@echo "  make debug    - Build SwiftUI app in Debug configuration"
	@echo "  make run      - Build and run attached to terminal"
	@echo "  make launch   - Build and launch detached"
	@echo "  make test     - Run unit tests"
	@echo "  make tools    - Build GhostTools guest agent"
	@echo "  make debug-tools - Build GhostTools debug binary (lldb-compatible with macOS 15)"
	@echo "  make dmg      - Create GhostTools.dmg"
	@echo "  make dist     - Create distribution DMG with app + vmctl"
	@echo "  make screenshots - Capture XCUITest screenshots for website"
	@echo "  make website  - Run Next.js dev server (Website/)"
	@echo "  make website-build - Build Next.js site for production"
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
