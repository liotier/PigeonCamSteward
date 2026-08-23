# PigeonCamSteward - install/uninstall
#
# There is nothing to compile. `install` copies the tree into place and
# substitutes the install prefix into the systemd unit files, which are the
# only files that carry an absolute path (every script derives its own root
# at runtime - see PIGEONCAM_PROJECT_ROOT in lib/pigeoncam-common.sh).
#
# Deliberately does NOT enable or start anything, create /etc/pigeoncam/
# config.yaml over an existing one, or install the udev rule: the rule needs
# your camera's vendor/product IDs edited in first, and starting a stream is
# a decision, not an install step. `make install` prints what to do next.
#
#   make install                     # to the default prefix, needs root
#   make install PREFIX=/usr/local/lib/pigeoncam
#   make install DESTDIR=/tmp/stage  # stage a tree without touching the system
#   make uninstall                   # leaves config and recordings alone
#   make check                       # the full test suite
#
# DESTDIR is honoured throughout so this can serve as the install step of a
# future package build (`debian/rules` would call exactly this).

PREFIX      ?= /opt/PigeonCamSteward
SYSCONFDIR  ?= /etc
UNITDIR     ?= $(SYSCONFDIR)/systemd/system
TMPFILESDIR ?= $(SYSCONFDIR)/tmpfiles.d
CONFDIR     ?= $(SYSCONFDIR)/pigeoncam
DESTDIR     ?=

# The literal path baked into the shipped unit files, rewritten to $(PREFIX)
# on install. Kept as a variable so there is one place to change if the
# checked-in units ever move.
UNIT_STOCK_PREFIX := /opt/PigeonCamSteward

INSTALL         := install
INSTALL_PROGRAM := $(INSTALL) -m 0755
INSTALL_DATA    := $(INSTALL) -m 0644

.PHONY: all install uninstall check help
.DEFAULT_GOAL := help

all: ## Nothing to build - this is shell, systemd units and a udev rule
	@echo "Nothing to build. Run 'make install' (as root), or 'make help'."

install: ## Install into $(DESTDIR)$(PREFIX) and $(DESTDIR)$(UNITDIR)
	$(INSTALL) -d $(DESTDIR)$(PREFIX)/bin $(DESTDIR)$(PREFIX)/lib \
	              $(DESTDIR)$(PREFIX)/api $(DESTDIR)$(PREFIX)/tools \
	              $(DESTDIR)$(PREFIX)/udev $(DESTDIR)$(PREFIX)/docs \
	              $(DESTDIR)$(UNITDIR) $(DESTDIR)$(TMPFILESDIR) \
	              $(DESTDIR)$(CONFDIR)
	$(INSTALL_PROGRAM) bin/*.sh            $(DESTDIR)$(PREFIX)/bin/
	$(INSTALL_DATA)    lib/*.sh            $(DESTDIR)$(PREFIX)/lib/
	$(INSTALL_PROGRAM) api/*.py            $(DESTDIR)$(PREFIX)/api/
	$(INSTALL_DATA)    api/requirements.txt $(DESTDIR)$(PREFIX)/api/
	$(INSTALL_PROGRAM) tools/*.sh          $(DESTDIR)$(PREFIX)/tools/
	$(INSTALL_DATA)    udev/*.example      $(DESTDIR)$(PREFIX)/udev/
	$(INSTALL_DATA)    config.example.yaml SPEC.md README.md LICENSE $(DESTDIR)$(PREFIX)/
	cp -r docs/.                           $(DESTDIR)$(PREFIX)/docs/
#	Unit files are the only place an absolute path is baked in; rewrite it
#	rather than shipping a copy that only works at the stock prefix.
	@for u in systemd/*.service systemd/*.timer; do \
	    sed 's#$(UNIT_STOCK_PREFIX)#$(PREFIX)#g' "$$u" \
	        > "$(DESTDIR)$(UNITDIR)/$$(basename $$u)"; \
	    chmod 0644 "$(DESTDIR)$(UNITDIR)/$$(basename $$u)"; \
	    echo "  unit  $$(basename $$u)"; \
	done
	$(INSTALL_DATA) systemd/pigeoncam-tmpfiles.conf $(DESTDIR)$(TMPFILESDIR)/pigeoncam.conf
#	Never clobber a config that is already in use.
	@if [ -f "$(DESTDIR)$(CONFDIR)/config.yaml" ]; then \
	    echo "  keep  $(CONFDIR)/config.yaml (already exists, left untouched)"; \
	else \
	    $(INSTALL_DATA) config.example.yaml "$(DESTDIR)$(CONFDIR)/config.yaml"; \
	    echo "  new   $(CONFDIR)/config.yaml (from config.example.yaml - edit it)"; \
	fi
	@echo
	@echo "Installed to $(DESTDIR)$(PREFIX). Nothing has been started or enabled."
	@echo "Next:"
	@echo "  1. edit $(CONFDIR)/config.yaml   (at minimum youtube.ingest_url and external_check.channel_live_url)"
	@echo "  2. put your stream key in $(CONFDIR)/stream_key, chmod 600"
	@echo "  3. cp $(PREFIX)/udev/99-pigeoncam.rules.example $(SYSCONFDIR)/udev/rules.d/99-pigeoncam.rules"
	@echo "     then edit in your camera's idVendor/idProduct and: udevadm control --reload && udevadm trigger"
	@echo "  4. systemd-tmpfiles --create $(TMPFILESDIR)/pigeoncam.conf && systemctl daemon-reload"
	@echo "  5. $(PREFIX)/bin/pigeoncam-doctor.sh        (fix everything it reports)"
	@echo "  6. $(PREFIX)/bin/pigeoncam-ctl.sh enable && $(PREFIX)/bin/pigeoncam-ctl.sh start"

uninstall: ## Remove the program files and units; keeps config and recordings
	rm -f $(DESTDIR)$(TMPFILESDIR)/pigeoncam.conf
	@for u in systemd/*.service systemd/*.timer; do \
	    rm -f "$(DESTDIR)$(UNITDIR)/$$(basename $$u)"; \
	done
	rm -rf $(DESTDIR)$(PREFIX)
	@echo
	@echo "Removed $(PREFIX) and the systemd units."
	@echo "Deliberately left in place:"
	@echo "  $(CONFDIR)/            your config and credentials"
	@echo "  /var/lib/pigeoncam/    rotation state and recordings"
	@echo "Remove those by hand if you actually want them gone."
	@echo "The udev rule at $(SYSCONFDIR)/udev/rules.d/99-pigeoncam.rules is yours too."

check: ## Run the full test suite
	tests/run_all.sh

help: ## Show this help
	@echo "PigeonCamSteward - nothing to build; install/uninstall/check only."
	@echo
	@grep -E '^[a-z][a-zA-Z_-]*:.*?## ' $(MAKEFILE_LIST) \
	    | awk 'BEGIN{FS=":.*?## "}{printf "  %-10s %s\n", $$1, $$2}'
	@echo
	@echo "Variables: PREFIX=$(PREFIX)  UNITDIR=$(UNITDIR)  CONFDIR=$(CONFDIR)  DESTDIR="
