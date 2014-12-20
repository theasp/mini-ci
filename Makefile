NAME=mini-ci
VERSION=0.1
DESTDIR=

# Common prefix for installation directories.
# NOTE: This directory must exist when you start the install.
prefix = /usr/local
datarootdir = $(prefix)/share
datadir = $(datarootdir)/$(NAME)
exec_prefix = $(prefix)
# Where to put the executable for the command `gcc'.
bindir = $(exec_prefix)/bin
# Where to put the directories used by the compiler.
libexecdir = $(exec_prefix)/libexec
# Where to put the Info files.
infodir = $(datarootdir)/info

INSTALL_BIN=install
INSTALL_DATA=install -m 0644

MINI_CI=mini-ci-header.sh mini-ci.sh
MINI_CI_DATA=share/mini-ci.sh share/functions.sh
MINI_CI_DATA_PLUGINS=share/plugins.d/*.sh

DESTS=mini-ci

.PHONY: all
all: $(DESTS)

.PHONY: install
install: $(DESTS)
	install -d $(DESTDIR)$(bindir)
	install -d $(DESTDIR)$(datadir)
	install -d $(DESTDIR)$(datadir)/plugins.d
	$(INSTALL_BIN) mini-ci $(DESTDIR)$(bindir)
	$(INSTALL_DATA) $(MINI_CI_DATA) $(DESTDIR)$(datadir)
	$(INSTALL_DATA) $(MINI_CI_DATA_PLUGINS) $(DESTDIR)$(datadir)/plugins.d

mini-ci: $(MINI_CI)
	cat $^ > $@
	chmod +x $@

mini-ci-header.sh: Makefile
	echo "#!/bin/bash" > $@
	echo 'declare -x MINI_CI_DIR="$${MINI_CI_DIR:-$(datadir)}"' >> $@
	echo "declare -x MINI_CI_VER=$(VERSION)" >> $@

.PHONY: test
test: mini-ci
	MINI_CI_DIR=$(PWD)/share ./tests.sh

.PHONY: clean
clean:
	$(RM) -f $(DESTS)
	$(RM) -f mini-ci-header.sh

