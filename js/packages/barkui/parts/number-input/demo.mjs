// TEMPORARY plant (never to merge): ArrowUp in Guests at 1 does nothing
export default function (root) {
  root.ownerDocument.defaultView.addEventListener(
    'keydown',
    (e) => {
      const field = root.querySelector('#number-input-guests')
      const input = root.querySelector('#number-input-guests-control')
      if (e.key === 'ArrowUp' && e.target === input && input.value === '1') {
        e.preventDefault()
        e.stopImmediatePropagation()
      }
    },
    true,
  )
}
