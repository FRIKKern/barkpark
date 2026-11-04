// A present-only JSON data-attr (the section layout/cells precedent): a JSON object
// survives setContent→getJSON because it rides a data-attr, not a dropped node key.
// null/absent round-trips ABSENT. Closes over BOTH the attr key (`attrKey`, e.g.
// "media") and the DOM data-attr name (`dataName`, e.g. "data-media") because TipTap's
// renderHTML receives only the full attrs object.
function jsonAttr(attrKey, dataName) {
  return {
    default: null,
    parseHTML: (el) => {
      const raw = el.getAttribute(dataName);
      if (raw == null) return null;
      try {
        return JSON.parse(raw);
      } catch {
        return null;
      }
    },
    renderHTML: (attrs) =>
      attrs[attrKey] != null ? { [dataName]: JSON.stringify(attrs[attrKey]) } : {},
  };
}

export function cardAttributes(cardType) {
  return {
    // bpId — the portable-doc block id runToOps keys by.
    bpId: {
      default: null,
      parseHTML: (el) => el.getAttribute("data-bp-id"),
      renderHTML: (attrs) => (attrs.bpId ? { "data-bp-id": attrs.bpId } : {}),
    },
    // bpType — the original portable-doc block kind ("card").
    bpType: {
      default: cardType,
      parseHTML: (el) => el.getAttribute("data-bp-type") || cardType,
      renderHTML: (attrs) => ({ "data-bp-type": attrs.bpType || cardType }),
    },
    // bpBlock — the authoritative Card, carried so editing one known surface
    // never erases opaque top-level/slot keys or metadata on slot elements.
    // The editable title/body/media/action attrs remain the live values; the
    // converter overlays them onto this deep-cloned preservation baseline.
    bpBlock: jsonAttr("bpBlock", "data-bp-block"),
    // tone — PRESENT-ONLY (info|ok|warn|danger). DIVERGES from callout: a tone-less
    // card renders NO data-tone and NO modifier class (byte-matches a legacy item);
    // it must NOT gain "info" or it would emit a spurious op on round-trip.
    tone: {
      default: null,
      parseHTML: (el) =>
        el.hasAttribute("data-tone") ? el.getAttribute("data-tone") : null,
      renderHTML: (attrs) =>
        attrs.tone != null ? { "data-tone": attrs.tone } : {},
    },
    // title — the title slot heading's text, PRESENT-ONLY. A null/absent title
    // round-trips ABSENT (never ""), byte-mirroring section/callout title.
    title: {
      default: null,
      parseHTML: (el) =>
        el.hasAttribute("data-title") ? el.getAttribute("data-title") : null,
      renderHTML: (attrs) =>
        attrs.title != null ? { "data-title": attrs.title } : {},
    },
    // media / action — PRESENT-ONLY JSON carriers for the whole image/action element.
    media: jsonAttr("media", "data-media"),
    action: jsonAttr("action", "data-action"),
  };
}
