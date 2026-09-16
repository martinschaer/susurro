W    := vendor/whisper.cpp
B    := $(W)/build-mac
FA   := vendor/fluidaudio
FAR  := $(FA)/.build/arm64-apple-macosx/release
APP  := Susurro.app
SRC  := Sources/SusurroApp.swift Sources/Capture.swift Sources/Transcriber.swift Sources/Speaker.swift
LIB  := Sources/Capture.swift Sources/Transcriber.swift Sources/Speaker.swift

# swiftc comes from swiftly, not CommandLineTools, and the two are not interchangeable:
# both call themselves 6.3.3, but CLT's rejects the .swiftmodule that swiftly's SwiftPM
# produced for FluidAudio ("compiled module was created by an older version"). Whatever
# builds vendor/fluidaudio must also build this. See SETUP.md.
SWIFTC := $(HOME)/.swiftly/bin/swiftc -O -target arm64-apple-macosx14.2 \
          -import-objc-header bridge.h -I $(W)/ggml/include \
          -I $(FAR)/Modules -I $(FA)/Sources/FastClusterWrapper/include \
          -I $(FA)/Sources/MachTaskSelfWrapper/include

LINK := -L$(B)/src -L$(B)/ggml/src -L$(B)/ggml/src/ggml-blas \
        -lwhisper -lwhisper.coreml -lggml -lggml-base -lggml-cpu -lggml-blas \
        $(FAR)/libFluidAudio.a \
        -framework Accelerate -framework CoreML -lc++

.PHONY: app smoke run dist clean
app: $(APP)/Contents/MacOS/Susurro

# -parse-as-library because @main cannot coexist with top-level code.
$(APP)/Contents/MacOS/Susurro: $(SRC) Info.plist bridge.h models.sh | $(B) $(FAR)/libFluidAudio.a
	@mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp Info.plist $(APP)/Contents/Info.plist
	cp models.sh $(APP)/Contents/Resources/
	$(SWIFTC) -parse-as-library $(SRC) $(LINK) -o $@
	codesign --force --sign - --identifier dev.susurro $(APP)
	@echo "built $(APP)"

# Same flags as the app; smoke.swift carries its own @main and links the library files
# instead of SusurroApp.swift.
smoke: | $(B) $(FAR)/libFluidAudio.a
	@mkdir -p build
	$(SWIFTC) -parse-as-library Sources/smoke.swift $(LIB) $(LINK) -o build/smoke
	./build/smoke

run: app
	open $(APP)

# What a beta tester receives. ditto, not zip: it keeps the code signature intact.
dist: app
	@mkdir -p build && rm -f build/Susurro.zip
	ditto -c -k --keepParent $(APP) build/Susurro.zip
	@echo "build/Susurro.zip — send this, with docs/INSTALL.md"


$(B):
	@echo "whisper libs missing — run ./setup.sh first" && exit 1

$(FAR)/libFluidAudio.a:
	@echo "FluidAudio lib missing — run ./setup.sh first" && exit 1

clean:
	rm -rf $(APP) build
