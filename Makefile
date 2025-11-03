SWIFTC ?= swiftc
TARGET ?= vmctl
SOURCES := vmctl.swift
FRAMEWORKS := -framework Virtualization -framework AppKit
SWIFTFLAGS := -parse-as-library

.PHONY: all build clean run

all: build

build:
	$(SWIFTC) $(SWIFTFLAGS) -o $(TARGET) $(SOURCES) $(FRAMEWORKS)

run: build
	./$(TARGET)

clean:
	rm -f $(TARGET)
