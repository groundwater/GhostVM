# GhostVM Makefile
# Builds vmctl CLI and the SwiftUI app via xcodebuild

# Load .env for notarization credentials (NOTARY_APPLE_ID, NOTARY_TEAM_ID, NOTARY_PASSWORD)
-include .env
export

CODESIGN_ID ?= Apple Development
GHOSTTOOLS_SIGN_ID ?= $(CODESIGN_ID)

# Xcode project settings (generated via xcodegen)
XCODE_PROJECT = macOS/GhostVM.xcodeproj
XCODE_CONFIG ?= Release
BUILD_DIR = build/xcode
APP_NAME = GhostVM

.PHONY: all cli app clean help run launch generate test framework dist tools debug-tools dmg ghosttools-icon ghostvm-icon debug website website-build sparkle-tools sparkle-sign capture composite screenshots bump check-version

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

# Build the SwiftUI app in Debug configuration (ad-hoc signing)
debug: $(XCODE_PROJECT) dmg ghostvm-icon
	xcodebuild -project $(XCODE_PROJECT) \
		-scheme $(APP_NAME) \
		-configuration Debug \
		-derivedDataPath $(BUILD_DIR) \
		CODE_SIGN_STYLE=Manual \
		CODE_SIGN_IDENTITY=- \
		DEVELOPMENT_TEAM= \
		CODE_SIGNING_ALLOWED=NO \
		CODE_SIGNING_REQUIRED=NO \
		build
	@# Copy icons into app bundle Resources
	@mkdir -p "$(BUILD_DIR)/Build/Products/Debug/$(APP_NAME).app/Contents/Resources"
	@cp macOS/GhostVM/Resources/ghostvm.png "$(BUILD_DIR)/Build/Products/Debug/$(APP_NAME).app/Contents/Resources/"
	@cp macOS/GhostVM/Resources/ghostvm-dark.png "$(BUILD_DIR)/Build/Products/Debug/$(APP_NAME).app/Contents/Resources/"
	@cp build/GhostVMIcon.icns "$(BUILD_DIR)/Build/Products/Debug/$(APP_NAME).app/Contents/Resources/GhostVMIcon.icns"
	@# Copy GhostTools.dmg into app bundle Resources
	@cp "$(GHOSTTOOLS_DMG)" "$(BUILD_DIR)/Build/Products/Debug/$(APP_NAME).app/Contents/Resources/"
	@# Sign helper and app ad-hoc with entitlements
	codesign --entitlements macOS/GhostVMHelper/entitlements.plist --force --deep -s "-" "$(BUILD_DIR)/Build/Products/Debug/$(APP_NAME).app/Contents/PlugIns/Helpers/GhostVMHelper.app"
	codesign --entitlements macOS/GhostVM/entitlements.plist --force -s "-" "$(BUILD_DIR)/Build/Products/Debug/$(APP_NAME).app"
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

# Generate website screenshots from UI tests
# Step 1: capture — runs XCUITests, saves raw PNGs to build/screenshots/
# Step 2: composite — processes raw captures into final website images
SCREENSHOT_RAW = $(BUILD_DIR)/screenshots
SCREENSHOT_DEST = Website/public/images/screenshots
UITEST_CONTAINER = $(HOME)/Library/Containers/org.ghostvm.ghostvm.uitests.xctrunner/Data/tmp/GhostVM-Screenshots
HELPER_UITEST_CONTAINER = $(HOME)/Library/Containers/org.ghostvm.ghostvm.helper.uitests.xctrunner/Data/tmp/GhostVM-Screenshots

