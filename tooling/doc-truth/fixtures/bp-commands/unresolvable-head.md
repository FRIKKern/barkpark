# FIXTURE — a head that resolves in NO source.

`totally-not-a-noun` is in no manifest row, no completionNouns entry and no
router switch. The gate must FAIL on it, never skip it.

```sh
bp totally-not-a-noun list
```
