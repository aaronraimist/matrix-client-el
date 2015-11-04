;;; matrix-sauron.el --- Sauron integration for the Emacs Matrix Client

;; Copyright (C) 2015 Ryan Rix
;; Author: Ryan Rix <ryan@whatthefuck.computer>
;; Maintainer: Ryan Rix <ryan@whatthefuck.computer>
;; Created: 21 June 2015
;; Keywords: web
;; Homepage: http://doc.rix.si/matrix.html
;; Package-Version: 0.1.0

;; This file is not part of GNU Emacs.

;; matrix-sauron.el is free software: you can redistribute it and/or modify it
;; under the terms of the GNU General Public License as published by the Free
;; Software Foundation, either version 3 of the License, or (at your option) any
;; later version.
;;
;; matrix-sauron.el is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
;; FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
;; more details.
;;
;; You should have received a copy of the GNU General Public License along with
;; this file.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; This library pushes Matrix events in to Sauron, allowing you to easily see a
;; list of notifications and jump to them. See https://github.com/djcb/sauron
;; for information about Sauron.

;; To use this, install Sauron via package.el or manually, and then load or eval
;; this library. Add 'sauron-matrix to sauron-modules and run [`sauron-start']

;;; Code:

(require 'sauron nil 'noerror)

(defvar sauron-prio-matrix-new-messages 2
  "Priority for incoming Matrix events.")

(defvar sauron-matrix-running nil
  "When non-nil, matrix-sauron is running.")

(defun matrix-sauron-start ()
  "Start matrix-sauron."
  (if (and (boundp 'matrix-homeserver-base-url)
           matrix-homeserver-base-url)
      (progn
        (when sauron-matrix-running
          (error "matrix-sauron is already running. Call sauron-matrix-stop first."))
        (add-hook 'matrix-client-new-event-hook 'matrix-add-sauron-event)
        (setq sauron-matrix-running t))
    (message "matrix-client not loadable, so matrix-sauron could not start.")))

(defun matrix-sauron-stop ()
  "Stops and cleans up matrix-sauron."
  (when sauron-matrix-running
    (remove-hook 'matrix-client-new-event-hook 'matrix-add-sauron-event)
    (setq sauron-matrix-running nil)))

(defun matrix-add-sauron-event (data)
  (mapc (lambda (data)          
          (let* ((room-id (matrix-get 'room_id data))
                 (room-buf (matrix-get room-id matrix-client-active-rooms))
                 (type (matrix-get 'type data))
                 (content (matrix-get 'content data))
                 (target (if (buffer-live-p room-buf)
                             (save-excursion
                               (with-current-buffer room-buf
                                 (end-of-buffer)
                                 (previous-line)
                                 (point-marker))))))
            (when (equal type "m.room.message")
              (sauron-add-event 'matrix sauron-prio-matrix-new-messages
                                (matrix-get 'body content)
                                (lexical-let* ((target-mark target)
                                               (target-buf room-buf))
                                  (lambda ()
                                    (sauron-switch-to-marker-or-buffer (or target-mark target-buf))))))))
        (matrix-get 'chunk data)))

(provide 'matrix-sauron)

;; End of matrix-sauron.el