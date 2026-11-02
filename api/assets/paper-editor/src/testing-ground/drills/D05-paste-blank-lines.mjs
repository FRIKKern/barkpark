const p = (id, value) => ({ id, type: "paragraph", content: [{ type: "text", value }] });

export default {
  id: "D05",
  title: "Paste blank lines",
  doc: [p("p-a", "Alpha"), p("p-b", "Beta")],
  steps: [
    { say: "Click at the end of \"Alpha\"", click: { text: "Alpha", at: "end" } },
    { say: "Paste a line, three empty lines and a line", paste: { html: "<p>One</p><p></p><p></p><p></p><p>Two</p>" } },
  ],
  green: ["hidden-blocks"],
};
