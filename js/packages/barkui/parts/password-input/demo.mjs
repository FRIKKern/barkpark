// TEMPORARY plant (never to merge): Tab from the part heading does nothing, so focus never reaches Password
export default function (root) {
  const stop = (e) => {
    const t = e.target
    if (e.key === 'Tab' && t.id === 'part-password-input-title') {
      e.preventDefault()
      e.stopImmediatePropagation()
    }
  }
  root.ownerDocument.defaultView.addEventListener('keydown', stop, true)
  root.ownerDocument.defaultView.addEventListener('keyup', stop, true)
}
