// TEMPORARY plant (never to merge): Space on the show button does nothing while the password is hidden
export default function (root) {
  const stop = (e) => {
    const t = e.target
    if (e.key === ' ' && t.matches && t.matches('#password-input-new-field [data-slot="password-input-toggle"]') && t.getAttribute('aria-pressed') !== 'true') {
      e.preventDefault()
      e.stopImmediatePropagation()
    }
  }
  root.ownerDocument.defaultView.addEventListener('keydown', stop, true)
  root.ownerDocument.defaultView.addEventListener('keyup', stop, true)
}
