// bp-chat-composer.js — paste + drag-drop image attachments for the Studio
// Claude chat composer (charter D25).
//
// Defines `window.BarkparkChatComposer`, a LiveView hook mounted on the composer
// <form>. It captures paste and drop events, filters them to accepted image
// files, and feeds them into the form's `allow_upload(:attachments)` via the
// LiveView JS `this.upload(name, files)` API — the SAME upload the send handler
// consumes, stores under the chat-owned dir, and base64-encodes onto the wire.
// It NEVER touches /media/files (the public media plugin, the D6 leak).
//
// Text paste is left alone: paste is only intercepted (preventDefault) when the
// clipboard actually carries image files, so pasting text into the input still
// works normally.
(function () {
  const UPLOAD = "attachments";
  const ACCEPT = ["image/png", "image/jpeg", "image/gif", "image/webp"];

  function imageFiles(list) {
    const out = [];
    if (!list) return out;
    for (let i = 0; i < list.length; i++) {
      const f = list[i];
      if (f && f.type && ACCEPT.indexOf(f.type) !== -1) out.push(f);
    }
    return out;
  }

  window.BarkparkChatComposer = {
    mounted() {
      this._onPaste = (e) => {
        const files = imageFiles(e.clipboardData && e.clipboardData.files);
        if (files.length) {
          e.preventDefault();
          this.upload(UPLOAD, files);
        }
      };

      // preventDefault on dragover is required for a drop to fire on the element.
      this._onDragOver = (e) => {
        if (e.dataTransfer) e.dataTransfer.dropEffect = "copy";
        e.preventDefault();
      };

      this._onDrop = (e) => {
        const files = imageFiles(e.dataTransfer && e.dataTransfer.files);
        if (files.length) {
          e.preventDefault();
          this.upload(UPLOAD, files);
        }
      };

      this.el.addEventListener("paste", this._onPaste);
      this.el.addEventListener("dragover", this._onDragOver);
      this.el.addEventListener("drop", this._onDrop);
    },

    destroyed() {
      this.el.removeEventListener("paste", this._onPaste);
      this.el.removeEventListener("dragover", this._onDragOver);
      this.el.removeEventListener("drop", this._onDrop);
    }
  };
})();
