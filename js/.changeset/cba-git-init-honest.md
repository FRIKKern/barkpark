---
"create-barkpark-app": patch
---

A failed `git init`/`add`/`commit` sequence no longer strands a half-initialised repository in silence: the scaffold now prints a yellow warning with the manual recovery command (mirroring the dependency-install failure path) and removes the `.git` this run created (create-next-app precedent). A pre-existing repository is never touched. The measured repro — a global `commit.gpgsign=true` with a broken signer — used to leave `.git` present, files staged, zero commits, and zero output.
