.PHONY: test compile checkdoc clean

CASK ?= org-latest
EMACS ?= emacs
# Where deferred, request, consult, compat and org-noter are found; straight's
# build directory by default.
DEPS ?= $(HOME)/.emacs.d/straight/build
LOAD_PATH = -L . $(patsubst %,-L %,$(wildcard $(DEPS)/*))
SRCS = zotxt.el org-zotxt.el org-zotxt-noter.el zotxt-altero.el

test:
	$(MAKE) -C casks/$(CASK) test

compile:
	$(EMACS) -Q --batch $(LOAD_PATH) \
	  --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile $(SRCS)

checkdoc:
	$(EMACS) -Q --batch $(LOAD_PATH) \
	  --eval '(dolist (f (list $(patsubst %,"%",$(SRCS)))) (checkdoc-file f))'

clean:
	rm -f *.elc
