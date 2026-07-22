import { exportBundle, runScenario } from "./src/lab.ts";
import { decodeScenario } from "./src/scenario.ts";

const [command, path, output] = Deno.args;
if (!command || !path) throw new Error("usage: deno task lab validate|run|bundle SCENARIO [OUTPUT]");
const text = await Deno.readTextFile(path);
if (command === "validate") console.log(JSON.stringify(decodeScenario(text), null, 2));
else {
  const result = await runScenario(text, Deno.env.get("PP") ?? "pp");
  if (command === "run") console.log(JSON.stringify({ status: result.status, assertions: result.assertions, metrics: result.metrics }, null, 2));
  else if (command === "bundle") {
    if (!output) throw new Error("bundle requires an output path"); await Deno.writeTextFile(output, exportBundle(result));
  } else throw new Error(`unknown lab command ${command}`);
  if (result.status !== 0 || result.assertions.some((assertion) => !assertion.passed)) Deno.exit(1);
}
