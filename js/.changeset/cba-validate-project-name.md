---
'create-barkpark-app': patch
---

Validate a non-interactively supplied project name. The interactive prompt already rejects an empty or dot-leading name, but a name passed as a positional argument or with `--yes` skipped that check — so `create-barkpark-app .` (or `/`, an empty string, or whitespace) normalized to the current directory and failed later with a confusing "directory not empty" error. These now fail fast with a clear "Invalid project name" message.
