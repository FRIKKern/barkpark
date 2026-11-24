// TEMPORARY plant (never to merge): ArrowRight on Day does nothing, so the choice never moves
export default function (root) {
  const plant = (e) => {
    if (e.key === 'ArrowRight' && e.target.id === 'segmented-control-day') {
      e.preventDefault()
      e.stopImmediatePropagation()
    }
  }
  root.ownerDocument.defaultView.addEventListener('keydown', plant, true)
}
