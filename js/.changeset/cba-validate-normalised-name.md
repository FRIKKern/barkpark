---
"create-barkpark-app": patch
---

The interactive project-name prompt now validates the NORMALISED name — the value the run actually uses — via the same rule as the non-interactive path (one owner). An entry like `foo/..` used to pass the raw-value check, normalise to `..`, and point the scaffold at the parent directory, surfacing as a confusing "target not empty" error naming a directory the user never typed.
