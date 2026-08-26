#!/usr/bin/env bash
# Unit contract for runtime-dynamic-replace-top-capability-frame!:
# replacing the innermost capability frame must PRESERVE the outer frames.
#
# Regression background: forcing a persistent node inside nested capability
# extents used to call runtime-dynamic-set-capabilities! with the flat
# caller list, which collapsed {inner, outer, ambient} to {caller} and
# destroyed every enclosing capability extent. The bracket-shaped
# replacement keeps the rest of the stack intact.
#
# Runs against the host SBCL because the stack shape below the innermost
# frame is not observable from pp source (current-capabilities composes
# only the innermost frame).
set -uo pipefail

SBCL=${SBCL:-sbcl}
command -v "$SBCL" >/dev/null || { echo "ok   caps-frame-restore (skipped: no sbcl)"; exit 0; }

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/check.lisp" <<'LISP'
(require :asdf)
(asdf:load-asd (truename (merge-pathnames "lisp/pp.asd" *default-pathname-defaults*)))
(asdf:load-system "pp/runtime")

(defun pushf (frame)
  (push frame (pp.rt.scope::runtime-dynamic-scope-capabilities
                  (pp.rt.scope:runtime-dynamic-current))))

(defun frames ()
  (pp.rt.scope::runtime-dynamic-scope-capabilities
   (pp.rt.scope:runtime-dynamic-current)))

(let ((session (pp.runtime:make-runtime-session))
      failures)
  (pp.rt.scope:runtime-dynamic-with-top-level session
      (lambda ()
        (pushf '(AMBIENT))
        (pushf '(OUTER))
        (pushf '(INNER))
        (pp.rt.scope:runtime-dynamic-replace-top-capability-frame!
         '(REPLACEMENT))
        (unless (equal (frames)
                       '((REPLACEMENT) (OUTER) (AMBIENT) NIL))
          (push (format nil "frame stack ~A" (frames)) failures))
        ;; Bracket-shaped pop peels exactly one frame.
        (pop (pp.rt.scope::runtime-dynamic-scope-capabilities
              (pp.rt.scope:runtime-dynamic-current)))
        (unless (equal (frames) '((OUTER) (AMBIENT) NIL))
          (push (format nil "after pop ~A" (frames)) failures))))
  (if failures
      (progn (dolist (f (nreverse failures))
               (format t "FAIL caps-frame-restore: ~A~%" f))
             (sb-ext:exit :code 1))
      (progn (format t "ok   caps-frame-restore~%")
             (sb-ext:exit :code 0))))
LISP

HOME="$TMP" "$SBCL" --noinform --disable-debugger --no-userinit \
  --load "$TMP/check.lisp" 2>&1 | grep -E "^ok |^FAIL"
exit "${PIPESTATUS[0]}"
