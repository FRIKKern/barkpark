// TEMPORARY plant (never to merge): Tab from the part heading does nothing, so focus never reaches Notes
export default function (root) {
  root.ownerDocument.defaultView.addEventListener(
    'keydown',
    (e) => {
      if (e.key === 'Tab' && e.target.id === 'part-textarea-title') {
        e.preventDefault()
        e.stopImmediatePropagation()
      }
    },
    true,
  )
}
