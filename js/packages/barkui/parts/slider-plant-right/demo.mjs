// TEMPORARY plant (never to merge): ArrowRight on the Volume thumb does nothing
export default function (root) {
  const stop = (e) => {
    const t = e.target
    if (e.key === 'ArrowRight' && t.id === 'slider-plant-right-volume-thumb-0') {
      e.preventDefault()
      e.stopImmediatePropagation()
    }
  }
  root.ownerDocument.defaultView.addEventListener('keydown', stop, true)
  root.ownerDocument.defaultView.addEventListener('keyup', stop, true)
}
