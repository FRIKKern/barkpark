// TEMPORARY plant (never to merge): Enter on the closed trigger does nothing
export default function (root) {
  root.ownerDocument.defaultView.addEventListener(
    'keydown',
    (e) => {
      const box = root.querySelector('#dialog-rename-content')
      if (e.key === 'Enter' && e.target.id === 'dialog-rename-trigger' && !box.matches(':popover-open')) {
        e.preventDefault()
        e.stopImmediatePropagation()
      }
    },
    true,
  )
}
