;; Quotation is total: any form becomes data. Quasiquote (`) with unquote (,)
;; and unquote-splicing (,@) build structure with holes.
(print '(if a b c))
(print `(1 ,(+ 1 1) ,@(list 3 4)))
