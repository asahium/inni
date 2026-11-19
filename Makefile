.PHONY: build app run debug test verify sync-test clean icon ios ios-sim ios-device print-device ios-autosign ios-autosign-off

IOS_SIM ?= iPhone 17 Pro
LAUNCH ?= 1
# Team of the first "Apple Development" certificate (Xcode → Settings → Accounts creates one, a free Apple ID works).
TEAM ?= $(shell security find-certificate -c "Apple Development" -p 2>/dev/null | openssl x509 -noout -subject 2>/dev/null | sed -n 's/.*OU *= *\([A-Z0-9]*\).*/\1/p')
DEVICE ?= $(shell xcrun devicectl list devices 2>/dev/null | awk '/physical/ && /(available|connected)/ {for (i=1;i<=NF;i++) if ($$i ~ /^[0-9A-F]{8}-/) {print $$i; exit}}')
# Python with the `anki` package, for checking Inni's output with Anki itself.
ANKI_PY ?= /tmp/inni-ref/venv/bin/python

build:
	swift build -c release

app:
	./scripts/bundle.sh release

run: app
	open build/Inni.app

debug:
	./scripts/bundle.sh debug && open build/Inni.app

test:
	swift test

# Writes a collection and packages with InniCore, then opens and imports them with the official Anki backend.
verify:
	INNI_OUT=/tmp/inni-ref/out swift test --filter testWriteForAnki
	$(ANKI_PY) scripts/verify_with_anki.py /tmp/inni-ref/out

# Syncs with Anki's own sync server, using Anki's backend as the second device. SYNC_LARGE=<collection> adds a big-collection run.
SYNC_PORT ?= 27711
sync-test:
	@rm -rf /tmp/inni-sync-server; \
	SYNC_USER1=test:pass SYNC_BASE=/tmp/inni-sync-server SYNC_HOST=127.0.0.1 SYNC_PORT=$(SYNC_PORT) $(ANKI_PY) -m anki.syncserver >/tmp/inni-sync-server.log 2>&1 & \
	pid=$$!; sleep 2; \
	INNI_SYNC_SERVER=http://127.0.0.1:$(SYNC_PORT)/ ANKI_PY=$(ANKI_PY) INNI_SYNC_LARGE=$(SYNC_LARGE) swift test --filter SyncTests; \
	status=$$?; kill $$pid; exit $$status

clean:
	rm -rf .build build

ios:
	cd iOS && xcodegen generate && open InniMobile.xcodeproj

ios-sim:
	cd iOS && xcodegen generate && xcodebuild -project InniMobile.xcodeproj -scheme InniMobile \
		-destination 'platform=iOS Simulator,name=$(IOS_SIM)' -derivedDataPath ../.build/ios build
	xcrun simctl boot '$(IOS_SIM)' 2>/dev/null || true
	xcrun simctl install booted .build/ios/Build/Products/Debug-iphonesimulator/Inni.app
	xcrun simctl launch booted dev.inni.mobile

ios-device:
	@test -n "$(TEAM)" || (echo "No Apple Development certificate: add an Apple ID in Xcode → Settings → Accounts" && exit 1)
	@test -n "$(DEVICE)" || (echo "No paired iPhone found (connect it, unlock, trust this Mac)" && exit 1)
	cd iOS && xcodegen generate && xcodebuild -project InniMobile.xcodeproj -scheme InniMobile \
		-destination 'generic/platform=iOS' -derivedDataPath ../.build/ios-device -allowProvisioningUpdates \
		DEVELOPMENT_TEAM=$(TEAM) -configuration Release build
	xcrun devicectl device install app --device $(DEVICE) .build/ios-device/Build/Products/Release-iphoneos/Inni.app
	@if [ "$(LAUNCH)" = 1 ]; then xcrun devicectl device process launch --device $(DEVICE) dev.inni.mobile; fi

print-device:
	@echo $(DEVICE)

AGENT = $(HOME)/Library/LaunchAgents/dev.inni.ios-resign.plist

# Re-sign the iPhone build over Wi-Fi before the free 7-day signature runs out.
ios-autosign:
	chmod +x scripts/ios-resign.sh
	@mkdir -p $(HOME)/Library/LaunchAgents
	@printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
		'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
		'<plist version="1.0"><dict>' \
		'<key>Label</key><string>dev.inni.ios-resign</string>' \
		'<key>ProgramArguments</key><array><string>$(CURDIR)/scripts/ios-resign.sh</string></array>' \
		'<key>StartInterval</key><integer>10800</integer>' \
		'<key>RunAtLoad</key><true/>' \
		'</dict></plist>' > $(AGENT)
	-launchctl bootout gui/$$(id -u) $(AGENT) 2>/dev/null
	launchctl bootstrap gui/$$(id -u) $(AGENT)
	@echo "Installed. Log: ~/Library/Logs/Inni/ios-resign.log"

ios-autosign-off:
	-launchctl bootout gui/$$(id -u) $(AGENT)
	rm -f $(AGENT)

icon:
	swift scripts/make-icon.swift /tmp/inni-icon.png
	swift scripts/make-icon.swift iOS/Inni/Assets.xcassets/AppIcon.appiconset/AppIcon.png --full
	rm -rf /tmp/AppIcon.iconset && mkdir /tmp/AppIcon.iconset
	for s in 16 32 128 256 512; do \
		sips -z $$s $$s /tmp/inni-icon.png --out /tmp/AppIcon.iconset/icon_$${s}x$${s}.png >/dev/null; \
		sips -z $$((s*2)) $$((s*2)) /tmp/inni-icon.png --out /tmp/AppIcon.iconset/icon_$${s}x$${s}@2x.png >/dev/null; \
	done
	iconutil -c icns /tmp/AppIcon.iconset -o Resources/AppIcon.icns
