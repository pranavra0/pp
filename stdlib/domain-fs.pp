# stdlib/domain-fs.pp — filesystem-domain policy
#
# This is the POLICY half of the domain: what counts as
# create/update/delete, how a `blob:<hash>` reference resolves to bytes,
# single-writer deletion. The TRUSTED MECHANICS (atomic materialize/remove,
# whole-tree observation) are OCaml primitives (src/runtime/domain_prims.ml),
# reached only via `perform`. main.ml's `--reconcile ROOT` auto-loads this
# file (after stdlib/list.pp, map.pp, string.pp) and calls
# `register-fs-domain` with ROOT and a write-cap already narrowed via
# `cap-restrict`.
#
# observe = perform tree-observe(root)   -> {relpath -> content-hash}
# desired = {relpath -> content}  (content: an inline string, or a
# "blob:<sha256>" / "blob:<sha256>:x" CAS reference from the
# `blob` primitive — :x materializes with the executable bit)
# diff    = create/update/delete by content hash, PURE — its only
# inputs are `observed`/`desired` plus `root` (captured
# lexically by register-fs-domain, not threaded as a diff
# argument — Q13's diff signature stays (observed, desired))
# apply   = materialize-file / remove-file per item

# ---- blob: reference parsing ----

def fs-blob-ref?(c) { starts-with?(c, "blob:") }

def fs-blob-ref-hash(c) {
  let (rest = string-sub(c, 5, string-length(c) - 5)) {
    if ends-with?(rest, ":x") { string-sub(rest, 0, string-length(rest) - 2) } else {
      rest
    }
  } }
def fs-blob-ref-executable?(c) {
  if fs-blob-ref?(c) { ends-with?(c, ":x") } else { false }
}
# A desired content's identity hash: a blob ref diffs BY HASH, without
# loading bytes (exit criterion 4 — `rm -rf build/` restores from the CAS
# with zero tool re-runs); inline content hashes its own bytes, the SAME
# algorithm (hash-string, SHA-256) `tree-observe` used to hash the file on
# disk, so the two sides of the diff compare like for like.
def fs-content-hash(c) {
  if fs-blob-ref?(c) { fs-blob-ref-hash(c) } else { hash-string(c) }
}
# Bytes are pulled from the store only when a write is actually needed
# (apply time), never during diff.
def fs-content-bytes(c) {
  if fs-blob-ref?(c) { blob-get(string-append("blob:", fs-blob-ref-hash(c))) } else {
    c
# ---- desired-path validation (relative, no traversal) ----
  } }
def fs-validate-rel-part(rel, part) {
  if part = ".." {
    error(string-append("reconcile: '..' not allowed in desired path: ", rel))
  }
}
def fs-validate-rel(rel) {
  if rel = "" { error("reconcile: empty path in desired map") } else if starts-with?(rel, "/") {
    error(string-append("reconcile: desired paths must be relative to the domain root: ", rel))
  } else {
    each(

fn(part) { fs-validate-rel-part(rel, part) }, string-split(rel, "/"))
  }
# ---- diff ----
}
def fs-plan-item(kind, rel, content) {
  {:kind -> kind, :rel -> rel, :content -> content}
}
# A closure over `root`: diff's PUBLIC shape stays (observed desired) ->
# plan (Q13), root is baked in at registration time, not passed at every
# call — this is what lets the plan's :summary include "root=" and still
# leaves diff free of any implicit ambient dependency (root is a plain
# lexical capture, like any other closed-over value).
def fs-diff-for(root) {
  fn(observed, desired) {
    each(fs-validate-rel, map-keys(desired))
    let (dkeys = map-keys(desired), okeys = map-keys(observed), creates = filter(


fn(rel) { nil?(observed[rel]) }, dkeys), existing = filter(
fn(rel) { not(nil?(observed[rel])) }, dkeys), updates = filter(
fn(rel) {
      not(observed[rel] = fs-content-hash(desired[rel]))
    }, existing), deletes = filter(

fn(rel) { nil?(desired[rel]) }, okeys), items = append(map(

fn(rel) { fs-plan-item("create", rel, desired[rel]) }, creates), append(map(

fn(rel) { fs-plan-item("update", rel, desired[rel]) }, updates), map(
fn(rel) { fs-plan-item("delete", rel, nil) }, deletes)))) {
{:items -> items, :summary -> vec[vec[:root, root], vec[:create, number->string(length(creates))], vec[:update, number->string(length(updates))], vec[:delete, number->string(length(deletes))]]}
# A VECTOR of [key value] pairs, not a map — plan caching
# round-trips a cache MISS's result through the store, and
# Codec's on-disk format canonicalizes (sorts) a VMap's entries
# but preserves a VVector's order (domains.ml), so a cache HIT
# must not be allowed to reorder this or the "root=R create=C
# update=U delete=D" journal/print byte-compatibility breaks on
# exactly the passes that matter most (repeated/null reconciles).
    }
  }
}


# ---- apply ----

def fs-apply-item(root, item) {
  let (kind = item[:kind], rel = item[:rel], path = string-append(root, "/", rel)) {
    if kind = "delete" { perform remove-file(path) } else {
      let (content = item[:content], bytes = fs-content-bytes(content)) {
        if fs-blob-ref-executable?(content) {
          perform materialize-file(path, bytes, :executable)
        } else { perform materialize-file(path, bytes) }
      }
    }
  }
}

def fs-apply-for(root) {
  fn(plan) { each(fn(item) { fs-apply-item(root, item) }, plan[:items])
  }
# ---- registration ----
}
def register-fs-domain(root, write-cap) {
  register-domain({:name -> "fs", :namespace -> vec[string-append("file:", root), string-append("tree:", root), string-append("stat:", root)], :observe -> (




fn() { perform tree-observe(root) }), :diff -> fs-diff-for(root), :apply -> fs-apply-for(root), :write-cap -> write-cap})
}
