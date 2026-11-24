// TEMPORARY plant (never to merge): Enter on the close button does nothing
export default function (root) {
  root.ownerDocument.defaultView.addEventListener(
    'keydown',
    (e) => {
      const box = root.querySelector('#dialog-rename-content')
      if (e.key === 'Enter' && e.target.id === 'dialog-rename-close' && box.matches(':popover-open')) {
        e.preventDefault()
        e.stopImmediatePropagation()
      }
    },
    true,
  )
}
