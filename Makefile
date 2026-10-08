.PHONY: build icon install

build:
	swift build -c release

icon:
	scripts/make-icon.sh

install: build icon
	.build/release/ergokeys install --icon assets/AppIcon.icns
