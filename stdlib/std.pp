# pp Standard Library
# --------------------------------------------------------
# Evaluation transparency law:
#   All library functions operate on realized values.
#   No library function may observe thunk identity.
#   Derivations are never auto-forced.
#   Equality is semantic (structural), not operational (pointer).
#   type-of is the single reflection system.
#   if is the single privileged control form.
#
# Primitive core (13): int-add int-sub int-mul int-div int-cmp
#                      str-append str-length int-to-str str-to-int
#                      eq? type-of error
#                      exec realize
# --------------------------------------------------------

# === SECTION 1: Foundational - the semantic substrate ===

# -- Booleans --
# true/false are pre-bound sentinel records. type-of returns :true/:false.

not := \x. if (eq? x true) false true;
and := \a. \b. if a b false;
or  := \a. \b. if a true b;

# -- Type predicates (derived entirely from type-of) --
# No .tag field inspection anywhere in library code.

is-int        := \x. eq? (type-of x) :int;
is-str        := \x. eq? (type-of x) :str;
is-symbol     := \x. eq? (type-of x) :symbol;
is-record     := \x. eq? (type-of x) :record;
is-fn         := \x. eq? (type-of x) :fn;
is-derivation := \x. eq? (type-of x) :derivation;
is-error      := \x. eq? (type-of x) :error;

is-true  := \x. eq? (type-of x) :true;
is-false := \x. eq? (type-of x) :false;
is-nil   := \x. eq? (type-of x) :nil;
is-cons  := \x. eq? (type-of x) :cons;

# -- Comparison (derived from int-cmp) --

lt := \a. \b. eq? (int-cmp a b) -1;
gt := \a. \b. eq? (int-cmp a b) 1;
le := \a. \b. not (gt a b);
ge := \a. \b. not (lt a b);
ne := \a. \b. not (eq? a b);

# -- Arithmetic utilities --

negate := \x. int-sub 0 x;
abs := \x. if (lt x 0) (negate x) x;

# -- Error handling --
# error is the single primitive. Propagation is automatic (NaN model).

err-type     := \msg. error :type msg;
err-runtime  := \msg. error :runtime msg;
err-notfound := \msg. error :not-found msg;
err-name     := \msg. error :name msg;

# -- Strings --

str-len := \s. str-length s;

# -- Lists (tagged records, cons/nil foundation) --
# [1, 2, 3] syntax desugars to cons 1 (cons 2 (cons 3 nil)).

cons := \h. \t. { tag = :cons; head = h; tail = t; };

head := \xs.
    if (is-cons xs) xs.head (err-type "head of non-list");

tail := \xs.
    if (is-cons xs) xs.tail (err-type "tail of non-list");

# -- Higher-order list operations --

map := \f. \xs.
    if (is-nil xs) nil (cons (f (head xs)) (map f (tail xs)));

foldl := \f. \acc. \xs.
    if (is-nil xs) acc (foldl f (f acc (head xs)) (tail xs));

foldr := \f. \acc. \xs.
    if (is-nil xs) acc (f (head xs) (foldr f acc (tail xs)));

filter := \pred. \xs.
    if (is-nil xs) nil
        (if (pred (head xs))
            (cons (head xs) (filter pred (tail xs)))
            (filter pred (tail xs)));

sum     := foldl int-add 0;
product := foldl int-mul 1;

any := \pred. \xs.
    if (is-nil xs) false
        (if (pred (head xs)) true (any pred (tail xs)));

all := \pred. \xs.
    if (is-nil xs) true
        (if (pred (head xs)) (all pred (tail xs)) false);

# -- Function combinators --

id := \x. x;
const := \x. \y. x;
flip := \f. \x. \y. f y x;
compose := \f. \g. \x. f (g x);

# Fixed-point combinator (lazy Y)
Y := \f. (\x. f (x x)) (\x. f (x x));

# === SECTION 2: Convenience (derived, NOT foundational) ===

# -- List utilities --

member? := \x. \xs.
    if (is-nil xs) false
        (if (eq? (head xs) x) true (member? x (tail xs)));

length := \xs.
    if (is-nil xs) 0 (int-add 1 (length (tail xs)));

reverse := foldl (flip cons) nil;

take := \n. \xs.
    if (or (eq? n 0) (is-nil xs)) nil
        (cons (head xs) (take (int-sub n 1) (tail xs)));

drop := \n. \xs.
    if (or (eq? n 0) (is-nil xs)) xs
        (drop (int-sub n 1) (tail xs));

zip := \xs. \ys.
    if (or (is-nil xs) (is-nil ys)) nil
        (cons (cons (head xs) (cons (head ys) nil))
              (zip (tail xs) (tail ys)));

replicate := \n. \x.
    if (eq? n 0) nil (cons x (replicate (int-sub n 1) x));

range := \lo. \hi.
    if (ge lo hi) nil (cons lo (range (int-add lo 1) hi));

# -- Result type (user-level ADT convention) --

ok   := \v.   { tag = :ok;   value = v; };
fail := \k. \m. { tag = :fail; kind = k; message = m; };

# -- Derivation helpers --

import := \path.
    realize (exec { kind = :import; path = path; });

wasm-run := \module. \inputs. \args. \outputs.
    realize (exec {
        kind = :wasm;
        module = module;
        inputs = inputs;
        args = args;
        outputs = outputs;
    });
