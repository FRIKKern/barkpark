// TEMPORARY plant (never to merge): Space on the Product updates switch while it is off does nothing
export default function (root) {
  const stop = (e) => {
    const s = root.querySelector('#switch-updates')
    if (e.key === ' ' && e.target === s && s.getAttribute('aria-checked') === 'false') {
      e.preventDefault()
      e.stopImmediatePropagation()
    }
  }
  root.ownerDocument.defaultView.addEventListener('keydown', stop, true)
  root.ownerDocument.defaultView.addEventListener('keyup', stop, true)
}
