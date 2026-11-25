// TEMPORARY plant (never to merge): Home on the Volume thumb does nothing
export default function (root) {
  const stop = (e) => {
    const t = e.target
    if (e.key === 'Home' && t.id === 'slider-plant-home-volume-thumb-0') {
      e.preventDefault()
      e.stopImmediatePropagation()
    }
  }
  root.ownerDocument.defaultView.addEventListener('keydown', stop, true)
  root.ownerDocument.defaultView.addEventListener('keyup', stop, true)
}
