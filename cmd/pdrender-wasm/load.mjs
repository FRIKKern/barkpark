import { readFileSync } from "node:fs";
import { gunzipSync } from "node:zlib";
import { join } from "node:path";
import { createRequire } from "node:module";
import vm from "node:vm";

export const repoRoot = join(import.meta.dirname, "..", "..");

export async function loadRenderTUI() {
  const sandbox = {
    globalThis: null,
    require: createRequire(import.meta.url),
    process,
    Buffer,
    TextEncoder,
    TextDecoder,
    crypto: globalThis.crypto,
    performance: globalThis.performance,
    console,
    WebAssembly,
    setTimeout,
    clearTimeout,
    setInterval,
    clearInterval,
  };
  sandbox.globalThis = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(readFileSync(join(repoRoot, "api/priv/static/assets/bp-wasm-exec.js"), "utf8"), sandbox, { filename: "bp-wasm-exec.js" });
  if (typeof sandbox.Go !== "function") throw new Error("bp-wasm-exec.js did not define Go");

  const go = new sandbox.Go();
  const wasm = gunzipSync(readFileSync(join(repoRoot, "api/priv/static/assets/bp-pdrender.wasm.gz")));
  const { instance } = await WebAssembly.instantiate(wasm, go.importObject);
  go.run(instance);
  for (let i = 0; i < 200; i++) {
    if (typeof sandbox.bpRenderTUI === "function") return sandbox.bpRenderTUI;
    await new Promise((r) => setTimeout(r, 10));
  }
  throw new Error("wasm did not export bpRenderTUI");
}
