APP        := Switcher
CONFIG     := release
DIST       := dist
APP_BUNDLE := $(DIST)/$(APP).app
VERSION    := $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
TARBALL    := $(DIST)/$(APP)-$(VERSION).tar.gz

# Scratch paths. Overridable because some sandboxed environments upset SwiftPM's
# SQLite build database when it lives under the repo.
BUILD_DIR  ?= .build
X86_DIR    := $(BUILD_DIR)-x86

# Ship a universal binary so Intel Macs work. UNIVERSAL=0 builds native-only,
# which is roughly twice as fast while developing.
UNIVERSAL  ?= 1
X86_TARGET := x86_64-apple-macosx14.0

# Homebrew builds in its own sandbox; it passes --disable-sandbox through here.
SWIFT_EXTRA ?=

BINARIES := SwitcherApp switcher

.PHONY: all build test icon app install uninstall run clean dist-source help

all: app

help:
	@echo "make app           build $(APP).app into $(DIST)/"
	@echo "make install       build and install to ~/Applications"
	@echo "make run           build, install nothing, just launch"
	@echo "make test          run the self-test suite"
	@echo "make icon          regenerate Resources/AppIcon.icns"
	@echo "make dist-source   tarball + sha256 for the Homebrew formula"
	@echo "make clean         remove build and dist output"
	@echo ""
	@echo "UNIVERSAL=0        skip the x86_64 slice (faster local builds)"
	@echo "BUILD_DIR=<path>   build somewhere other than ./.build"

build:
	swift build -c $(CONFIG) $(SWIFT_EXTRA) --scratch-path $(BUILD_DIR)
ifeq ($(UNIVERSAL),1)
	@echo "--- x86_64 slice ---"
	swift build -c $(CONFIG) $(SWIFT_EXTRA) \
		-Xswiftc -target -Xswiftc $(X86_TARGET) --scratch-path $(X86_DIR)
endif

test:
	swift run $(SWIFT_EXTRA) --scratch-path $(BUILD_DIR) switcher-selftest

# swiftc emits the cross-built slice under the *host* triple directory, so the
# two architectures must use separate scratch paths or they overwrite each other.
$(DIST)/bin/%: build
	@mkdir -p $(DIST)/bin
ifeq ($(UNIVERSAL),1)
	lipo -create $(BUILD_DIR)/$(CONFIG)/$* $(X86_DIR)/$(CONFIG)/$* -output $@
else
	cp $(BUILD_DIR)/$(CONFIG)/$* $@
endif

Resources/anthropic-mark.png: Tools/make-route-icons.swift
	swift Tools/make-route-icons.swift Resources

icon Resources/AppIcon.icns: Tools/make-icon.swift
	swift Tools/make-icon.swift Resources
	iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
	rm -rf Resources/AppIcon.iconset

app: $(addprefix $(DIST)/bin/,$(BINARIES)) Resources/AppIcon.icns Resources/anthropic-mark.png
	rm -rf $(APP_BUNDLE)
	mkdir -p $(APP_BUNDLE)/Contents/MacOS $(APP_BUNDLE)/Contents/Resources
	cp Resources/Info.plist   $(APP_BUNDLE)/Contents/Info.plist
	cp Resources/AppIcon.icns $(APP_BUNDLE)/Contents/Resources/AppIcon.icns
	cp Resources/airia-mark.png Resources/anthropic-mark.png $(APP_BUNDLE)/Contents/Resources/
	$(foreach b,$(BINARIES),cp $(DIST)/bin/$(b) $(APP_BUNDLE)/Contents/MacOS/$(b);)
	@# Nested Mach-O binaries must be signed before the bundle that contains them.
	$(foreach b,$(BINARIES),codesign --force --sign - $(APP_BUNDLE)/Contents/MacOS/$(b);)
	codesign --force --sign - $(APP_BUNDLE)
	codesign --verify --strict $(APP_BUNDLE)
	@echo "Built $(APP_BUNDLE)  ($(shell lipo -archs $(DIST)/bin/SwitcherApp 2>/dev/null))"

install: app
	mkdir -p $(HOME)/Applications
	rm -rf $(HOME)/Applications/$(APP).app
	cp -R $(APP_BUNDLE) $(HOME)/Applications/
	@echo ""
	@echo "Installed  ~/Applications/$(APP).app"
	@echo "Launch     open ~/Applications/$(APP).app"
	@echo "CLI        ~/Applications/$(APP).app/Contents/MacOS/switcher status"

uninstall:
	rm -rf $(HOME)/Applications/$(APP).app

run: app
	open $(APP_BUNDLE)

# Source tarball for the Homebrew formula. Requires a tagged commit.
dist-source:
	@mkdir -p $(DIST)
	git archive --format=tar.gz --prefix=$(APP)-$(VERSION)/ -o $(TARBALL) HEAD
	@echo "$(TARBALL)"
	@echo "sha256  $$(shasum -a 256 $(TARBALL) | cut -d' ' -f1)"

clean:
	rm -rf $(BUILD_DIR) $(X86_DIR) $(DIST) Resources/AppIcon.iconset
