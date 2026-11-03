export const journeys = [
  { id: "E01", title: "Type paragraph; saves", state: "available", artifact: "gif" },
  { id: "E02", title: "Enter splits, Backspace merges, across blocks", state: "unavailable", reason: "cross-block scripted assertions are not implemented" },
  { id: "E03", title: "Paste rich text, Markdown, table; shape survives", state: "unavailable", reason: "clipboard fixture and shape assertions are not implemented" },
  { id: "E04", title: "Undo/redo across blocks/pastes", state: "unavailable", reason: "depends on the E03 paste fixture" },
  { id: "E05", title: "[[link]] typed/pasted/aliased; title stays live", state: "unavailable", reason: "live title resolver host stub is not implemented" },
  { id: "E06", title: "Slash menu inserts every block type", state: "unavailable", reason: "complete block-type insertion matrix is not implemented" },
  { id: "E07", title: "Remote edit arrives while I type; my keys win", state: "unavailable", reason: "two-window deterministic interleaving is not implemented" },
  { id: "E08", title: "Offline/reconnect pending edits flush", state: "unavailable", reason: "offline transport and op-log capture are not implemented" },
  { id: "E09", title: "Read=Edit same doc looks same reader/editor", state: "unavailable", reason: "awaiting TG2 sixth Read≠Edit light and known-red proof (task-53f2fc33b834114f)" },
  { id: "E10", title: "Phone width and dark mode", state: "available", artifact: "screenshots" },
  { id: "E11", title: "Pickers image/reference/card media", state: "unavailable", reason: "Studio picker host stubs are not implemented" },
  { id: "E12", title: "Upgrade no downtime; old clients still save", state: "unavailable", reason: "two-build replay report is not implemented" },
];
