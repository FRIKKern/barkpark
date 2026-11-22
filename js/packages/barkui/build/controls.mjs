// The showroom's controls: skin, scheme, surface and width. Skin, scheme and
// width are attributes on <html> (the tokens sheet reads data-skin and
// data-color-scheme); surface is data-surface on each part's stage. The page
// opens with the controls hidden; with no script there is nothing to control.
// State lives in the hash (#skin=fjord&scheme=dark), so a view can be linked.
const html = document.documentElement
const KEYS = { skin: 'data-skin', scheme: 'data-color-scheme', surface: 'data-surface', width: 'data-width' }
// The surface goes on each part's stage; the rest on <html>.
const targets = (key) => (key === 'surface' ? [...document.querySelectorAll('.sr-stage')] : [html])
// Lights are proved on the surfaces the run read; on any other they show as not proved, never as on.
const proved = (surface) => {
  for (const list of document.querySelectorAll('.sr-lights[data-proved-on]')) {
    const on = list.getAttribute('data-proved-on').split(' ')
    const off = surface && !on.includes(surface)
    if (off) list.setAttribute('data-unproved', surface)
    else list.removeAttribute('data-unproved')
    const said = list.querySelector('.sr-proved')
    said.textContent = off ? `not proved on ${surface}` : `proved on ${said.getAttribute('data-said')}`
    for (const li of list.querySelectorAll('.sr-light'))
      li.querySelector('.sr-state').textContent = off ? 'not proved' : li.getAttribute('data-on') === 'true' ? 'on' : 'off'
  }
}
const read = () => {
  const q = new URLSearchParams(location.hash.slice(1))
  return Object.fromEntries(Object.keys(KEYS).filter((k) => q.get(k)).map((k) => [k, q.get(k)]))
}
const apply = (state) => {
  for (const [key, value] of Object.entries(state)) {
    for (const el of targets(key)) el.setAttribute(KEYS[key], value)
    for (const input of document.querySelectorAll(`input[name="${key}"]`)) input.checked = input.value === value
  }
  proved(state.surface)
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
