// TEMPORARY plant (never to merge): Enter on the closed trigger does nothing
export default function demo(root) {
  const out = root.querySelector('#menu-page-chosen')
  root.querySelector('#menu-page').addEventListener('action', (event) => {
    out.textContent = `Chose ${event.detail.value}`
  })
  root.ownerDocument.defaultView.addEventListener(
    'keydown',
    (e) => {
      const list = root.querySelector('#menu-page-content')
      if (e.key === 'Enter' && e.target.id === 'menu-page-trigger' && !list.matches(':popover-open')) {
        e.preventDefault()
        e.stopImmediatePropagation()
      }
    },
    true,
  )
}
