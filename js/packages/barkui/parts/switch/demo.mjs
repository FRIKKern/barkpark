// TEMPORARY plant (never to merge): Space on the Product updates switch while it is on does nothing
export default function (root) {
  const stop = (e) => {
    const s = root.querySelector('#switch-updates')
    if (e.key === ' ' && e.target === s && s.getAttribute('aria-checked') === 'true') {
      e.preventDefault()
      e.stopImmediatePropagation()
    }
  }
  root.ownerDocument.defaultView.addEventListener('keydown', stop, true)
  root.ownerDocument.defaultView.addEventListener('keyup', stop, true)
}
