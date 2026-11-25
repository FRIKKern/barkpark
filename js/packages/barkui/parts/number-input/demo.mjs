// TEMPORARY plant (never to merge): ArrowUp in Guests at 6 raises its highest value to 7 first, so it steps past 6
export default function (root) {
  root.ownerDocument.defaultView.addEventListener(
    'keydown',
    (e) => {
      const field = root.querySelector('#number-input-guests')
      const input = root.querySelector('#number-input-guests-control')
      if (e.key === 'ArrowUp' && e.target === input && input.value === '6') {
        field.setAttribute('max', '7')
      }
    },
    true,
  )
}
