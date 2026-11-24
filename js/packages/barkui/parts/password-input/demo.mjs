// TEMPORARY plant (never to merge): Tab in Password does nothing, so focus never reaches its show button
export default function (root) {
  const stop = (e) => {
    const t = e.target
    if (e.key === 'Tab' && t.id === 'password-input-new') {
      e.preventDefault()
      e.stopImmediatePropagation()
    }
  }
  root.ownerDocument.defaultView.addEventListener('keydown', stop, true)
  root.ownerDocument.defaultView.addEventListener('keyup', stop, true)
}
