# Build analyze_hello against libvizg.a + vizg.h from the repo root.
LIB_DIR := ../../../zig-out/lib
LIB     := $(LIB_DIR)/libvizg.a
H       := ../../../Lib/vizg.h

all: analyze_hello

analyze_hello: analyze_hello.c $(H) $(LIB)
	gcc -O2 -Wall -Wextra -o $@ $< \
	    -I$(dir $(H)) -L$(LIB_DIR) -lvizg

release: analyze_hello_release

analyze_hello_release: analyze_hello.c $(H) $(LIB)
	gcc -O3 -DNDEBUG -Wall -Wextra -o $@ $< \
	    -I$(dir $(H)) -L$(LIB_DIR) -lvizg

clean:
	rm -f analyze_hello analyze_hello_release

.PHONY: all clean release
