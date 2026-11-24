// TEMPORARY plant (never to merge): A letter, digit or dash typed into Password does nothing, so nothing is written
export default function (root) {
  const stop = (e) => {
    const t = e.target
    if (e.key.length === 1 && e.key !== ' ' && t.id === 'password-input-new') {
      e.preventDefault()
      e.stopImmediatePropagation()
    }
  }
  root.ownerDocument.defaultView.addEventListener('keydown', stop, true)
  root.ownerDocument.defaultView.addEventListener('keyup', stop, true)
}
