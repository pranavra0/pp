await Deno.mkdir("site", { recursive: true });
await Promise.all([
  Deno.copyFile("src/index.html", "site/index.html"),
  Deno.copyFile("src/style.css", "site/style.css"),
  Deno.copyFile("fixtures/local-build.jsonl", "site/local-build.jsonl")
]);
