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
APP_NAME   = Agent Usage
APP_BUNDLE = $(APP_NAME).app

.PHONY: build app test clean

build: $(BIN)

$(BIN): $(SRCS) Makefile
	$(SWIFTC) $(SWIFTFLAGS) -target $(SWIFT_TARGET) -sdk $(SDK) -o $@ $(SRCS) $(LDFLAGS)

app: build
	@echo "==> Building $(APP_BUNDLE)..."
	@rm -rf "$(APP_BUNDLE)"
	@mkdir -p "$(APP_BUNDLE)/Contents/MacOS"
	@cp $(BIN) "$(APP_BUNDLE)/Contents/MacOS/$(BIN)"
	@cp Sources/Info.plist "$(APP_BUNDLE)/Contents/Info.plist"
	@codesign --force --sign - "$(APP_BUNDLE)"
	@echo "==> Built $(APP_BUNDLE)"

test:
	swift test

clean:
	rm -f $(BIN)
	rm -rf "$(APP_BUNDLE)" .build
