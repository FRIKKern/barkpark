---
'@barkpark/core': patch
---

typedClient: preserve the `TypeMap` across `.withConfig()`. `TypedClient<TMap>` inherited `withConfig()` from the open `BarkparkClient`, so `typedClient<TMap>(bp).withConfig({ perspective: 'drafts' })` returned a plain `BarkparkClient` and silently dropped all schema typing on the exact drafts pattern the README leads with. `withConfig` is now re-narrowed to return `TypedClient<TMap>`. Pure type-level change — the runtime is unchanged (typedClient stays an identity cast).
