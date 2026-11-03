export const journeys = [
  { id: "E01", title: "Type paragraph; saves", state: "available", artifact: "gif" },
  { id: "E02", title: "Enter splits, Backspace merges, across blocks", state: "available", artifact: "gif" },
  { id: "E03", title: "Paste rich text, Markdown, table; shape survives", state: "available", artifact: "before/after" },
  { id: "E04", title: "Undo/redo across blocks/pastes", state: "available", artifact: "gif" },
  { id: "E05", title: "[[link]] typed/pasted/aliased; title stays live", state: "available", artifact: "gif" },
  { id: "E06", title: "Slash menu inserts every block type", state: "available", artifact: "screenshot grid" },
  { id: "E07", title: "Remote edit arrives while I type; my keys win", state: "available", artifact: "gif" },
  { id: "E08", title: "Offline/reconnect pending edits flush", state: "available", artifact: "gif + op log" },
  { id: "E09", title: "Read=Edit same doc looks same reader/editor", state: "unavailable", reason: "awaiting TG2 sixth Read≠Edit light and known-red proof (task-53f2fc33b834114f)" },
  { id: "E10", title: "Phone width and dark mode", state: "available", artifact: "screenshots" },
  { id: "E11", title: "Pickers image/reference/card media", state: "available", appliesTo: "Studio hosts", artifact: "gif" },
  { id: "E12", title: "Upgrade no downtime; old clients still save", state: "conditional", reason: "requires --candidate=<verified staged editor directory>", artifact: "replay report" },
];
