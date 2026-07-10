# Build analyze_hello (C++) against libvizg.a + vizg.h.
LIB_DIR := ../../../zig-out/lib
LIB     := $(LIB_DIR)/libvizg.a

all: analyze_hello

analyze_hello: analyze_hello.cpp
	g++ -O2 -Wall -Wextra -std=c++17 -o $@ $< \
	    -I$(CURDIR)/../../../Lib -L$(LIB_DIR) -lvizg

release: analyze_hello_release

analyze_hello_release: analyze_hello.cpp
	g++ -O3 -DNDEBUG -Wall -Wextra -std=c++17 -o $@ $< \
	    -I$(CURDIR)/../../../Lib -L$(LIB_DIR) -lvizg

clean:
	rm -f analyze_hello analyze_hello_release

.PHONY: all clean release
