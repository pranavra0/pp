// pp Reference Manual: the Typst source of truth.
//
// Typst source for the pp reference manual.

#import "lib.typ": example

#set document(title: "pp reference manual", author: "Pranav Rao")
#set heading(numbering: "1.1")
#set par(justify: true)
#set raw(syntaxes: "pp.sublime-syntax", theme: "/pp.tmTheme")

// HTML export: inline the stylesheet, dark-mode toggle, and script.
// read() makes style.css and dark-mode.js tracked dependencies, so a CSS or
// JS edit re-triggers the manual build.
#context {
  if target() == "html" {
    html.elem("style", read("style.css"))
    html.elem("div", attrs: (style: "display: contents;"), {
      html.elem("button", attrs: (id: "dm-toggle", title: "Toggle dark mode"), "")
    })
    html.elem("script", read("dark-mode.js"))
    html.elem("h1", "pp reference manual")
    html.elem("nav", attrs: (class: "site-nav"), {
      html.elem("a", attrs: (href: "index.html"), "pp")
      html.elem("a", attrs: (href: "manual.html"), "Manual")
    })
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
#include "chapters/05-foreign-execution.typ"
#include "chapters/06-capabilities.typ"
#include "chapters/07-modules-islands.typ"
#include "chapters/08-domains.typ"
#include "chapters/09-distribution.typ"
#include "chapters/10-engine.typ"
#include "chapters/A1-language-reference.typ"
#include "chapters/B-cli-reference.typ"
#include "chapters/C-stdlib-index.typ"
