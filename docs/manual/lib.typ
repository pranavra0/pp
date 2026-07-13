// lib.typ — the manual's Typst helpers.
//
// The centrepiece is #example, which renders a Zig-reference-style block:
// a filename header, the example's SOURCE, the shell command, and the REAL
// captured output. Source comes straight from examples/<name>.pp; the command
// and output come from captured/<name>.{cmd,out}, which build.pp produces by
// actually running the example through pp. read() makes all three tracked
// dependencies, so a changed example (or a changed result) re-renders — and a
// broken example fails the build before it can reach a reader.

// #example("name")            — a pp example: examples/name.pp
// #example("name", sh: true)  — a shell transcript: examples/name.sh
#let example(name, sh: false) = {
  let ext = if sh { ".sh" } else { ".pp" }
  let lang = if sh { "bash" } else { "clojure" }
  let src = read("examples/" + name + ext).trim("\n", at: end)
  let out = read("captured/" + name + ".out").trim("\n", at: end)

  block(width: 100%, breakable: false, {
    // filename caption
    context {
      if target() == "html" {
        html.elem("div", attrs: (class: "ex-file"), name + ext)
      } else {
        block(fill: rgb("#fcdba5"), inset: (x: 8pt, y: 3pt), radius: (top: 4pt),
          text(font: "DejaVu Sans Mono", size: 8pt, weight: "bold", name + ext))
      }
    }
    // source
    raw(src, lang: lang, block: true)
    // for pp examples, echo the command line before the output
    if not sh {
      let cmd = read("captured/" + name + ".cmd").trim()
      context {
        if target() == "html" {
          html.elem("div", attrs: (class: "ex-shell"), "$ " + cmd)
        } else {
          block(inset: (y: 3pt), text(font: "DejaVu Sans Mono", size: 8.5pt,
            fill: luma(70))[\$ #cmd])
        }
      }
    }
    // captured output
    if out != "" {
      context {
        if target() == "html" {
          html.elem("pre", attrs: (class: "ex-out"), out)
        } else {
          block(fill: luma(247), inset: 8pt, width: 100%,
            text(font: "DejaVu Sans Mono", size: 8.5pt, raw(out)))
        }
      }
    }
  })
}
