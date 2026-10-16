<!-- doc-tier: agent | canonical-for: personal-application-turns | budget: 1800tok -->
# Personal application turns

Sessions, messages and host leases persist application turns. No model or
repository worker runs here; legacy Claude/plan defaults stay inert.

## Deployment configuration

Release startup reads `BARKPARK_PERSONAL_CHAT_APPLICATIONS` as a JSON object.
Nonusable placeholder shape:

```json
{"application-id":{"workspace_id":"WORKSPACE_UUID","host_id":"HOST_UUID","version":"1","contract_version":"APP_CONTRACT"}}
```

Unset or `{}` disables bindings. Supplied malformed/empty input fails startup
with a fixed error, never its values. Maximum: 16 applications, 16,384 UTF-8 bytes.
Unknown/duplicate keys refuse the entire map. UUIDs must be canonical lowercase;
IDs use ASCII letters/digits plus `._-`; versions/contracts also allow `:/`.
All start alphanumeric, at most 100 bytes. There is no default Pensum profile.

Set the value through the instance's approved environment/restart procedure
([operations](../ops/PROD_OPS.md)), then verify deployed commit and authenticated
binding behavior; config alone proves neither release nor execution. Remove the
variable to recover from invalid config. Host registration/enrollment is separate;
it must already be unrevoked in the named workspace. No credentials belong here.
Changed/removed binding refuses existing sessions. Requests cannot choose a
host/provider/model/tools/owner or bind an old session through title/draft edits.

## Personal input

The following routes share the existing login/MFA/current workspace-seat gate
under `/w/:workspace_slug/v1/personal-chat`. Cookie mutations retain CSRF checks;
API tokens, host credentials, grants and anonymous callers do not substitute for
a personal login.

| Method and suffix | Body or result |
|---|---|
| `POST /applications/:application_id/sessions` | Optional `title`; returns `id`, revision 0 and `runtime_available:false`. |
| `GET /sessions/:id/application` | Committed state/identities/typed answer and exact question; latest question/status. Read terminalizes expiry. |
| `GET /sessions/:id/application/history` | Bounded whole turns; signed snapshot continuation. |
| `POST /sessions/:id/turns` | Exactly `query`, `request_id`, `expected_revision`; returns accepted turn ID, epoch, base revision, digest and status. |
| `POST /sessions/:id/turns/:turn_id/cancel` | Fences pending work; cannot cancel committed turns. |

Verified user/workspace owns the session. Store exact question/login ID, never
bearer. Limits: 6,400 question bytes, 100 request-ID bytes, revision 2,147,483,646.
One pending turn owns a revision. Identical requests replay; changed payload/stale
revision conflicts. Postgres work survives host queues. Editable title/draft cannot
supply assistant history, reader facts, selection, source identities or context.

## Executor

`Authorization: Host <credential>` protects:

- `GET /v1/chat-host/application-turns/:turn_id`
- `POST /v1/chat-host/application-turns/:turn_id/commit`

Fetch returns question, actor user/workspace, contract version and committed
context/selection/source identities, never the reader credential/login ID. Host
must match the binding and cannot create personal input.

Commit requires `epoch`, `expected_revision`, `request_digest` and `result`:

```json
{
  "contract_version": "application-context/1",
  "context": {},
  "selection": [],
  "source_identities": [],
  "answer": {"id": "application-answer-id", "text": "completed display text", "presentation": {}}
}
```

Version must match; context/presentation are objects. Limits: three selections,
100 sources, 200 answer-ID bytes, 64,000 answer-text bytes, 128,000 result bytes.
Applications validate domain semantics at commit/read. Metadata retains typed
statements/citations; generic plain-text history gains no typed authority.
Structural validation establishes neither semantic truth nor source permission.

Fetch/commit recheck accepting-login expiry/revocation/org/MFA policy, read seat,
host credential/version, binding and nonarchived owner. Host auth never delegates
source authority. Applications must introspect their personal source reader and
match the accepted actor or refuse; broader delegation is unsupported.

A session lock serializes acceptance/commit. Commit atomically writes the typed
assistant message, updates context and completes the lease. Identical commits
replay; changed content conflicts. Pending/cancelled/expired/archived work cannot
advance context. The 120-second deadline cannot be extended by host heartbeat.
Archive cancels work; restore cannot revive it. Generic host/herd events cannot
write application leases. Personal CLI runtime stays closed, even for operators.

Stored source IDs grant no reuse. The application rechecks withdrawal, cancellation
and current source-use authority before commit/display. Withdrawal keeps the
question and an unavailable-answer notice, never stale prose.

## Typed history

Accept only `limit` (canonical integer string 1–10, default 5) or only opaque
`cursor` (4,096 bytes maximum, one hour). Framework signing binds owner, workspace,
session, application binding, revision and maximum sequence. Pages recheck
personal access. Later questions stay outside the snapshot; new commits return
409. Pending statuses are current observations; expiry becomes terminal. Fresh
owner login may read older turns; archive/changed configuration still refuses.

Pages contain the newest remaining whole turns, returned chronologically:
`{id,revision,contract_version,snapshot_max_seq,turns,has_more,next_cursor}`.
Each turn has `turn_id,user_message_id,user_seq,query,status,base_revision,
committed_revision,answer`. Committed `answer` contains
`message_id,seq,contract_version,selection,source_identities,answer` (the typed
answer object above); otherwise it and `committed_revision` are null. Status is
accepted, committed, cancelled, expired, archived or revoked. Message IDs and
sequences are positive JSON-safe integers; empty snapshot sequence is zero.
Exact lease/message/query joins are checked; corrupt or orphaned rows refuse.
Internal accepting-login, host and lease fields are not exposed.

UTF-8 JSON is capped at 256,000 bytes including cursor/envelope. Return fewer
whole turns with continuation to fit; a single oversized/invalid turn refuses,
never drops or loops empty. Display still requires fresh source-use checks.
No historical context snapshot or expanded model memory is supplied.

## Verification

Account export includes context/message metadata; deletion/erasure cascades leases.
No attachments or provider process are created. External executors must observe
cancellation; storage fences late commits, not model billing.

Owners: `StudioChat.ApplicationTurns`, `ApplicationBinding`,
`ApplicationChatController`, `RequirePersonalChatAccess`, `RequireChatHost`.
Run strict `runtime_personal_chat_applications_test.exs`,
`studio_chat_application_turns_test.exs`, `application_chat_controller_test.exs`
and personal/legacy/host/layering regressions.
Ecto tests use fictional payloads, not deployment/sign-in/model proof.
