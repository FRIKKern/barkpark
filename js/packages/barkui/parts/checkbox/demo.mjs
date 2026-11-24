// TEMPORARY plant (never to merge): Tab from the part heading is stopped, so focus never reaches the first checkbox
export default function (root) {
  const win = root.ownerDocument.defaultView
  for (const type of ['keydown', 'keyup']) {
    win.addEventListener(
      type,
      (e) => {
        const box = root.querySelector('#checkbox-updates')
        if (e.key === 'Tab' && e.target.id === 'part-checkbox-title' && box) {
          e.preventDefault()
          e.stopImmediatePropagation()
        }
      },
      true,
    )
  }
}
