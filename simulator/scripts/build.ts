await Deno.mkdir("site", { recursive: true });
try { await Deno.remove("site/pp-browser.js"); }
catch (error) { if (!(error instanceof Deno.errors.NotFound)) throw error; }
await Promise.all([
  Deno.copyFile("src/index.html", "site/index.html"),
  Deno.copyFile("src/style.css", "site/style.css"),
  Deno.copyFile("fixtures/local-build.jsonl", "site/local-build.jsonl"),
  Deno.copyFile("../_build/default/src/browser/pp_browser.bc.js", "site/pp-browser.js")
]);
