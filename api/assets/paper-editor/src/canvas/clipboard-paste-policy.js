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
  if (html) {
    const doc = new DOMParser().parseFromString(html, "text/html");
    // Only existing native image/Figure wrappers are represented by our schema.
    // Do not fetch external images or reinterpret arbitrary HTML as an upload.
    const missingImage = [...doc.body.querySelectorAll("img")].some(image =>
      !image.closest("figure[data-bp-type='image'], figure[data-bp-type='figure']"));
    if (missingImage) return {
      blocked: "This formatted content includes an image that cannot be pasted together with its text. Paste text with Ctrl+Shift+V, or drag the image file into the editor separately.",
    };
  }
  if (slice && !slice.content.size && (html || text || data.files?.length)) return {
    blocked: "This clipboard content cannot be represented here. Copy text or an image file to paste.",
  };
  return null;
}
