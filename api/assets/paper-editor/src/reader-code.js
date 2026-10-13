// reader-code.js → /assets/bp-paper-code.js — syntax highlighting on the `/papers` reader, from THE
// tokenizer the canvas uses (code-highlight.js). The server renders a code block as
// `<pre data-lang="…">escaped source</pre>`; this pass paints hljs-* tokens inside it, once, and keeps
// painting blocks LiveView swaps in later. Exposes `window.BarkparkPaperCode` so a test or another
// surface can run the same pass on a detached document (the parity row does, in jsdom).
import { highlightHtml, highlightPre, tokenSignature, resolveLang, languages } from "./code-highlight.js";
// The same asset finishes the reader's tab strips once the hook hydrates them.
import { wireAllTabs } from "./reader-tabs.js";

function run(root) {
  const scope = root || (typeof document !== "undefined" ? document : null);
  if (!scope || !scope.querySelectorAll) return 0;
  let n = 0;
  for (const pre of Array.from(scope.querySelectorAll("pre[data-lang]:not([data-hl])"))) if (highlightPre(pre)) n++;
  return n;
}

const api = { highlightHtml, highlightPre, tokenSignature, resolveLang, languages, run, wireAllTabs };
if (typeof window !== "undefined") {
  window.BarkparkPaperCode = api;
  const start = () => {
    run(document);
    wireAllTabs(document);
    // LiveView patches and the edit toggle swap blocks in later; paint those too, once each.
    // The hook stamps data-hydrated on a tab strip without adding nodes, so watch that
    // attribute too: this deferred script and the hook can run in either order.
    if (typeof MutationObserver !== "undefined" && document.body) {
      const mo = new MutationObserver(() => {
        run(document);
        wireAllTabs(document);
      });
      mo.observe(document.body, {
        childList: true,
        subtree: true,
        attributes: true,
        attributeFilter: ["data-hydrated"],
      });
    }
  };
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", start);
  else start();
}
export default api;
