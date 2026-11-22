---
"@barkpark/react": patch
---

Inline text nested past the depth limit (100 levels, counting marks) keeps its words: they are drawn flat, followed by "Nested too deep to show", where before only the notice was drawn. Words more than 1000 inline levels deep are still left out, with the notice.
