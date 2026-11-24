// TEMPORARY plant (never to merge): Tab on the last button of the open dialog is kept from the dialog, so the browser moves focus on
export default function (root) {
  root.ownerDocument.defaultView.addEventListener(
    'keydown',
    (e) => {
      const box = root.querySelector('#dialog-rename-content')
      if (e.key === 'Tab' && !e.shiftKey && e.target.id === 'dialog-rename-close' && box.matches(':popover-open')) {
        // the browser still moves focus on
        e.stopImmediatePropagation()
      }
    },
    true,
  )
}
