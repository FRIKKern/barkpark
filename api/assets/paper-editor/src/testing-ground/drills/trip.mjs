const text = (value) => ({ type: "text", value });
const para = (id, value) => ({ id, type: "paragraph", content: [text(value)] });

export const trip = [
  { id: "h-trip", type: "heading", level: 2, text: "Trip" },
  {
    id: "s-day",
    type: "section",
    title: "Day one",
    blocks: [
      para("p-day", "Left the car park at six."),
      { id: "co-ice", type: "callout", tone: "warning", content: [text("Ice on the north face.")] },
    ],
  },
  para("p-after", "Home by dark."),
];
