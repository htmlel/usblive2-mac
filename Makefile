# Build:  make            (macOS: brew install libusb pkg-config sdl2 ffmpeg)
# Test:   make mocktest   (runs against a simulated device, no hardware)
CC      ?= clang
CFLAGS  ?= -O2 -g
# -funsigned-char: the Linux kernel builds with unsigned char, keep that semantic
CFLAGS  += -std=gnu11 -funsigned-char -I. -Igen -Wall -Wno-unused-function \
           -Wno-pointer-sign -Wno-missing-braces -Wno-unused-variable
LIBUSB_CFLAGS ?= $(shell pkg-config --cflags libusb-1.0)
LIBUSB_LIBS   ?= $(shell pkg-config --libs libusb-1.0)
SDL_CFLAGS    ?= $(shell sdl2-config --cflags)
SDL_LIBS      ?= $(shell sdl2-config --libs)

CORE = ul2.c glue.c gen/core_port.c gen/avcore.c gen/pcb_cfg.c \
       gen/cx25840_port.c gen/video_port.c gen/cards_port.c imgutil.c
HDRS = kstubs.h gen/cx231xx.h ul2.h imgutil.h recorder.h

all: usblive2_viewer usblive2_capture

# ---- the Mac app: make app  ->  USB-Live2.app (then: open USB-Live2.app)
APP      = USB-Live2.app
ARCH    := $(shell uname -m)
MACOS_MIN = 14.0
SWIFT_SRC = mac/USBLive2App.swift mac/ContentView.swift mac/CaptureModel.swift \
            mac/VideoSurface.swift mac/AudioOutput.swift \
            mac/EditorModel.swift mac/EditorView.swift
APP_C    = $(CORE) engine.c recorder.c

app: $(APP)

$(APP): $(SWIFT_SRC) $(APP_C) $(HDRS) engine.h mac/Bridge.h mac/Info.plist mac/AppIcon.icns
	rm -rf build/obj && mkdir -p build/obj
	for f in $(APP_C); do \
	  $(CC) $(CFLAGS) -mmacosx-version-min=$(MACOS_MIN) $(LIBUSB_CFLAGS) -c $$f \
	        -o build/obj/$$(basename $$f .c).o || exit 1; \
	done
	swiftc -O -swift-version 5 -parse-as-library \
	  -target $(ARCH)-apple-macos$(MACOS_MIN) \
	  -import-objc-header mac/Bridge.h -I. \
	  $(SWIFT_SRC) build/obj/*.o $(LIBUSB_LIBS) -o build/USB-Live2
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp build/USB-Live2 $(APP)/Contents/MacOS/USB-Live2
	cp mac/Info.plist $(APP)/Contents/Info.plist
	cp mac/AppIcon.icns $(APP)/Contents/Resources/AppIcon.icns
	codesign --force --sign - $(APP)
	@echo
	@echo "Built $(APP). Open it with:  open $(APP)"
	@echo "or drag it into your Applications folder."

usblive2_capture: usblive2_capture.c $(CORE) $(HDRS)
	$(CC) $(CFLAGS) $(LIBUSB_CFLAGS) -o $@ usblive2_capture.c $(CORE) $(LIBUSB_LIBS)

usblive2_viewer: usblive2_viewer.c recorder.c $(CORE) $(HDRS)
	$(CC) $(CFLAGS) $(LIBUSB_CFLAGS) $(SDL_CFLAGS) -o $@ usblive2_viewer.c recorder.c \
	    $(CORE) $(LIBUSB_LIBS) $(SDL_LIBS) -lpthread

# --- builds against the simulated device in tests/mock_libusb.c -lm
usblive2_mock: usblive2_capture.c $(CORE) $(HDRS) tests/mock_libusb.c -lm
	$(CC) $(CFLAGS) $(LIBUSB_CFLAGS) -o $@ usblive2_capture.c $(CORE) tests/mock_libusb.c -lm

viewer_mock: usblive2_viewer.c recorder.c $(CORE) $(HDRS) tests/mock_libusb.c -lm
	$(CC) $(CFLAGS) $(LIBUSB_CFLAGS) $(SDL_CFLAGS) -o $@ usblive2_viewer.c recorder.c \
	    $(CORE) tests/mock_libusb.c $(SDL_LIBS) -lm -lpthread

engine_test: tests/engine_test.c engine.c recorder.c $(CORE) $(HDRS) engine.h tests/mock_libusb.c
	$(CC) $(CFLAGS) $(LIBUSB_CFLAGS) -o $@ tests/engine_test.c engine.c recorder.c \
	    $(CORE) tests/mock_libusb.c -lm -lpthread

mocktest: usblive2_mock
	cd tests && MOCK_TRACE=mock_trace.txt ../usblive2_mock --seconds 3 --raw mock.yuv

regen:
	python3 tools/gen.py

clean:
	rm -rf build $(APP)
	rm -f usblive2_capture usblive2_viewer usblive2_mock viewer_mock engine_test \
	      tests/*.bmp tests/*.yuv tests/*.mp4 tests/*.log tests/mock_trace.txt
.PHONY: all app mocktest regen clean
