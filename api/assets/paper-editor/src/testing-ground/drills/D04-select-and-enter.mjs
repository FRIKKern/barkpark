export default {
  id: "D04",
  title: "Select and Enter",
  doc: [{ id: "p-pack", type: "paragraph", content: [{ type: "text", value: "Pack the stove and the tent." }] }],
  steps: [
    { say: "Double-click the word \"stove\"", dblclick: { word: "stove" } },
    { say: "Press Enter", key: "Enter" },
  ],
  green: ["hidden-blocks"],
};
