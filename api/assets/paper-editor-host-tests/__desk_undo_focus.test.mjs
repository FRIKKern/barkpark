// __desk_undo_focus.test.mjs — task-3fb0efdfc94a7ad6: a focus the user moves
// while the desk's undo is on its way stays where they put it, as TanStack's
// undo (done before the next key) leaves it. A press of a focus mode button
// keeps focus mode on with the focus on the pressed button; its patch comes
// after the answer, and nothing waits for it or leaves it. A focus moved into
// another control is never taken back, by the answer or later. With two
// undos on their way, both answers keep it. Focus mode on another pane
// already: the page is left as it is.
//
// Runs the TRACKED static asset api/priv/static/assets/bp-desk-undo.js under
// jsdom, on the page __desk_undo_page.mjs draws.
//
// Run: node ../paper-editor-host-tests/__desk_undo_focus.test.mjs
import assert from "node:assert/strict";
import { $, check, doc, done, key, later, undone } from "./__desk_undo_page.mjs";

const desk = $("desk-panes");
const TYPED = "Fixture post 14 X";
const BACK = { field: "doc[title]", value: "Fixture post 14", was: TYPED };

// A read-only pane beside the editor, with its focus mode button. A click is
// the server's `desk-focus`: the patch toggles the marks a round trip later.
function side(id) {
  const pane = doc.createElement("section");
  pane.id = id;
  pane.setAttribute("data-pane-index", "2");
  pane.innerHTML = `<header><button type="button" class="dk-focus" id="${id}-focus" aria-pressed="false">Focus</button></header>`;
  desk.appendChild(pane);
  const button = $(`${id}-focus`);
  const turns = [];
  button.addEventListener("click", () => {
    const on = !desk.hasAttribute("data-focus-mode");
    turns.push(on ? "enter" : "leave");
    setTimeout(() => {
      if (on) {
        desk.setAttribute("data-focus-mode", "true");
        pane.setAttribute("data-desk-focused", "true");
      } else {
        desk.removeAttribute("data-focus-mode");
        pane.removeAttribute("data-desk-focused");
      }
      button.setAttribute("aria-pressed", String(on));
    }, 20);
  });
  return { pane, button, turns };
}

// Every focus the title takes from here on.
function watchTitle() {
  const seen = [];
  const on = () => seen.push(true);
  $("title").addEventListener("focus", on);
  return { seen, stop: () => $("title").removeEventListener("focus", on) };
}

// The title typed in and focused; then every focus it takes is watched.
function typed() {
  $("title").value = TYPED;
  $("title").focus();
  return watchTitle();
}

function clean(pane, watch) {
  if (watch) watch.stop();
  desk.removeAttribute("data-focus-mode");
  if (pane) pane.remove();
  $("title").value = "Fixture post 14";
}

await check("a focus mode button pressed after Mod+Z: focus mode stays on, the focus on the pressed button", async () => {
  const { pane, button, turns } = side("side1");
  let watch;
  try {
    watch = typed();
    key($("title"), { key: "z", metaKey: true });
    button.focus();
    button.click();
    // The answer comes first, the focus mode patch after it.
    undone(BACK);
    assert.equal(doc.activeElement, button, "the pressed button keeps the focus");
    await later(80);
    assert.deepEqual(turns, ["enter"], "focus mode is not left");
    assert.equal(desk.hasAttribute("data-focus-mode"), true);
    assert.equal(doc.activeElement, button);
    assert.deepEqual(watch.seen, [], "the field never takes the focus");
    assert.equal($("title").value, TYPED, "the field it hides is not set: the server's render draws it");
  } finally {
    clean(pane, watch);
  }
});

await check("a press that does not focus the button (a click in Safari): the field the user is in takes the value, the focus stays", async () => {
  const { pane, button, turns } = side("side2");
  try {
    typed().stop();
    key($("title"), { key: "z", metaKey: true });
    button.click();
    undone(BACK);
    assert.equal(doc.activeElement, $("title"));
    assert.equal($("title").value, "Fixture post 14", "a patch leaves the focused input alone");
    await later(80);
    assert.deepEqual(turns, ["enter"]);
  } finally {
    clean(pane);
  }
});

await check("focus mode already on another pane when the answer comes: the page is left as it is", async () => {
  const { pane, button } = side("side3");
  pane.setAttribute("data-desk-focused", "true");
  desk.setAttribute("data-focus-mode", "true");
  try {
    button.focus();
    $("title").value = TYPED;
    undone(BACK);
    await later(30);
    assert.equal($("title").value, TYPED, "not set out of sight");
    assert.equal(doc.activeElement, button, "the focus stays");
    assert.equal(desk.hasAttribute("data-focus-mode"), true);
  } finally {
    clean(pane);
  }
});

await check("a focus moved to another control before the answer is never taken back", async () => {
  let watch;
  try {
    watch = typed();
    key($("title"), { key: "z", metaKey: true });
    $("search").focus();
    undone(BACK);
    assert.equal(doc.activeElement, $("search"));
    await later(50);
    assert.equal(doc.activeElement, $("search"), "nor later");
    assert.deepEqual(watch.seen, []);
  } finally {
    clean(null, watch);
  }
});

await check("two undos on their way and a focus mode press: neither answer takes the focus", async () => {
  const { pane, button, turns } = side("side4");
  let watch;
  try {
    watch = typed();
    key($("title"), { key: "z", metaKey: true });
    key($("title"), { key: "z", metaKey: true });
    button.focus();
    button.click();
    undone(BACK);
    undone({ field: "doc[excerpt]", value: "Short.", was: "Short. B" });
    assert.equal(doc.activeElement, button);
    await later(80);
    assert.deepEqual(turns, ["enter"]);
    assert.equal(doc.activeElement, button);
    assert.deepEqual(watch.seen, []);
  } finally {
    clean(pane, watch);
  }
});

await check("two undos on their way, the focus moved after the first answer: the second keeps it", async () => {
  try {
    typed().stop();
    key($("title"), { key: "z", metaKey: true });
    key($("title"), { key: "z", metaKey: true });
    $("excerpt").value = "Short. B";
    undone({ field: "doc[excerpt]", value: "Short.", was: "Short. B" });
    assert.equal(doc.activeElement, $("excerpt"), "the first answer, with nothing moved, takes the focus");
    $("search").focus();
    undone(BACK);
    assert.equal(doc.activeElement, $("search"));
  } finally {
    clean();
    $("excerpt").value = "Short.";
  }
});

await check("nothing moved: the answer takes the focus; and so does the next undo after a kept one", async () => {
  try {
    typed().stop();
    key($("title"), { key: "z", metaKey: true });
    $("search").focus();
    undone(BACK);
    assert.equal(doc.activeElement, $("search"));
    $("excerpt").value = "Short. B";
    $("title").focus();
    key($("title"), { key: "z", metaKey: true });
    undone({ field: "doc[excerpt]", value: "Short.", was: "Short. B" });
    assert.equal(doc.activeElement, $("excerpt"));
    assert.equal($("excerpt").value, "Short.");
  } finally {
    clean();
  }
});

await check("Mod+Z with nothing focused, then a click into the field the answer names: it takes the value", async () => {
  try {
    $("title").value = TYPED;
    $("title").blur();
    key(doc.body, { key: "z", metaKey: true });
    $("title").focus();
    undone(BACK);
    assert.equal(doc.activeElement, $("title"));
    assert.equal($("title").value, "Fixture post 14", "a patch leaves the focused input alone");
  } finally {
    clean();
  }
});

done("desk undo focus");
