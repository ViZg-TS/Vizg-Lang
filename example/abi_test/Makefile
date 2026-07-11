# ABI tests: run all four scenarios from Zig + C drivers. Exits nonzero on any fail.

REPO := $(abspath ../..)
LIB  := $(REPO)/zig-out/lib/libvizg.a
H    := $(REPO)/Lib/vizg.h
ZIG  ?= zig

.PHONY: all run-zig run-c clean

all: run-zig run-c

run-zig: main_zig
	@echo '--- Zig ABI test driver ---'
	./main_zig || exit 1

run-c: test_c
	@echo '--- C ABI test driver ---'
	./test_c || exit 1

# Zig binary — link against the same archive used by `zig build`.
main_zig: | main.zig $(LIB)
	$(ZIG) build-exe main.zig \
	    -lc "$(LIB)" \
	    -femit-bin=main_zig

# C binary — uses the public header at repo root.
test_c: | test.c $(LIB)
	gcc -O2 -Wall -Wextra test.c \
	    -I"$(dir $(abspath $(H)))" \
	    -L"$(dir $(abspath $(LIB)))" -lvizg -o test_c

clean:
	rm -f main_zig test_c
