# Makefile za Touchpad Switcher
# Kompajliranje i pokretanje prototipa

CC = clang
CFLAGS = -fobjc-arc -O2
FRAMEWORKS = -framework Cocoa -framework ApplicationServices -framework ScreenCaptureKit -framework QuartzCore -F/System/Library/PrivateFrameworks -framework MultitouchSupport
TARGET = touchpad_switcher
SRC = touchpad_switcher.m
RING_APP = Touchpad Switcher.app
RING_APP_EXECUTABLE = $(RING_APP)/Contents/MacOS/touchpad_ring_test
RING_APP_IDENTIFIER = com.milev.touchpad-switcher

.PHONY: all build run run-python list-apps ring-test install-ring clean

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

touchpad_ring_test: touchpad_ring_test.m
	$(CC) $(CFLAGS) $(FRAMEWORKS) touchpad_ring_test.m -o $@
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
	@echo "Installed /Applications/$(RING_APP)"

clean:
	rm -f $(TARGET)
	@echo "Obrisan binarni fajl $(TARGET)"
