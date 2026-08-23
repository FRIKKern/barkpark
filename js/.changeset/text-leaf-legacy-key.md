---
'@barkpark/react': patch
---

PortableDoc: a text leaf keyed by the legacy `text` spelling (`{"type":"text","text":…}`) now renders its prose instead of dropping it. Raw mutate writers persisted whole papers in that shape; the server's Hollow predicate counts both spellings as content, so those papers published cleanly and then rendered as structure with zero visible characters. One `textLeafValue` helper (canonical `value` wins when non-empty) is shared by `renderInline`, `inlineText`, `renderCell`, and the blank-paragraph scaffold predicate — which was suppressing a legacy-keyed paragraph as an empty scaffold. Render-side only, in parity with the Elixir and Go renderers.
