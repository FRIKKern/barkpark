---
'@barkpark/react': patch
---

Render cancelled task-board rows in the derived cancel lane. The React `taskboard` block now builds its board columns from the status manifest's derived board-roles order (cancel moved last) instead of a hand-typed role literal, matching the Elixir, Go, and mobile board surfaces so cancelled rows appear in their own lane rather than being dropped.
