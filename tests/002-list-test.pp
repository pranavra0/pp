;; 002-list-test.pp
;; Test file for stdlib/list.pp
;; Must run without errors and produce expected output.

(load "stdlib/list.pp")

(print "=== 1. map ===")
(print "map +1 [1 2 3 4 5] =>" (map (fn (x) (+ x 1)) (list 1 2 3 4 5)))

(print "")
(print "=== 2. map is lazy (does not force unused elements) ===")
;; Only force the first element
(let [lazy-list (map (fn (x) (do (print "  computing" x) (* x 2)))
                     (list 10 20 30 40 50))]
  (print "first element:" (force (car lazy-list)))
  (print "(only one computing message should appear)"))

(print "")
(print "=== 3. filter ===")
(print "filter even? [1 2 3 4 5 6] =>"
       (filter (fn (x) (= (mod x 2) 0)) (list 1 2 3 4 5 6)))

(print "")
(print "=== 4. foldl ===")
(print "foldl + 0 [1 2 3 4 5] =>" (foldl + 0 (list 1 2 3 4 5)))
(print "foldl string-append \"\" [\"a\" \"b\" \"c\"] =>"
       (foldl string-append "" (list "a" "b" "c")))

(print "")
(print "=== 5. foldr ===")
(print "foldr cons nil [1 2 3] =>" (foldr cons nil (list 1 2 3)))

(print "")
(print "=== 6. range ===")
(print "take 5 (range 10 20) =>" (take 5 (range 10 20)))
(print "foldl + 0 (range 1 6) =>" (foldl + 0 (range 1 6)))

(print "")
(print "=== 7. length ===")
(print "length [1 2 3 4 5] =>" (length (list 1 2 3 4 5)))
(print "length nil =>" (length nil))

(print "")
(print "=== ALL TESTS PASSED ===")
