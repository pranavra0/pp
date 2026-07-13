;; `delay` builds a thunk that has not run yet; `force` runs it, and the
;; result is memoized — the work happens at most once.
(let [t (delay (do (print "working") (* 100 200)))]
  (print (force t))    ; prints "working", then 20000
  (print (force t)))   ; prints 20000 — no re-run
