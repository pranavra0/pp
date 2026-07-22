const runtimePath = new URL("../../_build/default/src/browser/pp_browser.bc.js", import.meta.url);
await import(runtimePath.href);

const run = (name, source) => JSON.parse(globalThis.ppBrowser.run(name, source));
const check = (condition, message) => { if (!condition) throw new Error(message); };

const brace = run("smoke.pp", "let twice = fn(x) { x * 2 }\ntwice(21)");
check(brace.ok && brace.output.endsWith("42"), "brace evaluation failed");
check(brace.result_hashes.at(-1) === "d98fba09338648079975ad61b2a3ca43cb3ddf4e2c36c7724f66aab333224012", "native/browser result hash changed");
const sexpr = run("smoke.ppl", "(let [twice (fn [x] (* x 2))] (twice 21))");
check(sexpr.ok && sexpr.result_hashes.at(-1) === brace.result_hashes.at(-1), "surface parity failed");
const macro = run("macro.pp", "defmacro unless(test, body) { quasiquote { if unquote(test) { nil } else { unquote(body) } } }\nunless(false, 42)");
check(macro.ok && macro.output.endsWith("42"), "macro expansion failed");
const effect = run("effect.pp", 'with { handlers: { :ask -> fn(question) { string-append(question, " 42") } } } { perform ask("answer:") }');
check(effect.ok && effect.output === '"answer: 42"', "effect handling failed");
const nonce = Date.now() % 1_000_000_000;
const nodeSource = `force(node { 40 + 2 + ${nonce} - ${nonce} })`;
const cold = run("node.pp", nodeSource);
const warm = run("node.pp", nodeSource);
check(cold.ok && cold.events.includes('"cache.miss"'), "cold node did not miss");
check(warm.ok && warm.events.includes('"cache.hit"'), "warm node did not hit");
check(cold.result_hashes.at(-1) === warm.result_hashes.at(-1), "node result changed");
const invalid = run("bad.pp", "unknown-name");
check(!invalid.ok && invalid.events.includes('"run.failed"'), "failure diagnostics missing");
check(brace.host_services.filesystem === "virtual" && brace.host_services.process === "unavailable" && brace.host_services.network === "unavailable", "browser service boundary changed");
console.log("browser runtime smoke passed");
