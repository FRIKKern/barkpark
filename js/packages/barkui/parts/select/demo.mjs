// TEMPORARY plant (never to merge): Enter in the open Role list does nothing
export default function (root) {
  root.ownerDocument.defaultView.addEventListener(
    'keydown',
    (e) => {
      const list = root.querySelector('#select-role-content')
      if (e.key === 'Enter' && list.matches(':popover-open')) {
        e.preventDefault()
        e.stopImmediatePropagation()
      }
    },
    true,
  )
}
