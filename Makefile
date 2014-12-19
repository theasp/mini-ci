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

MINI_CI=mini-ci.sh
DESTS=mini-ci

.PHONY: all
all: $(DESTS)

.PHONY: install
install: $(DESTS)
	install -d $(bindir)
	install -d $(datadir)
	$(INSTALL_BIN) mini-ci $(DESTDIR)$(bindir)
	$(INSTALL_DATA) share/* $(DESTDIR)$(datadir)

.PHONY: clean
clean:
	$(RM) -f $(DESTS)

mini-ci: $(MINI_CI)
	cat $^ > $@
	sed -i -e "s!MINI_CI_DIR=.*!MINI_CI_DIR=$(datadir)!" $@
	sed -i -e "s!MINI_CI_VER=.*!MINI_CI_VER=$(VERSION)!" $@
	chmod +x $@
