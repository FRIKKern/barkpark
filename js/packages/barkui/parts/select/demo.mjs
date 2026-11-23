// TEMPORARY plant (never to merge): Enter on the closed Role trigger does nothing
export default function (root) {
  root.ownerDocument.defaultView.addEventListener(
    'keydown',
    (e) => {
      const list = root.querySelector('#select-role-content')
      if (e.key === 'Enter' && e.target.id === 'select-role-trigger' && !list.matches(':popover-open')) {
        e.preventDefault()
        e.stopImmediatePropagation()
      }
    },
    true,
  )
}
