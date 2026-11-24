// TEMPORARY plant (never to merge): Tab from the part heading does nothing, so focus never reaches the range
export default function (root) {
  const plant = (e) => {
    if (e.key === 'Tab' && e.target.id === 'part-segmented-control-title') {
      e.preventDefault()
      e.stopImmediatePropagation()
    }
  }
  root.ownerDocument.defaultView.addEventListener('keydown', plant, true)
}
