---
'create-barkpark-app': patch
---

`--hosted-demo` now exits 1 before writing anything, with a message pointing at a local Barkpark: the demo host it targets (https://barkpark.dev) does not answer, so every app scaffolded with it failed its API calls. The next steps no longer advertise the flag. It comes back by flipping HOSTED_DEMO_AVAILABLE once a demo host answers.
