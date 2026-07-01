---
'create-barkpark-app': patch
---

website-starter: the contact form's submit-result message is now a persistent `role="status"` / `aria-live="polite"` region, so screen readers announce whether the submission succeeded or failed. Previously the message was inserted into the DOM only after submit, so assistive tech could miss the announcement.
