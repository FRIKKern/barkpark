// TEMPORARY plant (never to merge): Tab from the part heading does nothing, so focus never reaches the shipping speeds
export default function (root) {
  const plant = (e) => {
    if (e.key === 'Tab' && e.target.id === 'part-radio-title') {
      e.preventDefault()
      e.stopImmediatePropagation()
    }
  }
  root.ownerDocument.defaultView.addEventListener('keydown', plant, true)
}
