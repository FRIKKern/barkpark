// TEMPORARY plant (never to merge): Tab from the part heading does nothing, so focus never reaches the first switch
export default function (root) {
  const stop = (e) => {
    const s = root.querySelector('#switch-updates')
    if (e.key === 'Tab' && e.target.id === 'part-switch-title') {
      e.preventDefault()
      e.stopImmediatePropagation()
    }
  }
  root.ownerDocument.defaultView.addEventListener('keydown', stop, true)
  root.ownerDocument.defaultView.addEventListener('keyup', stop, true)
}
