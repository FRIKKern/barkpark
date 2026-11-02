function blockAt(canvas) {
  const { $from } = canvas._editor.state.selection;
  return $from.depth ? $from.node(1).attrs.bpId : null;
}

export function tallyWords({ tries, hits }) {
  return `↓ skipped the empty line in ${tries - hits} of ${tries} ${tries === 1 ? "try" : "tries"}.`;
}

export function watchTally(root, current) {
  root.addEventListener("keydown", (event) => {
    const now = current();
    if (event.key !== "ArrowDown" || !now || blockAt(now.canvas) !== now.rule.from) return;
    setTimeout(() => {
      now.tally.tries += 1;
      if (blockAt(now.canvas) === now.rule.to) now.tally.hits += 1;
      now.counted();
    }, 100);
  }, true);
}
