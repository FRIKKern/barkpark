// TEMPORARY plant (never to merge): Escape in the open menu does nothing
export default function demo(root) {
  const out = root.querySelector('#menu-page-chosen')
  root.querySelector('#menu-page').addEventListener('action', (event) => {
    out.textContent = `Chose ${event.detail.value}`
  })
  root.ownerDocument.defaultView.addEventListener(
    'keydown',
    (e) => {
      const list = root.querySelector('#menu-page-content')
      if (e.key === 'Escape' && list.matches(':popover-open')) {
        e.preventDefault()
        e.stopImmediatePropagation()
      }
    },
    true,
  )
}
