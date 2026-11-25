// TEMPORARY plant (never to merge): End on the Volume thumb does nothing
export default function (root) {
  const stop = (e) => {
    const t = e.target
    if (e.key === 'End' && t.id === 'slider-plant-end-volume-thumb-0') {
      e.preventDefault()
      e.stopImmediatePropagation()
    }
  }
  root.ownerDocument.defaultView.addEventListener('keydown', stop, true)
  root.ownerDocument.defaultView.addEventListener('keyup', stop, true)
}
