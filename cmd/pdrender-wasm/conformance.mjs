import { MISSING, cli, columnMajorText, columnWiseText, diffEquation, diffFigureWords, diffTabSections, diffTrackedEyebrow, diffWords, diffWordsSplitPunctuation, diffWordsUnordered, goldenWords, htmlText, loadPack, pdrenderStructuralVerdict, tabPanelWords } from "../../api/priv/portable_doc/conformance/conformance.mjs";
import { loadRenderTUI } from "./load.mjs";

const render = await loadRenderTUI();

function judge(golden) {
  const text = htmlText(render(JSON.stringify({ blocks: [golden.input] }), 100, "light"));
  if (text.includes(`unknown block: ${golden.type}`)) return MISSING;
  const structural = pdrenderStructuralVerdict(golden, text);
  if (structural) return structural;
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

function assertStructuralMutants() {
  const cases = new Map(loadPack().cases.filter(({ type }) => ["divider", "image", "video"].includes(type)).map((golden) => [golden.type, golden]));
  const verdict = (type, actualText, renderedInput) => {
    const golden = cases.get(type);
    if (!golden) throw new Error(`structural self-test: golden pack missing ${type}`);
    return pdrenderStructuralVerdict(golden, actualText, renderedInput ?? golden.input);
  };
  const renderText = (input) => htmlText(render(JSON.stringify({ blocks: [input] }), 100, "light"));

  for (const type of ["divider", "image", "video"]) {
    const golden = cases.get(type);
    if (!golden || verdict(type, renderText(golden.input), golden.input)?.diff.length !== 0) {
      throw new Error(`structural self-test: canonical ${type} did not pass`);
    }
    if (verdict(type, "", golden.input)?.diff.length === 0) throw new Error(`structural self-test: empty ${type} text passed`);
  }

  if (verdict("divider", "§")?.diff.length === 0) throw new Error("structural self-test: divider without rule passed");
  const image = cases.get("image");
  const wrongImage = { ...image.input, src: "https://cdn.example.com/wrong.png" };
  if (verdict("image", renderText(wrongImage), wrongImage)?.diff.length === 0) throw new Error("structural self-test: wrong image source passed");
  const video = cases.get("video");
  const videoText = renderText(video.input).replaceAll("open in browser", "");
  if (verdict("video", videoText, video.input)?.diff.length === 0) throw new Error("structural self-test: video without handoff label passed");
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

assertStructuralMutants();
await cli({ renderer: "pdrender-wasm", compare: "text", judge });
process.exit();
