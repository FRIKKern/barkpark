import { createRequire } from "node:module";
import { join } from "node:path";
import { primaryJs } from "./server.mjs";

export async function chromium() {
  const from = process.env.BP_PLAYWRIGHT_FROM || join(primaryJs(), "package.json");
  let playwright;
  try {
    playwright = createRequire(from)("playwright");
  } catch {
    throw new Error(`playwright not found from ${from} (set BP_PLAYWRIGHT_FROM)`);
  }
  return playwright.chromium.launch();
}
