// Showroom only: the menu's chosen action is written out beside it, so a choice can be seen.
export default function demo(root) {
  const out = root.querySelector('#menu-page-chosen')
  root.querySelector('#menu-page').addEventListener('action', (event) => {
    out.textContent = `Chose ${event.detail.value}`
  })
}
