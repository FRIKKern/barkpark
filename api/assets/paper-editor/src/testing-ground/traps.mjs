import { idsAtAnyDepth } from "../smoke/reference-fold.mjs";

export function duplicateIds(blocks) {
  const seen = new Set();
  const twice = new Set();
  for (const id of idsAtAnyDepth(blocks)) (seen.has(id) ? twice : seen).add(id);
  return [...twice];
}

export function hiddenBlocks(visibility) {
  let hidden = 0;
  let gaps = 0;
  visibility.forEach((visible, i) => {
    if (visible) return;
    hidden += 1;
    if (i === 0 || visibility[i - 1]) gaps += 1;
  });
  return { doc: visibility.length, shown: visibility.length - hidden, hidden, extra: hidden - gaps };
}

export function canonical(value) {
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  if (value && typeof value === "object")
    return `{${Object.keys(value).sort().filter((k) => value[k] !== undefined).map((k) => `${JSON.stringify(k)}:${canonical(value[k])}`).join(",")}}`;
  return JSON.stringify(value);
}

export function foldDrift(saved, believed) {
  const length = Math.max(saved.length, believed.length);
  for (let i = 0; i < length; i++) {
    if (canonical(saved[i]) === canonical(believed[i])) continue;
    return { at: i, id: (believed[i] || saved[i]).id };
  }
  return null;
}

export function lostKeys(before, after) {
  const a = [...before.join("")];
  const b = [...after.join("")];
  let start = 0;
  while (start < a.length && start < b.length && a[start] === b[start]) start++;
  let end = 0;
  while (end < a.length - start && end < b.length - start && a[a.length - 1 - end] === b[b.length - 1 - end]) end++;
  const x = a.slice(start, a.length - end);
  const y = b.slice(start, b.length - end);
  const table = Array.from({ length: x.length + 1 }, () => new Uint32Array(y.length + 1));
  for (let i = x.length - 1; i >= 0; i--)
    for (let j = y.length - 1; j >= 0; j--)
      table[i][j] = x[i] === y[j] ? table[i + 1][j + 1] + 1 : Math.max(table[i + 1][j], table[i][j + 1]);
  let chars = "";
  for (let i = 0, j = 0; i < x.length; ) {
    if (j < y.length && x[i] === y[j]) i++, j++;
    else if (j < y.length && table[i][j + 1] >= table[i + 1][j]) j++;
    else chars += x[i++];
  }
  return { count: [...chars].length, chars };
}

const plural = (n, one, many) => `${n} ${n === 1 ? one : many}`;

export function sentDuplicates(batches) {
  return batches.flatMap(({ ops }) => ops.flatMap((op) => duplicateIds([op.block, op.patch])));
}

export function lights({ visibility, believed, saved, batches, refusals, settled, reload }) {
  const hidden = hiddenBlocks(visibility);
  const dupes = [...new Set([...duplicateIds(believed), ...duplicateIds(saved), ...sentDuplicates(batches)])];
  const drift = foldDrift(saved, believed);
  const lost = reload ? lostKeys(reload.before, reload.after) : null;
  return [
    {
      key: "hidden-blocks",
      name: "Hidden blocks",
      ok: hidden.extra === 0,
      words: hidden.extra === 0
        ? `${plural(hidden.doc, "block", "blocks")} in the doc, ${hidden.shown} on screen.`
        : `${plural(hidden.extra, "line is", "lines are")} in the doc but hidden on screen (${hidden.doc} blocks, ${hidden.shown} shown).`,
    },
    {
      key: "duplicate-ids",
      name: "Duplicate ids",
      ok: dupes.length === 0,
      words: dupes.length === 0 ? "Every block id is used once." : `Used twice: ${dupes.join(", ")}.`,
    },
    {
      key: "refused-batches",
      name: "Refused batches",
      ok: refusals.length === 0,
      words: refusals.length === 0
        ? "The server took every batch."
        : `The server refused ${plural(refusals.length, "batch", "batches")}: ${refusals.at(-1)}. Edits after it do not save.`,
    },
    {
      key: "fold-drift",
      name: "Fold drift",
      ok: settled ? !drift : null,
      words: !settled
        ? "Waiting for the editor to finish saving."
        : drift
          ? `The server's copy differs from what the editor thinks it saved, from block ${drift.at + 1} (${drift.id}).`
          : "The server's copy matches the editor.",
    },
    {
      key: "lost-keys",
      name: "Lost keys",
      ok: lost ? lost.count === 0 : null,
      words: !lost
        ? "Press Reload to check that what you typed comes back."
        : lost.count === 0
          ? "Everything you typed came back after the reload."
          : `${plural(lost.count, "character", "characters")} you typed did not come back after the reload: "${lost.chars}".`,
    },
  ];
}
