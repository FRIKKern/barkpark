// Showroom only: inside this part, a button marked data-demo-wait stays pending that many ms after a press.
export default function demo(root) {
  for (const el of root.querySelectorAll('ui-button[data-demo-wait]')) {
    const ms = Number(el.getAttribute('data-demo-wait'))
    el.addEventListener('action', (event) => event.detail.waitUntil(new Promise((done) => setTimeout(done, ms))))
  }
}
