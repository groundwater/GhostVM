SWIFTC ?= swiftc
TARGET ?= vmctl
SOURCES := vmctl.swift
FRAMEWORKS := -framework Virtualization -framework AppKit
SWIFTFLAGS := -parse-as-library
CODESIGN_ID ?=
ENTITLEMENTS := entitlements.plist

.PHONY: all build clean run

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

clean:
	rm -f $(TARGET)
