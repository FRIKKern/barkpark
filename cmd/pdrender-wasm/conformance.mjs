import { MISSING, cli, diffFigureWords, diffTrackedEyebrow, diffWords, diffWordsSplitPunctuation, diffWordsUnordered, goldenWords, htmlText } from "../../api/priv/portable_doc/conformance/conformance.mjs";
import { loadRenderTUI } from "./load.mjs";

const render = await loadRenderTUI();

function judge(golden) {
  const text = htmlText(render(JSON.stringify({ blocks: [golden.input] }), 100, "light"));
  if (text.includes(`unknown block: ${golden.type}`)) return MISSING;
	const expected = goldenWords(golden.shape);
	if (new Set(["duel", "stat-grid", "stats"]).has(golden.type)) return diffWordsUnordered(text, expected);
	if (golden.type === "stat") return diffWordsSplitPunctuation(text, expected);
	if (golden.type === "lineage") return diffFigureWords(text, expected);
	if (golden.type === "eyebrow") return diffTrackedEyebrow(text, expected);
	return diffWords(text, expected);
}

await cli({ renderer: "pdrender-wasm", compare: "text", judge });
process.exit();
