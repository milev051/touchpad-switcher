# Makefile za Touchpad Switcher
# Kompajliranje i pokretanje prototipa

CC = clang
# macOS 14 is the oldest system with every API the ring uses.
CFLAGS = -fobjc-arc -O2 -mmacosx-version-min=14.0
FRAMEWORKS = -framework Cocoa -framework ApplicationServices -framework ScreenCaptureKit -framework QuartzCore -framework ImageIO -F/System/Library/PrivateFrameworks -framework MultitouchSupport
TARGET = touchpad_switcher
SRC = touchpad_switcher.m
RING_APP = Touchpad Switcher.app
RING_APP_EXECUTABLE = $(RING_APP)/Contents/MacOS/touchpad_ring_test
RING_APP_IDENTIFIER = com.milev.touchpad-switcher

.PHONY: all build run run-python list-apps ring-test install-ring update dist clean

all: build

build: $(TARGET)

$(TARGET): $(SRC)
	$(CC) $(CFLAGS) $(FRAMEWORKS) $(SRC) -o $(TARGET)
	@echo "Uspešno kompajliran: $(TARGET)"

run: $(TARGET)
	./$(TARGET)

run-python:
	python3 touchpad_switcher.py

list-apps: $(TARGET)
	./$(TARGET) --list-apps

RING_SOURCES = touchpad_ring_test.m ring_media.m

touchpad_ring_test: $(RING_SOURCES) ring_media.h
	$(CC) $(CFLAGS) $(FRAMEWORKS) $(RING_SOURCES) -o $@
	@if [ -d "$(RING_APP)/Contents/MacOS" ]; then \
		cp "$@" "$(RING_APP_EXECUTABLE)" && \
		codesign --force --deep --sign - --identifier "$(RING_APP_IDENTIFIER)" \
			-r='designated => identifier "$(RING_APP_IDENTIFIER)"' "$(RING_APP)"; \
	fi
	@echo "Uspešno kompajliran eksperimentalni test: $@"

ring-test: touchpad_ring_test
	./touchpad_ring_test

install-ring: touchpad_ring_test
	@test -d "$(RING_APP)" || { echo "Missing app bundle: $(RING_APP)"; exit 1; }
	@mkdir -p /Applications
	@ditto "$(RING_APP)" "/Applications/$(RING_APP)"
	codesign --force --deep --sign - --identifier "$(RING_APP_IDENTIFIER)" \
		-r='designated => identifier "$(RING_APP_IDENTIFIER)"' "/Applications/$(RING_APP)"
	@# The app's Update button pulls and rebuilds from this folder.
	@defaults write $(RING_APP_IDENTIFIER) SourceRepository "$(CURDIR)"
	@echo "Installed /Applications/$(RING_APP)"

# Pull changes from GitHub, rebuild, and start the new version (it replaces the
# running one on its own).
update:
	git pull --ff-only
	$(MAKE) install-ring
	open -n "/Applications/$(RING_APP)"

# Zip for someone else's Mac: one binary for Apple Silicon and Intel.
dist: $(RING_SOURCES) ring_media.h
	@mkdir -p "$(RING_APP)/Contents/MacOS" dist
	$(CC) $(CFLAGS) -arch arm64 -arch x86_64 $(FRAMEWORKS) $(RING_SOURCES) -o "$(RING_APP_EXECUTABLE)"
	codesign --force --deep --sign - --identifier "$(RING_APP_IDENTIFIER)" \
		-r='designated => identifier "$(RING_APP_IDENTIFIER)"' "$(RING_APP)"
	@rm -f "dist/Touchpad Switcher.zip"
	ditto -c -k --keepParent "$(RING_APP)" "dist/Touchpad Switcher.zip"
	@echo "Spremno za slanje: dist/Touchpad Switcher.zip"

clean:
	rm -f $(TARGET)
	@echo "Obrisan binarni fajl $(TARGET)"
