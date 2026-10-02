---
'create-barkpark-app': patch
---

The "Next steps" `cd` line quotes a directory name that is not one plain shell word: `create-barkpark-app "Bad Name!"` now prints `cd 'Bad Name!'` instead of `cd Bad Name!`, which the shell split in two. Plain names print unchanged.
