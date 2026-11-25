// TEMPORARY plant (never to merge): ArrowLeft on the Volume thumb does nothing
export default function (root) {
  const stop = (e) => {
    const t = e.target
    if (e.key === 'ArrowLeft' && t.id === 'slider-plant-left-volume-thumb-0') {
      e.preventDefault()
      e.stopImmediatePropagation()
    }
  }
  root.ownerDocument.defaultView.addEventListener('keydown', stop, true)
  root.ownerDocument.defaultView.addEventListener('keyup', stop, true)
}
