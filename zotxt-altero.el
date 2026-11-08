;;; zotxt-altero.el --- Consult menu of Zotero attachments, local or on altero  -*- lexical-binding: t -*-

;; Copyright (C) 2026 Jacob Walchuk

;; Author: Jacob Walchuk <git@7800.io>
;; URL: https://gitlab.7800.io/7800uk/zotxt
;; Keywords: bib
;; Version: 6.1.0
;; Package-Requires: ((emacs "29.1") (zotxt "6.1.0") (consult "1.0"))

;; This file is not part of GNU Emacs.

;; zotxt-altero.el is free software: you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.

;; zotxt-altero.el is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with zotxt-altero.el.  If not, see
;; <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Two things kept apart from zotxt's own files:
;;
;; `zotxt-consult-attachment' is a consult menu of every attachment in
;; the Zotero library, by title, with creator, year and file name
;; alongside, narrowed by type with p (PDF), e (EPUB), w (web page)
;; and o (other).  `zotxt-consult-noter' uses the same menu to choose
;; the document for an org-noter session at the heading at point.
;;
;; Both read the library from the running Zotero's local API, which
;; Zotero 7 and later serve next to zotxt's own endpoints (Settings ->
;; Advanced -> "Allow other applications on this computer to
;; communicate with Zotero").
;;
;; `zotxt-altero-mode' makes every attachment open from an altero
;; server instead of from the local Zotero storage.  altero
;; (https://github.com/eseifert/altero) is a self-hosted Zotero sync
;; server that keeps each file under its MD5 digest,
;; STORAGE/<md5[:2]>/<md5>, which is the same digest Zotero records for
;; the attachment.  So with `zotxt-altero-storage-directory' set to a
;; TRAMP name for that directory, an attachment can be opened from the
;; server without being downloaded by Zotero first.  The mode covers
;; the commands here, `org-zotxt-open-attachment' and `org-zotxt-noter'.
;;
;; Documents are handed to EμReader under their real file name when it
;; is installed, since the server's names have no extension; anything
;; else is copied over TRAMP into `zotxt-altero-cache-directory' first.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'auth-source)
(require 'url)
(require 'url-http)
(require 'consult)
(require 'zotxt)

(declare-function emureader-open-doc "emureader" (document &optional name))
(declare-function org-noter "org-noter" (&optional arg))
(declare-function org-zotxt-extract-link-id-at-point "org-zotxt" ())
(declare-function org-zotxt-make-item-link "org-zotxt" (item))
(declare-function org-entry-put "org" (pom property value))
(declare-function org-before-first-heading-p "org" ())
(declare-function org-entry-get "org" (pom property &optional inherit literal-nil))
(defvar emureader-supported-formats)
(defvar org-noter-property-doc-file)
(defvar org-zotxt-noter-zotero-link)
(defvar org-zotxt-link-description-style)
(defvar url-http-end-of-headers)
(defvar url-http-response-status)
(defvar zotxt-altero-mode)

(defgroup zotxt-altero nil
  "Zotero attachments through consult, opened locally or from altero."
  :group 'zotxt
  :prefix "zotxt-altero-")

(defcustom zotxt-altero-api-url "http://127.0.0.1:23119/api/users/0/"
  "Base URL of the Zotero Web API to read the library from.
The default is the local API of the running Zotero, whose user
library is user 0.  It can instead be the server's own API, as in
\"https://altero.example/users/12345/\", which knows the digest of
every file whether Zotero has downloaded it or not.  A server other
than this machine is sent the API key that `auth-source' has for its
host, as in the ~/.authinfo line
  machine altero.example login 12345 password KEY"
  :type 'string)

