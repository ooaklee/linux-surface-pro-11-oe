# SPDX-License-Identifier: BSD-3-Clause
CC = cc
SRCDIR ?= .
CFLAGS = -std=c11 -O2 -Wall -Wextra -Werror -pedantic
CPPFLAGS = -I$(SRCDIR)/include
LDFLAGS =
LDLIBS =

.PHONY: all check clean
all: cdsp-capabilities

cdsp-capabilities: $(SRCDIR)/main.c $(SRCDIR)/cdsp-caps.c $(SRCDIR)/include/cdsp-caps.h $(SRCDIR)/include/fastrpc.h
	$(CC) $(CPPFLAGS) $(CFLAGS) $(LDFLAGS) $(SRCDIR)/main.c $(SRCDIR)/cdsp-caps.c $(LDLIBS) -o $@

query-unit: $(SRCDIR)/tests/query-unit.c $(SRCDIR)/cdsp-caps.c $(SRCDIR)/include/cdsp-caps.h $(SRCDIR)/include/fastrpc.h
	$(CC) $(CPPFLAGS) $(CFLAGS) $(LDFLAGS) $(SRCDIR)/tests/query-unit.c $(SRCDIR)/cdsp-caps.c \
		-Wl,--wrap=open,--wrap=fstat,--wrap=ioctl,--wrap=close $(LDLIBS) -o $@

check: cdsp-capabilities query-unit
	./query-unit
	python3 -I -B $(SRCDIR)/tests/check-cli.py ./cdsp-capabilities

# Explicit build outputs only. Never removes a firmware, device or source tree.
clean:
	rm -f cdsp-capabilities query-unit
