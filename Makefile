APP_NAME := SpotifyLyricsMenuBar
BUNDLE := build/$(APP_NAME).app
BINARY := $(BUNDLE)/Contents/MacOS/$(APP_NAME)
DMG := dist/$(APP_NAME).dmg
DMG_ROOT := dist/dmg-root
SOURCES := Sources/SpotifyLyricsMenuBar/main.swift
SWIFTC := CLANG_MODULE_CACHE_PATH="$(CURDIR)/build/ModuleCache" swiftc

.PHONY: app dmg run clean

app: $(BINARY)

$(BINARY): $(SOURCES) Bundle/Info.plist
	mkdir -p "$(BUNDLE)/Contents/MacOS"
	cp Bundle/Info.plist "$(BUNDLE)/Contents/Info.plist"
	printf 'APPL????' > "$(BUNDLE)/Contents/PkgInfo"
	$(SWIFTC) -O -framework Cocoa -o "$(BINARY)" $(SOURCES)
	codesign --force --sign - "$(BUNDLE)"

dmg: app
	rm -rf "$(DMG_ROOT)"
	mkdir -p "$(DMG_ROOT)"
	cp -R "$(BUNDLE)" "$(DMG_ROOT)/"
	ln -s /Applications "$(DMG_ROOT)/Applications"
	hdiutil create -volname "$(APP_NAME)" -srcfolder "$(DMG_ROOT)" -ov -format UDZO "$(DMG)"
	hdiutil verify "$(DMG)"

run: app
	open "$(BUNDLE)"

clean:
	rm -rf build
