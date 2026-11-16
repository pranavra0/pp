# stdlib/path.pp — absolute-path?, path-basename, path-dirname, path-extension,
# path-stem, path-join, path-normalize. Pure lexical operations.
# Load stdlib/list.pp and stdlib/string.pp first.

def absolute-path?(p) { starts-with?(p, "/") }
def path-basename(p) {
  let (parts = filter(fn(x) { not(x = "") }, string-split(p, "/"))) {
    if nil?(parts) { if absolute-path?(p) { "/" } else { "" } }
    else { nth(length(parts) - 1, parts) }
  }
}
def path-dirname(p) {
  let (parts = filter(fn(x) { not(x = "") }, string-split(p, "/")), n = length(parts)) {
    if n = 0 { if absolute-path?(p) { "/" } else { "." } }
    else if n = 1 { if absolute-path?(p) { "/" } else { "." } }
    else { let (body = string-join("/", take(n - 1, parts))) { if absolute-path?(p) { string-append("/", body) } else { body } } }
  }
}
def path-extension(p) {
  let (parts = reverse(string-split(path-basename(p), "."))) {
    if any?(fn(part) { not(part = "") }, cdr(parts)) {
      string-append(".", car(parts))
    } else { "" }
  }
}
def path-stem(p) {
  let (base = path-basename(p), ext = path-extension(p)) {
    if ext = "" { base } else { string-sub(base, 0, string-length(base) - string-length(ext)) }
  }
}
def path-join(a, b) {
  if absolute-path?(b) { error("path-join: later segment must be relative") }
  else if a = "" { b } else { path-normalize(string-append(a, "/", b)) }
}
def path-normalize(p) {
  if not(nil?(string-index(p, "\000"))) { error("path-normalize: NUL is not allowed") }
  else { path-normalize-parts(absolute-path?(p), string-split(p, "/"), nil) }
}
def path-normalize-parts(abs, parts, stack) {
  if nil?(parts) {
    let (body = string-join("/", reverse(stack))) { if abs { string-append("/", body) } else if body = "" { "." } else { body } }
  } else {
    let (part = car(parts)) {
      if part = "" or part = "." { path-normalize-parts(abs, cdr(parts), stack) }
      else if part = ".." {
        if nil?(stack) { if abs { path-normalize-parts(abs, cdr(parts), stack) } else { error("path-normalize: relative path escapes root") } }
        else { path-normalize-parts(abs, cdr(parts), cdr(stack)) }
      } else { path-normalize-parts(abs, cdr(parts), cons(part, stack)) }
    }
  }
}
