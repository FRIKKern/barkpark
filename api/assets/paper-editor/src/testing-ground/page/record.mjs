const WINDOW = 5 * 60 * 1000;
const MODIFIERS = new Set(["Shift", "Control", "Alt", "Meta"]);

const combo = (event) => [event.ctrlKey && "Control", event.altKey && "Alt", event.metaKey && "Meta", event.shiftKey && event.key.length > 1 && "Shift", event.key].filter(Boolean).join("+");

function caretOf(canvas) {
  const { $from } = canvas._editor.state.selection;
  return { id: $from.parent.attrs.bpId, offset: $from.parentOffset };
}

export function recorder(root, canvases, now = () => performance.now()) {
  const events = [];
  let clicked = null;
  const push = (event) => {
    events.push({ t: Math.round(now()), ...event });
    while (events[0].t < events.at(-1).t - WINDOW) events.shift();
  };
  const note = (event) => {
    if (clicked) push({ kind: "caret", ...caretOf(clicked) });
    clicked = null;
    push(event);
  };
  root.addEventListener("keydown", (event) => {
    if (MODIFIERS.has(event.key)) return;
    if (event.key.length > 1 || event.metaKey || event.ctrlKey || event.altKey) note({ kind: "key", key: combo(event) });
  }, true);
  root.addEventListener("beforeinput", (event) => {
    if (event.inputType === "insertText") note({ kind: "type", text: event.data });
  }, true);
  root.addEventListener("paste", (event) => {
    note({ kind: "paste", html: event.clipboardData.getData("text/html"), text: event.clipboardData.getData("text/plain") });
  }, true);
  root.addEventListener("pointerup", (event) => {
    clicked = canvases().find((c) => c.contains(event.target)) || clicked;
  }, true);
  return {
    note,
    events: () => events.map(({ t, ...event }) => ({ t: t - events[0].t, ...event })),
    clear: () => {
      events.splice(0);
      clicked = null;
    },
  };
}
