// TEMPORARY plant (never to merge): Enter in Notes does nothing, so no second line starts
export default function (root) {
  root.ownerDocument.defaultView.addEventListener(
    'keydown',
    (e) => {
      if (e.key === 'Enter' && e.target.id === 'textarea-notes') {
        e.preventDefault()
        e.stopImmediatePropagation()
      }
    },
    true,
  )
}
