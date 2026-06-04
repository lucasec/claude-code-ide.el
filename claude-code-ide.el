;;; claude-code-ide.el --- Claude Code integration for Emacs  -*- lexical-binding: t; -*-

;; Copyright (C) 2025

;; Author: Yoav Orot
;; Version: 0.2.7
;; Package-Requires: ((emacs "28.1") (websocket "1.12") (transient "0.9.0") (web-server "0.1.2"))
;; Keywords: ai, claude, code, assistant, mcp, websocket
;; URL: https://github.com/manzaltu/claude-code-ide.el

;; This file is not part of GNU Emacs.

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

;; Claude Code IDE integration for Emacs provides seamless integration
;; with Claude Code CLI through the Model Context Protocol (MCP).
;; It supports file operations, diagnostics, and editor state management.
;;
;; This package starts a WebSocket server that Claude Code CLI connects to,
;; enabling real-time communication between Emacs and Claude.  It supports
;; multiple concurrent sessions per project.
;;
;; Features:
;; - Automatic IDE mode activation when starting Claude
;; - MCP WebSocket server for bidirectional communication
;; - Project-aware sessions with automatic working directory detection
;; - Clean session management with automatic cleanup on exit
;; - Selection and buffer state tracking
;; - Tool support for file operations, diagnostics, and more
;; - Emacs MCP tools for xref and project navigation
;;
;; Usage:
;; M-x claude-code-ide - Start Claude Code for current project
;; M-x claude-code-ide-continue - Continue most recent conversation in directory
;; M-x claude-code-ide-resume - Resume Claude Code with previous conversation
;; M-x claude-code-ide-stop - Stop Claude Code for current project
;; M-x claude-code-ide-switch-to-buffer - Switch to project's Claude buffer
;; M-x claude-code-ide-list-sessions - List and switch between all sessions
;; M-x claude-code-ide-check-status - Check CLI availability and version
;; M-x claude-code-ide-insert-at-mentioned - Send selected text to Claude
;;
;; Emacs MCP Tools:
;; To enable Emacs tools for Claude, add to your config:
;;   (claude-code-ide-emacs-tools-setup)

;;; Code:

