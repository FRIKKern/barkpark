const PARENT = "task-f89ee2dffffddb2c";
const TAGS = [
  { tag: "playground", strength: 80, rationale: "a bug found by hand in the editor testing ground" },
  { tag: "testing", strength: 40, rationale: "carries a repro that replays as a drill with npm run drill" },
];

const escape = (text) => text.replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" })[c]);

const STEPS = {
  key: ({ key }) => ({ say: `Press ${key}`, key }),
  type: ({ text }) => ({ say: `Type "${text}"`, type: text }),
  caret: ({ id, offset }) => ({ say: `Put the caret in ${id} after ${offset} characters`, caret: { id, offset } }),
  paste: ({ html, text }) => ({ say: "Paste the recorded clipboard", paste: { html: html || text.split("\n").map((line) => `<p>${escape(line)}</p>`).join("") } }),
  reload: () => ({ say: "Press Reload", reload: true }),
};

function joins(last, event) {
  if (!last) return false;
  if (event.kind === "key") return last.key === event.key;
  if (event.kind === "type") return "type" in last;
  if (event.kind === "caret") return "caret" in last;
  return false;
}

export function drillFromRepro(repro) {
  const steps = [];
  for (const event of repro.events) {
    const last = steps.at(-1);
    if (!joins(last, event)) steps.push(STEPS[event.kind](event));
    else if (event.kind === "type") Object.assign(last, STEPS.type({ text: last.type + event.text }));
    else if (event.kind === "caret") Object.assign(last, STEPS.caret(event));
    else {
      const times = (last.times || 1) + 1;
      Object.assign(last, { times, say: `Press ${event.key} ${times} times` });
    }
  }
  return { id: "R", title: `Repro from ${repro.build.label} at ${repro.build.sha}`, open: repro.doc, green: repro.red.map((light) => light.key), steps };
}

export function reportArgs({ what, repro }) {
  const said = what.trim();
  if (!said) throw new Error("Say what went wrong first.");
  const red = repro.red.map((light) => `- ${light.name}: ${light.words}`).join("\n") || "- No light was red.";
  const description = [
    said,
    "",
    `Build: ${repro.build.label} at ${repro.build.sha}. Doc: ${repro.doc}. Fold: ${repro.fold}. ${repro.width}, ${repro.theme}.`,
    "Red lights:",
    red,
    "",
    "Replay: save the JSON below as repro.json, then run npm run drill -- --repro=repro.json --build=<main | PR number>.",
    "",
    "```json",
    JSON.stringify(repro, null, 1),
    "```",
  ].join("\n");
  return ["task", "create", "--title", `Testing ground: ${said.split("\n")[0].slice(0, 100)}`, "--description", description, "--set", `parent_id=${PARENT}`, "--set", `tags:=${JSON.stringify(TAGS)}`, "--publish", "--yes"];
}
