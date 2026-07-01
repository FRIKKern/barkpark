---
'@barkpark/codegen': patch
---

Codegen now escapes control characters in string-literal types. A select option value or `localizedText` language key containing a raw newline, tab, or other C0/DEL control byte previously emitted a syntactically invalid `.ts` module, which made `barkpark generate` abort with an opaque prettier `SyntaxError`. Such values are now escaped (`\n`, `\r`, `\t`, `\uXXXX`), so `generate` survives any string the server accepts. Ordinary values are unchanged.
