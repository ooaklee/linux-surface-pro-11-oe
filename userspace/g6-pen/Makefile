CC ?= cc
CPPFLAGS ?=
CFLAGS ?= -O2 -g
LDFLAGS ?=
LDLIBS ?=
sbindir ?= /usr/sbin

CPPFLAGS += -Iinclude -D_POSIX_C_SOURCE=200809L
CFLAGS += -std=c11 -Wall -Wextra -Wformat=2 -Wshadow -Wconversion

COMMON_SOURCES := src/g6_heat.c src/g6_processor.c
DAEMON_SOURCES := $(COMMON_SOURCES) src/g6_uinput.c src/main.c
TEST_SOURCES := $(COMMON_SOURCES) tests/test_g6_pen.c

.PHONY: all check clean install

all: g6-pen

g6-pen: $(DAEMON_SOURCES) include/g6_pen.h include/g6_heat_abi.h
	$(CC) $(CPPFLAGS) $(CFLAGS) $(LDFLAGS) -o $@ $(DAEMON_SOURCES) $(LDLIBS)

tests/test_g6_pen: $(TEST_SOURCES) include/g6_pen.h include/g6_heat_abi.h
	$(CC) $(CPPFLAGS) $(CFLAGS) $(LDFLAGS) -o $@ $(TEST_SOURCES) $(LDLIBS)

check: g6-pen tests/test_g6_pen
	./tests/test_g6_pen
	./tests/test-replay.sh ./g6-pen

install: g6-pen
	install -d "$(DESTDIR)$(sbindir)"
	install -m 0755 g6-pen "$(DESTDIR)$(sbindir)/g6-pen"

clean:
	rm -f g6-pen tests/test_g6_pen
	rm -rf g6-pen.dSYM tests/test_g6_pen.dSYM
