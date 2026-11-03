import { MISSING, cli, columnMajorText, columnWiseText, diffEquation, diffFigureWords, diffTabSections, diffTrackedEyebrow, diffWords, diffWordsSplitPunctuation, diffWordsUnordered, goldenWords, htmlText, tabPanelWords } from "../../api/priv/portable_doc/conformance/conformance.mjs";
import { loadRenderTUI } from "./load.mjs";

const render = await loadRenderTUI();

function judge(golden) {
  const text = htmlText(render(JSON.stringify({ blocks: [golden.input] }), 100, "light"));
  if (text.includes(`unknown block: ${golden.type}`)) return MISSING;
  const expected = goldenWords(golden.shape);
  if (golden.type === "duel") return [...diffWordsUnordered(text, expected), ...duelAssociationDiff(text, golden.input)];
  if (golden.type === "stat-grid" || golden.type === "stats") return diffFigureWords(columnMajorText(text), expected);
  if (golden.type === "columns") return diffWords(columnWiseText(text), expected);
  if (golden.type === "code-tabs" || golden.type === "tabs") {
    return diffTabSections(text, (golden.input.tabs || []).map((tab) => String(tab.label || "").trim()), tabPanelWords(golden.shape));
  }
  if (golden.type === "equation") return diffEquation(text, expected);
  if (golden.type === "stat") return diffWordsSplitPunctuation(text, expected);
  if (golden.type === "lineage") return diffFigureWords(text, expected);
  if (golden.type === "eyebrow") return diffTrackedEyebrow(text, expected);
  return diffWords(text, expected);
}

function duelAssociationDiff(text, input) {
  const lines = text.split("\n");
  return (input.rows || []).flatMap((row, i) => {
    const label = String(row.label || "").trim();
    const valueA = String(row.valueA || "").trim();
    const valueB = String(row.valueB || "").trim();
    const unit = String(row.unit || "").trim();
    const expected = `${label} ${valueA}${unit ? ` ${unit}` : ""} vs ${valueB}${unit ? ` ${unit}` : ""}`.replace(/\s+/g, " ").trim();
    if (!label || lines.some((line) => line.replace(/\s+/g, " ").trim() === expected)) return [];
    return [`row ${i + 1} "${label}" is not associated with values "${valueA}" and "${valueB}"`];
  });
}

await cli({ renderer: "pdrender-wasm", compare: "text", judge });
process.exit();
