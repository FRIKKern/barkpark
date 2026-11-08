// ── doctrine template attrs (pdd-t2): locked / role round-trip ───────────────
//
// A mandated template block carries `locked: true` + a `role` ("title" |
// "featured"). These are TOP-LEVEL block keys (see Content.Papers.Template), NOT
// content — so the canvas must carry them through the blocks ⇄ node ⇄ blocks
// round-trip for the prose title (an opaque image carries them for free inside
// its verbatim bpBlock). Both directions are D3-additive: an UNLOCKED block gets
// NO locked/role key, so it saves byte-identically (the pre-#1161 corpus is
// untouched). locked/role are NEVER a diff-relevant field (the stable-key
// change-detectors ignore them) and NEVER ride a patch (patch.ex strips them):
// they are immutable template identity, seeded at create, carried here for
// fidelity + so the live node can be recognized as locked.

// Stamp locked/role onto a NODE attrs bag from its source block — only when set.
function stampTemplateAttrs(attrs, block) {
  if (block && block.locked === true) attrs.locked = true;
  if (block && block.role != null) attrs.role = block.role;
  return attrs;
}

// Carry locked/role back onto a reconstructed BLOCK from its node attrs — only
// when set (the inverse of stampTemplateAttrs). BpAttrs' parseHTML yields null
// for an absent attr, so an unlocked node adds nothing.
function carryTemplateAttrs(block, attrs) {
  if (attrs && attrs.locked === true) block.locked = true;
  if (attrs && attrs.role != null) block.role = attrs.role;
  return block;
}

export {
  carryTemplateAttrs,
  stampTemplateAttrs,
};
