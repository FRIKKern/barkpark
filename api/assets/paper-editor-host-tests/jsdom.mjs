import { createRequire } from "node:module";

const requireFromPaperEditor = createRequire(
  new URL("../paper-editor/package.json", import.meta.url),
);

export const { JSDOM } = requireFromPaperEditor("jsdom");
