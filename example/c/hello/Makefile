# Build analyze_hello against libvizg.a + vizg.h from the repo root.
LIB_DIR := ../../../zig-out/lib
LIB     := $(LIB_DIR)/libvizg.a
H       := ../../../Lib/vizg.h

all: analyze_hello

analyze_hello: analyze_hello.c $(H) $(LIB)
	gcc -O2 -Wall -Wextra -o $@ $< \
	    -I$(dir $(H)) -L$(LIB_DIR) -lvizg

clean:
	rm -f analyze_hello

.PHONY: all clean
