;; stdlib/list.pp — basic list operation library

;; NOTE: `map` is intentionally NOT defined here. It is a BUILTIN
;; (src/primitives.ml) as of Phase 3, and the builtin is the batching
;; fan-out point the parallel scheduler collects on: it applies f via the
;; apply hook and conses the results WITHOUT forcing them, so a list of
;; (node ...) elements stays unforced until force-deep dispatches the whole
;; batch. A pp-level `(def (map f lst) (cons (f (car lst)) ...))` here would
;; SHADOW the builtin and — because application is strict (Q1: EApply forces
;; every argument, so cons's `(f (car lst))` argument is forced inline) —
;; force each element one at a time, silently defeating parallel/remote
;; batching for any program that loads this file (e.g. every --reconcile
;; build, which auto-loads it for the domain libraries). Do not re-add it.

;; (filter pred lst) — return a lazy list of elements satisfying pred
(def (filter pred lst)
  (if (nil? lst)
      nil
      (if (pred (car lst))
          (cons (car lst) (filter pred (cdr lst)))
          (filter pred (cdr lst)))))

;; (foldl f acc lst) — left fold (strict in the accumulator)
;;   (foldl + 0 (list 1 2 3))  =>  ((0 + 1) + 2) + 3 = 6
(def (foldl f acc lst)
  (if (nil? lst)
      acc
      (foldl f (f acc (car lst)) (cdr lst))))

;; (foldr f acc lst) — right fold (lazy)
;;   (foldr cons nil (list 1 2 3))  =>  (1 . (2 . (3 . nil)))  =  (1 2 3)
(def (foldr f acc lst)
  (if (nil? lst)
      acc
      (f (car lst) (foldr f acc (cdr lst)))))

;; (range start end) — generate numbers from start (inclusive) to end (exclusive)
(def (range start end)
  (if (>= start end)
      nil
      (cons start (range (+ start 1) end))))

;; (take n lst) — take first n elements of lst
(def (take n lst)
  (if (or (nil? lst) (= n 0))
      nil
      (cons (car lst) (take (- n 1) (cdr lst)))))

;; (length lst) — count elements in lst (strict: forces the whole list)
(def (length lst)
  (if (nil? lst)
      0
      (+ 1 (length (cdr lst)))))

;; (each f lst) — apply f to each element for its effects, return nil
(def (each f lst)
  (if (nil? lst)
      nil
      (do (f (car lst)) (each f (cdr lst)))))

;; (append a b) — concatenate two lists (lazy in b)
(def (append a b)
  (if (nil? a)
      b
      (cons (car a) (append (cdr a) b))))

;; (reverse lst) — strict reversal
(def (reverse lst)
  (foldl (fn (acc x) (cons x acc)) nil lst))

;; (nth n lst) — zero-based element access; nil past the end
(def (nth n lst)
  (if (nil? lst)
      nil
      (if (= n 0) (car lst) (nth (- n 1) (cdr lst)))))

;; (drop n lst) — lst without its first n elements
(def (drop n lst)
  (if (or (nil? lst) (= n 0))
      lst
      (drop (- n 1) (cdr lst))))

;; (member? x lst) — structural membership
(def (member? x lst)
  (if (nil? lst)
      false
      (if (= x (car lst)) true (member? x (cdr lst)))))
