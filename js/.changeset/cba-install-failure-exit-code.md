---
'create-barkpark-app': patch
---

A dependency install the user asked for that fails now exits 1 instead of 0, and the outro says `Done, with warnings.` instead of a green `Done.` that contradicted the yellow errors. Scripted use (`create-barkpark-app x -y && cd x && npm test`) no longer proceeds silently on a half-installed tree. Nothing else changes: the finished scaffold stays on disk, git init still runs, the next-steps output still shows the manual install command, and `--skip-install` still exits 0.