# Capture raw screenshots from XCUITests → build/screenshots/
capture: $(XCODE_PROJECT)
	@rm -rf "$(UITEST_CONTAINER)" "$(HELPER_UITEST_CONTAINER)"
	xcodebuild build-for-testing -project $(XCODE_PROJECT) -scheme GhostVMUITests \
		-derivedDataPath $(BUILD_DIR) -destination 'platform=macOS'
	xcodebuild build-for-testing -project $(XCODE_PROJECT) -scheme GhostVMHelperUITests \
		-derivedDataPath $(BUILD_DIR) -destination 'platform=macOS'
	xcodebuild test-without-building -project $(XCODE_PROJECT) -scheme GhostVMUITests \
		-derivedDataPath $(BUILD_DIR) -destination 'platform=macOS' \
		-only-testing:GhostVMUITests/ScreenshotTests
	xcodebuild test-without-building -project $(XCODE_PROJECT) -scheme GhostVMHelperUITests \
		-derivedDataPath $(BUILD_DIR) -destination 'platform=macOS' \
		-only-testing:GhostVMHelperUITests/HelperScreenshotTests
	@mkdir -p "$(SCREENSHOT_RAW)"
	@if [ -d "$(UITEST_CONTAINER)" ]; then cp "$(UITEST_CONTAINER)"/*.png "$(SCREENSHOT_RAW)/"; fi
	@if [ -d "$(HELPER_UITEST_CONTAINER)" ]; then cp "$(HELPER_UITEST_CONTAINER)"/*.png "$(SCREENSHOT_RAW)/"; fi
	@echo "Raw captures saved to $(SCREENSHOT_RAW)/:"
	@ls -1 "$(SCREENSHOT_RAW)"/ 2>/dev/null | while read f; do echo "  $$f"; done

# Composite raw captures into final website images → Website/public/images/screenshots/
composite:
	@if [ ! -d "$(SCREENSHOT_RAW)" ]; then echo "No raw captures found. Run 'make capture' first."; exit 1; fi
	@mkdir -p "$(SCREENSHOT_DEST)"
	@cp "$(SCREENSHOT_RAW)"/*.png "$(SCREENSHOT_DEST)/"
	@# Composite helper-window captures onto host desktop wallpaper (before flattening — needs alpha)
	swift scripts/composite-screenshots.swift Resources "$(SCREENSHOT_DEST)"
	@# Flatten all PNGs to RGB (remove alpha transparency artifacts)
	@for f in "$(SCREENSHOT_DEST)"/*.png; do \
		python3 -c "from PIL import Image; img=Image.open('$$f'); img.convert('RGB').save('$$f')" 2>/dev/null; \
	done
	@# Convert composites to JPEG for web
	@for f in "$(SCREENSHOT_DEST)/multiple-vms.png" "$(SCREENSHOT_DEST)/vm-integration.png" "$(SCREENSHOT_DEST)/hero-screenshot.png"; do \
		sips -s format jpeg -s formatOptions 85 "$$f" --out "$${f%.png}.jpg" >/dev/null 2>&1 && rm "$$f"; \
	done
	@echo "Website images saved to $(SCREENSHOT_DEST)/:"
	@ls -1 "$(SCREENSHOT_DEST)"/ 2>/dev/null | while read f; do echo "  $$f"; done

# Full pipeline: capture + composite
screenshots: capture composite

# GhostTools settings
GHOSTTOOLS_DIR = macOS/GhostTools
GHOSTTOOLS_BUILD_DIR = $(BUILD_DIR)/GhostTools
GHOSTTOOLS_APP = $(GHOSTTOOLS_BUILD_DIR)/GhostTools.app
GHOSTTOOLS_DMG = $(BUILD_DIR)/GhostTools.dmg

# Build GhostTools guest agent (.app bundle, signed)
tools: ghosttools-icon
	@echo "Building GhostTools..."
	@echo "Injecting build timestamp..."
	@TIMESTAMP=$$(date +%s); \
	plutil -replace CFBundleVersion -string "$$TIMESTAMP" \
		"$(GHOSTTOOLS_DIR)/Sources/GhostTools/Resources/Info.plist"
	@# Force relink so the embedded __TEXT/__info_plist picks up the new timestamp
	@rm -f "$(GHOSTTOOLS_BUILD_DIR)/release/GhostTools"
	swift build --package-path $(GHOSTTOOLS_DIR) --scratch-path $(GHOSTTOOLS_BUILD_DIR) -c release
	@# Assemble .app bundle
	@rm -rf "$(GHOSTTOOLS_APP)"
	@mkdir -p "$(GHOSTTOOLS_APP)/Contents/MacOS"
	@mkdir -p "$(GHOSTTOOLS_APP)/Contents/Resources"
	@cp "$(GHOSTTOOLS_BUILD_DIR)/release/GhostTools" "$(GHOSTTOOLS_APP)/Contents/MacOS/"
	vtool -set-build-version macos 14.0 15.0 -replace -output "$(GHOSTTOOLS_APP)/Contents/MacOS/GhostTools" "$(GHOSTTOOLS_APP)/Contents/MacOS/GhostTools"
	@cp "$(GHOSTTOOLS_DIR)/Sources/GhostTools/Resources/Info.plist" "$(GHOSTTOOLS_APP)/Contents/"
	@cp "$(GHOSTTOOLS_ICON_ICNS)" "$(GHOSTTOOLS_APP)/Contents/Resources/"
	codesign --force --deep --entitlements "$(GHOSTTOOLS_DIR)/Sources/GhostTools/Resources/entitlements.plist" -s "$(GHOSTTOOLS_SIGN_ID)" "$(GHOSTTOOLS_APP)"
	@echo "GhostTools.app built at: $(GHOSTTOOLS_APP)"

# Build GhostTools debug binary for guest VM debugging
debug-tools:
	@echo "Building GhostTools (debug)..."
	swift build --package-path $(GHOSTTOOLS_DIR) --scratch-path $(GHOSTTOOLS_BUILD_DIR)
	@echo "Patching SDK version for guest compatibility..."
	vtool -set-build-version macos 14.0 15.0 -replace \
		-output $(GHOSTTOOLS_BUILD_DIR)/debug/GhostTools-debug \
		$(GHOSTTOOLS_BUILD_DIR)/debug/GhostTools
	codesign --force -s "-" $(GHOSTTOOLS_BUILD_DIR)/debug/GhostTools-debug
	@echo "Debug binary: $(GHOSTTOOLS_BUILD_DIR)/debug/GhostTools-debug"
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

# Package GhostTools.app into a DMG
dmg: tools
	@echo "Creating GhostTools.dmg..."
	@rm -rf "$(GHOSTTOOLS_BUILD_DIR)/dmg-stage"
	@mkdir -p "$(GHOSTTOOLS_BUILD_DIR)/dmg-stage"
	@cp -R "$(GHOSTTOOLS_APP)" "$(GHOSTTOOLS_BUILD_DIR)/dmg-stage/"
	@cp "$(GHOSTTOOLS_DIR)/README.txt" "$(GHOSTTOOLS_BUILD_DIR)/dmg-stage/"
	@rm -f "$(GHOSTTOOLS_DMG)"
	hdiutil makehybrid -o "$(GHOSTTOOLS_DMG)" \
		-hfs \
		-hfs-volume-name "GhostTools" \
		"$(GHOSTTOOLS_BUILD_DIR)/dmg-stage"
	@echo "GhostTools.dmg created at: $(GHOSTTOOLS_DMG)"

# Sparkle tools for signing updates
SPARKLE_TOOLS_DIR = tools/sparkle

$(SPARKLE_TOOLS_DIR)/bin/sign_update:
	@echo "Downloading Sparkle tools..."
	@mkdir -p $(SPARKLE_TOOLS_DIR)
	@SPARKLE_TAG=$$(curl -sI https://github.com/sparkle-project/Sparkle/releases/latest | grep -i '^location:' | sed 's|.*/||' | tr -d '\r'); \
	echo "  Sparkle version: $$SPARKLE_TAG"; \
	curl -L -o /tmp/sparkle.tar.xz \
		"https://github.com/sparkle-project/Sparkle/releases/download/$$SPARKLE_TAG/Sparkle-$$SPARKLE_TAG.tar.xz" && \
	tar -xf /tmp/sparkle.tar.xz -C $(SPARKLE_TOOLS_DIR) bin/ && \
	rm /tmp/sparkle.tar.xz

