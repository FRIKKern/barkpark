<!-- doc-tier: human | canonical-for: gr-p4-members-env-evidence | budget: 400tok -->
# G-06 Members + env-vars — evidence shots

Evergreen headless-Chrome shots (1440w, ×2 DPR) of the four admin/member states,
light + dark. Regenerate from the SPA preview harness:

    node cloud/priv/static/__preview__/serve.mjs --port 4188 &
    # then per (scenario, theme), append the deepLink hash to the URL:
    #   ?scen=<scenario>&theme=<light|dark>#settings/<members|env>

| shot | scenario | state |
|---|---|---|
| `members-populated-{light,dark}` | `members-populated` | admin roster (3 roles) + pending invitations |
| `members-member-{light,dark}` | `members-member` | plain-member read-only roster (no manage affordances) |
| `env-populated-{light,dark}` | `env-populated` | admin env rows (secret / write-once / scopes) + add-var form |
| `env-member-{light,dark}` | `env-member` | plain-member read-only env rows (no add form, no delete) |
| `env-write-once-409-{light,dark}` | `env-write-once-409` | the sealed write-once row state (POST-collision 409 copy unit-pinned) |

Gate as-run at build: 554/554 app tests, 63/63 smoke, css_check 0 errors
(765 classes / 516 contrast pairs).
