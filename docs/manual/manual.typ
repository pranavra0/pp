// pp Reference Manual — the Typst source of truth.
//
// Built by build.pp (pp building its own manual) into two artifacts:
//   • pp-manual.pdf   — typst -> PDF
//   • index.html      — typst --features html -> a single-page, Lua-manual-
//                       style site (numbered sections, a linked table of
//                       contents, anchored headings), with style.css inlined.
//
// Both fall out of ONE source: each chapter is #include-d below, and the
// build's depfile records exactly which chapters (and style.css) were read,
// so editing one chapter re-renders only what changed.

#import "lib.typ": example

#set document(title: "pp reference manual", author: "the pp project")
#set heading(numbering: "1.1")
#set par(justify: true)
#set raw(theme: "/pp.tmTheme")  // muted, Zig-like syntax colours

// HTML export: inline the stylesheet, dark-mode toggle, and script.
// read() makes style.css a tracked dependency, so a CSS edit re-triggers
// the manual build.
#context {
  if target() == "html" {
    html.elem("style", read("style.css"))
    html.elem("button", attrs: (id: "dm-toggle", title: "Toggle dark mode"), "")
    html.elem("script", ```
(function () {
  const root = document.documentElement;
  const btn = document.getElementById('dm-toggle');
  const stored = localStorage.getItem('pp-theme');
  const prefersDark = window.matchMedia('(prefers-color-scheme: dark)').matches;
  function setTheme(dark) {
    if (dark) {
      root.setAttribute('data-theme', 'dark');
    } else {
      root.removeAttribute('data-theme');
    }
    localStorage.setItem('pp-theme', dark ? 'dark' : 'light');
  }
  setTheme(stored ? stored === 'dark' : prefersDark);
  btn.addEventListener('click', function () {
    setTheme(root.getAttribute('data-theme') !== 'dark');
  });
})();
    ```)
    html.elem("h1", "pp reference manual")
  }
}

// PDF export: a simple title block.
#context {
  if target() != "html" {
    align(center)[
      #text(size: 24pt, weight: "bold")[pp reference manual]
      #v(0.3em)
      #text(size: 12pt, style: "italic")[a content-addressed, capability-scoped Lisp]
    ]
    v(2em)
  }
}

#outline(title: "Contents", depth: 3)

#include "chapters/01-introduction.typ"
#include "chapters/02-language.typ"
#include "chapters/03-nodes.typ"
#include "chapters/04-store-traces.typ"
#include "chapters/05-building.typ"
#include "chapters/06-capabilities.typ"
#include "chapters/07-modules-islands.typ"
#include "chapters/08-domains.typ"
#include "chapters/09-distribution.typ"
#include "chapters/10-backends.typ"
#include "chapters/A1-language-reference.typ"
#include "chapters/B-cli-reference.typ"
#include "chapters/C-stdlib-index.typ"