sparkle-tools: $(SPARKLE_TOOLS_DIR)/bin/sign_update

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
	@# Verify notarization credentials are set
	@if [ -z "$(NOTARY_APPLE_ID)" ] || [ -z "$(NOTARY_TEAM_ID)" ] || [ -z "$(NOTARY_PASSWORD)" ]; then \
		echo "ERROR: Notarization requires NOTARY_APPLE_ID, NOTARY_TEAM_ID, and NOTARY_PASSWORD"; \
		echo "Set these in a .env file or as environment variables."; \
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
	@# 2b. Sign Sparkle nested components (XPC services, Autoupdate helper)
	@for xpc in "$(DIST_DIR)/dmg-stage/$(APP_NAME).app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/"*.xpc 2>/dev/null; do \
		if [ -d "$$xpc" ]; then \
			echo "  Signing $$(basename $$xpc) (Sparkle XPC)"; \
			codesign --force --options runtime --timestamp -s "$(DIST_CODESIGN_ID)" "$$xpc"; \
		fi; \
	done
	@if [ -d "$(DIST_DIR)/dmg-stage/$(APP_NAME).app/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate.app" ]; then \
		echo "  Signing Autoupdate.app (Sparkle)"; \
		codesign --force --options runtime --timestamp -s "$(DIST_CODESIGN_ID)" \
			"$(DIST_DIR)/dmg-stage/$(APP_NAME).app/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate.app"; \
	fi
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
	@mkdir -p "$(DIST_DIR)/ghosttools-stage"
	@cp -R "$(GHOSTTOOLS_APP)" "$(DIST_DIR)/ghosttools-stage/"
	@cp "$(GHOSTTOOLS_DIR)/README.txt" "$(DIST_DIR)/ghosttools-stage/"
	codesign --force --options runtime --timestamp --deep --entitlements "$(GHOSTTOOLS_DIR)/Sources/GhostTools/Resources/entitlements.plist" -s "$(DIST_CODESIGN_ID)" "$(DIST_DIR)/ghosttools-stage/GhostTools.app"
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
	xcrun notarytool submit "$(DIST_DIR)/$(DMG_NAME)-$(VERSION).dmg" \
		--apple-id "$(NOTARY_APPLE_ID)" \
		--team-id "$(NOTARY_TEAM_ID)" \
		--password "$(NOTARY_PASSWORD)" \
		--wait
	xcrun stapler staple "$(DIST_DIR)/$(DMG_NAME)-$(VERSION).dmg"
	@echo "Distribution created: $(DIST_DIR)/$(DMG_NAME)-$(VERSION).dmg"
	@echo "vmctl is at: $(APP_NAME).app/Contents/MacOS/vmctl"

