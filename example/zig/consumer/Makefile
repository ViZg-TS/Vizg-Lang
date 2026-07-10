# Build vizg_zig_consumer against libvizg.a + vizg.h from the repo root.
LIB_DIR := ../../../zig-out/lib
LIB     := $(LIB_DIR)/libvizg.a
H       := ../../../Lib/vizg.h

ZIG_BIN  := ~/Apps/zig-x86_64-linux-0.16.0/zig
OUTPUT   := vizg_zig_consumer

all: $(OUTPUT)

$(OUTPUT): main.zig $(H) $(LIB)
	$(ZIG_BIN) build-exe main.zig -I $(dir $(abspath $(H))) \
	    -lc $(LIB) -femit-bin=$(OUTPUT)

clean:
	rm -f $(OUTPUT)

.PHONY: all clean
