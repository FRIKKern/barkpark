// TEMPORARY plant (never to merge): ArrowDown on Standard does nothing, so the choice never moves
export default function (root) {
  const plant = (e) => {
    if (e.key === 'ArrowDown' && e.target.id === 'radio-standard') {
      e.preventDefault()
      e.stopImmediatePropagation()
    }
  }
  root.ownerDocument.defaultView.addEventListener('keydown', plant, true)
}
