const assert = (condition: unknown, message: string): void => { if (!condition) throw new Error(message); };

Deno.test("simulator controls and reduced motion have accessible text contracts", () => {
  const html = Deno.readTextFileSync("src/index.html");
  const css = Deno.readTextFileSync("src/style.css");
  for (const id of ["run", "run-scenario", "pause-run", "resume-run", "step-run", "stop-run", "export", "play", "step", "step-back"])
    assert(new RegExp(`<button id="${id}"[^>]*>[^<]+</button>`).test(html), `${id} lacks an accessible name`);
  for (const id of ["seek", "query", "topology"])
    assert(new RegExp(`id="${id}"[^>]*aria-label=`).test(html) || new RegExp(`aria-label=[^>]*id="${id}"`).test(html), `${id} lacks an aria label`);
  assert(html.includes('aria-live="polite"'), "run diagnostics are not announced");
  assert(css.includes("prefers-reduced-motion: reduce"), "reduced motion is not honored");
});
