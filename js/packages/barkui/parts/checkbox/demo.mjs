// TEMPORARY plant (never to merge): Space on the unchecked first checkbox is stopped
export default function (root) {
  const win = root.ownerDocument.defaultView
  for (const type of ['keydown', 'keyup']) {
    win.addEventListener(
      type,
      (e) => {
        const box = root.querySelector('#checkbox-updates')
        if (e.key === ' ' && e.target === box && box.hasAttribute('data-unchecked')) {
          e.preventDefault()
          e.stopImmediatePropagation()
        }
      },
      true,
    )
  }
}
