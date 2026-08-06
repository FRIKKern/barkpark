<!-- doc-tier: cold | canonical-for: legendary-paper-restart-verify-14 | budget: 2100tok -->
# Restart Verify 14 — Studio authorization and reconnect

Assignment `restart-verify-14` tested Studio authorization roles, live expiry/revocation, and the required reconnect proof. Verdict: **refuted as a conjunction; initial and live authorization pass, forced reconnect is unproven**.

The declared 20-cell initial policy matrix passes 20/20. Anonymous production-posture access denies mount/read/write/admin; service-session, ordinary member, and read-only principals receive their intended capability subsets; admin receives all four. Passing persistence oracles prove forged read-only writes leave document counts unchanged, component-targeted Paper writes leave blocks unchanged, and unauthorized share/link actions create zero rows.

Grant expiry and revocation are directly tested on live sockets. Expiry redirects when the expiring grant is the last covering grant; revocation broadcasts and kills an uncovered live socket; another valid grant keeps the caller connected while the expired grant disappears from context. Revoked and expired API tokens fail verification, and token revocation emits a `token_revoked` audit event.

| Suite | Result |
|---|---:|
| Studio policy/liveness | 64 tests, 0 failures |
| Component/Paper write boundaries | 23 tests, 0 failures |
| Token lifecycle/audit primitives | 39 tests, 0 failures |
| Initial actor/control cells | 20/20 supported |
| Forced transport drops/reconnects | 0 |
| Captured reconnect handshakes/frames | 0 |

The reconnect threshold fails. No existing suite forces a WebSocket transport drop, captures reconnect frames, or proves Studio audit/mutation counts across reconnect. The authorization census found 87 relevant declared tests but no websocket reconnect action, frame assertion, Studio reconnect audit query, or reconnect write-count assertion. Connected `LiveAuth` re-verifies the browser-session token, so fail-closed reconnect is plausible from code, but that inference is not proof. Direct Bearer resolution in the dead-render plug also does not prove a raw Bearer-only WebSocket reconnect.

Canonical worktree dependencies were absent. The installed shared cache was lock-incompatible, including Req 0.5.17 versus the required `~>0.6.1`. The verifier first recorded that failure, then copied exact application source into `/private/tmp` and ran a compatibility harness without installing or modifying repository dependencies. Passing source-path tests therefore do not prove the canonical locked dependency set.

A conclusive follow-up needs a disposable real Endpoint/browser-WebSocket test that captures initial and forced-reconnect frames for anonymous, service-session, admin, member, and read-only actors; expires or revokes authorization between disconnect and reconnect; and queries audit/mutation rows before and after. Repository, Barkpark, and production mutations were zero.

## Cycle payload

```json
{"assignment_id":"restart-verify-14","cycle_uuid":"0bb79067-ad57-498c-81a6-7ab653c43dd2","verdict":"refuted","initial_policy":{"declared_cells":20,"supported_cells":20},"tests":{"studio_policy":{"passed":64,"failed":0},"component_write_boundaries":{"passed":23,"failed":0},"token_lifecycle":{"passed":39,"failed":0},"canonical_lock_exact":false},"reconnect":{"forced_transport_drops":0,"handshake_frames":0,"proven":false},"expiry_revocation":{"live_grant_expiry_proven":true,"live_grant_revoke_proven":true,"token_filter_proven":true},"read_only":{"deny_side_writes":0,"reconnect_write_count_proven":false},"audit":{"token_revoke_proven":true,"studio_reconnect_matrix_proven":false},"blocked":["canonical dependencies absent from worktree","installed dependency cache lock-incompatible","no existing forced WebSocket reconnect fixture"],"mutations":{"repo":0,"barkpark":0,"production":0}}
```
