# stdlib/domain-fs.pp — filesystem-domain policy
#
# This is the POLICY half of the domain: what counts as
# create/update/delete and how a blob identity resolves to bytes,
# single-writer deletion. Trusted mechanics (atomic materialize/remove
# and whole-tree observation) live in the Lisp runtime providers and are
# Programs load this file after stdlib/list.pp, map.pp, and string.pp,
# then call `register-fs-domain` with ROOT and a write capability narrowed
# through `cap-restrict`.
#
# observe = perform tree-observe(root)   -> {relpath -> content-hash}
# desired = {:tree -> {relpath -> file descriptor}}
# diff    = create/update/delete by content hash, PURE — its only
# inputs are `observed`/`desired` plus `root` (captured
# lexically by register-fs-domain, not threaded as a diff
# argument — Q13's diff signature stays (observed, desired))
# apply   = materialize-file / remove-file per item

def fs-content-hash(c) {
  c[:blob]
}
def fs-content-bytes(c) {
  blob-get(c[:blob])
# ---- desired-path validation (relative, no traversal) ----
}
def fs-validate-rel-part(rel, part) {
  if part = ".." {
    error(string-append("reconcile: '..' not allowed in desired path: ", rel))
  }
}
def fs-validate-rel(rel) {
  if rel = "" { error("reconcile: empty path in desired tree") } else if starts-with?(rel, "/") {
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
    let (entries = desired[:tree]) {
    each(fs-validate-rel, map-keys(entries))
    let (dkeys = filter(fn(rel) { entries[rel][:kind] = :file }, map-keys(entries)), okeys = map-keys(observed), creates = filter(


fn(rel) { nil?(observed[rel]) }, dkeys), existing = filter(
fn(rel) { not(nil?(observed[rel])) }, dkeys), updates = filter(
fn(rel) {
      not(observed[rel] = fs-content-hash(entries[rel]))
    }, existing), deletes = filter(

fn(rel) { nil?(entries[rel]) }, okeys), items = append(map(

fn(rel) { fs-plan-item("create", rel, entries[rel]) }, creates), append(map(

fn(rel) { fs-plan-item("update", rel, entries[rel]) }, updates), map(
fn(rel) { fs-plan-item("delete", rel, nil) }, deletes)))) {
{:items -> items, :summary -> vec[vec[:root, root], vec[:create, number->string(length(creates))], vec[:update, number->string(length(updates))], vec[:delete, number->string(length(deletes))]]}
# A VECTOR of [key value] pairs, not a map — plan caching
# round-trips a cache MISS's result through the store, and
# the runtime's codec canonicalizes map entries while preserving
# vector order. A cache HIT must not reorder this or the
# "root=R create=C update=U delete=D" journal/print byte-compatibility
# breaks on exactly the passes that matter most (repeated/null reconciles).
    }}
  }
}


# ---- apply ----

def fs-apply-item(root, item) {
  let (kind = item[:kind], rel = item[:rel], path = string-append(root, "/", rel)) {
    if kind = "delete" { perform remove-file(path) } else {
      let (content = item[:content], bytes = fs-content-bytes(content)) {
        if content[:mode] = 493 {
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
