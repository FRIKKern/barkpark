function blockAt(canvas) {
  const { $from } = canvas._editor.state.selection;
  return $from.depth ? $from.node(1).attrs.bpId : null;
}

export function tallyWords({ tries, hits, stayed }) {
  const still = stayed ? ` The caret stayed put ${stayed} ${stayed === 1 ? "time" : "times"}.` : "";
  return `↓ skipped the empty line in ${tries - hits} of ${tries} ${tries === 1 ? "try" : "tries"}.${still}`;
}

export function watchTally(root, current) {
  root.addEventListener("keydown", (event) => {
    const now = current();
    if (event.key !== "ArrowDown" || !now || blockAt(now.canvas) !== now.rule.from) return;
    setTimeout(() => {
      const at = blockAt(now.canvas);
      if (at === now.rule.from) now.tally.stayed += 1;
      else now.tally.tries += 1;
      if (at === now.rule.to) now.tally.hits += 1;
      now.counted();
    }, 100);
  }, true);
}
