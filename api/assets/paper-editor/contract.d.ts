// Types for @barkpark/paper-editor/contract (dist/contract.js, a copy of src/contract.js).
// The module has no imports and no DOM access, so it loads in Node and in a browser.

/** The embed contract version. EMBED-CONTRACT.md describes this version. */
export const CONTRACT_VERSION: string;
/** Milliseconds between the last keystroke and the `bp-op` / `bp-canvas-ops` event. */
export const DEBOUNCE_MS: number;
export const PLACEHOLDER: {
  paragraph: string;
  heading: (level?: number) => string;
  title: string;
  eyebrow: string;
  byline: string;
  ingress: string;
  pullquote: string;
  blockquote: string;
};
export function configControlHidden(state?: { value?: unknown; hovered?: boolean; focused?: boolean }): boolean;
