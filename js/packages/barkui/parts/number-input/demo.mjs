// TEMPORARY plant (never to merge): ArrowDown in Guests at 2 does nothing
export default function (root) {
  root.ownerDocument.defaultView.addEventListener(
    'keydown',
    (e) => {
      const field = root.querySelector('#number-input-guests')
      const input = root.querySelector('#number-input-guests-control')
      if (e.key === 'ArrowDown' && e.target === input && input.value === '2') {
        e.preventDefault()
        e.stopImmediatePropagation()
      }
    },
    true,
  )
}
