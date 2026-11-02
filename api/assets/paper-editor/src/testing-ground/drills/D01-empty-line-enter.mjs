const p = (id, value) => ({ id, type: "paragraph", content: value ? [{ type: "text", value }] : [] });

export default {
  id: "D01",
  title: "Empty-line Enter",
  doc: [p("p-a", "Alpha"), p("p-e", ""), p("p-b", "Beta")],
  steps: [
    { say: "Click the + in the margin under \"Alpha\" to open the empty line", button: "Edit empty paragraph" },
    { say: "Press Enter 6 times", key: "Enter", times: 6 },
    { say: "Type x", type: "x" },
    { say: "Press Backspace", key: "Backspace" },
    { say: "Press Reload", reload: true },
  ],
  green: ["hidden-blocks", "lost-keys"],
};
