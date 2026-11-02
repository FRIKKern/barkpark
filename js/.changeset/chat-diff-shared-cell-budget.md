---
"@barkpark/react": patch
---

A `chat-tool-diff` multi-edit block's line diffs share one cell budget, matching the server renderer: an edit past what is left shows its plain before and after instead of a line diff. Edits within the budget render as before.