(defcustom zotxt-altero-storage-directory nil
  "Directory holding an altero server's attachment files, as a TRAMP name.
For example \"/ssh:host:/var/lib/altero/storage/\".  It must end in a
slash.  `zotxt-altero-mode' opens attachments from here."
  :type '(choice (const :tag "Not set" nil) directory))

(defcustom zotxt-altero-cache-directory
  (expand-file-name "zotxt-altero/" user-emacs-directory)
  "Directory for copies of attachments fetched from the altero server.
Used for the formats EμReader does not show, and for web snapshots,
which altero keeps zipped."
  :type 'directory)

(defcustom zotxt-altero-narrow
  '((?p . "PDF") (?e . "EPUB") (?w . "Web page") (?o . "Other"))
  "Narrowing keys of `zotxt-consult-attachment' and the groups they name."
  :type '(alist :key-type character :value-type string))

(defface zotxt-altero-creator '((t :inherit font-lock-variable-name-face))
  "Face for the creators in the attachment menu.")

(defface zotxt-altero-year '((t :inherit font-lock-constant-face))
  "Face for the year in the attachment menu.")

(defface zotxt-altero-file '((t :inherit completions-annotations))
  "Face for the file name in the attachment menu.")

(defvar zotxt-altero-history nil
  "History of `zotxt-consult-attachment'.")

;;;; The library, from the Web API

(defun zotxt-altero--api-key ()
  "Return the API key for `zotxt-altero-api-url', or nil.
The local API needs none, so it is only looked up for another host."
  (let ((host (url-host (url-generic-parse-url zotxt-altero-api-url))))
    (unless (member host '("127.0.0.1" "localhost" "::1"))
      (when-let* ((found (car (auth-source-search :host host :max 1)))
                  (secret (plist-get found :secret)))
        (if (functionp secret) (funcall secret) secret)))))

(defun zotxt-altero--request (path &optional params)
  "GET PATH, relative to `zotxt-altero-api-url', with query PARAMS.
Return a cons of the parsed JSON body and an alist of the response
headers, with lower-case names."
  (let* ((url-request-extra-headers
          `(("Zotero-API-Version" . "3")
            ,@(when-let* ((key (zotxt-altero--api-key)))
                `(("Zotero-API-Key" . ,key)))))
         (query (and params (url-build-query-string params)))
         (url (concat zotxt-altero-api-url path (and query (concat "?" query))))
         (buffer (condition-case err
                     (url-retrieve-synchronously url t t 30)
                   (file-error
                    (user-error "Cannot reach Zotero at %s: %s"
                                zotxt-altero-api-url (error-message-string err))))))
    (unless buffer
      (user-error "No answer from Zotero at %s" zotxt-altero-api-url))
    (unwind-protect
        (with-current-buffer buffer
          (unless (eq url-http-response-status 200)
            (user-error "Zotero answered %s for %s%s" url-http-response-status path
                        (if (eq url-http-response-status 403)
                            " (is its local API turned on?)" "")))
          (let (headers)
            (goto-char (point-min))
            (while (re-search-forward "^\\([^:\n]+\\): \\(.*?\\)\r?$"
                                      url-http-end-of-headers t)
              (push (cons (downcase (match-string 1)) (match-string 2)) headers))
            (goto-char url-http-end-of-headers)
            (cons (json-parse-buffer :object-type 'alist :array-type 'list
                                     :null-object nil :false-object nil)
                  headers)))
      (kill-buffer buffer))))

(defun zotxt-altero--request-all (path &optional params)
  "Return every object at PATH with PARAMS, following the API's pages."
  (let ((start 0) total objects)
    (while (or (null total) (< start total))
      (pcase-let ((`(,page . ,headers)
                   (zotxt-altero--request
                    path (append `(("limit" "100") ("start" ,(number-to-string start)))
                                 params))))
        (setq total (string-to-number (or (cdr (assoc "total-results" headers)) "0"))
              objects (nconc objects page)
              start (+ start 100))
        (when (null page) (setq total 0))))
    objects))

(defun zotxt-altero--library-version ()
  "Return the version of the library, as the API reports it."
  (cdr (assoc "last-modified-version"
              (cdr (zotxt-altero--request "items" '(("limit" "1")
                                                    ("format" "versions")))))))

(defvar zotxt-altero--cache nil
  "The attachments last read, as a cons of library version and list.")

