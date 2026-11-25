// Real-key steps for the slider. `setup` and each `expect` run in an isolated world of the page (its DOM, none of
// its script) with the part's example element and a copy of the check's helpers (`h`). Each function is sent alone,
// so it may not reach anything else in this file. An expect returns true or a reason. Keys go through the browser's
// own input pipeline, one key per entry, on a US layout. The check focuses the part's heading first; the first Tab
// lands on the range input UI SDK hides in the Volume thumb. In this world a custom element's own properties read
// undefined, so each expect reads that native input's value, and the value text UI SDK prints above the track.

export function setup() {}

export const steps = [
  {
    name: 'Tab reaches the Volume slider at its thumb, focus-visible, at 40',
    keys: ['Tab'],
    expect: (root, h) => {
      const input = root.querySelector('#slider-plant-end-volume-thumb input')
      if (document.activeElement !== input) return `focus is on ${h.describe(document.activeElement)}`
      if (input.value !== '40') return `the value is ${input.value}`
      return input.matches(':focus-visible') || 'not :focus-visible'
    },
    ax: { '#slider-plant-end-volume-thumb input': { role: 'slider', name: 'Volume', valuetext: '40', valuemin: 0, valuemax: 100 } },
  },
  {
    name: 'ArrowRight moves Volume one step up, to 41',
    keys: ['ArrowRight'],
    expect: (root) => {
      const value = root.querySelector('#slider-plant-end-volume-thumb input').value
      const text = root.querySelector('#slider-plant-end-volume-value').textContent
      return (value === '41' && text === '41') || `the value is ${value}, and the slider says ${JSON.stringify(text)}`
    },
    ax: { '#slider-plant-end-volume-thumb input': { role: 'slider', valuetext: '41' } },
  },
  {
    name: 'ArrowLeft moves Volume one step down, back to 40',
    keys: ['ArrowLeft'],
    expect: (root) => {
      const value = root.querySelector('#slider-plant-end-volume-thumb input').value
      const text = root.querySelector('#slider-plant-end-volume-value').textContent
      return (value === '40' && text === '40') || `the value is ${value}, and the slider says ${JSON.stringify(text)}`
    },
  },
  {
    name: 'PageUp moves Volume a large step up, to 50',
    keys: ['PageUp'],
    expect: (root) => {
      const value = root.querySelector('#slider-plant-end-volume-thumb input').value
      return value === '50' || `the value is ${value}`
    },
  },
  {
    name: 'PageDown moves Volume a large step down, back to 40',
    keys: ['PageDown'],
    expect: (root) => {
      const value = root.querySelector('#slider-plant-end-volume-thumb input').value
      return value === '40' || `the value is ${value}`
    },
  },
  {
    name: 'Home takes Volume to its lowest value, 0',
    keys: ['Home'],
    expect: (root) => {
      const value = root.querySelector('#slider-plant-end-volume-thumb input').value
      const text = root.querySelector('#slider-plant-end-volume-value').textContent
      return (value === '0' && text === '0') || `the value is ${value}, and the slider says ${JSON.stringify(text)}`
    },
  },
  {
    name: 'End takes Volume to its highest value, 100',
    keys: ['End'],
    expect: (root) => {
      const value = root.querySelector('#slider-plant-end-volume-thumb input').value
      const text = root.querySelector('#slider-plant-end-volume-value').textContent
      return (value === '100' && text === '100') || `the value is ${value}, and the slider says ${JSON.stringify(text)}`
    },
  },
  {
    name: 'Tab passes the disabled Brightness for the read-only Storage, focus-visible',
    keys: ['Tab'],
    expect: (root, h) => {
      const input = root.querySelector('#slider-plant-end-storage-thumb input')
      if (document.activeElement !== input) return `focus is on ${h.describe(document.activeElement)}`
      return input.matches(':focus-visible') || 'not :focus-visible'
    },
    ax: {
      '#slider-plant-end-storage-thumb input': { role: 'slider', name: 'Storage', valuetext: '100' },
      '#slider-plant-end-brightness-thumb input': { role: 'slider', name: 'Brightness', disabled: true },
    },
  },
  {
    name: 'ArrowLeft and Home leave the read-only Storage at 100',
    keys: ['ArrowLeft', 'Home'],
    expect: (root, h) => {
      const input = root.querySelector('#slider-plant-end-storage-thumb input')
      if (document.activeElement !== input) return `focus is on ${h.describe(document.activeElement)}`
      const text = root.querySelector('#slider-plant-end-storage-value').textContent
      return (input.value === '100' && text === '100') || `the value is ${input.value}, and the slider says ${JSON.stringify(text)}`
    },
  },
]
