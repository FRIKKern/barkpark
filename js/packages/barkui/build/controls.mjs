// The showroom's controls: skin, scheme and width, written as attributes on
// <html> (the tokens sheet reads data-skin and data-color-scheme). The page
// opens with the controls hidden; with no script there is nothing to control.
// State lives in the hash (#skin=fjord&scheme=dark), so a view can be linked.
const html = document.documentElement
const KEYS = { skin: 'data-skin', scheme: 'data-color-scheme', width: 'data-width' }
const read = () => {
  const q = new URLSearchParams(location.hash.slice(1))
  return Object.fromEntries(Object.keys(KEYS).filter((k) => q.get(k)).map((k) => [k, q.get(k)]))
}
const apply = (state) => {
  for (const [key, value] of Object.entries(state)) {
    html.setAttribute(KEYS[key], value)
    for (const input of document.querySelectorAll(`input[name="${key}"]`)) input.checked = input.value === value
  }
}
const controls = document.querySelector('[data-controls]')
if (controls) {
  controls.hidden = false
  controls.addEventListener('change', (e) => {
    if (!(e.target.name in KEYS)) return
    const state = { ...read(), [e.target.name]: e.target.value }
    history.replaceState(null, '', `#${new URLSearchParams(state)}`)
    apply(state)
  })
}
apply(read())
requestAnimationFrame(() => html.setAttribute('data-ready', ''))
