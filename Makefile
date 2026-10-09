APP      = TiltBar
BUILD    = .build/release
BUNDLE   = dist/$(APP).app
INSTALL  = /Applications/$(APP).app

.PHONY: build bundle install run stop clean icon

build:
	swift build -c release

bundle: build
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	cp $(BUILD)/$(APP) $(BUNDLE)/Contents/MacOS/$(APP)
	cp Info.plist $(BUNDLE)/Contents/Info.plist
	cp Icon/AppIcon.icns $(BUNDLE)/Contents/Resources/AppIcon.icns
	codesign --force --sign - $(BUNDLE)
	@echo "built $(BUNDLE)"

install: bundle
	rm -rf $(INSTALL)
	cp -R $(BUNDLE) $(INSTALL)
	@echo "installed $(INSTALL)"

run: bundle
	open $(BUNDLE)

stop:
	pkill -x $(APP) || true

clean:
	rm -rf .build dist

# Regenerate Icon/AppIcon.icns (and the README's .png) after editing Icon/make-icon.swift.
icon:
	swift Icon/make-icon.swift Icon/AppIcon.icns

AGENT = $(HOME)/Library/LaunchAgents/com.tjq.tiltbar.plist

.PHONY: login unlogin
login: install
	cp com.tjq.tiltbar.plist $(AGENT)
	-launchctl bootout gui/$$(id -u)/com.tjq.tiltbar 2>/dev/null
	launchctl bootstrap gui/$$(id -u) $(AGENT)

unlogin:
	-launchctl bootout gui/$$(id -u)/com.tjq.tiltbar 2>/dev/null
	rm -f $(AGENT)
