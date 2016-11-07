#!/usr/bin/make -f

SPHINX_DOCTREE = doctrees
SPHINX_SOURCE = .
SPHINX_HTML = html
SPHINX_MANPAGES = man

#-----------------------------------------------------------------------------

.PHONY: all doc html man clean

all doc: html man

html:
	sphinx-build -b html -d $(SPHINX_DOCTREE) $(SPHINX_SOURCE) $(SPHINX_HTML)

man:
	sphinx-build -b man -d $(SPHINX_DOCTREE) $(SPHINX_SOURCE) $(SPHINX_MANPAGES)
	bin/postprocess-manpages $(SPHINX_MANPAGES)/*.[1-8]

clean:
	rm -rf $(SPHINX_DOCTREE) $(SPHINX_MANPAGES) $(SPHINX_HTML)

#-----------------------------------------------------------------------------
# vim:ft=make
