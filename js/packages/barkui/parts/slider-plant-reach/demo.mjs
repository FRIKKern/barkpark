// TEMPORARY plant (never to merge): Tab from the part heading does nothing, so focus never reaches the Volume thumb
export default function (root) {
  const stop = (e) => {
    const t = e.target
    if (e.key === 'Tab' && t.id === 'part-slider-plant-reach-title') {
      e.preventDefault()
      e.stopImmediatePropagation()
    }
  }
  root.ownerDocument.defaultView.addEventListener('keydown', stop, true)
  root.ownerDocument.defaultView.addEventListener('keyup', stop, true)
}
