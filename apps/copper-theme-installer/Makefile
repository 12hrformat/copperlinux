# copper-theme-installer
#
# The application is deliberately small: C, GTK 3 and libarchive.  The same
# binary carries the window and the --inspect/--install command line, so the
# tests exercise exactly the code the GUI uses.

CC          ?= cc
PKG_CONFIG  ?= pkg-config
PREFIX      ?= /usr
DESTDIR     ?=
VERSION     ?= 0.1.0
BINDIR      ?= $(PREFIX)/bin
DATADIR     ?= $(PREFIX)/share

GTK_CFLAGS       := $(shell $(PKG_CONFIG) --cflags gtk+-3.0)
GTK_LIBS         := $(shell $(PKG_CONFIG) --libs gtk+-3.0)
ARCHIVE_CFLAGS   := $(shell $(PKG_CONFIG) --cflags libarchive)
ARCHIVE_LIBS     := $(shell $(PKG_CONFIG) --libs libarchive)

CFLAGS  ?= -O2 -g
CFLAGS  += -std=c11 -Wall -Wextra -Wformat=2 -Wshadow \
           -Wstrict-prototypes -Wmissing-prototypes \
           -DCOPPER_THEME_INSTALLER_VERSION=\"$(VERSION)\"
CPPFLAGS += -D_GNU_SOURCE $(GTK_CFLAGS) $(ARCHIVE_CFLAGS)
LDLIBS  += $(GTK_LIBS) $(ARCHIVE_LIBS)
LDFLAGS ?=

BIN  = copper-theme-installer
SRCS = src/main.c src/gui.c src/theme-archive.c src/theme-install.c
OBJS = $(SRCS:.c=.o)
ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))../..)

all: $(BIN)

$(BIN): $(OBJS)
	$(CC) $(LDFLAGS) -pthread -o $@ $(OBJS) $(LDLIBS)

src/%.o: src/%.c src/theme.h src/gui.h
	$(CC) $(CPPFLAGS) $(CFLAGS) -pthread -c -o $@ $<

check: $(BIN)
	sh "$(ROOT)/tests/theme-installer.sh"

install: $(BIN)
	install -d "$(DESTDIR)$(BINDIR)"
	install -Dm755 $(BIN) "$(DESTDIR)$(BINDIR)/$(BIN)"
	install -Dm644 data/copper-theme-installer.desktop \
		"$(DESTDIR)$(DATADIR)/applications/copper-theme-installer.desktop"
	install -Dm644 data/copper-theme-installer.svg \
		"$(DESTDIR)$(DATADIR)/icons/hicolor/scalable/apps/copper-theme-installer.svg"
	install -Dm644 data/copper-theme-installer.svg \
		"$(DESTDIR)$(DATADIR)/pixmaps/copper-theme-installer.svg"
	install -Dm644 README.md \
		"$(DESTDIR)$(DATADIR)/doc/copper-theme-installer/README.md"

uninstall:
	rm -f "$(DESTDIR)$(BINDIR)/$(BIN)"
	rm -f "$(DESTDIR)$(DATADIR)/applications/copper-theme-installer.desktop"
	rm -f "$(DESTDIR)$(DATADIR)/icons/hicolor/scalable/apps/copper-theme-installer.svg"
	rm -f "$(DESTDIR)$(DATADIR)/pixmaps/copper-theme-installer.svg"
	rm -f "$(DESTDIR)$(DATADIR)/doc/copper-theme-installer/README.md"

clean:
	rm -f $(OBJS) $(BIN)

.PHONY: all check install uninstall clean
