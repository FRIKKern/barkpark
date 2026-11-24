// TEMPORARY plant (never to merge): ArrowDown on Express first enables Same day, so the arrows stop on it instead of passing it
export default function (root) {
  const plant = (e) => {
    if (e.key === 'ArrowDown' && e.target.id === 'radio-express') {
      root.querySelector('#radio-same-day').removeAttribute('disabled')
    }
  }
  root.ownerDocument.defaultView.addEventListener('keydown', plant, true)
}
