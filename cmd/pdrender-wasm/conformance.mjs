import { MISSING, cli, diffWords, goldenWords } from "../../api/priv/portable_doc/conformance/conformance.mjs";
import { loadRenderTUI } from "./load.mjs";

const render = await loadRenderTUI();

const textOf = (html) => html.replace(/<[^>]*>/g, "").replaceAll("&lt;", "<").replaceAll("&gt;", ">").replaceAll("&amp;", "&");

function judge(golden) {
  const text = textOf(render(JSON.stringify({ blocks: [golden.input] }), 100, "light"));
  if (text.includes(`unknown block: ${golden.type}`)) return MISSING;
  return diffWords(text, goldenWords(golden.shape));
}

await cli({ renderer: "pdrender-wasm", compare: "text", judge });
process.exit();
