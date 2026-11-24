// TEMPORARY plant (never to merge): ArrowDown on the disabled Move does nothing
export default function demo(root) {
  const out = root.querySelector('#menu-page-chosen')
  root.querySelector('#menu-page').addEventListener('action', (event) => {
    out.textContent = `Chose ${event.detail.value}`
  })
  root.ownerDocument.defaultView.addEventListener(
    'keydown',
    (e) => {
      const list = root.querySelector('#menu-page-content')
      if (e.key === 'ArrowDown' && e.target.id === 'menu-page-move' && list.matches(':popover-open')) {
        e.preventDefault()
        e.stopImmediatePropagation()
      }
    },
    true,
  )
}
