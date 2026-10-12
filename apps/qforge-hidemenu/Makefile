# qforge-hidemenu — LD_PRELOAD shim: every QMainWindow after the first gets a zero-height menu
# bar (see src/qforge-hidemenu.c for why melonDS needs it).
#
# A shared library has to be dynamic, so unlike qforge-splash it cannot dodge the build container's
# newer glibc by linking statically. It references nothing but dlsym; `make` checks
# that no symbol it imports needs a glibc newer than 2.34 (dlsym's version since it moved into
# libc), so it loads on the image and in any AppImage's bundled glibc.
#
#   make            aarch64 -> build/libqforge-hidemenu.so
#   make host       x86_64 (for tests/test-hidemenu.sh) -> build/libqforge-hidemenu.host.so
#   make install    DESTDIR=... PREFIX=/usr
#
# Run inside the build image:
#   docker run --rm -v "$PWD":/src -w /src qforge-build -c 'make -C apps/qforge-hidemenu'

CROSS   ?= aarch64-linux-gnu-
CC      := $(CROSS)gcc
HOSTCC  ?= cc
STRIP   := $(CROSS)strip
OBJDUMP := $(CROSS)objdump

CFLAGS  := -O2 -std=c11 -Wall -Wextra -fPIC -shared
LDLIBS  := -ldl

PREFIX  ?= /usr
DESTDIR ?=
LIB     := build/libqforge-hidemenu.so
HOSTLIB := build/libqforge-hidemenu.host.so
SRC     := src/qforge-hidemenu.c

.PHONY: all host clean install

all: $(LIB)

$(LIB): $(SRC)
	@mkdir -p build
	$(CC) $(CFLAGS) -o $@ $(SRC) $(LDLIBS)
	$(STRIP) --strip-unneeded $@
	@newest=$$($(OBJDUMP) -T $@ | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -1); \
	  echo "[qforge] hidemenu: $@ (needs $$newest)"; \
	  [ "$$(printf '%s\n' "$$newest" GLIBC_2.34 | sort -V | tail -1)" = GLIBC_2.34 ] \
	    || { echo "[qforge] hidemenu: $$newest is newer than GLIBC_2.34" >&2; rm -f $@; exit 1; }

$(HOSTLIB): $(SRC)
	@mkdir -p build
	$(HOSTCC) $(CFLAGS) -o $@ $(SRC) $(LDLIBS)

host: $(HOSTLIB)

clean:
	rm -rf build

install: $(LIB)
	install -Dm0644 $(LIB) $(DESTDIR)$(PREFIX)/lib/qforge/libqforge-hidemenu.so
