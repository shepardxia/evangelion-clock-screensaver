# make          web resources (grunt) + the .saver (xcodebuild)
# make install  into ~/Library/Screen Savers, and restart the host so it loads the new build
SAVER := build/Build/Products/Release/Evangelion Clock.saver
DEST  := $(HOME)/Library/Screen Savers

.PHONY: all install clean

all: node_modules
	npx grunt build
	xcodebuild -scheme "Evangelion Clock" -configuration Release -derivedDataPath build \
		CODE_SIGN_IDENTITY=- -quiet

node_modules: package.json
	npm install --no-audit --no-fund
	touch node_modules

# legacyScreenSaver keeps the bundle it loaded first until it exits.
install: all
	mkdir -p "$(DEST)"
	rm -rf "$(DEST)/Evangelion Clock.saver"
	cp -R "$(SAVER)" "$(DEST)/"
	killall legacyScreenSaver 2>/dev/null || true

clean:
	rm -rf build Resources/Webview
