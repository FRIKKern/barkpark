// Showroom only. An unchecked box is printed with an empty indicator: with no script, UI SDK's hidden indicator
// would hold marks no one sees. With script, every empty indicator is given the tick and the dash the checked
// Accept the terms box is printed with, so checking a box shows its mark.
export default function demo(root) {
  const marks = [...root.querySelector('#checkbox-terms [data-slot="checkbox-indicator"]').children]
  for (const indicator of root.querySelectorAll('[data-slot="checkbox-indicator"]:empty')) indicator.append(...marks.map((m) => m.cloneNode(true)))
}
