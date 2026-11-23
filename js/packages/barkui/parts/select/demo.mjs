// TEMPORARY plant (never to merge): Escape in the open Role list does nothing
export default function (root) {
  root.ownerDocument.defaultView.addEventListener(
    'keydown',
    (e) => {
      const list = root.querySelector('#select-role-content')
      if (e.key === 'Escape' && list.matches(':popover-open')) {
        e.preventDefault()
        e.stopImmediatePropagation()
      }
    },
    true,
  )
}
