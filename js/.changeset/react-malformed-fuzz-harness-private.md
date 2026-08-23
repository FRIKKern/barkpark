---
---

Tests-only (no release): adversarial malformed-input fuzz harness for the @barkpark/react block emitters — every registered type × hostile field shapes (null/scalar/map-for-list/nested garbage) must degrade, never throw, mirroring the Elixir walk.ex children:null hardening (#12425). Zero crash-class findings on the current emitters; the harness pins the contract (proven by mutation: stripping one asList coercion reds exactly its type).
