// reader-tabs.js — the keyboard half of the reader's tab strips (task-df40f0527b20e4fb).
//
// compose.ex renders code-tabs and tabs as role=tablist / role=tab, and the reader hook
// (runCodeTabs / runTabs in layouts/bulldocs.html.heex) hydrates them: it hides the
// inactive panels, wires click-to-switch and stamps data-hydrated. The role promised
// more than that. This pass finishes the pattern on every HYDRATED strip:
//   * each tab names its panel (aria-controls), each panel is a labelled tabpanel;
//   * only the selected tab sits in the Tab order (roving tabindex), and Tab from it
//     moves into the panel;
//   * ArrowLeft / ArrowRight / Home / End move to a tab and select it.
// Selecting goes through the tab's own click, so the hook's logic (including the
// code-tabs sync-key that moves every block sharing a language) stays the one path.

let seq = 0;

export const TAB_KINDS = [
  { root: ".bp-code-tabs", tab: ".bp-code-tabs__tab", panel: ".bp-code-tabs__panel" },
  { root: ".bp-tabs", tab: ".bp-tabs__tab", panel: ".bp-tabs__panel" },
];

function syncRoving(tabs) {
  const selected = tabs.findIndex((t) => t.getAttribute("aria-selected") === "true");
  const keep = selected < 0 ? 0 : selected;
  tabs.forEach((t, i) => {
    t.tabIndex = i === keep ? 0 : -1;
  });
}

export function wireTabs(container, kind) {
  if (!container || container.dataset.tabsWired === "true") return false;
  const strip = container.querySelector('[role="tablist"]');
  const tabs = Array.from(container.querySelectorAll(kind.tab));
  const panels = Array.from(container.querySelectorAll(kind.panel));
  // compose.ex paints the strip and the panels from one list, in order; anything
  // else is not a strip this pass understands, so leave it as the hook made it.
  if (!strip || tabs.length === 0 || tabs.length !== panels.length) return false;

  const base = `bp-tabs-${++seq}`;
  tabs.forEach((tab, i) => {
    const panel = panels[i];
    if (!tab.id) tab.id = `${base}-tab-${i}`;
    if (!panel.id) panel.id = `${base}-panel-${i}`;
    tab.setAttribute("aria-controls", panel.id);
    panel.setAttribute("role", "tabpanel");
    panel.setAttribute("aria-labelledby", tab.id);
    // A code panel holds no control of its own; focusable so Tab lands on it
    // and a long line can be scrolled from the keyboard.
    panel.tabIndex = 0;
  });
  syncRoving(tabs);

  // A click (or a sync-key change from another block) moves aria-selected;
  // re-read it before the strip is used again.
  strip.addEventListener("click", () => syncRoving(tabs));
  strip.addEventListener("focusin", () => syncRoving(tabs));
  strip.addEventListener("keydown", (e) => {
    const from = tabs.indexOf(e.target && e.target.closest ? e.target.closest(kind.tab) : null);
    if (from < 0) return;
    const n = tabs.length;
    let to = null;
    if (e.key === "ArrowRight") to = (from + 1) % n;
    else if (e.key === "ArrowLeft") to = (from - 1 + n) % n;
    else if (e.key === "Home") to = 0;
    else if (e.key === "End") to = n - 1;
    if (to === null) return;
    e.preventDefault();
    tabs[to].click();
    syncRoving(tabs);
    tabs[to].focus();
  });

  container.dataset.tabsWired = "true";
  return true;
}

// Wire every hydrated, not-yet-wired strip under `root`. Returns how many it wired.
export function wireAllTabs(root) {
  const scope = root || (typeof document !== "undefined" ? document : null);
  if (!scope || !scope.querySelectorAll) return 0;
  let n = 0;
  for (const kind of TAB_KINDS) {
    const sel = `${kind.root}[data-hydrated="true"]:not([data-tabs-wired="true"])`;
    for (const container of Array.from(scope.querySelectorAll(sel))) {
      if (wireTabs(container, kind)) n++;
    }
  }
  return n;
}
