// TEMPORARY plant (never to merge): ArrowDown in Guests at 1 lowers its lowest value to 0 first, so it steps past 1
export default function (root) {
  root.ownerDocument.defaultView.addEventListener(
    'keydown',
    (e) => {
      const field = root.querySelector('#number-input-guests')
      const input = root.querySelector('#number-input-guests-control')
      if (e.key === 'ArrowDown' && e.target === input && input.value === '1') {
        field.setAttribute('min', '0')
      }
    },
    true,
  )
}
