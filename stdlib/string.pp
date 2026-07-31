# stdlib/string.pp — string utilities over the string primitives
# string-append, string-length, string-split, string-index, string-trim, string-sub,
# number->string, string->number are builtins. No dependencies.

# string-join(sep, lst) — join a list of strings with sep between elements
def string-join(sep, lst) {
  if nil?(lst) { "" } else if nil?(cdr(lst)) { string-append(car(lst)) } else {
    string-append(car(lst), sep, string-join(sep, cdr(lst)))
  }
}


# starts-with?(s, prefix)
def starts-with?(s, prefix) { string-index(s, prefix) = 0 }


# ends-with?(s, suffix)
def ends-with?(s, suffix) {
  let (sl = string-length(s), fl = string-length(suffix)) {
    if fl > sl { false } else { string-sub(s, sl - fl, fl) = suffix }
  }
}

def contains?(s, sub) { not(nil?(string-index(s, sub))) }
def string-repeat(s, n) {
  if n < 0 { error("string-repeat: count must not be negative") }
  else if n = 0 { "" } else { string-append(s, string-repeat(s, n - 1)) }
}
def string-replace(s, old, new) {
  if old = "" { error("string-replace: search string must not be empty") }
  else if nil?(string-index(s, old)) { s }
  else {
    let (i = string-index(s, old)) {
      string-append(string-sub(s, 0, i), new,
        string-replace(string-sub(s, i + string-length(old),
          string-length(s) - i - string-length(old)), old, new))
    }
  }
}

# lines removes only the terminal field introduced by a final newline.
def lines(s) {
  let (result = string-split(s, "\n")) {
    if ends-with?(s, "\n") { if nil?(result) { nil } else { take(length(result) - 1, result) } }
    else { result }
  }
}
