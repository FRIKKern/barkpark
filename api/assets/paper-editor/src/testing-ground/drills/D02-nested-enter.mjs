import { trip } from "./trip.mjs";

export default {
  id: "D02",
  title: "Nested Enter",
  doc: trip,
  steps: [
    { say: "Click at the end of \"Left the car park at six.\"", click: { text: "Left the car park at six.", at: "end" } },
    { say: "Press Enter", key: "Enter" },
    { say: "Type \"Fog by eight.\"", type: "Fog by eight." },
    { say: "Press Reload", reload: true },
  ],
  green: ["duplicate-ids", "refused-batches", "lost-keys"],
};
