---
'@barkpark/nextjs': patch
---

Fix a concurrent-delivery dedup race in the webhook handler. The delivery id was
committed to the dedup store on arrival, so two concurrent deliveries of the same
id could let the second return `{ deduped: true }` without running `onMutation`
while the first was still in flight — and if the first then failed and rolled
back, the revalidation was silently lost. The handler now reserves the id as
in-flight and only finalizes it as settled once `onMutation` succeeds: a
concurrent same-id delivery awaits the first's outcome (deduping only on success,
otherwise running `onMutation` itself), and a failed delivery leaves nothing
recorded so a retry re-runs.