(defun zotxt-altero--year (meta)
  "Return the year in the item META's parsed date, or nil."
  (when-let* ((date (alist-get 'parsedDate meta)))
    (substring date 0 (min 4 (length date)))))

(defun zotxt-altero--attachment (object parent)
  "Return a plist describing the attachment OBJECT, a child of PARENT.
PARENT is nil for a standalone attachment."
  (let* ((data (alist-get 'data object))
         (owner (or parent object))
         (href (alist-get 'href (alist-get 'enclosure (alist-get 'links object)))))
    (list :key (alist-get 'key data)
          :parent (alist-get 'key (alist-get 'data owner))
          :title (or (alist-get 'title (alist-get 'data owner)) "")
          :creators (alist-get 'creatorSummary (alist-get 'meta owner))
          :year (zotxt-altero--year (alist-get 'meta owner))
          :filename (or (alist-get 'filename data) (alist-get 'title data))
          :md5 (alist-get 'md5 data)
          :content-type (alist-get 'contentType data)
          :link-mode (alist-get 'linkMode data)
          :local (cond
                  ((and href (string-prefix-p "file://" href))
                   (url-unhex-string (url-filename (url-generic-parse-url href))))
                  ((equal (alist-get 'linkMode data) "linked_file")
                   (alist-get 'path data))))))

(defun zotxt-altero--read-attachments ()
  "Read every attachment with a file in the library."
  (let ((parents (make-hash-table :test #'equal)))
    (dolist (item (zotxt-altero--request-all "items/top"))
      (puthash (alist-get 'key item) item parents))
    (cl-loop for object in (zotxt-altero--request-all
                            "items" '(("itemType" "attachment")))
             for data = (alist-get 'data object)
             unless (equal (alist-get 'linkMode data) "linked_url")
             collect (zotxt-altero--attachment
                      object (gethash (alist-get 'parentItem data) parents)))))

(defun zotxt-altero-attachments (&optional refresh)
  "Return the attachments of the library, read again if it has changed.
With REFRESH non-nil, read them again regardless."
  (let ((version (zotxt-altero--library-version)))
    (unless (and (not refresh) zotxt-altero--cache
                 (equal version (car zotxt-altero--cache)))
      (setq zotxt-altero--cache (cons version (zotxt-altero--read-attachments))))
    (cdr zotxt-altero--cache)))

(defun zotxt-altero--item-attachments (key)
  "Return the attachments of the item with KEY, or the item if it is one."
  (or (cl-remove-if-not (lambda (a) (equal (plist-get a :key) key))
                        (zotxt-altero-attachments))
      (cl-remove-if-not (lambda (a) (equal (plist-get a :parent) key))
                        (zotxt-altero-attachments))))

;;;; Opening

(defun zotxt-altero--remote-file (attachment)
  "Return the name of ATTACHMENT's file on the altero server."
  (unless zotxt-altero-storage-directory
    (user-error "Set `zotxt-altero-storage-directory' first"))
  (let ((md5 (plist-get attachment :md5)))
    (unless md5
      (user-error "%s has no file on the server" (plist-get attachment :filename)))
    (concat (file-name-as-directory zotxt-altero-storage-directory)
            (substring md5 0 2) "/" md5)))

(defun zotxt-altero-attachment-file (attachment)
  "Return the file to open for ATTACHMENT.
In `zotxt-altero-mode', its file on the altero server; otherwise its
file in the local Zotero storage.  A linked file is always local,
since Zotero does not sync it."
  (if (and zotxt-altero-mode
           (not (equal (plist-get attachment :link-mode) "linked_file")))
      (zotxt-altero--remote-file attachment)
    (let ((file (plist-get attachment :local)))
      (unless (and file (file-exists-p file))
        (user-error "%s is not in the local storage%s"
                    (plist-get attachment :filename)
                    (if zotxt-altero-storage-directory
                        "; `zotxt-altero-mode' opens it from the server" "")))
      file)))

(defun zotxt-altero--emureader-p (name)
  "Non-nil if EμReader is installed and shows files named NAME."
  (and (fboundp 'emureader-open-doc)
       (require 'emureader nil t)
       (member (downcase (or (file-name-extension name) ""))
               emureader-supported-formats)))

(defun zotxt-altero--file-md5 (file)
  "Return the MD5 digest of the local FILE."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (secure-hash 'md5 (current-buffer))))

(defun zotxt-altero--zip-p (file)
  "Non-nil if the local FILE starts like a ZIP archive."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file nil 0 4)
    (equal (buffer-string) "PK\3\4")))

(defun zotxt-altero-fetch (attachment)
  "Copy ATTACHMENT's file from the altero server and return the copy.
The copy is kept in `zotxt-altero-cache-directory' under its own
name, and reused while its digest matches.  A web snapshot, which
Zotero uploads zipped, is unpacked there."
  (let* ((md5 (plist-get attachment :md5))
         (dir (file-name-as-directory
               (expand-file-name md5 zotxt-altero-cache-directory)))
         (name (plist-get attachment :filename))
         (copy (expand-file-name name dir)))
    (unless (and (file-exists-p copy) (equal (zotxt-altero--file-md5 copy) md5))
      (make-directory dir t)
      (let ((archive (expand-file-name ".download" dir)))
        (copy-file (zotxt-altero--remote-file attachment) archive t)
        (if (and (zotxt-altero--zip-p archive)
                 (not (equal (zotxt-altero--file-md5 archive) md5)))
            ;; The digest is the file's, not the archive's: a wrapper.
            (unwind-protect
                (unless (zerop (call-process "unzip" nil nil nil "-o" "-qq"
                                             archive "-d" dir))
                  (error "Could not unpack %s" name))
              (delete-file archive))
          (rename-file archive copy t))))
    copy))

(defun zotxt-altero--open-local (file)
  "Open the local FILE: in a browser if it is a web page, else visit it."
  (if (string-match-p "\\.x?html?\\'" file)
      (browse-url-of-file file)
    (find-file file)))

(defun zotxt-altero-open (attachment)
  "Open ATTACHMENT, from the altero server in `zotxt-altero-mode'."
  (let ((file (zotxt-altero-attachment-file attachment))
        (name (plist-get attachment :filename)))
    (cond
     ((not (file-remote-p file)) (zotxt-altero--open-local file))
     ((zotxt-altero--emureader-p name) (emureader-open-doc file name))
     (t (zotxt-altero--open-local (zotxt-altero-fetch attachment))))))

;;;; The menu

(defun zotxt-altero--type (attachment)
  "Return the narrowing key of ATTACHMENT's type."
  (let ((type (or (plist-get attachment :content-type) "")))
    (cond ((equal type "application/pdf") ?p)
          ((equal type "application/epub+zip") ?e)
          ((string-prefix-p "text/html" type) ?w)
          (t ?o))))

(defun zotxt-altero--candidates (attachments)
  "Return menu candidates for ATTACHMENTS, each unique."
  (let ((seen (make-hash-table :test #'equal)))
    (mapcar
     (lambda (attachment)
       (let* ((title (plist-get attachment :title))
              (title (if (string-empty-p title) (plist-get attachment :filename) title))
              (count (cl-incf (gethash title seen 0)))
              (cand (if (= count 1) title
                      (format "%s %s" title (propertize (format "(%d)" count)
                                                        'face 'shadow)))))
         (propertize cand 'zotxt-altero-attachment attachment
                     'consult--type (zotxt-altero--type attachment))))
     attachments)))

(defun zotxt-altero--annotate (cand)
  "Annotate CAND with its creators, year and file name."
  (let ((attachment (get-text-property 0 'zotxt-altero-attachment cand)))
    (concat
     (propertize " " 'display '(space :align-to (- right 80)))
     (propertize (truncate-string-to-width
                  (or (plist-get attachment :creators) "") 28 nil ?\s "…")
                 'face 'zotxt-altero-creator)
     "  "
     (propertize (string-pad (or (plist-get attachment :year) "") 4)
                 'face 'zotxt-altero-year)
     "  "
     (propertize (truncate-string-to-width
                  (or (plist-get attachment :filename) "") 44 nil nil "…")
                 'face 'zotxt-altero-file))))

(defun zotxt-altero-read-attachment (&optional prompt attachments)
  "Choose an attachment with consult, prompting with PROMPT.
ATTACHMENTS defaults to every attachment in the library."
  (let ((cand (consult--read
               (zotxt-altero--candidates (or attachments (zotxt-altero-attachments)))
               :prompt (or prompt (if zotxt-altero-mode
                                      "Attachment (altero): "
                                    "Attachment: "))
               :category 'zotxt-attachment
               :require-match t
               :sort nil
               :history 'zotxt-altero-history
               :lookup #'consult--lookup-member
               :annotate #'zotxt-altero--annotate
               :group (consult--type-group zotxt-altero-narrow)
               :narrow (consult--type-narrow zotxt-altero-narrow))))
    (get-text-property 0 'zotxt-altero-attachment cand)))

;;;###autoload
(defun zotxt-consult-attachment (&optional refresh)
  "Choose an attachment from the Zotero library and open it.
In `zotxt-altero-mode' it opens from the altero server.  With prefix
argument REFRESH, read the library again even if it has not changed."
  (interactive "P")
  (when refresh (setq zotxt-altero--cache nil))
  (zotxt-altero-open (zotxt-altero-read-attachment)))

(defun zotxt-altero--item-link (attachment)
  "Return an Org link to the Zotero item ATTACHMENT belongs to."
  (require 'org-zotxt)
  (let ((org-zotxt-link-description-style :title))
    (org-zotxt-make-item-link
     (list :key (concat "1_" (plist-get attachment :parent))
           :title (plist-get attachment :title)))))

;;;###autoload
(defun zotxt-consult-noter (&optional arg)
  "Take notes with org-noter on an attachment chosen from Zotero.
The heading at point gets the document and a link to its Zotero item
as properties, and an org-noter session starts on it.  In
`zotxt-altero-mode' the document is the file on the altero server.
A heading that already names a document is simply opened; ARG is
passed on to `org-noter'."
  (interactive "P")
  (require 'org-noter)
  (unless (derived-mode-p 'org-mode)
    (user-error "Not in an Org buffer"))
  (when (org-before-first-heading-p)
    (user-error "Use this inside a heading"))
  (unless (org-entry-get nil org-noter-property-doc-file)
    (let ((attachment (zotxt-altero-read-attachment "Take notes on: ")))
      (org-entry-put nil org-noter-property-doc-file
                     (zotxt-altero-attachment-file attachment))
      (org-entry-put nil "ZOTERO_LINK" (zotxt-altero--item-link attachment))))
  (org-noter arg))

;;;; altero mode

(defun zotxt-altero--link-key ()
  "Return the item key of the zotero: link at point, or nil."
  (when-let* ((id (org-zotxt-extract-link-id-at-point)))
    (replace-regexp-in-string "\\`[0-9]+_" "" id)))

(defun zotxt-altero--open-attachment (fn &rest args)
  "Open the attachment of the link at point from altero, or call FN with ARGS.
Advice for `org-zotxt-open-attachment' while `zotxt-altero-mode' is on."
  (if-let* ((zotxt-altero-mode)
            (key (zotxt-altero--link-key)))
      (let ((attachments (zotxt-altero--item-attachments key)))
        (zotxt-altero-open
         (pcase attachments
           ('() (user-error "No attachments for this item"))
           (`(,one) one)
           (_ (zotxt-altero-read-attachment "Attachment (altero): " attachments)))))
    (apply fn args)))

(defun zotxt-altero--storage-key (file)
  "Return the attachment key in the local Zotero storage FILE name, or nil."
  (and file
       (string-match "/storage/\\([A-Z0-9]\\{8\\}\\)/[^/]+\\'" file)
       (match-string 1 file)))

(defun zotxt-altero--choose-path (path)
  "Return the altero file for PATH, a file in the local Zotero storage.
Filter for `org-zotxt-choose-path', so that `org-zotxt-noter' takes its
document from the server while `zotxt-altero-mode' is on."
  (if-let* ((zotxt-altero-mode)
            (key (zotxt-altero--storage-key path))
            (attachment (car (zotxt-altero--item-attachments key))))
      (zotxt-altero--remote-file attachment)
    path))

;;;###autoload
(define-minor-mode zotxt-altero-mode
  "Open Zotero attachments from an altero server over TRAMP.

While this mode is on, `zotxt-consult-attachment',
`zotxt-consult-noter', `org-zotxt-open-attachment' and
`org-zotxt-noter' take attachments from
`zotxt-altero-storage-directory' rather than the local Zotero storage,
so a file Zotero has not downloaded still opens."
  :global t
  :lighter " Altero"
  :group 'zotxt-altero
  (if zotxt-altero-mode
      (progn
        (unless zotxt-altero-storage-directory
          (setq zotxt-altero-mode nil)
          (user-error "Set `zotxt-altero-storage-directory' first"))
        (advice-add 'org-zotxt-open-attachment :around
                    #'zotxt-altero--open-attachment)
        (advice-add 'org-zotxt-choose-path :filter-return
                    #'zotxt-altero--choose-path))
    (advice-remove 'org-zotxt-open-attachment #'zotxt-altero--open-attachment)
    (advice-remove 'org-zotxt-choose-path #'zotxt-altero--choose-path)))

(provide 'zotxt-altero)
;;; zotxt-altero.el ends here
