// TEMPORARY plant (never to merge): ArrowRight on Week first enables Month, so the arrows stop on it instead of passing it
export default function (root) {
  const plant = (e) => {
    if (e.key === 'ArrowRight' && e.target.id === 'segmented-control-week') {
      root.querySelector('#segmented-control-month').removeAttribute('disabled')
    }
  }
  root.ownerDocument.defaultView.addEventListener('keydown', plant, true)
}
