# Re-derivation recipe — SSO callback contract (V-callback-contract), pinned to origin/main 228090798b

Wave: web-glue-robustness-wave-2026-08-18 · lane: callback-contract · date: 2026-08-18

## A. Premise REFUTED — `Oidc.handle_callback/3` cannot return a third shape

    git show origin/main:api/lib/barkpark/sso/oidc.ex | sed -n '136,166p'

The `with/else` ends in `other -> {:error, other}`, so every non-happy path collapses to a
2-tuple; the body always returns the literal `{:ok, user, claims}`. `oidc_controller.ex:54-91`'s
two-arm `case` is therefore EXHAUSTIVE. No CaseClauseError. Same for SAML:

    git show origin/main:api/lib/barkpark/sso/saml.ex | sed -n '85,110p'

`consume/3` returns `{:ok, %{email: ...}}` (email never nil — `subject_email(assertion) == nil`
short-circuits to `{:error, :no_email}`) or `{:error, _}`, and a function-level
`rescue e -> {:error, {:parse_error, ...}}` converts even a hypothetical CaseClauseError.
`saml_controller.ex:69-83`'s `else` covers `:no_conn` / `:error` / `{:error, reason}` — exhaustive.

## B. NEW CONFIRMED 500 (class 1, param handling) — a LIST-valued param bypasses the guard

Three routes take a request param straight into an `is_binary`-guarded callee, so
`?code[]=x` / `SAMLResponse[]=x` raises **before** any validation:

| route | callee | raise |
|---|---|---|
| `GET /v1/auth/oidc/:org_slug/callback` | `Oidc.handle_callback/3` (guard `when is_binary(code)`) | FunctionClauseError |
| `POST /v1/auth/saml/:org_slug/acs` | `Base.decode64/1` (`saml_controller.ex:31`) | FunctionClauseError |
| `POST /v1/auth/saml/:org_slug/slo` | `Base.decode64/1` (`saml_controller.ex:107`) | FunctionClauseError |
| `GET /v1/auth/social/:provider/callback` | `Social.handle_callback/3` (guard `when is_binary(code)`) | code-confirmed, not run |

NOT converted to a 400: `deps/phoenix/lib/phoenix/controller/pipeline.ex:143-152` only reraises
`Phoenix.ActionClauseError` when the TOP stack frame is `{controller, action, [%Plug.Conn{}|_]}`.
Here the top frame is `Barkpark.Sso.Oidc.handle_callback/3` / `Base.decode64/2` → generic
`Plug.Conn.WrapperError.reraise` → **500**.

Reachability: the SAML pair needs only a slug with a configured SamlConnection (unauthenticated).
The OIDC arm sits behind `state != get_session(conn, :oidc_state)`; the session cookie is
SIGNED-ONLY (`api/lib/barkpark_web/endpoint.ex:9-12` — `signing_salt`, no `encryption_salt`), so a
client can read its own `oidc_state` out of the cookie and replay it with `code[]=`.

### Re-run the probe (probe lives OUTSIDE the repo; nothing to clean up)

    cd /Volumes/SATECHI/github/barkpark/api && MIX_ENV=test mix test \
      <scratchpad>/probe_callback_contract.exs 2>&1 | grep PROBE-

Observed 2026-08-18 on 228090798b:

    PROBE-OIDC-LIST-CODE => {:raised, FunctionClauseError, "no function clause matching in Barkpark.Sso.Oidc.handle_callback/3"}
    PROBE-SAML-LIST-RESPONSE => {:raised, FunctionClauseError, "no function clause matching in Base.decode64/2"}
    PROBE-SAML-LIST-SLOREQ => {:raised, FunctionClauseError, "no function clause matching in Base.decode64/2"}

### Fix shape (one-liner, in fence)

Add `when is_binary(code)` / `when is_binary(encoded)` to the *controller action head* — then the
top stack frame IS the action and Phoenix's ActionClauseError gives a clean **400** for free, with
the existing `def callback(conn, %{"org_slug" => _} = params)` fallback clause unchanged.
Regression test: assert 400 (not a raise) on `?code[]=x` with a matching session state.

## C. Baseline green (executed, same tree)

    cd /Volumes/SATECHI/github/barkpark/api && MIX_ENV=test mix test \
      test/barkpark_web/controllers/oidc_controller_test.exs \
      test/barkpark_web/controllers/saml_controller_test.exs 2>&1 | tail -3
    # => 17 tests, 0 failures

## D. V5 census-gap spot-close — in-body hard matches on these three files

`{:ok, token} = Accounts.create_user_session_token(...)` at `oidc_controller.ex:65`,
`saml_controller.ex:46`, `social_controller.ex:56` IS an in-body hard bind, but SAFE:
`accounts.ex:216-243` only fails on the changeset, whose `validate_required([:token_hash,
:user_id])` is satisfied and whose `ip_address`/`user_agent` are unvalidated `:string` (no length
cap → an oversized User-Agent header cannot red it). Fragile, not reachable. Cite, do not build.

## E. Residual, low priority

`Social.handle_callback/3` → `find_or_link/3` → `Accounts.get_user(uid)` can return `nil`, so
`{:ok, nil}` reaches `social_controller.ex:46` and `SessionIssuer.org_mfa_enrolment_blocked?(nil)`.
Requires an orphaned `SocialIdentity` row (FK makes that near-impossible). File at most.