# Sign DMG for Sparkle auto-updates (run after make dist)
sparkle-sign: sparkle-tools
	@echo "Signing DMG for Sparkle..."
	$(SPARKLE_TOOLS_DIR)/bin/sign_update "$(DIST_DIR)/$(DMG_NAME)-$(VERSION).dmg"
	@echo ""
	@echo "Add the above edSignature and length to Website/public/appcast.xml"

# Run the Next.js dev server
website:
	cd Website && npm run dev

# Build the Next.js site for production
website-build:
	cd Website && npm run build

# Plist paths for version management
PLIST_GHOSTVM = macOS/GhostVM/VMApp-Info.plist
PLIST_HELPER  = macOS/GhostVMHelper/Info.plist
PLIST_TOOLS   = macOS/GhostTools/Sources/GhostTools/Resources/Info.plist

# Bump CFBundleShortVersionString in all 3 targets, CFBundleVersion in GhostVM + Helper only
# Usage: make bump VERSION=1.2.0
bump:
	@if [ -z "$(VERSION)" ] || [ "$(VERSION)" = "$$(git describe --tags --always 2>/dev/null || echo dev)" ]; then \
		echo "Usage: make bump VERSION=x.y.z"; exit 1; \
	fi
	@echo "Bumping all targets to $(VERSION)..."
	plutil -replace CFBundleShortVersionString -string "$(VERSION)" "$(PLIST_GHOSTVM)"
	plutil -replace CFBundleVersion            -string "$(VERSION)" "$(PLIST_GHOSTVM)"
	plutil -replace CFBundleShortVersionString -string "$(VERSION)" "$(PLIST_HELPER)"
	plutil -replace CFBundleVersion            -string "$(VERSION)" "$(PLIST_HELPER)"
	plutil -replace CFBundleShortVersionString -string "$(VERSION)" "$(PLIST_TOOLS)"
	@echo "Done. GhostTools CFBundleVersion left unchanged (auto-injected build timestamp)."
	@$(MAKE) --no-print-directory check-version

