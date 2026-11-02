const p = (id, value) => ({ id, type: "paragraph", content: value ? [{ type: "text", value }] : [] });

export default {
  id: "D07",
  title: "ArrowDown into a hidden empty line",
  doc: [p("p-a", "Alpha"), p("p-e", ""), p("p-b", "Beta")],
  steps: [
    { say: "Click at the end of \"Alpha\"", click: { text: "Alpha", at: "end" } },
    { say: "Press ↓ once; the caret should land on the empty line", key: "ArrowDown" },
  ],
  repeat: 8,
  tally: { from: "p-a", to: "p-e" },
  green: [],
};
