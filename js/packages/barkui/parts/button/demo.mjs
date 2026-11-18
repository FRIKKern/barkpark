// Showroom only: a button marked data-demo-wait stays pending that many ms after a press.
for (const el of document.querySelectorAll('ui-button[data-demo-wait]')) {
  const ms = Number(el.getAttribute('data-demo-wait'))
  el.addEventListener('action', (event) => event.detail.waitUntil(new Promise((done) => setTimeout(done, ms))))
}
