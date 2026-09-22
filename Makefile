-include local.env
export

SWIFTC     ?= swiftc
SWIFTFLAGS ?= -O -swift-version 5 -parse-as-library

MACOS_MIN                = 14.0
MACOSX_DEPLOYMENT_TARGET = $(MACOS_MIN)
SWIFT_TARGET             ?= $(shell uname -m)-apple-macosx$(MACOS_MIN)
SDK                      := $(shell xcrun --show-sdk-path)
LDFLAGS                  = -framework AppKit -framework SwiftUI

SRCS       = $(wildcard Sources/*.swift)
BIN        = agent-usage
APP_NAME   = AUB
APP_BUNDLE = $(APP_NAME).app
ICON       = Resources/AppIcon.icns
ICONSET    = build/AppIcon.iconset
ICON_PNG   = build/AppIcon-1024.png
ICON_SIZES = 16 32 128 256 512
INSTALL_DIR ?= /Applications
VERSION    = $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Sources/Info.plist)

.PHONY: build app icon install release test clean

build: $(BIN)

$(BIN): $(SRCS) Makefile
	$(SWIFTC) $(SWIFTFLAGS) -target $(SWIFT_TARGET) -sdk $(SDK) -o $@ $(SRCS) $(LDFLAGS)

app: build
	@echo "==> Building $(APP_BUNDLE)..."
	@rm -rf "$(APP_BUNDLE)"
	@mkdir -p "$(APP_BUNDLE)/Contents/MacOS" "$(APP_BUNDLE)/Contents/Resources"
	@cp $(BIN) "$(APP_BUNDLE)/Contents/MacOS/$(BIN)"
	@cp Sources/Info.plist "$(APP_BUNDLE)/Contents/Info.plist"
	@cp $(ICON) "$(APP_BUNDLE)/Contents/Resources/AppIcon.icns"
	@codesign --force --sign - "$(APP_BUNDLE)"
	@echo "==> Built $(APP_BUNDLE)"

# Regenerates $(ICON) from the robot glyph. Needs only the Xcode CLI tools.
icon:
	@echo "==> Rendering $(ICON)..."
	@rm -rf "$(ICONSET)"
	@mkdir -p "$(ICONSET)" Resources
	@swift scripts/make-icon.swift "$(ICON_PNG)" 1024
	@for s in $(ICON_SIZES); do \
		sips -z $$s $$s "$(ICON_PNG)" --out "$(ICONSET)/icon_$${s}x$${s}.png" >/dev/null; \
		sips -z $$(($$s * 2)) $$(($$s * 2)) "$(ICON_PNG)" --out "$(ICONSET)/icon_$${s}x$${s}@2x.png" >/dev/null; \
	done
	@iconutil -c icns "$(ICONSET)" -o $(ICON)
	@echo "==> Wrote $(ICON)"

install: app
	@echo "==> Installing to $(INSTALL_DIR)/$(APP_BUNDLE)..."
	@rm -rf "$(INSTALL_DIR)/$(APP_BUNDLE)"
	@cp -R "$(APP_BUNDLE)" "$(INSTALL_DIR)/$(APP_BUNDLE)"
	@touch "$(INSTALL_DIR)/$(APP_BUNDLE)"
	@echo "==> Installed $(INSTALL_DIR)/$(APP_BUNDLE)"

release: app
	@mkdir -p dist
	@rm -f "dist/AUB-$(VERSION).zip"
	@ditto -c -k --keepParent "$(APP_BUNDLE)" "dist/AUB-$(VERSION).zip"
	@echo "==> Wrote dist/AUB-$(VERSION).zip"

test:
	swift test

clean:
	rm -f $(BIN)
	rm -rf "$(APP_BUNDLE)" .build build dist
