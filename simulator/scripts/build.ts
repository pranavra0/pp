import { build } from "npm:esbuild@0.25.6";

await Deno.mkdir("site", { recursive: true });
await build({
  entryPoints: ["src/app.ts"],
  bundle: true,
  format: "esm",
  minify: true,
  sourcemap: true,
  outfile: "site/app.js",
  target: ["es2022"]
});
await Promise.all([
  Deno.copyFile("src/index.html", "site/index.html"),
  Deno.copyFile("src/style.css", "site/style.css"),
  Deno.copyFile("fixtures/local-build.jsonl", "site/local-build.jsonl")
]);
