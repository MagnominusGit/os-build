# retroforge-gptk-interpose — LD_PRELOAD library for PortMaster's gptokeyb2: reports the pad's event
# node, so its exclusive grab works under sdl2-compat (see src/retroforge-gptk-interpose.c).
#
# A shared library has to be dynamic, so unlike retroforge-splash it cannot dodge the build container's
# newer glibc by linking statically. It references nothing past open, readlink and dlsym; `make` checks
# that no symbol it imports needs a glibc newer than 2.34 (dlsym's version since it moved into
# libc), so it loads on the image and in any AppImage's bundled glibc.
#
#   make            aarch64 -> build/libretroforge-gptk-interpose.so
#   make host       x86_64 (for tests/test-portmaster.sh) -> build/libretroforge-gptk-interpose.host.so
#   make install    DESTDIR=... PREFIX=/usr
#
# Run inside the build image:
#   docker run --rm -v "$PWD":/src -w /src retroforge-build -c 'make -C apps/retroforge-gptk-interpose'

CROSS   ?= aarch64-linux-gnu-
CC      := $(CROSS)gcc
HOSTCC  ?= cc
STRIP   := $(CROSS)strip
OBJDUMP := $(CROSS)objdump

CFLAGS  := -O2 -std=c11 -Wall -Wextra -fPIC -shared
LDLIBS  := -ldl

PREFIX  ?= /usr
DESTDIR ?=
LIB     := build/libretroforge-gptk-interpose.so
HOSTLIB := build/libretroforge-gptk-interpose.host.so
SRC     := src/retroforge-gptk-interpose.c

.PHONY: all host clean install

all: $(LIB)

$(LIB): $(SRC)
	@mkdir -p build
	$(CC) $(CFLAGS) -o $@ $(SRC) $(LDLIBS)
	$(STRIP) --strip-unneeded $@
	@newest=$$($(OBJDUMP) -T $@ | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -1); \
	  echo "[retroforge] gptk-interpose: $@ (needs $$newest)"; \
	  [ "$$(printf '%s\n' "$$newest" GLIBC_2.34 | sort -V | tail -1)" = GLIBC_2.34 ] \
	    || { echo "[retroforge] gptk-interpose: $$newest is newer than GLIBC_2.34" >&2; rm -f $@; exit 1; }

$(HOSTLIB): $(SRC)
	@mkdir -p build
	$(HOSTCC) $(CFLAGS) -o $@ $(SRC) $(LDLIBS)

host: $(HOSTLIB)

clean:
	rm -rf build

install: $(LIB)
	install -Dm0644 $(LIB) $(DESTDIR)$(PREFIX)/lib/retroforge/portmaster/libretroforge-gptk-interpose.so
