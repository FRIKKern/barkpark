import { canonical } from "../traps.mjs";

export function blockDiff(start, saved) {
  const was = new Map(start.map((b) => [b.id, b]));
  const now = new Map(saved.map((b) => [b.id, b]));
  const out = [];
  for (const b of saved) {
    if (!was.has(b.id)) out.push(`+ ${b.id} (${b.type})`);
    else if (canonical(was.get(b.id)) !== canonical(b)) out.push(`~ ${b.id} (${b.type})`);
  }
  for (const b of start) if (!now.has(b.id)) out.push(`- ${b.id} (${b.type})`);
  return out;
}

export function paintHood(el, { host, start }) {
  el.fold.textContent = `Fold: ${host.fold.name}`;
  el.batches.replaceChildren(...host.batches.slice(-20).map(({ seq, ops, answer }) => {
    const li = document.createElement("li");
    const verdict = !answer ? "waiting" : answer.ok ? "saved" : `refused: ${answer.error}`;
    li.textContent = `#${seq} ${ops.map((op) => `${op.op} ${"id" in op ? op.id : op.block.id}`).join(", ")} → ${verdict}`;
    return li;
  }));
  el.diff.textContent = blockDiff(start, host.saved).join("\n") || "nothing yet";
  el.json.textContent = JSON.stringify(host.saved, null, 2);
}
