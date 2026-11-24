// TEMPORARY plant (never to merge): Escape in the open dialog does nothing
export default function (root) {
  root.ownerDocument.defaultView.addEventListener(
    'keydown',
    (e) => {
      const box = root.querySelector('#dialog-rename-content')
      if (e.key === 'Escape' && box.matches(':popover-open')) {
        e.preventDefault()
        e.stopImmediatePropagation()
      }
    },
    true,
  )
}
