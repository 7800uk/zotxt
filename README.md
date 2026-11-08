# zotxt-emacs

This is a fork of [egh/zotxt-emacs](https://github.com/egh/zotxt-emacs), kept at
[gitlab.7800.io/7800uk/zotxt](https://gitlab.7800.io/7800uk/zotxt) and push-mirrored to
[github.com/7800uk/zotxt](https://github.com/7800uk/zotxt). It brings the package up to date
with Emacs 29 and later (it is used on 31 and 32) and adds `zotxt-altero.el`, described
below; zotxt's own files keep their behaviour.

## Introduction

zotxt-emacs works with [zotxt](https://github.com/egh/zotxt) to provide Emacs integration with Zotero, allowing you to manage citation keys for pandoc markdown documents as well as org mode links to items in your Zotero collection.

## Installation

zotxt-emacs depends on [Zotero](https://www.zotero.org/) and the [zotxt](https://github.com/egh/zotxt) Zotero addon, which must be installed first. [Better BibTeX](https://retorque.re/zotero-better-bibtex/) is required for pandoc and citekey integration.

zotxt-emacs can be installed via [MELPA](https://melpa.org/#/?q=zotxt) by installing the package named `zotxt`.

If installing without MELPA, please note that zotxt-emacs depends on [request.el](https://github.com/tkf/emacs-request) and [deferred.el](https://github.com/kiwanami/emacs-deferred)

## Requirements

zotxt-emacs requires GNU Emacs >= 29.1. It should work with built-in org-mode or with the latest org-mode installed via the org ELPA repository.

zotxt-emacs requires Zotero and the zotxt addon >= 5.0.5.

# Org mode integration

To insert a link to a reference into a [org-mode](https://orgmode.org/) document, first enable the `org-zotxt` minor mode:

    M-x org-zotxt-mode

Then you can use: `C-c " i` (`org-zotxt-insert-reference-link`) to insert an item.

To update the current link text at point to reflect changed metadata from Zotero, use `C-c " u` (`org-zotxt-update-reference-link-at-point`).

To open an attachment of the link at point, use `C-c " a` (`org-zotxt-open-attachment`)

# Pandoc citekey integration

To insert citation keys into a markdown document (for use with pandoc), first enable  `zotxt-citekey` minor mode:

  M-x zotxt-citekey-mode
  
Then you can use: `C-c " k` (`zotxt-citekey-insert`) to insert a citation key. You can also use `complete-at-point` to complete the citekey. For example, if you type `@doe` `M-x completion-at-point`, you will be presented with a list of completions. In `markdown-mode` this is not bound to any key sequence, but you can of course bind it as you would like.

See [zotxt](https://github.com/egh/zotxt) for instructions on using [pandoc-zotxt.lua](https://github.com/odkr/pandoc-zotxt.lua) to automatically connect to a running Zotero instance to fetch citation data when using pandoc.

## org-noter

If you use [Org-noter](https://github.com/weirdNox/org-noter) you can use the `org-zotxt-noter` command to select an item in Zotero and take notes on its attachment. You will need to load the library using `M-x load-library org-zotxt-noter` or `(require 'org-zotxt-noter)`. Use the command in a headline, and it will either open the Org-noter interface or prompt for a Zotero search to load an attachment that can be annotated using Org-noter.

# Attachments through consult, and altero

`zotxt-altero.el` is kept apart from zotxt's own files and needs
[consult](https://github.com/minad/consult) as well. It reads the library from the
local API Zotero 7 and later serve beside zotxt (Settings → Advanced → *Allow other
applications on this computer to communicate with Zotero*).

- `zotxt-consult-attachment` lists every attachment in the library by title, with
  creators, year and file name alongside. Narrow with `p` (PDF), `e` (EPUB),
  `w` (web page) or `o` (other) after `consult-narrow-key`. A prefix argument reads
  the library again; otherwise it is read again only when its version has changed.
- `zotxt-consult-noter` chooses the document for an
  [org-noter](https://github.com/org-noter/org-noter) session at the heading at point
  from the same menu, and records it and a `zotero:` link to its item as properties.
- `zotxt-altero-mode` opens attachments from an [altero](https://github.com/eseifert/altero)
  server over TRAMP rather than from the local storage, so files Zotero has not
  downloaded still open. altero keeps each file under its MD5 digest,
  `STORAGE/<md5[:2]>/<md5>`, the digest Zotero records for the attachment. The mode also
  covers `org-zotxt-open-attachment` and `org-zotxt-noter`.

```elisp
(use-package zotxt
  :straight (zotxt :type git :repo "https://gitlab.7800.io/7800uk/zotxt.git")
  :hook ((org-mode . org-zotxt-mode)
         (org-mode . zotxt-citekey-mode))
  :custom
  (zotxt-altero-storage-directory "/ssh:root@altero.example:/var/lib/altero/storage/"))
```

The server's file names have no extension, so a document is handed to
[EμReader](https://gitlab.7800.io/7800uk/emureader) with its real name when that is
installed (EμReader fetches and caches it), and anything else is copied into
`zotxt-altero-cache-directory` first. Web snapshots, which Zotero uploads zipped, are
unpacked there.

A file has a digest in Zotero once Zotero has synced or downloaded it. To use the
server's own record instead, point `zotxt-altero-api-url` at its API, e.g.
`https://altero.example/users/12345/`, with the key in `~/.authinfo`:

    machine altero.example login 12345 password KEY

# The browser

`zotxt-browser.el` lays the library out the way Zotero does, and the way
[emacs-zotero](https://github.com/emacsmirror/zotero)'s `zotero-browser` does: libraries at
the top left, the collections of the library below them, the items of the collection in the
middle as a tree with their attachments and notes folded under them, and the item at point on
the right. It reads the library from Zotero's local API, as `zotxt-altero` does, and is
read-only, as that API is. Its panes are [vui.el](https://github.com/d12frosted/vui.el)
components, one tree per buffer, all drawn from one state, so it needs vui as well.

`M-x zotxt-browser` opens it. The keys are `zotero-browser`'s, less the ones that edit:

| Key | | Key | |
|-----|-|-----|-|
| `RET` | open the attachment or note, or show the item | `e` | show the item |
| `TAB` | fold or unfold | `S-TAB` | fold or unfold all |
| `$` / `M-$` | unfold / fold all | `u` | up to the parent |
| `n` / `p` | next / previous row | `C-c C-f` / `C-c C-b` | next / previous sibling |
| `C-c C-n` / `C-c C-p` | next / previous collection | `C-c C-u` | up a collection |
| `a` / `U` / `B` | all items / unfiled / bin | `s` | sort (or click a column) |
| `/` | filter by title, creator or year | `o` | open the attachment |
| `w` | copy an Org `zotero:` link | `k` | copy the citekey |
| `z` | select in Zotero | `A` | toggle `zotxt-altero-mode` |
| `g` | read the library again | `q` | close the browser |

`zotxt-browser-item-columns` chooses the columns; a column of width `nil`, the title by
default, takes what the window leaves.

# Development

`make compile` byte-compiles every file with warnings as errors, and `make checkdoc`
checks the documentation. `DEPS` names the directory holding the dependencies,
straight.el's build directory by default.
