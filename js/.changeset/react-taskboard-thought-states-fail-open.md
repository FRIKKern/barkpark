---
'@barkpark/react': minor
---

Task status vocabulary learns the two thought states and fails OPEN on the unknown. `STATUS_ROLES` / `STATUS_TO_ROLE` gain `considering` (`◌` U+25CC, dim) and `researching` (`◎` U+25CE), so `roleOf('considering')` / `roleOf('researching')` resolve to their own dim glyph roles instead of masquerading as bright `open`. An UNRECOGNIZED non-empty status now fails open to a new dim-neutral `unknown` role (`◦` U+25E6) rather than the bright `open` circle; an ABSENT/empty status still defaults to `open` (nothing about today's blank-status rows changes). The `task-board` emitter gains trailing dim `considering`/`researching` columns (empty columns collapse), and homes any column-less (`unknown`) row in the `open` column while painting the row's own glyph — placement and styling decouple, so a row is never dropped. Known-status board output is byte-identical to before (goldens unaffected).
