// Clipboard format selection runs before any transaction or media upload.
// Files and HTML can be different items, not necessarily alternate renditions.
export function clipboardPastePolicy(view, event, slice) {
  const data = event?.clipboardData;
  if (!data) return null;
  const html = data.getData("text/html") || "";
  const text = data.getData("text/plain") || "";
  const files = [...(data.files || [])].filter(file => file?.type?.startsWith("image/"));
  const plain = view.input?.shiftKey && view.input.lastKeyCode !== 45;
  if (plain) return text ? { plain: true } : {
    blocked: "The clipboard has no plain text. Copy text to paste, or paste an image file without Shift.",
  };
  if (files.length === 1 && html) {
    const doc = new DOMParser().parseFromString(html, "text/html");
    const images = [...doc.body.querySelectorAll("img")];
    const image = images[0];
    const onlyImageWrappers = [...doc.body.querySelectorAll("*")].every(el =>
      /^(IMG|DIV|SPAN|P|FIGURE)$/.test(el.tagName));
    // Browsers supply HTML and a file for one copied image. Its source is only
    // compared as text; the actual bytes still go through the host uploader.
    const imageText = image && [image.getAttribute("src"), image.getAttribute("alt")]
      .filter(Boolean).map(value => value.trim());
    if (images.length === 1 && onlyImageWrappers && !doc.body.textContent.trim() &&
        (!text.trim() || imageText.includes(text.trim()))) {
      return { imageAlt: image.getAttribute("alt") || null };
    }
  }
  if (files.length && (html.trim() || text.trim())) return {
    blocked: "The clipboard contains both image files and formatted content or text. Paste text with Ctrl+Shift+V, or drag the image files into the editor separately.",
  };
  if (files.length) return null; // Existing host-owned upload path.
  // An <img> inside formatted content is no longer a reason to refuse the whole
  // paste (task-76c5440175affe20): stripPastedImages leaves it out, the text
  // lands, and the canvas names what was left out.
  if (slice && !slice.content.size && (html || text || data.files?.length)) return {
    blocked: "This clipboard content cannot be represented here. Copy text or an image file to paste.",
  };
  return null;
}

// Only existing native image/Figure wrappers are represented by our schema. Do
// not fetch external images or reinterpret arbitrary HTML as an upload: every
// other <img> is removed before parsing, and counted so the canvas can say so.
// A <figure> keeps its caption text; a <picture>/<source> wrapper goes with it.
export function stripPastedImages(html) {
  if (!html || !/<img[\s>]/i.test(html)) return { html, count: 0 };
  const doc = new DOMParser().parseFromString(html, "text/html");
  const native = "figure[data-bp-type='image'], figure[data-bp-type='figure']";
  const stray = [...doc.querySelectorAll("img")].filter(image => !image.closest(native));
  if (!stray.length) return { html, count: 0 };
  for (const image of stray) {
    const picture = image.closest("picture");
    (picture || image).remove();
  }
  return { html: doc.body.innerHTML, count: stray.length };
}
