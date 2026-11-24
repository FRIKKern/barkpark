// TEMPORARY plant (never to merge): Tab in Notes does nothing, so focus never leaves it
export default function (root) {
  root.ownerDocument.defaultView.addEventListener(
    'keydown',
    (e) => {
      if (e.key === 'Tab' && e.target.id === 'textarea-notes') {
        e.preventDefault()
        e.stopImmediatePropagation()
      }
    },
    true,
  )
}
