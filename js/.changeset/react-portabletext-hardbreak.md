---
'@barkpark/react': minor
---

`<PortableText>` now renders a `\n` inside a span as a hard line break (`<br/>`), matching the Portable Text convention and the reference renderer. Previously newlines collapsed under HTML whitespace rules, silently losing intentional line breaks in content. Override the element with `components.hardBreak`, or pass `components.hardBreak = false` to keep the old raw-text behavior. Content without newlines renders byte-identically.
