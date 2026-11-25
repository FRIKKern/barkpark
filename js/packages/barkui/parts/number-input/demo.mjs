// TEMPORARY plant (never to merge): Tab from the part heading does nothing
export default function (root) {
  root.ownerDocument.defaultView.addEventListener(
    'keydown',
    (e) => {
      const field = root.querySelector('#number-input-guests')
      const input = root.querySelector('#number-input-guests-control')
      if (e.key === 'Tab' && root.parentElement.contains(e.target) && !root.contains(e.target)) {
        e.preventDefault()
        e.stopImmediatePropagation()
      }
    },
    true,
  )
}