(require 'cl-lib)
(require 'project)
(require 'claude-code-ide-debug)
(require 'claude-code-ide-mcp)
(require 'claude-code-ide-transient)
(require 'claude-code-ide-mcp-server)
(require 'claude-code-ide-emacs-tools)

;; External variable declarations
(defvar eat-terminal)
(defvar vterm-shell)
(defvar vterm-environment)
(defvar eat-term-name)
(defvar vterm--process)

;; External function declarations for vterm
(declare-function vterm "vterm" (&optional arg))
(declare-function vterm-send-string "vterm" (string))
(declare-function vterm-send-escape "vterm" ())
(declare-function vterm-send-return "vterm" ())
(declare-function vterm--window-adjust-process-window-size "vterm" (&optional frame))

;; External function declarations for eat
(declare-function eat-mode "eat" ())
(declare-function eat-exec "eat" (buffer name command startfile &rest switches))
(declare-function eat-term-send-string "eat" (terminal string))
(declare-function eat-term-display-cursor "eat" (terminal))
(declare-function eat--adjust-process-window-size "eat" (process windows))

;;; Customization

(defgroup claude-code-ide nil
  "Claude Code integration for Emacs."
  :group 'tools
  :prefix "claude-code-ide-")

(defcustom claude-code-ide-cli-path "claude"
  "Path to the Claude Code CLI executable."
  :type 'string
  :group 'claude-code-ide)

(defcustom claude-code-ide-buffer-name-function #'claude-code-ide--default-buffer-name
  "Function to generate buffer names for Claude Code sessions.
The function is called with one argument, the working directory,
and should return a string to use as the buffer name."
  :type 'function
  :group 'claude-code-ide)

(defcustom claude-code-ide-cli-debug nil
  "When non-nil, launch Claude Code with the -d debug flag."
  :type 'boolean
  :group 'claude-code-ide)

(defcustom claude-code-ide-cli-extra-flags ""
  "Additional flags to pass to the Claude Code CLI.
This should be a string of space-separated flags, e.g. \"--model opus\"."
  :type 'string
  :group 'claude-code-ide)

(defcustom claude-code-ide-system-prompt nil
  "System prompt to append to Claude's default system prompt.
When non-nil, the --append-system-prompt flag will be added with this value.
Set to nil to disable (default)."
  :type '(choice (const :tag "Disabled" nil)
                 (string :tag "System prompt text"))
  :group 'claude-code-ide)

(defcustom claude-code-ide-mcp-allowed-tools 'auto
  "Configuration for allowed MCP tools when MCP server is enabled.
Can be one of:
  'auto - Automatically allow all configured emacs-tools (default)
  nil - Disable the --allowedTools flag
  A string - Custom pattern/tools passed directly to --allowedTools
  A list of strings - List of specific tool names to allow"
  :type '(choice (const :tag "Auto (all emacs-tools)" auto)
                 (const :tag "Disabled" nil)
                 (string :tag "Custom pattern")
                 (repeat :tag "Specific tools" string))
  :group 'claude-code-ide)

(defcustom claude-code-ide-window-side 'right
  "Side of the frame where the Claude Code window should appear.
Can be `'left', `'right', `'top', or `'bottom'."
  :type '(choice (const :tag "Left" left)
                 (const :tag "Right" right)
                 (const :tag "Top" top)
                 (const :tag "Bottom" bottom))
  :group 'claude-code-ide)

(defcustom claude-code-ide-window-width 100
  "Body width of the Claude Code side window when opened on left or right.
This sets the usable text area width, excluding fringes and margins."
  :type 'integer
  :group 'claude-code-ide)

(defcustom claude-code-ide-window-height 20
  "Height of the Claude Code side window when opened on top or bottom."
  :type 'integer
  :group 'claude-code-ide)

(defcustom claude-code-ide-focus-on-open t
  "Whether to focus the Claude Code window when it opens."
  :type 'boolean
  :group 'claude-code-ide)

(defcustom claude-code-ide-focus-claude-after-ediff t
  "Whether to focus the Claude Code window after opening ediff.
When non-nil (default), focus returns to the Claude Code window
after opening ediff.  When nil, focus remains on the ediff control
window, allowing direct interaction with the diff controls."
  :type 'boolean
  :group 'claude-code-ide)

(defcustom claude-code-ide-show-claude-window-in-ediff t
  "Whether to show the Claude Code side window when viewing diffs.
When non-nil (default), the Claude Code side window is restored
after opening ediff.  When nil, the Claude Code window remains
hidden during diff viewing, giving you more screen space for the
diff comparison."
  :type 'boolean
  :group 'claude-code-ide)

(defcustom claude-code-ide-enable-execute-code t
  "Whether to expose the executeCode tool to the model.
When non-nil, Claude Code can evaluate Elisp expressions in Emacs
via the executeCode MCP tool.  Set to nil to hide the tool entirely."
  :type 'boolean
  :group 'claude-code-ide)

(defcustom claude-code-ide-use-ide-diff t
  "Whether to use IDE diff viewer for file differences.
When non-nil (default), Claude Code will open an IDE diff viewer
(ediff) when showing file changes.  When nil, Claude Code will
display diffs in the terminal instead."
  :type 'boolean
  :group 'claude-code-ide)

(defcustom claude-code-ide-switch-tab-on-ediff t
  "Whether to switch back to Claude's original tab when opening ediff.
When non-nil (default), Claude Code will switch back to the tab
where Claude Code was started when opening an ediff session.
When nil, the current tab remains active when ediff is opened."
  :type 'boolean
  :group 'claude-code-ide)

(defcustom claude-code-ide-use-side-window t
  "Whether to display Claude Code in a side window.
When non-nil (default), Claude Code opens in a dedicated side window
controlled by `claude-code-ide-window-side' and related settings.
When nil, Claude Code opens in a regular buffer that follows standard
display-buffer behavior."
  :type 'boolean
  :group 'claude-code-ide)

(defcustom claude-code-ide-terminal-backend 'vterm
  "Terminal backend to use for Claude Code sessions.
Can be either `vterm' or `eat'.  The vterm backend is the default
and provides a fully-featured terminal emulator.  The eat backend
is an alternative terminal emulator that may work better in some
environments."
  :type '(choice (const :tag "vterm" vterm)
                 (const :tag "eat" eat))
  :group 'claude-code-ide)

(defcustom claude-code-ide-prevent-reflow-glitch t
  "Workaround for Claude Code terminal scrolling bug #1422.
When non-nil (default), prevents the terminal from reflowing on height-only
changes which can trigger uncontrollable scrolling in Claude Code.
See: https://github.com/anthropics/claude-code/issues/1422
This setting should be removed once the upstream bug is fixed."
  :type 'boolean
  :group 'claude-code-ide)

(defcustom claude-code-ide-vterm-anti-flicker t
  "Enable intelligent flicker reduction for vterm display.
When enabled, this feature optimizes terminal rendering by detecting
and batching rapid update sequences.  This provides smoother visual
output during complex terminal operations such as expanding text areas
and rapid screen updates.

This optimization applies only to vterm and uses advanced pattern
matching to maintain responsiveness while improving visual quality."
  :type 'boolean
  :group 'claude-code-ide)

(defcustom claude-code-ide-vterm-render-delay 0.005
  "Rendering optimization delay for batched terminal updates.
This parameter defines the collection window for related terminal
update sequences when anti-flicker mode is active.  The timing
balances visual smoothness with interaction responsiveness.

The 0.005 second (5ms) default delivers optimal rendering quality
with imperceptible latency."
  :type 'number
  :group 'claude-code-ide)

(defcustom claude-code-ide-terminal-initialization-delay 0.1
  "Initialization delay for terminal stability.
Provides a brief stabilization period when launching terminals
to ensure proper layout calculation and rendering.

The delay allows terminals to complete initial dimension calculations,
preventing display artifacts like prompt misalignment and cursor
positioning errors.  The 100ms default ensures reliable initialization
without noticeable latency."
  :type 'number
  :group 'claude-code-ide)

(defcustom claude-code-ide-eat-preserve-position t
  "Attempt to preserve scroll position when Claude Code redraws.
When you re-size the terminal window (and in a few other circumstances),
Claude Code may clear and re-write the scrollback buffer. If you have
currently scrolled into the scrollback, this can cause you to lose your
position.

When non-nil (default), the current cursor position relative to the end
of the buffer is captured before and restored after the redraw. Due to
changes in extra characters Claude inserts for text wrapping, the
position restoration may not be exact."
  :type 'boolean
  :group 'claude-code-ide)

(define-obsolete-variable-alias
  'claude-code-ide-eat-initialization-delay
  'claude-code-ide-terminal-initialization-delay
  "0.2.6")

;;; Constants

(defconst claude-code-ide--active-editor-notification-delay 0.1
  "Delay in seconds before sending active editor notification after connection.")

;;; Variables

(defvar claude-code-ide--cli-available nil
  "Whether Claude Code CLI is available and detected.")

(defvar claude-code-ide--processes (make-hash-table :test 'equal)
  "Hash table mapping project/directory roots to their Claude Code processes.")

(defvar claude-code-ide--session-ids (make-hash-table :test 'equal)
  "Hash table mapping project/directory roots to their session IDs.")

(defvar claude-code-ide--last-accessed-buffer nil
  "The most recently accessed Claude Code buffer.")

;;; Vterm Rendering Optimization

(defvar-local claude-code-ide--vterm-render-queue nil
  "List of pending terminal output strings awaiting batched rendering.
Stored in reverse order for O(1) push, joined at flush time.")

(defvar-local claude-code-ide--vterm-render-timer nil
  "Timer for executing queued rendering operations.")

(defun claude-code-ide--count-escape-sequence (sequence input)
  "Count occurrences of escape SEQUENCE in INPUT.
More efficient than split-string + cl-count-if for simple counting."
  (let ((count 0) (start 0))
    (while (setq start (string-search sequence input start))
      (cl-incf count)
      (cl-incf start (length sequence)))
    count))

(defun claude-code-ide--vterm-smart-renderer (orig-fun process input)
  "Smart rendering filter for optimized vterm display updates.
This advanced filter analyzes terminal output patterns to identify
rapid update sequences that benefit from batched processing.
It significantly improves visual quality during complex operations.

ORIG-FUN is the underlying filter to enhance.
PROCESS is the terminal process being optimized.
INPUT contains the terminal output stream."
  (if (or (not claude-code-ide-vterm-anti-flicker)
          (not (claude-code-ide--session-buffer-p (process-buffer process))))
      ;; Feature disabled or not a Claude buffer, pass through normally
      (funcall orig-fun process input)
    (with-current-buffer (process-buffer process)
      ;; Fast path: plain text with no active queue skips all pattern detection
      ;; This optimizes the common case of typing in the prompt
      (if (and (not claude-code-ide--vterm-render-queue)
               (not (string-search "\033" input)))
          (funcall orig-fun process input)
        ;; Detect rapid terminal redraw sequences
        ;; Pattern analysis for complex terminal updates:
        ;; - Vertical cursor movements (ESC[<n>A)
        ;; - Line clearing operations (ESC[K)
        ;; - High escape sequence density
        (let* ((complex-redraw-detected
                ;; Pattern: vertical movement + clear, repeated
                (string-match-p "\033\\[[0-9]*A.*\033\\[K.*\033\\[[0-9]*A.*\033\\[K" input))
               (clear-count (claude-code-ide--count-escape-sequence "\033[K" input))
               (escape-count (cl-count ?\033 input))
               (input-length (length input))
               ;; High escape density indicates redrawing, not normal output
               (escape-density (if (> input-length 0)
                                   (/ (float escape-count) input-length)
                                 0)))
          ;; Optimize rendering for detected patterns:
          ;; 1. Complex redraw sequence detected, OR
          ;; 2. Escape sequence density exceeds threshold with line operations
          ;; 3. OR already queuing (to complete the sequence)
          (if (or complex-redraw-detected
                  (and (> escape-density 0.3)
                       (>= clear-count 2))
                  claude-code-ide--vterm-render-queue)
              (progn
                ;; Add to queue (list for O(1) push, joined at flush time)
                (push input claude-code-ide--vterm-render-queue)
                ;; Reset existing render timer
                (when claude-code-ide--vterm-render-timer
                  (cancel-timer claude-code-ide--vterm-render-timer))
                ;; Schedule optimized rendering
                ;; Timing calibrated for visual quality
                (setq claude-code-ide--vterm-render-timer
                      (run-at-time claude-code-ide-vterm-render-delay nil
                                   (lambda (buf)
                                     (when (buffer-live-p buf)
                                       (with-current-buffer buf
                                         (when claude-code-ide--vterm-render-queue
                                           (let* ((inhibit-redisplay t)
                                                  (queue claude-code-ide--vterm-render-queue)
                                                  ;; Join list in correct order
                                                  (data (apply #'concat (nreverse queue))))
                                             ;; Clear queue first to prevent recursion
                                             (setq claude-code-ide--vterm-render-queue nil
                                                   claude-code-ide--vterm-render-timer nil)
                                             ;; Execute queued rendering
                                             (funcall orig-fun
                                                      (get-buffer-process buf)
                                                      data))))))
                                   (current-buffer))))
            ;; Standard processing for regular output
            (funcall orig-fun process input)))))))

(defvar-local claude-code-ide--saved-cursor-type nil
  "Saved cursor-type before entering vterm-copy-mode.")

(defun claude-code-ide--vterm-copy-mode-hook ()
  "Make sure cursor is visible in `vterm-copy-mode'.
Saves the current cursor-type when entering copy mode and restores it
when exiting, ensuring compatibility with evil-mode and other packages
that manage cursor appearance."
  (if vterm-copy-mode
      ;; Entering copy mode: save current cursor-type and make cursor visible
      (progn
        (setq claude-code-ide--saved-cursor-type cursor-type)
        (when (null cursor-type)
          (setq cursor-type t)))
    ;; Exiting copy mode: restore previous cursor-type
    (setq cursor-type claude-code-ide--saved-cursor-type)))

(defun claude-code-ide--configure-vterm-buffer ()
  "Configure vterm for enhanced performance and visual quality.
Establishes optimal terminal settings including rendering optimizations,
cursor management, and process buffering for superior user experience."
  ;; Disable automatic scrolling to bottom on output to prevent flickering
  (setq-local vterm-scroll-to-bottom-on-output nil)
  ;; Disable immediate redraw to batch updates and reduce flickering
  (when (boundp 'vterm--redraw-immididately)
    (setq-local vterm--redraw-immididately nil))
  ;; Try to prevent cursor flickering by disabling Emacs' own cursor management
  (setq-local cursor-in-non-selected-windows nil)
  (setq-local blink-cursor-mode nil)
  (setq-local cursor-type nil)  ; Let vterm handle the cursor entirely
  ;; disable hl-line-mode, eliminates another source of flicker
  (setq-local global-hl-line-mode nil)
  (when (featurep 'hl-line)
    (hl-line-mode -1))
  ;; make sure the non-breaking space in the prompt isn't themed
  (face-remap-add-relative 'nobreak-space :inherit 'default)
  ;; Register hook for copy-mode cursor visibility
  (add-hook 'vterm-copy-mode-hook #'claude-code-ide--vterm-copy-mode-hook nil t)
  ;; Increase process read buffering to batch more updates together
  (when-let ((proc (get-buffer-process (current-buffer))))
    (set-process-query-on-exit-flag proc nil)
    ;; Try to make vterm read larger chunks at once
    (when (fboundp 'process-put)
      (process-put proc 'read-output-max 4096)))
  ;; Set up rendering optimization
  (when claude-code-ide-vterm-anti-flicker
    (advice-add 'vterm--filter :around #'claude-code-ide--vterm-smart-renderer)))


;;; Terminal Backend Abstraction

(defun claude-code-ide--terminal-ensure-backend ()
  "Ensure the selected terminal backend is available."
  (cond
   ((eq claude-code-ide-terminal-backend 'vterm)
    (unless (featurep 'vterm)
      (require 'vterm nil t))
    (unless (featurep 'vterm)
      (user-error "The package vterm is not installed.  Please install the vterm package or change `claude-code-ide-terminal-backend' to 'eat")))
   ((eq claude-code-ide-terminal-backend 'eat)
    (unless (featurep 'eat)
      (require 'eat nil t))
    (unless (featurep 'eat)
      (user-error "The package eat is not installed.  Please install the eat package or change `claude-code-ide-terminal-backend' to 'vterm")))
   (t
    (user-error "Invalid terminal backend: %s.  Valid options are 'vterm or 'eat" claude-code-ide-terminal-backend))))

(defun claude-code-ide--terminal-send-string (string)
  "Send STRING to the terminal in the current buffer."
  (cond
   ((eq claude-code-ide-terminal-backend 'vterm)
    (vterm-send-string string))
   ((eq claude-code-ide-terminal-backend 'eat)
    (when eat-terminal
      (eat-term-send-string eat-terminal string)))
   (t
    (error "Unknown terminal backend: %s" claude-code-ide-terminal-backend))))

(defun claude-code-ide--terminal-send-escape ()
  "Send escape key to the terminal in the current buffer."
  (cond
   ((eq claude-code-ide-terminal-backend 'vterm)
    (vterm-send-escape))
   ((eq claude-code-ide-terminal-backend 'eat)
    (when eat-terminal
      (eat-term-send-string eat-terminal "\e")))
   (t
    (error "Unknown terminal backend: %s" claude-code-ide-terminal-backend))))

(defun claude-code-ide--terminal-send-return ()
  "Send return key to the terminal in the current buffer."
  (cond
   ((eq claude-code-ide-terminal-backend 'vterm)
    (vterm-send-return))
   ((eq claude-code-ide-terminal-backend 'eat)
    (when eat-terminal
      (eat-term-send-string eat-terminal "\r")))
   (t
    (error "Unknown terminal backend: %s" claude-code-ide-terminal-backend))))

(defun claude-code-ide--sync-terminal-dimensions (buffer window)
  "Sync terminal dimensions in BUFFER to match WINDOW size.
This ensures the terminal process has the correct dimensions after
the buffer has been displayed in its final window, which may differ
from the window where it was initially created."
  (when (and buffer window (buffer-live-p buffer) (window-live-p window))
    (with-current-buffer buffer
      (when-let ((proc (get-buffer-process buffer)))
        (let ((height (window-body-height window))
              (width (window-body-width window)))
          (set-process-window-size proc height width))))))

(defun claude-code-ide--setup-terminal-keybindings ()
  "Set up keybindings for the Claude Code terminal buffer.
This function binds:
- M-RET (Alt-Return) to insert a newline
- C-<escape> to send escape"
  (cond
   ((eq claude-code-ide-terminal-backend 'vterm)
    ;; For vterm, we set up local keybindings in vterm-mode-map
    (local-set-key (kbd "S-<return>") #'claude-code-ide-insert-newline)
    (local-set-key (kbd "C-<escape>") #'claude-code-ide-send-escape))
   ((eq claude-code-ide-terminal-backend 'eat)
    ;; For eat, we need to modify the semi-char mode map which is the default
    ;; We use local-set-key to make it buffer-local
    (local-set-key (kbd "S-<return>") #'claude-code-ide-insert-newline)
    (local-set-key (kbd "C-<escape>") #'claude-code-ide-send-escape))
   (t
    (error "Unknown terminal backend: %s" claude-code-ide-terminal-backend))))

;;; Terminal Reflow Glitch Prevention
;;
;; This section implements a workaround for Claude Code bug #1422
;; where terminal reflows during height-only changes can cause
;; uncontrollable scrolling. This code should be removed once
;; the upstream bug is fixed.
;; See: https://github.com/anthropics/claude-code/issues/1422

(defun claude-code-ide--terminal-resize-handler ()
  "Retrieve the terminal's resize handling function based on backend."
  (pcase claude-code-ide-terminal-backend
    ('vterm #'vterm--window-adjust-process-window-size)
    ('eat #'eat--adjust-process-window-size)
    (_ (error "Unsupported terminal backend: %s" claude-code-ide-terminal-backend))))

(defun claude-code-ide--terminal-scroll-mode-active-p ()
  "Determine if terminal is currently in scroll/copy mode."
  (pcase claude-code-ide-terminal-backend
    ('vterm (bound-and-true-p vterm-copy-mode))
    (_ nil)))

(defun claude-code-ide--session-buffer-p (buffer)
  "Check if BUFFER belongs to a Claude Code session."
  (when-let ((name (if (stringp buffer) buffer (buffer-name buffer))))
    (string-prefix-p "*claude-code[" name)))

(defvar-local claude-code-ide--last-reported-size nil
  "The last terminal size reported as (WIDTH . HEIGHT), or nil if never reported.
This is the size actually applied to the terminal, as computed by
`window-adjust-process-window-size-function' across all windows
displaying the session buffer on any frame.")

(defvar claude-code-ide--reflow-bypass nil
  "When non-nil, the reflow filter passes through unconditionally.")

(defvar-local claude-code-ide--pending-resync nil
  "Non-nil when a height-only reflow was suppressed for this buffer.
The filter suppresses height-only changes (the bug #1422 workaround),
which skips eat's redisplay and scroll synchronization.  When the
session window is later re-selected, the flush re-runs the resize handler
to re-sync the display even if the applied terminal size is unchanged.")

(defun claude-code-ide--prospective-terminal-size (process windows)
  "Return the (WIDTH . HEIGHT) the terminal would be resized to.
This defers to `window-adjust-process-window-size-function', the same
reducer the backend itself calls, so it honors the user's configured
sizing policy and the full cross-frame WINDOWS list Emacs supplies.
PROCESS and WINDOWS are the arguments the backend's resize handler
received.  Return nil if WINDOWS is empty or the reducer returns nil."
  (when windows
    (funcall window-adjust-process-window-size-function process windows)))

(defun claude-code-ide--flush-buffer-reflow (buf)
  "Re-sync or resize session BUF after a suppressed height-only reflow.
The filter suppresses height-only changes to work around the upstream
scrolling glitch, which skips eat's redisplay/scroll sync and may leave
the applied terminal size stale.  This re-runs the resize handler when
either is true:
- a resync is pending (`claude-code-ide--pending-resync'): the display
  was left out of sync by a suppressed change and must be redrawn now
  that the window is focused, even if the applied size is unchanged;
- the size the backend would apply differs from the last reported one.
The size is computed across all windows on all frames, so it is correct
no matter which window or frame triggered the flush."
  (when (and (buffer-live-p buf)
             (claude-code-ide--session-buffer-p buf)
             (buffer-local-value 'claude-code-ide--last-reported-size buf))
    (with-current-buffer buf
      (let* ((proc (get-buffer-process buf))
             (windows (get-buffer-window-list buf nil t))
             (prospective (claude-code-ide--prospective-terminal-size
                           proc windows))
             (size-changed (and prospective
                                (not (equal claude-code-ide--last-reported-size
                                            prospective)))))
        (when (and prospective
                   (or size-changed claude-code-ide--pending-resync))
          (let* ((claude-code-ide--reflow-bypass t)
                 (applied (funcall (claude-code-ide--terminal-resize-handler)
                                   proc windows)))
            (setq claude-code-ide--pending-resync nil)
            ;; Advance the baseline to the size we just applied, exactly as
            ;; the filter does on its allow path.  Without this the baseline
            ;; goes stale after the first flush and the next genuine change
            ;; is misread as "unchanged" and never sent.
            (when applied
              (setq claude-code-ide--last-reported-size
                    (cons (car applied) (cdr applied))))
            ;; The resize handler only reflows the terminal's own display and
            ;; returns the size; it does NOT signal the child process.  On
            ;; the normal path Emacs follows the handler with
            ;; `set-process-window-size', but our manual flush bypasses that,
            ;; so do it here or the child keeps its stale size.
            (when (and applied (process-live-p proc) size-changed)
              (set-process-window-size proc (cdr applied) (car applied)))))))))

(defun claude-code-ide--flush-pending-reflow (_arg)
  "Flush a deferred resize for the session buffer in the selected window.
Registered on `window-selection-change-functions' and
`window-buffer-change-functions'.  _ARG is the frame or window passed by
those hooks (ignored).

Scoping to the selected window is deliberate: a suppressed height-only
change must propagate only once the session window regains focus.  For
example, opening the minibuffer shrinks the session window but selects
the minibuffer (not a session) so nothing flushes; closing it returns
focus to the session window, which then flushes the settled size."
  (claude-code-ide--flush-buffer-reflow (window-buffer (selected-window))))


(defun claude-code-ide--terminal-reflow-filter (original-fn &rest args)
  "Filter terminal reflows to prevent height-only resize triggers.
This wraps ORIGINAL-FN to suppress reflow signals unless the terminal
width has actually changed, working around the scrolling glitch."
  (if (or claude-code-ide--reflow-bypass
          (not (claude-code-ide--session-buffer-p (current-buffer))))
      ;; Bypass or not in a Claude buffer - pass through and record size
      (let ((result (apply original-fn args)))
        (when (and result (claude-code-ide--session-buffer-p (current-buffer)))
          (setq claude-code-ide--last-reported-size
                (cons (car result) (cdr result))))
        result)
    ;; Decide based on the size the backend would actually apply.  We ask
    ;; the same reducer the backend uses, passing through the (process
    ;; windows) arguments Emacs handed us, so the check sees the full
    ;; cross-frame window list rather than just the selected frame's.  This
    ;; keeps the width comparison correct when the buffer is shown in, or
    ;; moved between, multiple frames.
    (let* ((prospective (apply #'claude-code-ide--prospective-terminal-size
                               args))
           (width-changed (and prospective
                               (not (eql (car prospective)
                                         (car claude-code-ide--last-reported-size))))))
      (cond
       ;; In scroll mode - suppress reflow entirely
       ((claude-code-ide--terminal-scroll-mode-active-p)
        nil)
       ;; Width changed - allow reflow and record reported size.  The
       ;; handler re-syncs the display, so any pending resync is satisfied.
       (width-changed
        (let ((result (apply original-fn args)))
          (when result
            (setq claude-code-ide--last-reported-size
                  (cons (car result) (cdr result))
                  claude-code-ide--pending-resync nil))
          result))
       ;; No width change - suppress.  Mark the display out of sync so the
       ;; flush re-syncs it once the session window regains focus (e.g. the
       ;; window's height changed under a minibuffer and must be redrawn).
       (t
        (setq claude-code-ide--pending-resync t)
        nil)))))


(defvar-local claude-code-ide--display-erased nil
  "Non-nil when erase-in-disp was called during current output processing.")

(defun claude-code-ide--track-scrollback-clear (original-fn &optional n)
  "Advice around `eat--t-erase-in-disp' to flag display clears.
ORIGINAL-FN is called with N.  Sets a flag when N is 2 or 3."
  (when (memq n '(2 3))
    (setq claude-code-ide--display-erased t))
  (funcall original-fn n))

(defun claude-code-ide--preserve-scroll-position (original-fn buffer)
  "Preserve scroll position across display clears during output processing.
Wraps ORIGINAL-FN (eat--process-output-queue) for BUFFER.
Saves window state BEFORE dispatch, restores AFTER if a clear occurred."
  (if (not (and (buffer-live-p buffer)
                (claude-code-ide--session-buffer-p (buffer-name buffer))))
      (funcall original-fn buffer)
    (with-current-buffer buffer
      (let* ((pmax (point-max))
             (cursor (and eat-terminal
                          (eat-term-display-cursor eat-terminal)))
             (saved
              (when cursor
                (let (result)
                  (dolist (win (get-buffer-window-list nil nil t))
                    (let ((wpoint (window-point win)))
                      (when (/= wpoint cursor)
                        (push (list win
                                    (- pmax (window-start win))
                                    (- pmax wpoint))
                              result))))
                  result))))
        (setq claude-code-ide--display-erased nil)
        (funcall original-fn buffer)
        (when (and saved claude-code-ide--display-erased)
          (let ((new-pmax (point-max))
                (new-pmin (point-min)))
            (dolist (entry saved)
              (let* ((win (nth 0 entry))
                     (start-offset (nth 1 entry))
                     (point-offset (nth 2 entry)))
                (when (and (window-live-p win)
                           (eq (window-buffer win) (current-buffer)))
                  (let ((new-start
                         (save-excursion
                           (goto-char (max new-pmin
                                           (- new-pmax start-offset)))
                           (line-beginning-position)))
                        (new-point
                         (max new-pmin (- new-pmax point-offset))))
                    (set-window-start win new-start t)
                    (set-window-point win new-point)))))))))))

;;; Helper Functions

(defun claude-code-ide--default-buffer-name (directory)
  "Generate default buffer name for DIRECTORY."
  (format "*claude-code[%s]*"
          (file-name-nondirectory (directory-file-name directory))))

(defun claude-code-ide--get-working-directory ()
  "Get the current working directory (project root or current directory)."
  (if-let ((project (project-current)))
      (expand-file-name (project-root project))
    (expand-file-name default-directory)))

(defun claude-code-ide--get-buffer-name (&optional directory)
  "Get the buffer name for the Claude Code session in DIRECTORY.
If DIRECTORY is not provided, use the current working directory."
  (funcall claude-code-ide-buffer-name-function
           (or directory (claude-code-ide--get-working-directory))))

(defun claude-code-ide--get-process (&optional directory)
  "Get the Claude Code process for DIRECTORY or current working directory."
  (gethash (or directory (claude-code-ide--get-working-directory))
           claude-code-ide--processes))

(defun claude-code-ide--set-process (process &optional directory)
  "Set the Claude Code PROCESS for DIRECTORY or current working directory."
  ;; Check if this is the first session starting
  (when (= (hash-table-count claude-code-ide--processes) 0)
    ;; Apply advice globally for the first session
    (when claude-code-ide-prevent-reflow-glitch
      (advice-add (claude-code-ide--terminal-resize-handler)
                  :around #'claude-code-ide--terminal-reflow-filter)
      (add-hook 'window-selection-change-functions
                #'claude-code-ide--flush-pending-reflow)
      ;; Also flush when a window's buffer changes: switching a window to a
      ;; session buffer (without changing the selected window) does not fire
      ;; the selection hook, but does change the size the backend should use.
      (add-hook 'window-buffer-change-functions
                #'claude-code-ide--flush-pending-reflow))
    (when claude-code-ide-eat-preserve-position
      (advice-add 'eat--process-output-queue
                  :around #'claude-code-ide--preserve-scroll-position)
      (advice-add 'eat--t-erase-in-disp
                  :around #'claude-code-ide--track-scrollback-clear)))
  (puthash (or directory (claude-code-ide--get-working-directory))
           process
           claude-code-ide--processes))

(defun claude-code-ide--cleanup-dead-processes ()
  "Remove entries for dead processes from the process table."
  (maphash (lambda (directory process)
             (unless (process-live-p process)
               (remhash directory claude-code-ide--processes)))
           claude-code-ide--processes))

(defun claude-code-ide--cleanup-all-sessions ()
  "Clean up all active Claude Code sessions."
  (maphash (lambda (directory process)
             (when (process-live-p process)
               (claude-code-ide--cleanup-on-exit directory)))
           claude-code-ide--processes))

;; Ensure cleanup on Emacs exit
(add-hook 'kill-emacs-hook #'claude-code-ide--cleanup-all-sessions)

(defun claude-code-ide--display-buffer-in-side-window (buffer)
  "Display BUFFER in a side window according to customization.
The window is displayed on the side specified by
`claude-code-ide-window-side' with dimensions from
`claude-code-ide-window-width' or `claude-code-ide-window-height'.
If `claude-code-ide-focus-on-open' is non-nil, the window is selected."
  (let ((window
         (if claude-code-ide-use-side-window
             ;; Use side window
             (let* ((side claude-code-ide-window-side)
                    (slot 0)
                    (window-parameters '((no-delete-other-windows . t)))
                    (display-buffer-alist
                     `((,(regexp-quote (buffer-name buffer))
                        (display-buffer-in-side-window)
                        (side . ,side)
                        (slot . ,slot)
                        ,@(when (memq side '(left right))
                            `((window-width
                               . ,(lambda (win)
                                    (let ((delta (- claude-code-ide-window-width
                                                    (window-body-width win))))
                                      (unless (zerop delta)
                                        (window-resize win delta t)))))))
                        ,@(when (memq side '(top bottom))
                            `((window-height . ,claude-code-ide-window-height)))
                        (window-parameters . ,window-parameters)))))
               (display-buffer buffer))
           ;; Use regular buffer
           (display-buffer buffer))))
    ;; Update last accessed buffer whenever we display a Claude buffer
    (setq claude-code-ide--last-accessed-buffer buffer)
    ;; Select the window to give it focus if configured to do so
    (when (and window claude-code-ide-focus-on-open)
      (select-window window))
    ;; For bottom/top windows, explicitly set and preserve the height
    (when (and window
               claude-code-ide-use-side-window
               (memq claude-code-ide-window-side '(top bottom)))
      (set-window-text-height window claude-code-ide-window-height)
      (set-window-dedicated-p window t))
    ;; Sync terminal dimensions with the actual window size
    ;; This is necessary because vterm/eat may have been created with
    ;; different dimensions before being displayed in this window
    (when window
      (claude-code-ide--sync-terminal-dimensions buffer window))
    window))

(defvar claude-code-ide--cleanup-in-progress nil
  "Flag to prevent recursive cleanup calls.")

(defun claude-code-ide--cleanup-on-exit (directory)
  "Clean up MCP server and process tracking when Claude exits for DIRECTORY."
  (unless claude-code-ide--cleanup-in-progress
    (setq claude-code-ide--cleanup-in-progress t)
    (unwind-protect
        (progn
          ;; Remove from process table
          (remhash directory claude-code-ide--processes)
          ;; Check if this was the last session
          (when (= (hash-table-count claude-code-ide--processes) 0)
            ;; Remove advice globally when no sessions remain
            (advice-remove (claude-code-ide--terminal-resize-handler)
                           #'claude-code-ide--terminal-reflow-filter)
            (advice-remove 'eat--process-output-queue
                           #'claude-code-ide--preserve-scroll-position)
            (advice-remove 'eat--t-erase-in-disp
                           #'claude-code-ide--track-scrollback-clear)
            (remove-hook 'window-selection-change-functions
                         #'claude-code-ide--flush-pending-reflow)
            (remove-hook 'window-buffer-change-functions
                         #'claude-code-ide--flush-pending-reflow))
          ;; Remove vterm rendering optimization if no sessions remain
          (when (and (eq claude-code-ide-terminal-backend 'vterm)
                     claude-code-ide-vterm-anti-flicker
                     (= (hash-table-count claude-code-ide--processes) 0))
            (advice-remove 'vterm--filter #'claude-code-ide--vterm-smart-renderer))
          ;; Stop MCP server for this project directory
          (claude-code-ide-mcp-stop-session directory)
          ;; Notify MCP tools server about session end with session ID
          (let ((session-id (gethash directory claude-code-ide--session-ids)))
            (claude-code-ide-mcp-server-session-ended session-id)
            ;; Clean up session ID mapping
            (when session-id
              (remhash directory claude-code-ide--session-ids)))
          ;; Kill the vterm buffer if it exists
          (let ((buffer-name (claude-code-ide--get-buffer-name directory)))
            (when-let ((buffer (get-buffer buffer-name)))
              (when (buffer-live-p buffer)
                (let ((kill-buffer-hook nil) ; Disable hooks to prevent recursion
                      (kill-buffer-query-functions nil)) ; Don't ask for confirmation
                  (kill-buffer buffer)))))
          (claude-code-ide-debug "Cleaned up Claude Code session for %s"
                                 (file-name-nondirectory (directory-file-name directory))))
      (setq claude-code-ide--cleanup-in-progress nil))))

;;; CLI Detection

(defun claude-code-ide--detect-cli ()
  "Detect if Claude Code CLI is available."
  (let ((available (condition-case nil
                       (eq (call-process claude-code-ide-cli-path nil nil nil "--version") 0)
                     (error nil))))
    (setq claude-code-ide--cli-available available)))

(defun claude-code-ide--ensure-cli ()
  "Ensure Claude Code CLI is available, detect if needed."
  (unless claude-code-ide--cli-available
    (claude-code-ide--detect-cli))
  claude-code-ide--cli-available)

;;; Commands

(defun claude-code-ide--toggle-existing-window (existing-buffer working-dir)
  "Toggle visibility of EXISTING-BUFFER window for WORKING-DIR.
If the window is visible, it will be hidden.
If the window is not visible, it will be shown in a side window."
  (let ((window (get-buffer-window existing-buffer)))
    (if window
        ;; Window is visible, hide it
        (progn
          ;; Track this buffer as last accessed when closing
          (setq claude-code-ide--last-accessed-buffer existing-buffer)
          (delete-window window)
          (claude-code-ide-debug "Claude Code window hidden"))
      ;; Window is not visible, show it
      (progn
        (claude-code-ide--display-buffer-in-side-window existing-buffer)
        ;; Update the original tab when showing the window
        (when-let ((session (claude-code-ide-mcp--get-session-for-project working-dir)))
          (when (fboundp 'tab-bar--current-tab)
            (setf (claude-code-ide-mcp-session-original-tab session) (tab-bar--current-tab))))
        (claude-code-ide-debug "Claude Code window shown")))))

(defun claude-code-ide--build-claude-command (&optional continue resume session-id agents)
  "Build the Claude command with optional flags.
If CONTINUE is non-nil, add the -c flag.
If RESUME is non-nil, add the -r flag.
If SESSION-ID is provided, it's included in the MCP server URL path.
If AGENTS is non-nil, launch the `agents' subcommand instead of an interactive coding session.
If `claude-code-ide-cli-debug' is non-nil, add the -d flag.
If `claude-code-ide-system-prompt' is non-nil, add the --append-system-prompt flag.
Additional flags from `claude-code-ide-cli-extra-flags' are also included."
  (let ((claude-cmd claude-code-ide-cli-path))
    ;; Add debug flag if enabled
    (when claude-code-ide-cli-debug
      (setq claude-cmd (concat claude-cmd " -d")))
    ;; Add resume flag if requested
    (when resume
      (setq claude-cmd (concat claude-cmd " -r")))
    ;; Add continue flag if requested
    (when continue
      (setq claude-cmd (concat claude-cmd " -c")))
    ;; Add append-system-prompt flag with Emacs context
    (let ((emacs-prompt "IMPORTANT: Connected to Emacs via claude-code-ide.el integration. Emacs uses mixed coordinates: Lines: 1-based (line 1 = first line), Columns: 0-based (column 0 = first column). Example: First character in file is at line 1, column 0. Available: xref (LSP), tree-sitter, imenu, project.el, flycheck/flymake diagnostics. Context-aware with automatic project/file/selection tracking.")
          (combined-prompt nil))
      ;; Always include the Emacs-specific prompt
      (setq combined-prompt emacs-prompt)
      ;; Append user's custom prompt if set
      (when claude-code-ide-system-prompt
        (setq combined-prompt (concat combined-prompt "\n\n" claude-code-ide-system-prompt)))
      ;; Add the combined prompt to the command
      (setq claude-cmd (concat claude-cmd " --append-system-prompt "
                               (shell-quote-argument combined-prompt))))
    ;; Add any extra flags
    (when (and claude-code-ide-cli-extra-flags
               (not (string-empty-p claude-code-ide-cli-extra-flags)))
      (setq claude-cmd (concat claude-cmd " " claude-code-ide-cli-extra-flags)))
    ;; Add MCP tools config if enabled
    (when (claude-code-ide-mcp-server-ensure-server)
      (when-let ((config (claude-code-ide-mcp-server-get-config session-id)))
        (let ((json-str (json-encode config))
              ;; The list of tool names/patterns to allow, as a list of
              ;; strings (a custom string pattern is split on whitespace).
              (tool-list
               (cond
                ;; Auto mode: get all emacs-tools names
                ((eq claude-code-ide-mcp-allowed-tools 'auto)
                 (claude-code-ide-mcp-server-get-tool-names "mcp__emacs-tools__"))
                ;; List of specific tools
                ((listp claude-code-ide-mcp-allowed-tools)
                 claude-code-ide-mcp-allowed-tools)
                ;; String pattern
                ((stringp claude-code-ide-mcp-allowed-tools)
                 (split-string claude-code-ide-mcp-allowed-tools nil t))
                ;; nil/disabled
                (t nil))))
          (claude-code-ide-debug "MCP tools config JSON: %s" json-str)
          ;; For vterm, we need to escape for sh -c context
          ;; First escape backslashes, then quotes
          (setq json-str (replace-regexp-in-string "\\\\" "\\\\\\\\" json-str))
          (setq json-str (replace-regexp-in-string "\"" "\\\\\"" json-str))
          ;; --mcp-config and --allowedTools are variadic flags: in the
          ;; space-separated form their values would greedily consume a
          ;; following bare token.  For the agents view that token is the
          ;; `agents' subcommand (appended below), which must survive, so we
          ;; emit the non-greedy "=" form there.  Interactive sessions have no
          ;; trailing subcommand and keep the original space form.
          (if agents
              (progn
                (setq claude-cmd (concat claude-cmd " --mcp-config=\"" json-str "\""))
                (dolist (tool tool-list)
                  (setq claude-cmd (concat claude-cmd " --allowedTools=" tool))))
            (setq claude-cmd (concat claude-cmd " --mcp-config \"" json-str "\""))
            (when tool-list
              (setq claude-cmd (concat claude-cmd " --allowedTools "
                                       (mapconcat #'identity tool-list " "))))))))
    ;; The agents subcommand goes last, after all global flags.
    (when agents
      (setq claude-cmd (concat claude-cmd " agents")))
    claude-cmd))


(defun claude-code-ide--parse-command-string (command-string)
  "Parse a command string into (program . args) for eat-exec.
COMMAND-STRING is a shell command line to parse.
Returns a cons cell (program . args) where program is the executable
and args is a list of arguments."
  (let ((parts (split-string-shell-command command-string)))
    (cons (car parts) (cdr parts))))


(defun claude-code-ide--create-terminal-session (buffer-name working-dir port continue resume session-id &optional agents)
  "Create a new terminal session for Claude Code.
BUFFER-NAME is the name for the terminal buffer.
WORKING-DIR is the working directory.
PORT is the MCP server port.
CONTINUE is whether to continue the most recent conversation.
RESUME is whether to resume a previous conversation.
SESSION-ID is the unique identifier for this session.
AGENTS is whether to launch the agent view instead of a standard session.

Returns a cons cell of (buffer . process) on success.
Signals an error if terminal fails to initialize."
  ;; Ensure terminal backend is available before proceeding
  (claude-code-ide--terminal-ensure-backend)
  (let* ((claude-cmd (claude-code-ide--build-claude-command continue resume session-id agents))
         (default-directory working-dir)
         (env-vars (list (format "CLAUDE_CODE_SSE_PORT=%d" port)
                         "TERM_PROGRAM=ghostty"
                         "FORCE_CODE_TERMINAL=true")))
    ;; Log the command for debugging
    (claude-code-ide-debug "Starting Claude with command: %s" claude-cmd)
    (claude-code-ide-debug "Working directory: %s" working-dir)
    (claude-code-ide-debug "Environment: CLAUDE_CODE_SSE_PORT=%d" port)
    (claude-code-ide-debug "Session ID: %s" session-id)
    (claude-code-ide-debug "Terminal backend: %s" claude-code-ide-terminal-backend)

    (cond
     ;; vterm backend
     ((eq claude-code-ide-terminal-backend 'vterm)
      (let* ((vterm-buffer-name buffer-name)
             ;; Set vterm-shell to run Claude directly
             (vterm-shell claude-cmd)
             ;; vterm uses vterm-environment for passing env vars
             (vterm-environment (append env-vars vterm-environment)))
        ;; Create vterm buffer without switching to it
        (let ((buffer (save-window-excursion
                        (vterm vterm-buffer-name))))
          ;; Check if vterm successfully created a buffer
          (unless buffer
            (error "Failed to create vterm buffer.  Please ensure vterm is properly installed and compiled"))
          ;; Configure vterm buffer for optimal performance
          (with-current-buffer buffer
            (claude-code-ide--configure-vterm-buffer))
          ;; Get the process that vterm created
          (let ((process (get-buffer-process buffer)))
            (unless process
              (error "Failed to get vterm process.  The vterm module may not be compiled correctly"))
            ;; Check if buffer is still alive
            (unless (buffer-live-p buffer)
              (error "Vterm buffer was killed during initialization"))
            (cons buffer process)))))

     ;; eat backend
     ((eq claude-code-ide-terminal-backend 'eat)
      (let* ((buffer (get-buffer-create buffer-name))
             ;; Parse command string into program and args
             (cmd-parts (claude-code-ide--parse-command-string claude-cmd))
             (program (car cmd-parts))
             (args (cdr cmd-parts)))
        (with-current-buffer buffer
          ;; Set up eat mode
          (unless (eq major-mode 'eat-mode)
            (eat-mode))
          ;; Record initial terminal size for deferred resize tracking.
          ;; Seed it with the size the backend will actually apply across
          ;; all windows showing the buffer, matching the value the reflow
          ;; filter and flush compare against.  The process does not exist
          ;; yet, but the size reducer derives its result from the windows.
          (when claude-code-ide-prevent-reflow-glitch
            (when-let* ((windows (get-buffer-window-list buffer nil t))
                        (size (claude-code-ide--prospective-terminal-size
                               (get-buffer-process buffer) windows)))
              (setq-local claude-code-ide--last-reported-size size)))
          ;; Prepend our env vars to the buffer-local process-environment
          (setq-local process-environment
                      (append env-vars process-environment))
          (eat-exec buffer buffer-name program nil args)
          ;; Get the process
          (let ((process (get-buffer-process buffer)))
            (unless process
              (error "Failed to create eat process.  Please ensure eat is properly installed"))
            (cons buffer process)))))

     (t
      (error "Unknown terminal backend: %s" claude-code-ide-terminal-backend)))))

(defun claude-code-ide--start-session (&optional continue resume agents)
  "Start a Claude Code session for the current project.
If CONTINUE is non-nil, start Claude with the -c (continue) flag.
If RESUME is non-nil, start Claude with the -r (resume) flag.
If AGENTS is non-nil, launch Claude agent view.

This function handles:
- CLI availability checking
- Dead process cleanup
- Existing session detection and window toggling
- New session creation with MCP server setup
- Process and buffer lifecycle management"
  (unless (claude-code-ide--ensure-cli)
    (user-error "Claude Code CLI not available.  Please install it and ensure it's in PATH"))

  ;; Clean up any dead processes first
  (claude-code-ide--cleanup-dead-processes)

  (let* ((working-dir (claude-code-ide--get-working-directory))
         (buffer-name (claude-code-ide--get-buffer-name))
         (existing-buffer (get-buffer buffer-name))
         (existing-process (claude-code-ide--get-process working-dir)))

    ;; If buffer exists and process is alive, toggle the window
    (if (and existing-buffer
             (buffer-live-p existing-buffer)
             existing-process)
        (claude-code-ide--toggle-existing-window existing-buffer working-dir)
      ;; Ensure the selected terminal backend is available before starting MCP
      (claude-code-ide--terminal-ensure-backend)
      ;; Start MCP server with project directory
      (let ((port nil)
            (session-id (format "claude-%s-%s"
                                (file-name-nondirectory (directory-file-name working-dir))
                                (format-time-string "%Y%m%d-%H%M%S"))))
        (condition-case err
            (progn
              ;; Start MCP server
              (setq port (claude-code-ide-mcp-start working-dir))
              ;; Create new terminal session
              (let* ((buffer-and-process (claude-code-ide--create-terminal-session
                                          buffer-name working-dir port continue resume session-id agents))
                     (buffer (car buffer-and-process))
                     (process (cdr buffer-and-process)))
                ;; Notify MCP tools server about new session with session info
                (claude-code-ide-mcp-server-session-started session-id working-dir buffer)
                (claude-code-ide--set-process process working-dir)
                ;; Store session ID for cleanup
                (puthash working-dir session-id claude-code-ide--session-ids)
                ;; Set up process sentinel to clean up when Claude exits
                (set-process-sentinel process
                                      (lambda (_proc event)
                                        ;; Check for abnormal exit with error code
                                        (when (string-match "exited abnormally with code \\([0-9]+\\)" event)
                                          (let ((exit-code (match-string 1 event)))
                                            (claude-code-ide-debug "Claude process exited with code %s, event: %s"
                                                                   exit-code event)
                                            (message "Claude exited with error code %s" exit-code)))
                                        (when (or (string-match "finished" event)
                                                  (string-match "exited" event)
                                                  (string-match "killed" event)
                                                  (string-match "terminated" event))
                                          (claude-code-ide--cleanup-on-exit working-dir))))
                ;; Also add buffer kill hook as a backup
                (with-current-buffer buffer
                  (add-hook 'kill-buffer-hook
                            (lambda ()
                              (claude-code-ide--cleanup-on-exit working-dir))
                            nil t)
                  ;; Set up terminal keybindings
                  (claude-code-ide--setup-terminal-keybindings)
                  ;; Add terminal-specific exit hooks
                  (cond
                   ((eq claude-code-ide-terminal-backend 'vterm)
                    ;; Add vterm exit hook to ensure buffer is killed when process exits
                    ;; vterm runs Claude directly, no shell involved
                    (add-hook 'vterm-exit-functions
                              (lambda (&rest _)
                                (when (buffer-live-p buffer)
                                  (kill-buffer buffer)))
                              nil t))
                   ((eq claude-code-ide-terminal-backend 'eat)
                    ;; eat uses kill-buffer-on-exit variable
                    (setq-local eat-kill-buffer-on-exit t))))
                ;; Stabilization period for terminal layout initialization
                (sleep-for claude-code-ide-terminal-initialization-delay)
                ;; Display the buffer in a side window
                (claude-code-ide--display-buffer-in-side-window buffer)
                (claude-code-ide-log "Claude Code %sstarted in %s with MCP on port %d%s"
                                     (cond (agents "agent view ")
                                           (continue "continued and ")
                                           (resume "resumed and ")
                                           (t ""))
                                     (file-name-nondirectory (directory-file-name working-dir))
                                     port
                                     (if claude-code-ide-cli-debug " (debug mode enabled)" ""))))
          (error
           ;; Terminal session creation failed - clean up MCP server
           (when port
             (claude-code-ide-mcp-stop-session working-dir))
           ;; Re-signal the error with improved message
           (signal (car err) (cdr err))))))))

;;;###autoload
(defun claude-code-ide ()
  "Run Claude Code in a terminal for the current project or directory."
  (interactive)
  (claude-code-ide--start-session))

;;;###autoload
(defun claude-code-ide-resume ()
  "Resume Claude Code in a terminal for the current project or directory.
This starts Claude with the -r (resume) flag to continue the previous
conversation."
  (interactive)
  (claude-code-ide--start-session nil t))

;;;###autoload
(defun claude-code-ide-continue ()
  "Continue the most recent Claude Code conversation in the current directory.
This starts Claude with the -c (continue) flag to continue the most recent
conversation in the current directory."
  (interactive)
  (claude-code-ide--start-session t))

;;;###autoload
(defun claude-code-ide-agent-view ()
  "Launch the Claude Code agent view for the current project or directory.
This starts Claude with the `agents' subcommand, which opens the
background agent management view. Agent view is launched in the current
directory so background agents can be easily dispatched against the
current project."
  (interactive)
  (claude-code-ide--start-session nil nil t))

;;;###autoload
(defun claude-code-ide-check-status ()
  "Check Claude Code CLI status."
  (interactive)
  (claude-code-ide--detect-cli)
  (if claude-code-ide--cli-available
      (let ((version-output
             (with-temp-buffer
               (call-process claude-code-ide-cli-path nil t nil "--version")
               (buffer-string))))
        (claude-code-ide-log "Claude Code CLI version: %s" (string-trim version-output)))
    (claude-code-ide-log "Claude Code is not installed.")))

;;;###autoload
(defun claude-code-ide-stop ()
  "Stop the Claude Code session for the current project or directory."
  (interactive)
  (let* ((working-dir (claude-code-ide--get-working-directory))
         (buffer-name (claude-code-ide--get-buffer-name)))
    (if-let ((buffer (get-buffer buffer-name)))
        (progn
          ;; Kill the buffer (cleanup will be handled by hooks)
          ;; The process sentinel will handle cleanup when the process dies
          (kill-buffer buffer)
          (claude-code-ide-log "Stopping Claude Code in %s..."
                               (file-name-nondirectory (directory-file-name working-dir))))
      (claude-code-ide-log "No Claude Code session is running in this directory"))))


;;;###autoload
(defun claude-code-ide-switch-to-buffer ()
  "Switch to the Claude Code buffer for the current project.
If the buffer is not visible, display it in the configured side window.
If the buffer is already visible, switch focus to it."
  (interactive)
  (let ((buffer-name (claude-code-ide--get-buffer-name)))
    (if-let ((buffer (get-buffer buffer-name)))
        (if-let ((window (get-buffer-window buffer)))
            ;; Buffer is visible, just focus it
            (select-window window)
          ;; Buffer exists but not visible, display it
          (claude-code-ide--display-buffer-in-side-window buffer))
      (user-error "No Claude Code session for this project.  Use M-x claude-code-ide to start one"))))

;;;###autoload
(defun claude-code-ide-list-sessions ()
  "List all active Claude Code sessions and switch to selected one."
  (interactive)
  (claude-code-ide--cleanup-dead-processes)
  (let ((sessions '()))
    (maphash (lambda (directory _)
               (push (cons (abbreviate-file-name directory)
                           directory)
                     sessions))
             claude-code-ide--processes)
    (if sessions
        (let ((choice (completing-read "Switch to Claude Code session: "
                                       sessions nil t)))
          (when choice
            (let* ((directory (alist-get choice sessions nil nil #'string=))
                   (buffer-name (funcall claude-code-ide-buffer-name-function directory)))
              (if-let ((buffer (get-buffer buffer-name)))
                  (claude-code-ide--display-buffer-in-side-window buffer)
                (user-error "Buffer for session %s no longer exists" choice)))))
      (claude-code-ide-log "No active Claude Code sessions"))))

;;;###autoload
(defun claude-code-ide-insert-at-mentioned ()
  "Insert selected text into Claude prompt."
  (interactive)
  (if-let* ((project-dir (claude-code-ide-mcp--get-buffer-project))
            (session (claude-code-ide-mcp--get-session-for-project project-dir))
            (client (claude-code-ide-mcp-session-client session)))
      (progn
        (claude-code-ide-mcp-send-at-mentioned)
        (claude-code-ide-debug "Sent selection to Claude Code"))
    (user-error "Claude Code is not connected.  Please start Claude Code first")))

;;;###autoload
(defun claude-code-ide-send-escape ()
  "Send escape key to the Claude Code terminal buffer for the current project."
  (interactive)
  (let ((buffer-name (claude-code-ide--get-buffer-name)))
    (if-let ((buffer (get-buffer buffer-name)))
        (with-current-buffer buffer
          (claude-code-ide--terminal-send-escape))
      (user-error "No Claude Code session for this project"))))

;;;###autoload
(defun claude-code-ide-insert-newline ()
  "Send a newline to the Claude Code terminal buffer for the current project.
This uses the ESC + carriage return sequence, which Claude Code interprets as a newline."
  (interactive)
  (let ((buffer-name (claude-code-ide--get-buffer-name)))
    (if-let ((buffer (get-buffer buffer-name)))
        (with-current-buffer buffer
          (claude-code-ide--terminal-send-escape)
          (claude-code-ide--terminal-send-return))
      (user-error "No Claude Code session for this project"))))

;;;###autoload
(defun claude-code-ide-toggle-vterm-optimization ()
  "Toggle vterm rendering optimization.
This command switches the advanced rendering optimization on or off.
Use this to balance between visual smoothness and raw responsiveness."
  (interactive)
  (setq claude-code-ide-vterm-anti-flicker
        (not claude-code-ide-vterm-anti-flicker))
  (message "Vterm rendering optimization %s"
           (if claude-code-ide-vterm-anti-flicker
               "enabled (smoother display with minimal latency)"
             "disabled (direct rendering, maximum responsiveness)")))

;;;###autoload
(defun claude-code-ide-send-prompt (&optional prompt)
  "Send a prompt to the Claude Code terminal.
When called interactively, reads a prompt from the minibuffer.
When called programmatically, sends the given PROMPT string."
  (interactive)
  (let ((buffer-name (claude-code-ide--get-buffer-name)))
    (if-let ((buffer (get-buffer buffer-name)))
        (let ((prompt-to-send (or prompt (read-string "Claude prompt: "))))
          (when (not (string-empty-p prompt-to-send))
            (with-current-buffer buffer
              (claude-code-ide--terminal-send-string prompt-to-send)
              ;; Small delay to ensure prompt text is processed before sending return
              (sit-for 0.1)
              (claude-code-ide--terminal-send-return))
            (claude-code-ide-debug "Sent prompt to Claude Code: %s" prompt-to-send)))
      (user-error "No Claude Code session for this project"))))

;;;###autoload
(defun claude-code-ide-toggle ()
  "Toggle visibility of Claude Code window for the current project."
  (interactive)
  (let* ((working-dir (claude-code-ide--get-working-directory))
         (buffer-name (claude-code-ide--get-buffer-name))
         (buffer (get-buffer buffer-name)))
    (if buffer
        (claude-code-ide--toggle-existing-window buffer working-dir)
      (user-error "No Claude Code session for this project"))))

;;;###autoload
(defun claude-code-ide-toggle-recent ()
  "Toggle visibility of the most recent Claude Code window.
If any Claude window is visible, hide all of them.
If no Claude windows are visible, show the most recently accessed one."
  (interactive)
  (let ((found-visible nil))
    ;; Check all sessions and close any visible windows
    (maphash (lambda (directory _process)
               (let* ((buffer-name (funcall claude-code-ide-buffer-name-function directory))
                      (buffer (get-buffer buffer-name)))
                 (when (and buffer
                            (buffer-live-p buffer)
                            (get-buffer-window buffer))
                   ;; Window is visible, use the toggle function to close it
                   (claude-code-ide--toggle-existing-window buffer directory)
                   (setq found-visible t))))
             claude-code-ide--processes)

    (cond
     ;; We found and closed visible windows
     (found-visible
      (message "Closed all Claude Code windows"))

     ;; No windows were visible, show the most recent one
     ((and claude-code-ide--last-accessed-buffer
           (buffer-live-p claude-code-ide--last-accessed-buffer))
      (claude-code-ide--display-buffer-in-side-window claude-code-ide--last-accessed-buffer)
      (message "Opened most recent Claude Code session"))

     ;; No recent session available
     (t
      (user-error "No recent Claude Code session to toggle")))))

(provide 'claude-code-ide)

;;; claude-code-ide.el ends here