# Verify all 3 targets have the same CFBundleShortVersionString
check-version:
	@V1=$$(plutil -extract CFBundleShortVersionString raw "$(PLIST_GHOSTVM)"); \
	V2=$$(plutil -extract CFBundleShortVersionString raw "$(PLIST_HELPER)"); \
	V3=$$(plutil -extract CFBundleShortVersionString raw "$(PLIST_TOOLS)"); \
	echo "GhostVM:       $$V1"; \
	echo "GhostVMHelper: $$V2"; \
	echo "GhostTools:    $$V3"; \
	if [ "$$V1" = "$$V2" ] && [ "$$V2" = "$$V3" ]; then \
		echo "All targets in sync ($$V1)"; \
	else \
		echo "ERROR: Version mismatch!" >&2; exit 1; \
	fi

clean:
	rm -rf build
	rm -rf $(XCODE_PROJECT)

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
	@echo "  make capture     - Capture raw screenshots from UI tests → build/screenshots/"
	@echo "  make composite   - Composite raw captures into website images"
	@echo "  make screenshots - Full pipeline: capture + composite"
	@echo "  make tools    - Build GhostTools guest agent"
	@echo "  make debug-tools - Build GhostTools debug binary (lldb-compatible with macOS 15)"
	@echo "  make dmg      - Create GhostTools.dmg"
	@echo "  make dist     - Create distribution DMG with app + vmctl"
	@echo "  make sparkle-tools - Download Sparkle signing tools"
	@echo "  make sparkle-sign  - Sign DMG for Sparkle auto-updates"
	@echo "  make website  - Run Next.js dev server (Website/)"
	@echo "  make website-build - Build Next.js site for production"
	@echo "  make bump VERSION=x.y.z - Bump version in all 3 targets"
	@echo "  make check-version     - Verify all targets have the same version"
	@echo "  make clean    - Remove build artifacts and generated project"
	@echo ""
	@echo "Variables:"
	@echo "  CODESIGN_ID   - Code signing identity (default: Apple Development)"
	@echo "  XCODE_CONFIG  - Xcode build configuration (default: Release)"
	@echo "  VERSION       - Version for DMG (default: git describe)"
	@echo ""
	@echo "Notarization (via .env file or environment):"
	@echo "  NOTARY_APPLE_ID  - Apple ID for notarization"
	@echo "  NOTARY_TEAM_ID   - Team ID for notarization"
	@echo "  NOTARY_PASSWORD  - App-specific password for notarization"
	@echo ""
	@echo "Requires: xcodegen (brew install xcodegen)"
