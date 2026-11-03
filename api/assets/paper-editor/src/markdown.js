// Public Markdown conversion surface. The implementation stays dependency-free;
// it is split by direction so no source file becomes a second editor god file.
export { blocksToMarkdown } from "./markdown/serialize.js";
export { markdownToBlocks, markdownToBlockSpans } from "./markdown/parse.js";
