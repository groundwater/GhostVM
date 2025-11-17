# Load optional local secrets/overrides (e.g., NOTARY_* credentials) from .env.
ifneq (,$(wildcard .env))
ENV_VARS := $(shell sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' .env)
include .env
export $(ENV_VARS)
endif

SWIFTC ?= swiftc
TARGET ?= vmctl
SOURCES := vmctl.swift
FRAMEWORKS := -framework Virtualization -framework AppKit
SWIFTFLAGS := -parse-as-library
CODESIGN_ID ?= -
ENTITLEMENTS := entitlements.plist
APP_TARGET ?= GhostVM
APP_SOURCES := VMApp.swift vmctl.swift
APP_BUNDLE := $(APP_TARGET).app
APP_PLIST := VMApp-Info.plist
APP_DISPLAY_NAME ?= $(APP_TARGET)
APP2_TARGET ?= GhostVM-SwiftUI
APP2_SOURCES := SwiftUIDemoApp.swift App2Models.swift App2VMRuntime.swift App2VMDisplayHost.swift
APP2_BUNDLE := $(APP2_TARGET).app
APP2_PLIST := VMApp-Info.plist
APP2_DISPLAY_NAME ?= $(APP2_TARGET)
APP2_SWIFTFLAGS := -parse-as-library
APP2_FRAMEWORKS := -framework SwiftUI -framework Virtualization -framework AppKit
DMG ?= $(APP_TARGET).dmg
DMG_VOLNAME ?= $(APP_DISPLAY_NAME)
DMG_STAGING := build/dmg-root
DEFAULT_DEVELOPER_ID := $(shell security find-identity -p codesigning -v 2>/dev/null | grep "Developer ID Application" | head -n1 | sed -E 's/.*"(Developer ID Application: [^"]+)".*/\1/' )
DEFAULT_TEAM_ID := $(shell security find-identity -p codesigning -v 2>/dev/null | grep "Developer ID Application" | head -n1 | sed -E 's/.*Developer ID Application: .* \(([A-Z0-9]+)\)".*/\1/' )
NOTARYTOOL_HAS_LIST_PROFILES := $(shell xcrun notarytool --help 2>/dev/null | grep -q "list-profiles" && echo 1 || echo 0)
ifeq ($(NOTARYTOOL_HAS_LIST_PROFILES),1)
DEFAULT_NOTARY_PROFILE := $(shell xcrun notarytool list-profiles 2>/dev/null | awk 'NR>2 && $$1!="--" {print $$1; exit}')
else
DEFAULT_NOTARY_PROFILE :=
endif
RELEASE_CODESIGN_ID ?= $(DEFAULT_DEVELOPER_ID)
NOTARY_KEYCHAIN_PROFILE ?= $(DEFAULT_NOTARY_PROFILE)
NOTARY_APPLE_ID ?=
NOTARY_TEAM_ID ?= $(DEFAULT_TEAM_ID)
NOTARY_PASSWORD ?=

.PHONY: all build clean run app app2 dmg notary-info

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
	cp ghostvm.png $(APP_BUNDLE)/Contents/Resources/ghostvm.png
	cp ghostvm-dark.png $(APP_BUNDLE)/Contents/Resources/ghostvm-dark.png
	cp racecar.png $(APP_BUNDLE)/Contents/Resources/racecar.png
	# Build a proper .icns for GhostVM bundles from GhostVMIcon.png
	rm -rf build/GhostVMIcon.iconset
	mkdir -p build/GhostVMIcon.iconset
	sips -z 16 16 GhostVMIcon.png --out build/GhostVMIcon.iconset/icon_16x16.png >/dev/null
	sips -z 32 32 GhostVMIcon.png --out build/GhostVMIcon.iconset/icon_16x16@2x.png >/dev/null
	sips -z 32 32 GhostVMIcon.png --out build/GhostVMIcon.iconset/icon_32x32.png >/dev/null
	sips -z 64 64 GhostVMIcon.png --out build/GhostVMIcon.iconset/icon_32x32@2x.png >/dev/null
	sips -z 128 128 GhostVMIcon.png --out build/GhostVMIcon.iconset/icon_128x128.png >/dev/null
	sips -z 256 256 GhostVMIcon.png --out build/GhostVMIcon.iconset/icon_128x128@2x.png >/dev/null
	sips -z 256 256 GhostVMIcon.png --out build/GhostVMIcon.iconset/icon_256x256.png >/dev/null
	sips -z 512 512 GhostVMIcon.png --out build/GhostVMIcon.iconset/icon_256x256@2x.png >/dev/null
	sips -z 512 512 GhostVMIcon.png --out build/GhostVMIcon.iconset/icon_512x512.png >/dev/null
	cp GhostVMIcon.png build/GhostVMIcon.iconset/icon_512x512@2x.png
	iconutil -c icns build/GhostVMIcon.iconset -o build/GhostVMIcon.icns
	cp build/GhostVMIcon.icns $(APP_BUNDLE)/Contents/Resources/GhostVMIcon.icns
	@if [ "$(CODESIGN_ID)" = "-" ]; then \
		echo "Codesigning $(APP_BUNDLE) with ad-hoc identity to apply entitlements."; \
	fi
	codesign --force --sign "$(CODESIGN_ID)" --entitlements "$(ENTITLEMENTS)" "$(APP_BUNDLE)"

app2:
	rm -rf $(APP2_BUNDLE)
	mkdir -p $(APP2_BUNDLE)/Contents/MacOS
	mkdir -p $(APP2_BUNDLE)/Contents/Resources
	cp $(APP2_PLIST) $(APP2_BUNDLE)/Contents/Info.plist
	/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $(APP2_TARGET)" $(APP2_BUNDLE)/Contents/Info.plist
	/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $(APP2_DISPLAY_NAME)" $(APP2_BUNDLE)/Contents/Info.plist
	/usr/libexec/PlistBuddy -c "Set :CFBundleName $(APP2_DISPLAY_NAME)" $(APP2_BUNDLE)/Contents/Info.plist
	$(SWIFTC) $(APP2_SWIFTFLAGS) -o $(APP2_BUNDLE)/Contents/MacOS/$(APP2_TARGET) $(APP2_SOURCES) $(APP2_FRAMEWORKS)
	cp ghostvm.png $(APP2_BUNDLE)/Contents/Resources/ghostvm.png
	cp ghostvm-dark.png $(APP2_BUNDLE)/Contents/Resources/ghostvm-dark.png
	cp racecar.png $(APP2_BUNDLE)/Contents/Resources/racecar.png
	@if [ "$(CODESIGN_ID)" = "-" ]; then \
		echo "Codesigning $(APP2_BUNDLE) with ad-hoc identity to apply entitlements."; \
	fi
	codesign --force --sign "$(CODESIGN_ID)" --entitlements "$(ENTITLEMENTS)" "$(APP2_BUNDLE)"

dmg: app
	@if [ -z "$(RELEASE_CODESIGN_ID)" ] || [ "$(RELEASE_CODESIGN_ID)" = "-" ]; then \
		echo "RELEASE_CODESIGN_ID must be set to a valid signing identity (e.g. 'Developer ID Application: Your Name (TEAMID)')."; \
		echo "Run 'make notary-info' to see detected identities."; \
		exit 1; \
	fi
	@echo "Re-signing app bundle with hardened runtime using $(RELEASE_CODESIGN_ID)"
	codesign --force --options runtime --timestamp --sign "$(RELEASE_CODESIGN_ID)" --entitlements "$(ENTITLEMENTS)" "$(APP_BUNDLE)/Contents/MacOS/$(APP_TARGET)"
	codesign --force --options runtime --timestamp --sign "$(RELEASE_CODESIGN_ID)" --entitlements "$(ENTITLEMENTS)" "$(APP_BUNDLE)/Contents/MacOS/vmctl"
	codesign --force --options runtime --timestamp --sign "$(RELEASE_CODESIGN_ID)" --entitlements "$(ENTITLEMENTS)" --deep "$(APP_BUNDLE)"
	codesign --verify --deep --strict "$(APP_BUNDLE)"
	@echo "Creating staged DMG payload"
	rm -rf "$(DMG_STAGING)"
	mkdir -p "$(DMG_STAGING)"
	cp -R "$(APP_BUNDLE)" "$(DMG_STAGING)/"
	ln -sf /Applications "$(DMG_STAGING)/Applications"
	hdiutil create -fs HFS+ -volname "$(DMG_VOLNAME)" -srcfolder "$(DMG_STAGING)" -format UDZO -ov "$(DMG)"
	rm -rf "$(DMG_STAGING)"
	@echo "Submitting $(DMG) for notarization"
	@if [ -n "$(NOTARY_KEYCHAIN_PROFILE)" ]; then \
		xcrun notarytool submit "$(DMG)" --keychain-profile "$(NOTARY_KEYCHAIN_PROFILE)" --wait; \
	elif [ -n "$(NOTARY_APPLE_ID)" ] && [ -n "$(NOTARY_TEAM_ID)" ] && [ -n "$(NOTARY_PASSWORD)" ]; then \
		xcrun notarytool submit "$(DMG)" --apple-id "$(NOTARY_APPLE_ID)" --team-id "$(NOTARY_TEAM_ID)" --password "$(NOTARY_PASSWORD)" --wait; \
	else \
		echo "Set NOTARY_KEYCHAIN_PROFILE or NOTARY_APPLE_ID/NOTARY_TEAM_ID/NOTARY_PASSWORD before running 'make dmg'."; \
		echo "Run 'make notary-info' for commands that create these credentials."; \
		rm -f "$(DMG)"; \
		exit 1; \
	fi
	xcrun stapler staple "$(APP_BUNDLE)"
	xcrun stapler staple "$(DMG)"
	spctl --assess --type execute "$(APP_BUNDLE)"
	@echo "DMG ready: $(DMG)"

notary-info:
	@echo "Detected Developer ID Application identity: $(if $(DEFAULT_DEVELOPER_ID),$(DEFAULT_DEVELOPER_ID),<none>)"
	@echo "Detected Team ID: $(if $(DEFAULT_TEAM_ID),$(DEFAULT_TEAM_ID),<none>)"
		@if [ "$(NOTARYTOOL_HAS_LIST_PROFILES)" = "1" ]; then \
			if [ -n "$(DEFAULT_NOTARY_PROFILE)" ]; then \
				echo "Available notarytool profile: $(DEFAULT_NOTARY_PROFILE)"; \
			else \
				echo "No notarytool profiles found via 'xcrun notarytool list-profiles'."; \
			fi; \
		else \
			echo "'xcrun notarytool' on this machine does not support 'list-profiles'; skipping auto-detection of profiles."; \
		fi
	@echo
		@echo "To create a profile (preferred):"
		@echo '  xcrun notarytool store-credentials ghostvm-notary --apple-id "you@example.com" \'
		@echo "      --team-id $(if $(DEFAULT_TEAM_ID),$(DEFAULT_TEAM_ID),TEAMID) --password \"<app-specific-password>\""
		@echo "Then run: RELEASE_CODESIGN_ID=\"$$(security find-identity -p codesigning -v 2>/dev/null | grep 'Developer ID Application' | head -n1 | sed -E 's/.*\"(Developer ID Application: [^\"]+)\".*/\1/')\" NOTARY_KEYCHAIN_PROFILE=ghostvm-notary make dmg"
	@echo
	@echo "To skip profiles, export NOTARY_APPLE_ID, NOTARY_TEAM_ID, and NOTARY_PASSWORD (app-specific) before 'make dmg'."

clean:
	rm -f $(TARGET)
	rm -rf $(APP_BUNDLE)
