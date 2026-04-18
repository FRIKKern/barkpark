# docs-site/

Placeholder directory that Track A's Fumadocs app (`apps/docs/`) will
read at build time.

Contents, all owned by Track C (this track):

| Path                        | Who writes it       | Notes                                              |
| --------------------------- | ------------------- | -------------------------------------------------- |
| `reference/<package>/`      | CI (`typedoc.yml`)  | Regenerated on every push to `main`, not committed |
| `ops/adding-a-domain.md`    | Track D (W5)        | Ops doc stub — Caddy TLS walkthrough               |

Nothing here is a runnable site on its own. The Fumadocs app (Track A) is
the consumer.
