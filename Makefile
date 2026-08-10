W    := vendor/whisper.cpp
B    := $(W)/build-mac
APP  := Susurro.app
SRC  := Sources/SusurroApp.swift Sources/Capture.swift Sources/Transcriber.swift
LIB  := Sources/Capture.swift Sources/Transcriber.swift

# No SwiftPM: this CommandLineTools install ships a libPackageDescription.dylib whose
# Package.init overloads don't match its own .swiftmodule, so every manifest fails to
# link. swiftc itself is fine. See SETUP.md.
SWIFTC := swiftc -O -target arm64-apple-macosx14.2 \
          -import-objc-header bridge.h -I $(W)/ggml/include

LINK := -L$(B)/src -L$(B)/ggml/src -L$(B)/ggml/src/ggml-blas \
        -lwhisper -lwhisper.coreml -lggml -lggml-base -lggml-cpu -lggml-blas \
        -framework Accelerate -framework CoreML -lc++

.PHONY: app smoke run clean
app: $(APP)/Contents/MacOS/Susurro

# -parse-as-library because @main cannot coexist with top-level code.
$(APP)/Contents/MacOS/Susurro: $(SRC) Info.plist bridge.h | $(B)
	@mkdir -p $(APP)/Contents/MacOS
	cp Info.plist $(APP)/Contents/Info.plist
	$(SWIFTC) -parse-as-library $(SRC) $(LINK) -o $@
	codesign --force --sign - --identifier dev.susurro $(APP)
	@echo "built $(APP)"

# Same flags as the app; smoke.swift carries its own @main and links the two library
# files instead of SusurroApp.swift.
smoke: | $(B)
	@mkdir -p build
	$(SWIFTC) -parse-as-library Sources/smoke.swift $(LIB) $(LINK) -o build/smoke
	./build/smoke

run: app
	open $(APP)

$(B):
	@echo "whisper libs missing — run ./setup.sh first" && exit 1

clean:
	rm -rf $(APP) build
