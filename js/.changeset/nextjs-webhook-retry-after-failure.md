---
'@barkpark/nextjs': patch
---

Fix the webhook handler dropping an event when `onMutation` throws. The delivery-id was committed to the dedup LRU *before* `onMutation` ran, so when `onMutation` threw the handler returned a retryable `500 handler_failed` — but Barkpark's redelivery then hit the dedup guard and got `200 { deduped: true }`, silently and permanently skipping the mutation (cache revalidation / side effect). The catch block now rolls back the dedup commit (`seenDeliveries.delete(deliveryId)`) before returning 500, so a redelivery re-invokes `onMutation`. Restores the intended at-least-once semantics.
