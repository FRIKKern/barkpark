---
'create-barkpark-app': patch
---

website-starter: the contact form now has field caps, a honeypot and a per-IP rate limit.

The form is an anonymous write made with the site's server token. A loop of submissions could create as many documents, as large as Next's 1 MB action body allows, as the caller liked. `lib/contact-guard.ts` adds three checks before the write:

- **Field caps:** name 200, email 320, message 5000 characters.
- **Honeypot:** a hidden `bp_hp` input, the same field the astro-starter uses. A filled one gets the normal thank-you and nothing is written.
- **Rate limit:** 5 submissions per client IP per 10 minutes. The counter is in memory, so it is per server instance: on serverless or multi-instance hosting each instance counts separately, and a restart resets it. Use your host's rate limiting or a shared store if you need a global limit.

Projects scaffolded from an earlier version can copy `lib/contact-guard.ts`, `app/contact/actions.ts` and `app/contact/page.tsx`.
