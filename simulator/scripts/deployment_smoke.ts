const required = ["index.html", "style.css", "app.js", "pp-browser.js", "local-build.jsonl"];
for (const name of required) {
  const info = await Deno.stat(`site/${name}`);
  if (!info.isFile || info.size === 0) throw new Error(`deployment artifact ${name} is missing or empty`);
}
const html = await Deno.readTextFile("site/index.html");
for (const reference of ["style.css", "pp-browser.js", "app.js", "../"]) if (!html.includes(reference)) throw new Error(`deployment index omits ${reference}`);
const javascript = await Deno.readTextFile("site/app.js");
if (!javascript.includes("ppBrowser") || !javascript.includes("run-scenario")) throw new Error("deployment bundle omits playground or controller controls");
console.log("simulator deployment smoke passed");
