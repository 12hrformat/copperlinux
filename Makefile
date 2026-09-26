CC      ?= cc
CFLAGS  ?= -Wall -Wextra -O2 -std=c11
PREFIX  ?= /usr/local

BIN = copper-sh
OBJS = main.o builtins.o

all: $(BIN)

$(BIN): $(OBJS)
	$(CC) $(CFLAGS) -o $@ $(OBJS)

main.o: src/main.c src/builtins.h
	$(CC) $(CFLAGS) -c -o $@ src/main.c

builtins.o: src/builtins.c src/builtins.h
	$(CC) $(CFLAGS) -c -o $@ src/builtins.c

clean:
	rm -f $(OBJS) $(BIN)

install: $(BIN)
	install -Dm755 $(BIN) $(DESTDIR)$(PREFIX)/bin/$(BIN)

uninstall:
	rm -f $(DESTDIR)$(PREFIX)/bin/$(BIN)

.PHONY: all clean install uninstall