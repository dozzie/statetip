#!/usr/bin/make -f

#-----------------------------------------------------------------------------

ifeq ($(wildcard .*.plt),)
#DIALYZER_PLT = ~/.dialyzer_plt
else
DIALYZER_PLT = ~/.dialyzer_plt $(wildcard .*.plt)
endif
DIALYZER_OPTS = --no_check_plt $(if $(DIALYZER_PLT),--plts $(DIALYZER_PLT))

DIAGRAMS = $(basename $(notdir $(wildcard diagrams/*.diag)))
DIAGRAMS_SVG = $(foreach D,$(DIAGRAMS),doc/images/$D.svg)

ERL_APP_FILE = $(wildcard ebin/*.app)
ERL_APP_NAME = $(patsubst ebin/%.app,%,$(ERL_APP_FILE))
ERL_APP_VER = $(shell _install/app_version $(ERL_APP_FILE))
ERL_INSTALL_PATH = $(shell _install/lib_dir)
ESCRIPT_ARGS_FILE = /etc/statetip/erlang.args

#-----------------------------------------------------------------------------

.PHONY: all clean

all: compile edoc

clean:
	rebar clean
	python setup.py clean --all
	rm -rf pylib/*.egg-info
	${MAKE} -C doc clean
	rm -rf doc/edoc

#-----------------------------------------------------------------------------

.PHONY: compile build dialyzer

build: compile

compile:
	rebar $@

YECC_ERL_FILES = $(subst .yrl,.erl,$(subst .xrl,.erl,$(wildcard src/*.[xy]rl)))
ERL_SOURCE_FILES = $(filter-out $(YECC_ERL_FILES),$(wildcard src/*.erl))
dialyzer:
	@echo "dialyzer $(strip $(DIALYZER_OPTS)) --src src/*.erl"
	@dialyzer $(strip $(DIALYZER_OPTS)) --src $(ERL_SOURCE_FILES)

#-----------------------------------------------------------------------------

.PHONY: doc edoc diagrams

doc: diagrams edoc
	${MAKE} -C doc all

edoc:
	rebar doc

diagrams: $(DIAGRAMS_SVG)

doc/images/%.svg: diagrams/%.diag
	blockdiag -o $@ -T svg $<

#-----------------------------------------------------------------------------

.PHONY: install install-doc install-erlang install-python

install: install-erlang install-python

install-doc:
	mkdir -p $(DESTDIR)/usr/share/doc/statetip
	mkdir -p $(DESTDIR)/usr/share/doc/statetip/html
	mkdir -p $(DESTDIR)/usr/share/doc/statetip/erlang-api
	cp -R doc/html/* $(DESTDIR)/usr/share/doc/statetip/html
	cp doc/edoc/*.html doc/edoc/*.png doc/edoc/*.css $(DESTDIR)/usr/share/doc/statetip/erlang-api
	install -m 644 -D doc/man/statetipd.8 $(DESTDIR)/usr/share/man/man8/statetipd.8
	install -m 644 -D doc/man/statetip.1 $(DESTDIR)/usr/share/man/man1/statetip.1
	install -m 644 -D doc/man/statetip-protocol.7 $(DESTDIR)/usr/share/man/man7/statetip-protocol.7

install-erlang:
	mkdir -p $(DESTDIR)/etc/statetip
	mkdir -p $(DESTDIR)/usr/sbin
	mkdir -p $(DESTDIR)$(ERL_INSTALL_PATH)/$(ERL_APP_NAME)-$(ERL_APP_VER)/ebin
	install -m 644 ebin/*.app ebin/*.beam $(DESTDIR)$(ERL_INSTALL_PATH)/$(ERL_APP_NAME)-$(ERL_APP_VER)/ebin
	sed 's:^%%!.*:%%! -noinput -kernel error_logger silent -args_file $(ESCRIPT_ARGS_FILE):' bin/statetipd > $(DESTDIR)/usr/sbin/statetipd
	chmod 755 $(DESTDIR)/usr/sbin/statetipd
	touch $(DESTDIR)$(ESCRIPT_ARGS_FILE)
	install -m 644 examples/statetip.toml $(DESTDIR)/etc/statetip/statetip.toml.example

install-python:
	python setup.py install --prefix=/usr --exec-prefix=/usr$(if $(DESTDIR), --root=$(DESTDIR))

#-----------------------------------------------------------------------------
# vim:ft=make
