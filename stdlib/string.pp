;; stdlib/string.pp — string utilities over the string primitives
;; (string-append/-length/-split/-index/-trim/-sub, number->string,
;; string->number are builtins). No dependencies.

;; (string-join sep lst) — join a list of strings with sep between elements
(def (string-join sep lst)
  (if (nil? lst)
      ""
      (if (nil? (cdr lst))
          (string-append (car lst))
          (string-append (car lst) sep (string-join sep (cdr lst))))))

;; (starts-with? s prefix)
(def (starts-with? s prefix)
  (= (string-index s prefix) 0))

;; (ends-with? s suffix)
(def (ends-with? s suffix)
  (let [sl (string-length s)
        fl (string-length suffix)]
    (if (> fl sl)
        false
        (= (string-sub s (- sl fl) fl) suffix))))

;; (lines s) — split into lines, dropping empty fields (trailing \n vanishes)
(def (lines s)
  (string-split s "\n"))
