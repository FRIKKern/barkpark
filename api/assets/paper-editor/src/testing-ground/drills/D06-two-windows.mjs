const p = (id, value) => ({ id, type: "paragraph", content: [{ type: "text", value }] });

export default {
  id: "D06",
  title: "Two windows",
  windows: 2,
  doc: [p("p-a", "Window A types here."), p("p-b", "Window B edits here.")],
  steps: [
    { say: "In the top editor, type at the end of \"Window A types here.\"", hands: true },
    { say: "At the same time, in the bottom editor, type at the end of \"Window B edits here.\"", hands: true },
    { say: "Press Reload", reload: true },
  ],
  green: ["lost-keys", "fold-drift"],
};
