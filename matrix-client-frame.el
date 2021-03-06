;;; matrix-client-frame.el --- Matrix Client dedicated frame  -*- lexical-binding: t; -*-

;; Copyright (C) 2018  Adam Porter

;; Author: Adam Porter <adam@alphapapa.net>
;; Keywords:

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;;

;;; Code:

;;;; Requirements

(require 'cl-lib)
(require 'eieio)
(require 'subr-x)

(require 'a)
(require 'dash)
(require 'dash-functional)
(require 'frame-purpose)

;;;; Variables

(defvar matrix-client-frame nil
  "The current Matrix Client frame.
There can be only one.")

;;;; Customization

(defgroup matrix-client-frame nil
  "Matrix Client dedicated frame."
  :group 'matrix-client)

(defcustom matrix-client-frame-sort-fns
  '(matrix-client-room-buffer-priority<
    matrix-client-room-buffer-name<)
  "How to sort room buffers in the frame sidebar.
A list of functions that take two room buffers as arguments and
return non-nil if the first should be sorted before the second."
  :group 'matrix-client
  :type `(repeat (choice (const :tag "Room priority" matrix-client-room-buffer-priority<)
                         (const :tag "Room name" matrix-client-room-buffer-name<)
                         (const :tag "Most recent event in room" matrix-client-room-buffer-latest-event<)
                         (const :tag "Unseen events" matrix-client-room-buffer-unseen-events<)))
  :set (lambda (option value)
         (set-default option value)
         (when (frame-live-p matrix-client-frame)
           (set-frame-parameter matrix-client-frame 'buffer-sort-fns (reverse value)))))

(defcustom matrix-client-frame-sidebar-buffer-prefix " "
  "String prefixing buffer names in room list sidebar."
  :type 'string)

(defcustom matrix-client-frame-buffer-group-fn #'matrix-client-frame-default-buffer-groups
  "Function to group room buffers.
It should return a list of strings for each buffer, for each of
which a group will be created."
  :type 'function)

;;;; Commands
;;;###autoload

(defun matrix-client-frame (&optional side)
  "Open and return the Matrix Client frame on SIDE.
SIDE may be `left', `right', `top', or `bottom'.

Only one such frame should be open at a time.  If more than one
is, only the latest one will have its sidebar updated
automatically."
  (interactive (list (if current-prefix-arg
                         (intern (completing-read "Side: " '(left right top bottom)))
                       'right)))
  (matrix-client-connect)
  (add-hook 'matrix-after-sync-hook #'matrix-client-frame-update-sidebar)
  (setq matrix-client-frame
        (frame-purpose-make-frame
         :modes '(matrix-client-mode)
         :title "Matrix"
         :icon-type (expand-file-name "logo.png" (file-name-directory (locate-library "matrix-client-frame")))
         :sidebar side
         ;; NOTE: We reverse the buffer sort functions because that's
         ;; how it needs to work.  We could do this in
         ;; `frame-purpose-make-frame', but then it would have to
         ;; special-case this parameter, which I don't want to do
         ;; right now.
         :buffer-sort-fns (reverse matrix-client-frame-sort-fns)
         :sidebar-buffers-fn (lambda ()
                               (cl-loop for session in matrix-client-sessions
                                        append (cl-loop for room in (oref* session rooms)
                                                        collect (oref* room client-data buffer))))
         :sidebar-update-fn #'matrix-client-frame-update-sidebar
         :sidebar-auto-update nil
         :sidebar-update-on-buffer-switch t
         :sidebar-header " Rooms"
         :require-mode nil))
  (with-selected-frame matrix-client-frame
    ;; Set sidebar keymap.
    (with-current-buffer (frame-purpose--get-sidebar)
      ;; HACK: Either elegant or a hack, to just copy the local map like this.  Should probably define one.
      (let ((map (copy-keymap (current-local-map))))
        (define-key map [mouse-2] #'matrix-client-frame-sidebar-open-room-frame-mouse)
        (define-key map (kbd "<C-return>") #'matrix-client-frame-sidebar-open-room-frame)
        (use-local-map map)))
    (matrix-client-switch-to-notifications-buffer))
  ;; Be sure to return the frame.
  matrix-client-frame)

(defun matrix-client-frame-sidebar-open-room-frame ()
  "Open a new frame showing room at point.
Should be called in the frame sidebar buffer."
  (interactive)
  (when-let* ((buffer (get-text-property (1+ (line-beginning-position)) 'buffer))
              (frame (make-frame
                      (a-list 'name (buffer-name buffer)
                              ;; MAYBE: Save room avatar to a temp file, pass to `icon-type'.
                              'icon-type (expand-file-name "logo.png"
                                                           (file-name-directory (locate-library "matrix-client-frame")))))))
    (with-selected-frame frame
      (switch-to-buffer buffer))))

(defun matrix-client-frame-sidebar-open-room-frame-mouse (click)
  "Move point to CLICK's position and call `matrix-client-frame-sidebar-open-room-frame'."
  (interactive "e")
  (mouse-set-point click)
  (matrix-client-frame-sidebar-open-room-frame))

;;;; Functions

;;;;; Sidebar

(defun matrix-client-frame-update-sidebar (&rest _ignore)
  "Update the buffer list sidebar when the `matrix-client-frame' is active.
Should be called manually, e.g. in `matrix-after-sync-hook', by
`frame-purpose--sidebar-switch-to-buffer', etc."
  (when (frame-live-p matrix-client-frame)
    (with-selected-frame matrix-client-frame
      ;; Copied from `frame-purpose--update-sidebar' to add grouping.
      (with-current-buffer (frame-purpose--get-sidebar 'create)
        (let* ((saved-point (point))
               (inhibit-read-only t)
               (buffer-sort-fns (frame-parameter nil 'buffer-sort-fns))
               ;; FIXME: This works fine but is a little messy.
               (buffers (funcall (frame-parameter nil 'sidebar-buffers-fn)))
               (sorted-buffers (dolist (fn buffer-sort-fns buffers)
                                 (setq buffers (-sort fn buffers))))
               (buffer-groups (matrix-client-frame-group-buffers sorted-buffers))
               (standard-groups (cl-loop for header in '("Favorites" "People")
                                         collect (cons header (alist-get header buffer-groups nil nil #'string=))))
               (low-priority-group (cons "Low priority" (alist-get "Low priority" buffer-groups nil nil #'string=)))
               (other-groups (seq-difference buffer-groups (-flatten-n 1 (list standard-groups (list low-priority-group)))
                                             (lambda (a b)
                                               (string= (car a) (car b)))))
               ;; FIXME: Make group order configurable.
               (separator (pcase (frame-parameter nil 'sidebar)
                            ((or 'left 'right) "\n")
                            ((or 'top 'bottom) "  "))))
          (setf buffer-groups (-flatten-n 1 (list standard-groups
                                                  other-groups
                                                  (list low-priority-group))))
          (erase-buffer)
          (--each buffer-groups
            (-let* (((header . buffers) it))
              (insert (propertize (concat " " header "\n")
                                  'face 'matrix-client-date-header))
              (cl-loop for buffer in buffers
                       for buffer-string = (frame-purpose--format-buffer buffer)
                       for properties = (matrix-client--plist-delete (matrix-client--string-properties buffer-string)
                                                                     'display)
                       for string = (concat matrix-client-frame-sidebar-buffer-prefix
                                            buffer-string
                                            separator)
                       ;; Apply all the properties to the entire string, including the separator,
                       ;; so the face will apply all the way to the newline, and getting the
                       ;; `buffer' property will be less error-prone.
                       do (insert (apply #'propertize string 'buffer buffer properties)))
              (insert "\n")))
          ;; FIXME: Is there a reason I didn't use `save-excursion' here?
          (goto-char saved-point))))))

(defun matrix-client-frame-group-buffers (buffers)
  "Return BUFFERS grouped."
  (let* ((grouped (-group-by #'matrix-client-frame-default-buffer-groups buffers))
         (actual-group-headers (-uniq (-flatten (-map #'car grouped)))))
    (cl-loop for header in actual-group-headers
             collect (cons header (-flatten
                                   (-map #'cdr
                                         (--select (member header (car it))
                                                   grouped)))))))

(defun matrix-client-frame-default-buffer-groups (buffer)
  "Return BUFFER's group headers."
  (let* ((room (buffer-local-value 'matrix-client-room buffer)))
    (with-slots (id tags session) room
      (let* ((user-tags (cl-loop for (tag . attrs) in tags
                                 for tag-name = (symbol-name tag)
                                 when (string-prefix-p "u." tag-name)
                                 collect (substring tag-name 2)))
             ;; User-tagged rooms can also appear in "Favorites", but not in "Low priority" or "People".
             (default-groups (if (assq 'm.favourite tags)
                                 "Favorites"
                               (unless user-tags
                                 (cond ((assq 'm.lowpriority tags) "Low priority")
                                       ;; We'll imitate Riot by not allowing a room to be both
                                       ;; favorite/low-priority AND "people".
                                       ((matrix-room-direct-p id session) "People"))))))
        (if (or default-groups user-tags)
            (-non-nil (-flatten (list default-groups user-tags)))
          '("Rooms"))))))

;;;;; Comparators

(defun matrix-client-room-buffer-priority< (buffer-a buffer-b)
  "Return non-nil if BUFFER-A's room is a higher priority than BUFFER-B's."
  (cl-macrolet ((room-buffer-tag-p
                 (tag buffer)
                 `(with-slots (tags) (buffer-local-value 'matrix-client-room ,buffer)
                    (assq ,tag tags))))
    (or (and (room-buffer-tag-p 'm.favourite buffer-a)
             (not (room-buffer-tag-p 'm.favourite buffer-b)))
        (and (not (room-buffer-tag-p 'm.lowpriority buffer-a))
             (room-buffer-tag-p 'm.lowpriority buffer-b)))))

(defun matrix-client-room-buffer-name< (buffer-a buffer-b)
  "Return non-nil if BUFFER-A's room name is `string<' than BUFFER-B's."
  (string-collate-lessp (buffer-name buffer-a)
                        (buffer-name buffer-b)))

(defun matrix-client-room-buffer-latest-event< (buffer-a buffer-b)
  "Return non-nil if BUFFER-A's room's latest event is more recent than BUFFER-B's."
  (> (matrix-client-buffer-latest-event-ts buffer-a)
     (matrix-client-buffer-latest-event-ts buffer-b)))

(defun matrix-client-room-buffer-unseen-events< (buffer-a buffer-b)
  "Return non-nil if BUFFER-A's room is modified but not BUFFER-B's."
  (and (buffer-modified-p buffer-a)
       (not (buffer-modified-p buffer-b))))

;;;;; Utility

;; NOTE: Leaving these functions here for now since they're only used here.

(defun matrix-client-buffer-latest-event-ts (buffer)
  "Return timestamp of latest event in BUFFER's room."
  (when-let* ((room (buffer-local-value 'matrix-client-room buffer))
              (last-event (car (oref* room timeline))))
    (a-get* last-event 'origin_server_ts)))

(defun matrix-client--string-properties (s)
  "Return plist of all properties and values in string S."
  (cl-loop with pos = 0
           append (text-properties-at pos s)
           do (setf pos (next-property-change pos s))
           while pos))

(defun matrix-client--plist-delete (plist property)
  "Return PLIST without PROPERTY."
  (cl-loop for (p v) on plist by #'cddr
           unless (equal property p)
           append (list p v)))

(provide 'matrix-client-frame)

;;; matrix-client-frame.el ends here
