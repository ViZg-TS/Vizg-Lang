# Token-iter: run Zig + C drivers that exercise length-aware token consumption.

REPO := $(abspath ../..)
LIB  := $(REPO)/zig-out/lib/libvizg.a
H    := $(REPO)/Lib/vizg.h
ZIG  ?= zig

.PHONY: all run-zig run-c clean

all: run-zig run-c

run-zig: main_zig
	@echo '--- Zig token-iter driver ---'
	./main_zig || exit 1

run-c: test_c
	@echo '--- C token-iter driver ---'
	./test_c || exit 1

main_zig: | main.zig $(LIB)
	$(ZIG) build-exe main.zig \
	    -lc "$(LIB)" \
	    -femit-bin=main_zig

test_c: | test.c $(LIB)
	gcc -O2 -Wall -Wextra test.c \
	    -I"$(dir $(abspath $(H)))" \
	    -L"$(dir $(abspath $(LIB)))" -lvizg -o test_c

clean:
	rm -f main_zig test_c
