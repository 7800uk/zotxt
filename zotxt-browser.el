;;; zotxt-browser.el --- Browse the Zotero library in four panes  -*- lexical-binding: t -*-

;; Copyright (C) 2026 Jacob Walchuk

;; Author: Jacob Walchuk <git@7800.io>
;; URL: https://gitlab.7800.io/7800uk/zotxt
;; Keywords: bib
;; Version: 6.1.0
;; Package-Requires: ((emacs "29.1") (zotxt "6.1.0") (consult "1.0") (vui "1.4.0"))

;; This file is not part of GNU Emacs.

;; zotxt-browser.el is free software: you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.

;; zotxt-browser.el is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with zotxt-browser.el.  If not, see
;; <http://www.gnu.org/licenses/>.

;;; Commentary:

;; `zotxt-browser' shows the Zotero library the way Zotero does, and
;; the way emacs-zotero's `zotero-browser' does: libraries at the top
;; left, the collections of the library below them, the items of the
;; collection in the middle, as a tree whose children are their
;; attachments and notes, and the item at point on the right.
;;
;; It reads the running Zotero through its local API, as `zotxt-altero'
;; does, and is read-only, as that API is.  Attachments open through
;; `zotxt-altero-open', so `zotxt-altero-mode' takes them from the
;; altero server.  The panes are vui.el components
;; (https://github.com/d12frosted/vui.el), one tree per buffer, all
;; drawn from one state.
;;
;; In the items pane: RET opens the item at point (its attachment, its
;; note, or the item itself in the item pane), TAB folds it, S-TAB
;; folds every item, $ and M-$ unfold and fold all, n and p move, u goes
;; to the parent, C-c C-f and C-c C-b move among siblings, C-c C-n,
;; C-c C-p and C-c C-u move through the collections, s sorts, / filters,
;; a, U and B show every item, the unfiled ones and the bin, e shows
;; the item, w copies a zotero: link, k copies the citekey, z selects
;; the item in Zotero, A toggles `zotxt-altero-mode', g reads the
;; library again and q quits.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'shr)
(require 'vui)
(require 'zotxt)
(require 'zotxt-altero)

(defvar url-http-end-of-headers)

;;;; Options

(defgroup zotxt-browser nil
  "Browse the Zotero library in four panes."
  :group 'zotxt
  :prefix "zotxt-browser-")

(defcustom zotxt-browser-item-columns '((:title . nil) (:creators . 25) (:year . 4))
  "Columns of the items pane, as (FIELD . WIDTH).
FIELD is :title, :creators, :year, :itemType, :dateAdded,
:dateModified or the keyword of any other field of an item.  A WIDTH
of nil takes what the window leaves of its width, and at least 20."
  :type '(alist :key-type symbol
                :value-type (choice (const :tag "Fill the window" nil) integer)))

(defcustom zotxt-browser-items-sort-field '(:title . nil)
  "Field the items are sorted by, and whether the order is reversed."
  :type '(cons symbol boolean))

(defcustom zotxt-browser-icons t
  "Whether to show a mark for the type of each item.
The mark is an icon of all-the-icons when that is installed and the
frame is graphical, and a symbol otherwise.  Icons line up with the
columns when they are sized to whole cells, as the 7800uk fork of
all-the-icons sizes them."
  :type 'boolean)

(defcustom zotxt-browser-libraries-buffer-name "*Zotxt Libraries*"
  "Name of the libraries buffer."
  :type 'string)

(defcustom zotxt-browser-collections-buffer-name "*Zotxt Collections*"
  "Name of the collections buffer."
  :type 'string)

(defcustom zotxt-browser-items-buffer-name "*Zotxt Items*"
  "Name of the items buffer."
  :type 'string)

(defcustom zotxt-browser-item-buffer-name "*Zotxt Item*"
  "Name of the buffer showing the item at point."
  :type 'string)

(defcustom zotxt-browser-note-buffer-name "*Zotxt Note*"
  "Name of the buffer showing a note."
  :type 'string)

(defvar zotxt-browser-libraries-buffer-action
  '((display-buffer-reuse-window display-buffer-in-side-window)
    (side . left) (slot . -1) (window-width . 0.2)
    (window-height . fit-window-to-buffer)
    (preserve-size . (t . nil)) (reusable-frames . nil))
  "How the libraries buffer is shown.")

(defvar zotxt-browser-collections-buffer-action
  '((display-buffer-reuse-window display-buffer-in-side-window)
    (side . left) (slot . 0) (window-width . 0.2)
    (preserve-size . (t . nil)) (reusable-frames . nil))
  "How the collections buffer is shown.")

(defvar zotxt-browser-items-buffer-action
  '((display-buffer-same-window))
  "How the items buffer is shown.")

(defvar zotxt-browser-item-buffer-action
  '((display-buffer-reuse-window display-buffer-in-side-window)
    (side . right) (slot . 0) (window-width . 0.3)
    (preserve-size . (t . nil)) (reusable-frames . nil))
  "How the buffer showing the item at point is shown.")

(defvar zotxt-browser-note-buffer-action
  '((display-buffer-reuse-window display-buffer-in-side-window)
    (side . bottom) (window-height . 0.4) (preserve-size . (nil . t)))
  "How the note buffer is shown.")

(defface zotxt-browser-selected '((t :inherit highlight :extend t))
  "Face for the selected library or collection.")

(defface zotxt-browser-header '((t :inherit (header-line bold)))
  "Face for the column headers of the items pane.")

(defface zotxt-browser-child '((t :inherit shadow))
  "Face for attachments and notes in the items pane.")

(defface zotxt-browser-field '((t :inherit font-lock-keyword-face))
  "Face for the field names in the item pane.")

;;;; The library

(defvar zotxt-browser--libraries nil
  "Libraries of the running Zotero: a list of plists.
Each has :id (a string, \"users/0\" or \"groups/ID\") and :name.")

(defvar zotxt-browser--data (make-hash-table :test #'equal)
  "What has been read of each library, by library id.
Each value is a plist: :version, :items (a hash table of item objects
by key), :children (a hash table of child keys by parent key) and
:collections (a list of collection objects).")

(defun zotxt-browser--api-root ()
  "Return the URL above the libraries of `zotxt-altero-api-url'."
  (replace-regexp-in-string "\\(users\\|groups\\)/[0-9]+/\\'" ""
                            zotxt-altero-api-url))

