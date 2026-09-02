<!-- doc-tier: human | canonical-for: gr-p4-members-env-evidence | budget: 400tok -->
# G-06 Members — evidence shots

Evergreen headless-Chrome shots (1440w, ×2 DPR) of the admin/member states,
light + dark. Regenerate from the SPA preview harness:

    node cloud/priv/static/__preview__/serve.mjs --port 4188 &
    # then per (scenario, theme), append the deepLink hash to the URL:
    #   ?scen=<scenario>&theme=<light|dark>#settings/members

The three `env-*` rows this page carried were deleted with the team env-var
feature (cch-w53-bl, Option A, ruled 2026-09-02 — prod `env_vars` held zero rows
ever). Their scenarios no longer exist, so the shots cannot be regenerated; the
page keeps the members half, which still can be.

| shot | scenario | state |
|---|---|---|
| `members-populated-{light,dark}` | `members-populated` | admin roster (3 roles) + pending invitations |
| `members-member-{light,dark}` | `members-member` | plain-member read-only roster (no manage affordances) |

Gate as-run at build: 554/554 app tests, 63/63 smoke, css_check 0 errors
(765 classes / 516 contrast pairs).
