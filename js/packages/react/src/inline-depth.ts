/* Inline nesting past the depth limit keeps its words (task-11bbe4b4ae8c85f4).
 *
 * The rule every Barkpark reader shares (render/inline_depth.ex,
 * internal/pdrender/inline_depth.go, apps/mobile inlines.tsx and the editor's
 * canvas/inline-depth.js):
 *
 *  - A wrapper (a node holding `children`, or a bare list) is drawn while its
 *    inline depth is under MAX_DEPTH (100). A text at depth d with k marks draws
 *    all of them when d + k <= 100.
 *  - A wrapper at depth 100 or deeper is not drawn. The words under it are, flat
 *    and in order, then one space and the notice. A text with more marks than fit
 *    draws the marks that fit, then the notice.
 *  - The words are read by a loop, never by recursion, down to inline depth
 *    MAX_WORD_DEPTH (1000). Words deeper than that are not read; the notice still
 *    follows, so a document of any depth draws without a crash.
 *
 * The walk itself (cutInline) and the marks cut (cutMarks) live in inline.tsx,
 * beside the leaf helpers they reuse: they ship in the PortableDoc client, RSC
 * server and subpath bundles, each under a byte budget (.size-limit.json).
 */

export const MAX_WORD_DEPTH = 1000