(defmacro zotxt-browser--in-library (library &rest body)
  "Run BODY with the API's requests going to LIBRARY, an id."
  (declare (indent 1))
  `(let ((zotxt-altero-api-url (concat (zotxt-browser--api-root) ,library "/")))
     ,@body))

(defun zotxt-browser--read-libraries ()
  "Read the libraries of the running Zotero."
  (setq zotxt-browser--libraries
        (cons (list :id (string-trim-right
                         (substring zotxt-altero-api-url
                                    (length (zotxt-browser--api-root)))
                         "/")
                    :name "My Library")
              (mapcar (lambda (group)
                        (list :id (format "groups/%s" (alist-get 'id group))
                              :name (alist-get 'name (alist-get 'data group))))
                      (ignore-errors
                        (zotxt-altero--request-all "groups"))))))

(defun zotxt-browser--read-library (library &optional refresh)
  "Read LIBRARY, an id, unless it has not changed since it was last read.
With REFRESH non-nil, read it regardless.  Return its data."
  (zotxt-browser--in-library library
    (let ((version (zotxt-altero--library-version))
          (data (gethash library zotxt-browser--data)))
      (if (and data (not refresh) (equal version (plist-get data :version)))
          data
        (message "Reading %s..." library)
        (let ((items (make-hash-table :test #'equal))
              (children (make-hash-table :test #'equal)))
          (dolist (object (zotxt-altero--request-all
                           "items" '(("includeTrashed" "1"))))
            (let* ((data (alist-get 'data object))
                   (key (alist-get 'key data))
                   (parent (alist-get 'parentItem data)))
              (puthash key object items)
              (when parent (push key (gethash parent children)))))
          (setq data (list :version version :items items :children children
                           :collections (zotxt-altero--request-all "collections")))
          (puthash library data zotxt-browser--data)
          (message "Reading %s...done" library)
          data)))))

;;;; Fields of an item

(defun zotxt-browser--field (object field)
  "Return FIELD of the item OBJECT as a string, or nil."
  (let ((data (alist-get 'data object))
        (meta (alist-get 'meta object)))
    (pcase field
      (:creators (zotxt-altero--clean (alist-get 'creatorSummary meta)))
      (:year (zotxt-altero--year meta))
      (:title (let ((type (alist-get 'itemType data)))
                (if (equal type "note")
                    (zotxt-browser--note-title data)
                  (alist-get 'title data))))
      ((or :dateAdded :dateModified)
       (when-let* ((date (alist-get (intern (substring (symbol-name field) 1)) data)))
         (substring date 0 (min 10 (length date)))))
      (_ (let ((value (alist-get (intern (substring (symbol-name field) 1)) data)))
           (and value (format "%s" value)))))))

(defun zotxt-browser--note-text (data)
  "Return the text of the note DATA, without its markup."
  (with-temp-buffer
    (insert (or (alist-get 'note data) ""))
    (goto-char (point-min))
    (while (re-search-forward "<[^>]*>" nil t) (replace-match " "))
    (string-trim (replace-regexp-in-string "[ \t\n]+" " " (buffer-string)))))

(defun zotxt-browser--note-title (data)
  "Return the first words of the note DATA."
  (let ((text (zotxt-browser--note-text data)))
    (if (string-empty-p text) "(empty note)"
      (truncate-string-to-width text 80))))

(defcustom zotxt-browser-type-icons
  '(("book" "book" all-the-icons-dyellow)
    ("bookSection" "bookmark" all-the-icons-yellow)
    ("journalArticle" "file-text-o" all-the-icons-lblue)
    ("magazineArticle" "newspaper-o" all-the-icons-blue)
    ("newspaperArticle" "newspaper-o" all-the-icons-blue)
    ("encyclopediaArticle" "university" all-the-icons-cyan)
    ("dictionaryEntry" "university" all-the-icons-cyan)
    ("thesis" "graduation-cap" all-the-icons-purple)
    ("conferencePaper" "users" all-the-icons-lblue)
    ("report" "file-o" all-the-icons-silver)
    ("manuscript" "pencil" all-the-icons-orange)
    ("letter" "envelope-o" all-the-icons-orange)
    ("email" "envelope-o" all-the-icons-orange)
    ("webpage" "globe" all-the-icons-green)
    ("blogPost" "rss" all-the-icons-green)
    ("forumPost" "comments-o" all-the-icons-green)
    ("videoRecording" "film" all-the-icons-red)
    ("film" "film" all-the-icons-red)
    ("audioRecording" "headphones" all-the-icons-red)
    ("podcast" "podcast" all-the-icons-red)
    ("computerProgram" "code" all-the-icons-purple)
    ("presentation" "television" all-the-icons-orange)
    ("note" "sticky-note-o" all-the-icons-yellow))
  "Font Awesome icons for Zotero item types, as (TYPE ICON FACE).
Used when all-the-icons is installed and the frame can show it; a type
not listed gets a plain file.  Attachments get the icon of their file."
  :type '(repeat (list string string face)))

(defun zotxt-browser--icons-p ()
  "Non-nil if marks are all-the-icons icons rather than symbols."
  (and zotxt-browser-icons (display-graphic-p)
       (require 'all-the-icons nil t)))

(defun zotxt-browser--mark-width ()
  "Return the columns a mark takes, with the space after it."
  (if (not zotxt-browser-icons) 0
    (1+ (or (and (zotxt-browser--icons-p)
                 (bound-and-true-p all-the-icons-cell-width))
            1))))

(declare-function all-the-icons-faicon "all-the-icons" (icon-name &rest args))
(declare-function all-the-icons-icon-for-file "all-the-icons" (file &rest args))

(defun zotxt-browser--icon (object)
  "Return the all-the-icons icon for the type of the item OBJECT."
  (let* ((data (alist-get 'data object))
         (type (alist-get 'itemType data)))
    (if (equal type "attachment")
        (let ((content (or (alist-get 'contentType data) "")))
          (cond ((equal (alist-get 'linkMode data) "linked_url")
                 (all-the-icons-faicon "link" :face 'all-the-icons-blue))
                ((string-prefix-p "text/html" content)
                 (all-the-icons-faicon "globe" :face 'all-the-icons-green))
                (t (all-the-icons-icon-for-file
                    (or (alist-get 'filename data) (alist-get 'title data) "file")))))
      (pcase-let ((`(,icon ,face) (cdr (assoc type zotxt-browser-type-icons))))
        (all-the-icons-faicon (or icon "file-o")
                              :face (or face 'all-the-icons-silver))))))

(declare-function all-the-icons-octicon "all-the-icons" (icon-name &rest args))

(defun zotxt-browser--fold (fold)
  "Return the two columns showing FOLD: `open', `closed' or nil.
An arrow of all-the-icons where icons are shown, so that it is one cell
wide like the icons; otherwise a symbol."
  (pcase fold
    ('nil "  ")
    (_ (concat (if (zotxt-browser--icons-p)
                   (all-the-icons-octicon (if (eq fold 'open) "triangle-down"
                                            "triangle-right")
                                          :face 'all-the-icons-silver)
                 (if (eq fold 'open) "▾" "▸"))
               " "))))

(defun zotxt-browser--mark (object)
  "Return the mark shown for the type of the item OBJECT.
An all-the-icons icon where it can be shown, otherwise a symbol."
  (if (zotxt-browser--icons-p)
      (zotxt-browser--icon object)
    (let ((data (alist-get 'data object)))
      (pcase (alist-get 'itemType data)
        ("note" "✎")
        ("attachment" (pcase (alist-get 'contentType data)
                        ("application/pdf" "⎙")
                        ((pred (lambda (type) (and type (string-prefix-p "text/html" type)))) "◎")
                        (_ "▫")))
        ((or "book" "bookSection") "▤")
        (_ "▪")))))

(defun zotxt-browser--deleted-p (object)
  "Non-nil if the item OBJECT is in the bin."
  (memq (alist-get 'deleted (alist-get 'data object)) '(1 t)))

;;;; State

(defvar zotxt-browser--shown-count 0
  "How many items the items pane shows.")

(defvar zotxt-browser--state nil
  "The browser's state, a plist.
:library is the id of the library shown.  :collection is nil for every
item, a collection key, `unfiled' or `trash'.  :open-collections and
:open-items are the keys unfolded.  :sort is as
`zotxt-browser-items-sort-field'.  :filter is the filter string, or
nil.  :item is the key of the item shown in the item pane.")

(defun zotxt-browser--get (key)
  "Return KEY of the browser's state."
  (plist-get zotxt-browser--state key))

(defun zotxt-browser--data ()
  "Return the data of the library shown."
  (gethash (zotxt-browser--get :library) zotxt-browser--data))

(defun zotxt-browser--object (key)
  "Return the item with KEY in the library shown."
  (gethash key (plist-get (zotxt-browser--data) :items)))

(defun zotxt-browser--children (key)
  "Return the attachments and notes of the item with KEY, in order."
  (let ((items (plist-get (zotxt-browser--data) :items)))
    (sort (seq-remove (lambda (object)
                        (and (not (eq (zotxt-browser--get :collection) 'trash))
                             (zotxt-browser--deleted-p object)))
                      (mapcar (lambda (k) (gethash k items))
                              (gethash key (plist-get (zotxt-browser--data) :children))))
          (lambda (a b)
            (let ((ta (alist-get 'itemType (alist-get 'data a)))
                  (tb (alist-get 'itemType (alist-get 'data b))))
              (if (equal ta tb)
                  (string< (or (zotxt-browser--field a :title) "")
                           (or (zotxt-browser--field b :title) ""))
                (equal ta "attachment")))))))

(defun zotxt-browser--top-items ()
  "Return the top-level items of the collection shown, filtered and sorted."
  (let* ((collection (zotxt-browser--get :collection))
         (filter (zotxt-browser--get :filter))
         (sort-field (or (zotxt-browser--get :sort) zotxt-browser-items-sort-field))
         items)
    (maphash
     (lambda (_ object)
       (let* ((data (alist-get 'data object))
              (deleted (zotxt-browser--deleted-p object)))
         (when (and (not (alist-get 'parentItem data))
                    (pcase collection
                      ('trash deleted)
                      ('unfiled (and (not deleted) (null (alist-get 'collections data))))
                      ('nil (not deleted))
                      (key (and (not deleted)
                                (member key (alist-get 'collections data)))))
                    (or (null filter)
                        (seq-some (lambda (field)
                                    (when-let* ((value (zotxt-browser--field object field)))
                                      (string-match-p (regexp-quote filter) value)))
                                  '(:title :creators :year))))
           (push object items))))
     (plist-get (zotxt-browser--data) :items))
    (let* ((field (car sort-field))
           (keyed (mapcar (lambda (object)
                            (cons (zotxt-browser--field object field) object))
                          items))
           (with (seq-filter (lambda (k) (and (car k) (not (string-empty-p (car k)))))
                             keyed))
           (sorted (mapcar #'cdr
                           (sort with (lambda (a b)
                                        (string-collate-lessp (car a) (car b) nil t))))))
      ;; Items without the field come last whichever way the rest go.
      (append (if (cdr sort-field) (nreverse sorted) sorted)
              (mapcar #'cdr (seq-difference keyed with #'eq))))))

(defun zotxt-browser--collection-children (parent)
  "Return the collections in PARENT, a key or nil for the top, by name."
  (sort (seq-filter (lambda (c)
                      (equal (or (alist-get 'parentCollection (alist-get 'data c)) nil)
                             (or parent nil)))
                    (mapcar (lambda (c)
                              ;; The API says :json-false for a top collection.
                              (let ((data (alist-get 'data c)))
                                (unless (stringp (alist-get 'parentCollection data))
                                  (setf (alist-get 'parentCollection (alist-get 'data c)) nil))
                                c))
                            (plist-get (zotxt-browser--data) :collections)))
        (lambda (a b)
          (string-collate-lessp (alist-get 'name (alist-get 'data a))
                                (alist-get 'name (alist-get 'data b))
                                nil t))))

;;;; Rendering

(defun zotxt-browser--cell (string width)
  "Return STRING fitted to WIDTH columns, padded on the right."
  (let ((string (or string "")))
    (truncate-string-to-width (replace-regexp-in-string "\n" " " string)
                              width nil ?\s "…")))

(vui-defcomponent zotxt-browser-library-row (library selected)
  :memo t
  :render
  (vui-region
   :key (plist-get library :id)
   :face (and selected 'zotxt-browser-selected)
   (vui-text (concat " " (if selected "▸ " "  ") (plist-get library :name)))))

(vui-defcomponent zotxt-browser-libraries (libraries current)
  :render
  (vui-vstack
   (vui-list libraries
             (lambda (library)
               (vui-component 'zotxt-browser-library-row
                              :key (plist-get library :id)
                              :library library
                              :selected (equal (plist-get library :id) current)))
             (lambda (library) (plist-get library :id)))))

(vui-defcomponent zotxt-browser-collection-row (key label level fold selected)
  :memo t
  :render
  (vui-region
   :key key
   :face (and selected 'zotxt-browser-selected)
   (vui-text (concat " " (make-string (* 2 level) ?\s)
                     (zotxt-browser--fold fold)
                     label))))

(defun zotxt-browser--collection-rows (parent level open current)
  "Return rows for the collections in PARENT at LEVEL, and theirs.
OPEN are the unfolded collections, CURRENT the one shown."
  (mapcan
   (lambda (c)
     (let* ((key (alist-get 'key c))
            (has (zotxt-browser--collection-children key))
            (unfolded (and has (member key open))))
       (cons (vui-component 'zotxt-browser-collection-row
                            :key key :label (alist-get 'name (alist-get 'data c))
                            :level level
                            :fold (cond (unfolded 'open) (has 'closed))
                            :selected (equal key current))
             (and unfolded
                  (zotxt-browser--collection-rows key (1+ level) open current)))))
   (zotxt-browser--collection-children parent)))

(vui-defcomponent zotxt-browser-collections (version open current)
  :render
  (progn
    (ignore version)
    (vui-vstack
     (zotxt-browser--collection-rows nil 0 open current)
     (vui-component 'zotxt-browser-collection-row
                    :key 'unfiled :label "Unfiled" :level 0 :fold nil
                    :selected (eq current 'unfiled))
     (vui-component 'zotxt-browser-collection-row
                    :key 'trash :label "Bin" :level 0 :fold nil
                    :selected (eq current 'trash)))))

(defun zotxt-browser--columns ()
  "Return `zotxt-browser-item-columns' with every width a number.
A column of no width takes what the items window leaves."
  (let* ((window (get-buffer-window zotxt-browser-items-buffer-name t))
         (total (if window (window-body-width window) 100))
         (fixed (+ 4 (zotxt-browser--mark-width)
                   (1- (length zotxt-browser-item-columns))
                   (apply #'+ (mapcar (lambda (c) (or (cdr c) 0))
                                      zotxt-browser-item-columns)))))
    (mapcar (lambda (c) (cons (car c) (or (cdr c) (max 20 (- total fixed)))))
            zotxt-browser-item-columns)))

(defun zotxt-browser--row-text (object level fold columns)
  "Return the line of the items pane for OBJECT at LEVEL, folded as FOLD.
COLUMNS are as `zotxt-browser--columns' returns them."
  (let ((first t))
    (concat
     " "
     (make-string (* 2 level) ?\s)
     (zotxt-browser--fold fold)
     (if zotxt-browser-icons (concat (zotxt-browser--mark object) " ") "")
     (mapconcat
      (lambda (column)
        (prog1 (zotxt-browser--cell
                (zotxt-browser--field object (car column))
                (if first (max 4 (- (cdr column) (* 2 level))) (cdr column)))
          (setq first nil)))
      columns
      " "))))

(vui-defcomponent zotxt-browser-item-row (object level fold columns)
  :memo t
  :render
  (vui-region
   :key (alist-get 'key (alist-get 'data object))
   :face (and (> level 0) 'zotxt-browser-child)
   (vui-text (zotxt-browser--row-text object level fold columns))))

(defun zotxt-browser--header (sort-field columns)
  "Return the header row of the items pane, sorted by SORT-FIELD.
COLUMNS are as `zotxt-browser--columns' returns them."
  (let ((first t))
    (vui-hstack
     :spacing 0
     (vui-text (concat " " (make-string (+ 2 (zotxt-browser--mark-width)) ?\s))
               :face 'zotxt-browser-header)
     (mapcar
      (lambda (column)
        (let* ((field (car column))
               (name (zotxt-browser--field-label (substring (symbol-name field) 1)))
               ;; As in zotero-browser: no arrow where it does not fit.
               (label (concat name
                              (cond ((not (eq field (car sort-field))) "")
                                    ((> (+ 2 (string-width name)) (cdr column)) "")
                                    ((cdr sort-field) " ▴")
                                    (t " ▾")))))
          (prog1
              (vui-fragment
               (unless first (vui-text " " :face 'zotxt-browser-header))
               (vui-button (zotxt-browser--cell label (cdr column))
                           :no-decoration t :help-echo nil
                           :face 'zotxt-browser-header
                           :on-click (lambda () (zotxt-browser-sort field))))
            (setq first nil))))
      columns))))

(vui-defcomponent zotxt-browser-items (version collection filter sort open columns)
  :render
  (let ((rows nil)
        (items (zotxt-browser--top-items)))
    (ignore version collection)
    (setq zotxt-browser--shown-count (length items))
    (dolist (object items)
      (let* ((key (alist-get 'key (alist-get 'data object)))
             (children (zotxt-browser--children key))
             (unfolded (and children (member key open))))
        (push (vui-component 'zotxt-browser-item-row
                             :key key :object object :level 0 :columns columns
                             :fold (cond (unfolded 'open) (children 'closed)))
              rows)
        (when unfolded
          (dolist (child children)
            (push (vui-component 'zotxt-browser-item-row
                                 :key (alist-get 'key (alist-get 'data child))
                                 :object child :level 1 :fold nil
                                 :columns columns)
                  rows)))))
    (vui-vstack
     (vui-region :sticky t
       (vui-vstack
        (zotxt-browser--header sort columns)
        (when filter
          (vui-text (format " Filtered by “%s”; / with nothing to clear it" filter)
                    :face 'shadow))
        (nreverse rows))))))

(defun zotxt-browser--field-label (name)
  "Return the label for the field NAME, a camelCase string."
  (let ((case-fold-search nil))
    (capitalize (replace-regexp-in-string "\\([a-z]\\)\\([A-Z]\\)" "\\1 \\2" name))))

(defconst zotxt-browser--hidden-fields
  '(key version itemType title creators tags collections relations
        dateAdded dateModified note parentItem deleted md5 mtime
        charset contentType linkMode filename path)
  "Fields the item pane shows apart from the rest, or not at all.")

(defconst zotxt-browser--label-width 17
  "Columns taken by the field names in the item pane.")

(defun zotxt-browser--wrap (string width)
  "Return STRING filled to WIDTH, later lines indented to the values."
  (with-temp-buffer
    (insert (replace-regexp-in-string "[ \t\n]+" " " string))
    (let ((fill-column (max 20 width)))
      (fill-region (point-min) (point-max)))
    (string-join (split-string (buffer-string) "\n")
                 (concat "\n" (make-string zotxt-browser--label-width ?\s)))))

(defun zotxt-browser--field-row (label value)
  "Return a row of the item pane for LABEL and VALUE."
  (let* ((window (get-buffer-window zotxt-browser-item-buffer-name t))
         (width (- (if window (window-body-width window) 60)
                   zotxt-browser--label-width 1)))
    (vui-fragment
     (vui-text (string-pad (concat label ":") zotxt-browser--label-width)
               :face 'zotxt-browser-field)
     (vui-text (zotxt-browser--wrap value width)))))

(vui-defcomponent zotxt-browser-item (object)
  :render
  (if (null object)
      (vui-text " No item at point." :face 'shadow)
    (let* ((data (alist-get 'data object))
           (key (alist-get 'key data))
           (type (alist-get 'itemType data)))
      (vui-vstack
       (zotxt-browser--field-row "Key" key)
       (zotxt-browser--field-row "Version" (format "%s" (alist-get 'version data)))
       (zotxt-browser--field-row "Item Type" (zotxt-browser--field-label type))
       (zotxt-browser--field-row "Title" (or (zotxt-browser--field object :title) ""))
       (mapcar (lambda (creator)
                 (zotxt-browser--field-row
                  (zotxt-browser--field-label (alist-get 'creatorType creator))
                  (or (alist-get 'name creator)
                      (string-join (delq nil (list (alist-get 'lastName creator)
                                                   (alist-get 'firstName creator)))
                                   ", "))))
               (alist-get 'creators data))
       (cl-loop for (field . value) in data
                unless (or (memq field zotxt-browser--hidden-fields)
                           (null value) (equal value "") (equal value []))
                collect (zotxt-browser--field-row
                         (zotxt-browser--field-label (symbol-name field))
                         (format "%s" value)))
       (when (equal type "attachment")
         (zotxt-browser--field-row "File" (or (alist-get 'filename data) "")))
       (when-let* ((tags (alist-get 'tags data)))
         (zotxt-browser--field-row
          "Tags" (mapconcat (lambda (tag) (alist-get 'tag tag)) tags ", ")))
       (when-let* ((collections (alist-get 'collections data)))
         (zotxt-browser--field-row
          "Collections"
          (mapconcat (lambda (k)
                       (or (seq-some (lambda (c)
                                       (and (equal (alist-get 'key c) k)
                                            (alist-get 'name (alist-get 'data c))))
                                     (plist-get (zotxt-browser--data) :collections))
                           k))
                     collections ", ")))
       (zotxt-browser--field-row "Date Added" (or (zotxt-browser--field object :dateAdded) ""))
       (zotxt-browser--field-row "Date Modified"
                                 (or (zotxt-browser--field object :dateModified) ""))
       (vui-newline)
       (vui-vstack
        (unless (member type '("attachment" "note"))
          (vui-button "Open attachment"
                      :on-click (lambda () (zotxt-browser--open-object object))))
        (vui-button "Show in Zotero" :on-click (lambda () (zotxt-browser--select key)))
        (vui-button "Copy link" :on-click (lambda () (zotxt-browser--copy-link object))))))))

;;;; Keymaps

(defvar-keymap zotxt-browser-libraries-mode-map
  :doc "Keymap for the libraries pane."
  "RET" #'zotxt-browser-display
  "g" #'zotxt-browser-revert
  "n" #'zotxt-browser-next
  "p" #'zotxt-browser-prev
  "C-c C-u" #'zotxt-browser-up-collection
  "C-c C-n" #'zotxt-browser-next-collection
  "C-c C-p" #'zotxt-browser-prev-collection
  "q" #'zotxt-browser-quit)

(defvar-keymap zotxt-browser-collections-mode-map
  :doc "Keymap for the collections pane."
  "RET" #'zotxt-browser-display
  "TAB" #'zotxt-browser-toggle
  "<tab>" #'zotxt-browser-toggle
  "<backtab>" #'zotxt-browser-cycle
  "$" #'zotxt-browser-expand-all
  "M-$" #'zotxt-browser-collapse-all
  "u" #'zotxt-browser-up
  "n" #'zotxt-browser-next
  "p" #'zotxt-browser-prev
  "C-c C-f" #'zotxt-browser-forward-same-level
  "C-c C-b" #'zotxt-browser-backward-same-level
  "C-c C-u" #'zotxt-browser-up-collection
  "C-c C-n" #'zotxt-browser-next-collection
  "C-c C-p" #'zotxt-browser-prev-collection
  "a" #'zotxt-browser-all-items
  "U" #'zotxt-browser-unfiled-items
  "B" #'zotxt-browser-trash-items
  "g" #'zotxt-browser-revert
  "q" #'zotxt-browser-quit)

(defvar-keymap zotxt-browser-items-mode-map
  :doc "Keymap for the items pane."
  "RET" #'zotxt-browser-open
  "TAB" #'zotxt-browser-toggle
  "<tab>" #'zotxt-browser-toggle
  "<backtab>" #'zotxt-browser-cycle
  "$" #'zotxt-browser-expand-all
  "M-$" #'zotxt-browser-collapse-all
  "u" #'zotxt-browser-up
  "n" #'zotxt-browser-next
  "p" #'zotxt-browser-prev
  "C-c C-f" #'zotxt-browser-forward-same-level
  "C-c C-b" #'zotxt-browser-backward-same-level
  "C-c C-u" #'zotxt-browser-up-collection
  "C-c C-n" #'zotxt-browser-next-collection
  "C-c C-p" #'zotxt-browser-prev-collection
  "a" #'zotxt-browser-all-items
  "U" #'zotxt-browser-unfiled-items
  "B" #'zotxt-browser-trash-items
  "e" #'zotxt-browser-edit
  "o" #'zotxt-browser-open-attachment
  "s" #'zotxt-browser-sort
  "/" #'zotxt-browser-filter
  "w" #'zotxt-browser-copy-link
  "k" #'zotxt-browser-copy-citekey
  "z" #'zotxt-browser-select-in-zotero
  "A" #'zotxt-altero-mode
  "g" #'zotxt-browser-revert
  "q" #'zotxt-browser-quit)

(defvar-keymap zotxt-browser-item-mode-map
  :doc "Keymap for the item pane."
  "o" #'zotxt-browser-open-attachment
  "w" #'zotxt-browser-copy-link
  "k" #'zotxt-browser-copy-citekey
  "z" #'zotxt-browser-select-in-zotero
  "q" #'quit-window)

;;;; Buffers

(defun zotxt-browser--collection-name (collection)
  "Return the name of COLLECTION as the state has it."
  (pcase collection
    ('nil (or (plist-get (seq-find (lambda (l) (equal (plist-get l :id)
                                                      (zotxt-browser--get :library)))
                                   zotxt-browser--libraries)
                         :name)
              "All items"))
    ('unfiled "Unfiled")
    ('trash "Bin")
    (key (or (seq-some (lambda (c) (and (equal (alist-get 'key c) key)
                                        (alist-get 'name (alist-get 'data c))))
                       (plist-get (zotxt-browser--data) :collections))
             key))))

(defun zotxt-browser-status ()
  "Return what the items pane shows: library or collection, count and order.
It is the header line of the items pane."
  (let ((sort (or (zotxt-browser--get :sort) zotxt-browser-items-sort-field)))
    (format " %s · %d items · by %s%s%s%s"
            (zotxt-browser--collection-name (zotxt-browser--get :collection))
            zotxt-browser--shown-count
            (downcase (zotxt-browser--field-label (substring (symbol-name (car sort)) 1)))
            (if (cdr sort) ", reversed" "")
            (if-let* ((filter (zotxt-browser--get :filter)))
                (format " · filtered by “%s”" filter) "")
            (if zotxt-altero-mode " · altero" ""))))

(defvar-local zotxt-browser--last-columns nil
  "The columns the items pane was last drawn with.")

(defun zotxt-browser--resized (_frame)
  "Draw the items pane again if its window changed width."
  (let ((columns (zotxt-browser--columns)))
    (unless (equal columns zotxt-browser--last-columns)
      (setq zotxt-browser--last-columns columns)
      (when (zotxt-browser--instance zotxt-browser-items-buffer-name)
        (zotxt-browser--render 'items)))))

(define-derived-mode zotxt-browser-libraries-mode vui-mode "Zotxt libraries"
  "Major mode for the libraries pane of `zotxt-browser'.")

(define-derived-mode zotxt-browser-collections-mode vui-mode "Zotxt collections"
  "Major mode for the collections pane of `zotxt-browser'.")

(define-derived-mode zotxt-browser-items-mode vui-mode "Zotxt items"
  "Major mode for the items pane of `zotxt-browser'.
\\{zotxt-browser-items-mode-map}"
  (setq-local truncate-lines t)
  (setq-local header-line-format '(:eval (zotxt-browser-status)))
  (add-hook 'window-size-change-functions #'zotxt-browser--resized nil t)
  (hl-line-mode 1))

(define-derived-mode zotxt-browser-item-mode vui-mode "Zotxt item"
  "Major mode for the item pane of `zotxt-browser'."
  (setq-local truncate-lines t))

(defun zotxt-browser--mount (name mode vnode)
  "Mount VNODE in the buffer NAME in MODE, without showing it.
Return the buffer."
  (let ((buffer (get-buffer-create name)))
    (with-current-buffer buffer
      (unless (derived-mode-p mode) (funcall mode)))
    (vui-mount vnode name t)
    buffer))

(defun zotxt-browser--instance (name)
  "Return the vui instance in the buffer NAME, or nil."
  (and (get-buffer name) (vui-get-instance (get-buffer name))))

(defun zotxt-browser--props (pane)
  "Return the props of PANE, one of the four, from the state."
  (let ((version (plist-get (zotxt-browser--data) :version)))
    (pcase pane
      ('libraries (list :libraries zotxt-browser--libraries
                        :current (zotxt-browser--get :library)))
      ('collections (list :version version
                          :open (zotxt-browser--get :open-collections)
                          :current (zotxt-browser--get :collection)))
      ('items (list :version version
                    :collection (zotxt-browser--get :collection)
                    :filter (zotxt-browser--get :filter)
                    :sort (or (zotxt-browser--get :sort) zotxt-browser-items-sort-field)
                    :open (zotxt-browser--get :open-items)
                    :columns (zotxt-browser--columns)))
      ('item (list :object (and (zotxt-browser--get :item)
                                (zotxt-browser--object (zotxt-browser--get :item))))))))

(defconst zotxt-browser--panes
  '((libraries zotxt-browser-libraries-buffer-name zotxt-browser-libraries-mode
               zotxt-browser-libraries)
    (collections zotxt-browser-collections-buffer-name zotxt-browser-collections-mode
                 zotxt-browser-collections)
    (items zotxt-browser-items-buffer-name zotxt-browser-items-mode
           zotxt-browser-items)
    (item zotxt-browser-item-buffer-name zotxt-browser-item-mode
          zotxt-browser-item))
  "Each pane: its buffer name variable, its mode and its component.")

(defun zotxt-browser--render (&rest panes)
  "Draw PANES again from the state, or every pane when PANES is nil."
  (pcase-dolist (`(,pane ,name-var ,mode ,component) zotxt-browser--panes)
    (when (or (null panes) (memq pane panes))
      (let* ((name (symbol-value name-var))
             (props (zotxt-browser--props pane)))
        (if-let* ((instance (zotxt-browser--instance name)))
            (vui-update instance props)
          (zotxt-browser--mount name mode (apply #'vui-component component props)))))))

(defun zotxt-browser--set (&rest pairs)
  "Set the state's keys and values in PAIRS."
  (while pairs
    (setq zotxt-browser--state (plist-put zotxt-browser--state (pop pairs) (pop pairs)))))

(defun zotxt-browser--toggle-member (key elt)
  "Add ELT to the list in state KEY, or take it out if it is there."
  (let ((list (zotxt-browser--get key)))
    (zotxt-browser--set key (if (member elt list) (delete elt (copy-sequence list))
                              (cons elt list)))))

;;;; Commands

(defun zotxt-browser--key-at ()
  "Return the key of the row at point, or nil."
  (vui-key-at))

(defun zotxt-browser--object-at ()
  "Return the item of the row at point, or signal an error."
  (or (and (derived-mode-p 'zotxt-browser-items-mode)
           (stringp (zotxt-browser--key-at))
           (zotxt-browser--object (zotxt-browser--key-at)))
      (and (derived-mode-p 'zotxt-browser-item-mode)
           (zotxt-browser--get :item)
           (zotxt-browser--object (zotxt-browser--get :item)))
      (user-error "No item at point")))

(defun zotxt-browser-display ()
  "Show the library, collection or item at point."
  (interactive)
  (let ((key (zotxt-browser--key-at)))
    (pcase major-mode
      ('zotxt-browser-libraries-mode
       (when key (zotxt-browser-show-library key)))
      ('zotxt-browser-collections-mode
       (when key
         (zotxt-browser--set :collection key)
         (zotxt-browser--render 'collections 'items)))
      ('zotxt-browser-items-mode (zotxt-browser-edit)))))

(defun zotxt-browser-show-library (library)
  "Show LIBRARY, an id, in the browser."
  (zotxt-browser--read-library library)
  (zotxt-browser--set :library library :collection nil :item nil
                      :open-collections nil :open-items nil)
  (zotxt-browser--render))

(defun zotxt-browser-edit ()
  "Show the item at point in the item pane."
  (interactive)
  (let ((object (zotxt-browser--object-at)))
    (zotxt-browser--set :item (alist-get 'key (alist-get 'data object)))
    (zotxt-browser--render 'item)
    (display-buffer zotxt-browser-item-buffer-name zotxt-browser-item-buffer-action)))

(defun zotxt-browser--open-note (object)
  "Show the note OBJECT, rendered, in the note buffer."
  (let ((html (or (alist-get 'note (alist-get 'data object)) "")))
    (with-current-buffer (get-buffer-create zotxt-browser-note-buffer-name)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert html)
        (shr-render-region (point-min) (point-max))
        (goto-char (point-min)))
      (special-mode))
    (display-buffer zotxt-browser-note-buffer-name zotxt-browser-note-buffer-action)))

(defun zotxt-browser--attachment (object)
  "Return the `zotxt-altero' plist for the attachment OBJECT."
  (zotxt-altero--attachment
   object (zotxt-browser--object (alist-get 'parentItem (alist-get 'data object)))))

(defun zotxt-browser--open-object (object)
  "Open OBJECT: its file if an attachment, its text if a note.
For any other item, open its first attachment."
  (let ((data (alist-get 'data object)))
    (pcase (alist-get 'itemType data)
      ("note" (zotxt-browser--open-note object))
      ("attachment"
       (if (member (alist-get 'linkMode data) '("linked_url"))
           (browse-url (alist-get 'url data))
         (zotxt-altero-open (zotxt-browser--attachment object))))
      (_ (let ((attachments (seq-filter
                             (lambda (child)
                               (equal (alist-get 'itemType (alist-get 'data child))
                                      "attachment"))
                             (zotxt-browser--children (alist-get 'key data)))))
           (pcase attachments
             ('() (user-error "No attachments for this item"))
             (`(,one) (zotxt-browser--open-object one))
             (_ (zotxt-altero-open
                 (zotxt-altero-read-attachment
                  "Attachment: " (mapcar #'zotxt-browser--attachment attachments))))))))))

(defun zotxt-browser-open ()
  "Open the item at point: an attachment's file, a note, or show an item."
  (interactive)
  (let* ((object (zotxt-browser--object-at))
         (type (alist-get 'itemType (alist-get 'data object))))
    (if (member type '("attachment" "note"))
        (zotxt-browser--open-object object)
      (zotxt-browser-edit))))

(defun zotxt-browser-open-attachment ()
  "Open the attachment of the item at point, or the attachment at point."
  (interactive)
  (zotxt-browser--open-object (zotxt-browser--object-at)))

(defun zotxt-browser--select (key)
  "Select the item with KEY in Zotero."
  (zotxt-select-key (concat "1_" key)))

(defun zotxt-browser-select-in-zotero ()
  "Select the item at point in Zotero."
  (interactive)
  (zotxt-browser--select (alist-get 'key (alist-get 'data (zotxt-browser--object-at)))))

(defun zotxt-browser--top (object)
  "Return OBJECT's parent item, or OBJECT if it has none."
  (or (zotxt-browser--object (alist-get 'parentItem (alist-get 'data object))) object))

(defun zotxt-browser--copy-link (object)
  "Copy an Org link to the item OBJECT belongs to."
  (require 'org-zotxt)
  (let* ((top (zotxt-browser--top object))
         (link (org-link-make-string
                (format "zotero://select/items/1_%s" (alist-get 'key (alist-get 'data top)))
                (or (zotxt-browser--field top :title) ""))))
    (kill-new link)
    (message "Copied %s" link)))

(defun zotxt-browser-copy-link ()
  "Copy an Org link to the item at point."
  (interactive)
  (zotxt-browser--copy-link (zotxt-browser--object-at)))

(defun zotxt-browser-copy-citekey ()
  "Copy the citekey of the item at point, with its @."
  (interactive)
  (let* ((top (zotxt-browser--top (zotxt-browser--object-at)))
         (item (deferred:sync!
                (zotxt-get-item-deferred
                 (list :key (concat "1_" (alist-get 'key (alist-get 'data top))))
                 :citekey)))
         (citekey (concat "@" (plist-get item :citekey))))
    (kill-new citekey)
    (message "Copied %s" citekey)))

(defun zotxt-browser-toggle ()
  "Fold or unfold the item or collection at point."
  (interactive)
  (let ((key (zotxt-browser--key-at)))
    (pcase major-mode
      ('zotxt-browser-collections-mode
       (when (and (stringp key) (zotxt-browser--collection-children key))
         (zotxt-browser--toggle-member :open-collections key)
         (zotxt-browser--render 'collections)))
      ('zotxt-browser-items-mode
       (let* ((object (zotxt-browser--object-at))
              (top (alist-get 'key (alist-get 'data (zotxt-browser--top object)))))
         (when (zotxt-browser--children top)
           (zotxt-browser--toggle-member :open-items top)
           (zotxt-browser--render 'items)
           (zotxt-browser--goto top)))))))

(defun zotxt-browser--goto (key)
  "Move point to the row of KEY, if it is shown."
  (let ((pos (point-min)) found)
    (while (and (not found) (< pos (point-max)))
      (if (equal (vui-key-at pos) key)
          (setq found pos)
        (setq pos (or (next-single-property-change pos 'vui-key) (point-max)))))
    (when found (goto-char found) (beginning-of-line))))

(defun zotxt-browser-expand-all ()
  "Unfold every item or collection."
  (interactive)
  (pcase major-mode
    ('zotxt-browser-collections-mode
     (zotxt-browser--set :open-collections
                         (mapcar (lambda (c) (alist-get 'key c))
                                 (plist-get (zotxt-browser--data) :collections)))
     (zotxt-browser--render 'collections))
    (_
     (zotxt-browser--set :open-items
                         (mapcar (lambda (o) (alist-get 'key (alist-get 'data o)))
                                 (zotxt-browser--top-items)))
     (zotxt-browser--render 'items))))

(defun zotxt-browser-collapse-all ()
  "Fold every item or collection."
  (interactive)
  (pcase major-mode
    ('zotxt-browser-collections-mode
     (zotxt-browser--set :open-collections nil)
     (zotxt-browser--render 'collections))
    (_ (zotxt-browser--set :open-items nil)
       (zotxt-browser--render 'items))))

(defun zotxt-browser-cycle ()
  "Unfold every item if none is unfolded, else fold them all."
  (interactive)
  (if (if (derived-mode-p 'zotxt-browser-collections-mode)
          (zotxt-browser--get :open-collections)
        (zotxt-browser--get :open-items))
      (zotxt-browser-collapse-all)
    (zotxt-browser-expand-all)))

(defun zotxt-browser--row-p ()
  "Non-nil if the line at point is a row with a key."
  (save-excursion (end-of-line) (vui-key-at)))

(defun zotxt-browser-next (arg)
  "Move to the next row; with ARG, that many."
  (interactive "p")
  (dotimes (_ (abs arg))
    (forward-line (if (< arg 0) -1 1))
    (while (and (not (zotxt-browser--row-p)) (not (bobp)) (not (eobp)))
      (forward-line (if (< arg 0) -1 1))))
  (when (and (derived-mode-p 'zotxt-browser-items-mode)
             (get-buffer-window zotxt-browser-item-buffer-name)
             (stringp (zotxt-browser--key-at)))
    (zotxt-browser--set :item (zotxt-browser--key-at))
    (zotxt-browser--render 'item)))

(defun zotxt-browser-prev (arg)
  "Move to the previous row; with ARG, that many."
  (interactive "p")
  (zotxt-browser-next (- arg)))

(defun zotxt-browser--level ()
  "Return the level of the row at point: 0 for an item, 1 for a child."
  (let ((object (ignore-errors (zotxt-browser--object-at))))
    (if (and object (alist-get 'parentItem (alist-get 'data object))) 1 0)))

(defun zotxt-browser-forward-same-level (arg)
  "Move to the next row at the same level; with ARG, that many."
  (interactive "p")
  (let ((level (zotxt-browser--level)) (step (if (< arg 0) -1 1)))
    (dotimes (_ (abs arg))
      (forward-line step)
      (while (and (not (bobp)) (not (eobp))
                  (or (not (zotxt-browser--row-p))
                      (/= (zotxt-browser--level) level)))
        (forward-line step)))))

(defun zotxt-browser-backward-same-level (arg)
  "Move to the previous row at the same level; with ARG, that many."
  (interactive "p")
  (zotxt-browser-forward-same-level (- arg)))

(defun zotxt-browser-up ()
  "Move to the parent of the row at point."
  (interactive)
  (pcase major-mode
    ('zotxt-browser-items-mode
     (when-let* ((parent (alist-get 'parentItem (alist-get 'data (zotxt-browser--object-at)))))
       (zotxt-browser--goto parent)))
    ('zotxt-browser-collections-mode
     (when-let* ((key (zotxt-browser--key-at))
                 ((stringp key))
                 (c (seq-find (lambda (c) (equal (alist-get 'key c) key))
                              (plist-get (zotxt-browser--data) :collections)))
                 (parent (alist-get 'parentCollection (alist-get 'data c))))
       (zotxt-browser--goto parent)))))

(defun zotxt-browser--visible-collections ()
  "Return the collection keys in the order the collections pane shows them."
  (let (keys)
    (cl-labels ((walk (parent)
                  (dolist (c (zotxt-browser--collection-children parent))
                    (let ((key (alist-get 'key c)))
                      (push key keys)
                      (when (member key (zotxt-browser--get :open-collections))
                        (walk key))))))
      (walk nil))
    (append (nreverse keys) '(unfiled trash))))

(defun zotxt-browser-next-collection (arg)
  "Show the next collection; with ARG, move that many."
  (interactive "p")
  (let* ((keys (zotxt-browser--visible-collections))
         (here (or (cl-position (zotxt-browser--get :collection) keys :test #'equal) -1))
         (there (max 0 (min (1- (length keys)) (+ here arg)))))
    (zotxt-browser--set :collection (nth there keys))
    (zotxt-browser--render 'collections 'items)))

(defun zotxt-browser-prev-collection (arg)
  "Show the previous collection; with ARG, move that many."
  (interactive "p")
  (zotxt-browser-next-collection (- arg)))

(defun zotxt-browser-up-collection ()
  "Show the collection above the one shown, or every item."
  (interactive)
  (let* ((key (zotxt-browser--get :collection))
         (c (and (stringp key)
                 (seq-find (lambda (c) (equal (alist-get 'key c) key))
                           (plist-get (zotxt-browser--data) :collections)))))
    (zotxt-browser--set :collection (and c (alist-get 'parentCollection (alist-get 'data c))))
    (zotxt-browser--render 'collections 'items)))

(defun zotxt-browser-all-items ()
  "Show every item of the library."
  (interactive)
  (zotxt-browser--set :collection nil)
  (zotxt-browser--render 'collections 'items))

(defun zotxt-browser-unfiled-items ()
  "Show the items in no collection."
  (interactive)
  (zotxt-browser--set :collection 'unfiled)
  (zotxt-browser--render 'collections 'items))

(defun zotxt-browser-trash-items ()
  "Show the items in the bin."
  (interactive)
  (zotxt-browser--set :collection 'trash)
  (zotxt-browser--render 'collections 'items))

(defun zotxt-browser-sort (field &optional reverse)
  "Sort the items by FIELD, reversed when REVERSE is non-nil.
Interactively, prompt for one of the columns; sorting again by the
field already in use reverses the order."
  (interactive
   (list (intern (completing-read
                  "Sort by: "
                  (mapcar (lambda (c) (substring (symbol-name (car c)) 1))
                          zotxt-browser-item-columns)
                  nil t nil nil
                  (substring (symbol-name (car (or (zotxt-browser--get :sort)
                                                   zotxt-browser-items-sort-field)))
                             1)))))
  (when (and (symbolp field) (not (keywordp field)))
    (setq field (intern (concat ":" (symbol-name field)))))
  (let ((current (or (zotxt-browser--get :sort) zotxt-browser-items-sort-field)))
    (zotxt-browser--set :sort (cons field (if (eq field (car current))
                                              (not (cdr current))
                                            reverse)))
    (zotxt-browser--render 'items)))

(defun zotxt-browser-filter (string)
  "Show only the items whose title, creators or year contain STRING.
An empty STRING shows them all again."
  (interactive (list (read-string "Filter items: " (zotxt-browser--get :filter))))
  (zotxt-browser--set :filter (and (not (string-empty-p string)) string))
  (zotxt-browser--render 'items))

(defun zotxt-browser-revert (&optional refresh)
  "Read the library again if it has changed, and draw it again.
With REFRESH, read it regardless."
  (interactive "P")
  (zotxt-browser--read-library (zotxt-browser--get :library) refresh)
  (zotxt-browser--render))

(defun zotxt-browser-quit ()
  "Close the browser's windows and buffers."
  (interactive)
  (dolist (name (list zotxt-browser-item-buffer-name zotxt-browser-note-buffer-name
                      zotxt-browser-libraries-buffer-name
                      zotxt-browser-collections-buffer-name
                      zotxt-browser-items-buffer-name))
    (when-let* ((buffer (get-buffer name)))
      (dolist (window (get-buffer-window-list buffer nil t))
        (if (window-parameter window 'window-side)
            (delete-window window)
          (quit-window nil window)))
      (kill-buffer buffer))))

;;;; Entry point

;;;###autoload
(defun zotxt-browser (&optional refresh)
  "Browse the Zotero library: libraries, collections, items and the item.
Switch to the browser if it is open.  With prefix argument REFRESH,
read the library again."
  (interactive "P")
  (when (or refresh (null zotxt-browser--libraries))
    (zotxt-browser--read-libraries))
  (let ((library (or (zotxt-browser--get :library)
                     (plist-get (car zotxt-browser--libraries) :id))))
    (zotxt-browser--read-library library refresh)
    (unless (equal library (zotxt-browser--get :library))
      (zotxt-browser--set :library library :collection nil)))
  (zotxt-browser--render)
  (pop-to-buffer zotxt-browser-items-buffer-name zotxt-browser-items-buffer-action)
  (display-buffer zotxt-browser-collections-buffer-name
                  zotxt-browser-collections-buffer-action)
  (display-buffer zotxt-browser-libraries-buffer-name
                  zotxt-browser-libraries-buffer-action)
  ;; Again, now that the items window has the width the title fills.
  (zotxt-browser--render 'items))

(provide 'zotxt-browser)
;;; zotxt-browser.el ends here
