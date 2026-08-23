// lib.typ: the manual's Typst helpers.
//
// a filename header, the example's source, the shell command, and the captured
// output. Source comes straight from examples/<name>.{pp,sh}; shell heredocs
// that contain pp source are rendered as separate pp blocks. The command and
// output come from captured/<name>.{cmd,out}, checked by actually running the
// example through pp. read() makes all three tracked dependencies, so a changed
// example (or a changed result) re-renders, and a broken example fails the build
// before it can reach a reader.

#let heredoc-start(line) = {
  let marker = line.match(regex("<<-?[\\\"']?([A-Za-z_][A-Za-z0-9_]*)[\\\"']?\\s*$"))
  if marker == none {
    return none
  }
  let delimiter = marker.captures.at(0)
  let pp = line.contains(".pp") or delimiter == "PP" or delimiter == "EOF"
  (delimiter: delimiter, pp: pp)
}

#let mixed-parts(src) = {
  let parts = ()
  let shell = ()
  let body = ()
  let mode = "shell"
  let delimiter = none
  for line in src.split("\n") {
    if mode == "shell" {
      let start = heredoc-start(line)
      if start != none and start.pp {
        shell.push(line)
        parts.push((lang: "bash", text: shell.join("\n")))
        shell = ()
        body = ()
        delimiter = start.delimiter
        mode = "pp"
      } else {
        shell.push(line)
      }
    } else {
      if line.trim() == delimiter {
        parts.push((lang: "pp", text: body.join("\n")))
        shell.push(line)
        mode = "shell"
        delimiter = none
      } else {
        body.push(line)
      }
    }
  }
  if shell.len() > 0 {
    parts.push((lang: "bash", text: shell.join("\n")))
  }
  parts
}

// #example("name"):            a pp example: examples/name.pp
// #example("name", sh: true):  a shell transcript: examples/name.sh
#let example(name, sh: false) = {
  let ext = if sh { ".sh" } else { ".pp" }
  let lang = if sh { "bash" } else { "pp" }
  let src = read("examples/" + name + ext).trim("\n", at: end)
  let out = read("captured/" + name + ".out").trim("\n", at: end)

  block(width: 100%, breakable: false, {
    context {
      if target() == "html" {
        html.elem("div", attrs: (class: "ex-file"), name + ext)
      } else {
        block(fill: rgb("#fcdba5"), inset: (x: 8pt, y: 3pt), radius: (top: 4pt),
          text(font: "DejaVu Sans Mono", size: 8pt, weight: "bold", name + ext))
      }
    }
    let parts = if sh {
      mixed-parts(src)
    } else {
      ((lang: lang, text: src),)
    }
    for part in parts {
      raw(part.text, lang: part.lang, block: true)
    }
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
