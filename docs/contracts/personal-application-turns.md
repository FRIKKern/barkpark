<!-- doc-tier: agent | canonical-for: personal-application-turns | budget: 1800tok -->
# Personal application turns

StudioChat sessions, messages and host leases store accepted
input and committed application state. No model or repository worker runs here;
legacy personal Claude/plan defaults remain inert.

The instance must explicitly configure `:personal_chat_applications` as a map
from application ID to `%{workspace_id:, host_id:, version:, contract_version:}`.
Absent or changed configuration refuses use. The bound machine must be registered
and unrevoked in that workspace. Requests cannot choose the host, provider, model,
tools, callback, system prompt or owner, or bind existing rows via title/draft.

## Personal input

The following routes share the existing login/MFA/current workspace-seat gate
under `/w/:workspace_slug/v1/personal-chat`. Cookie mutations retain CSRF checks;
API tokens, host credentials, grants and anonymous callers do not substitute for
a personal login.

| Method and suffix | Body or result |
|---|---|
| `POST /applications/:application_id/sessions` | Optional `title`; returns `id`, revision 0 and `runtime_available:false`. |
| `GET /sessions/:id/application` | Last committed revision, context, selection, source identities, contract version, last turn and typed answer, plus latest turn status. Expired work becomes terminal on read. |
| `GET /sessions/:id/application/history` | Bounded typed whole turns with signed snapshot continuation; see below. |
| `POST /sessions/:id/turns` | Exactly `query`, `request_id`, `expected_revision`; returns accepted turn ID, epoch, base revision, digest and status. |
| `POST /sessions/:id/turns/:turn_id/cancel` | Cancels pending work and advances its fence. A committed turn cannot be cancelled retrospectively. |

Verified user/workspace owns the session. Acceptance stores the exact question
and login-session ID, never its bearer. Limits: 6,400 UTF-8 question bytes, 100
request-ID bytes, revision 2,147,483,646. One pending turn owns a revision. Identical
requests replay; changed payload or stale revision conflicts. Work survives in
Postgres independently of the host queue. Reader-editable title/draft confer no
context authority; personal callers cannot submit assistant history, reader facts,
selection, source identities or context.

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

Version must match. Context and presentation are JSON objects. Limits: three
selections, 100 source identities, 200 answer-ID bytes, 64,000 answer-text bytes,
128,000 complete-result bytes. Applications validate domain semantics before
commit and consumption. Message metadata retains typed statements/citations.
State GET includes latest-turn and last-committed exact questions and one typed
answer. Generic plain-text history gains no typed authority. Backend structural
validation establishes neither semantic truth nor source permission.

Fetch and commit recheck the exact accepting login (expiry, revocation and org
policy), MFA policy, current read seat, host credential/version, binding and
nonarchived personal owner. A host credential never becomes delegated source
authority. Applications that read sources using a configured personal session
must independently introspect that session and match the accepted actor, or
refuse. A broader delegated-reader facility is not part of this contract.

The session row lock serializes acceptance and commit. Commit atomically writes
the assistant message with turn/revision/answer/selection/source metadata,
updates the last committed application context and marks the lease complete.
An identical commit replays its receipt; different content conflicts. Pending,
cancelled, expired and archived work never advances committed context. A fixed
120-second application deadline cannot be extended by a host heartbeat. Archive
cancels pending work; restore does not revive it. Generic host events and herd
reports cannot write application leases. Personal CLI runtime entry remains
closed, including for an operator.

Stored source IDs require rereading; they grant no prose/source/rights reuse.
The application guards withdrawal/cancellation and currentness before commit and
before displaying restored licensed text. Withdrawal retains the question and an
unavailable-answer notice, never stale prose. Storage is not current permission.

## Typed history

Accept only `limit` (canonical integer string 1–10, default 5) or only opaque
`cursor` (4,096 bytes maximum, one hour). Framework signing binds owner, workspace,
session, application binding, revision and maximum sequence. Every page rechecks
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
Run the strict wrapper over `studio_chat_application_turns_test.exs` and
`application_chat_controller_test.exs`, plus personal/legacy/host regressions.
Ecto tests use fictional payloads, not deployment/sign-in/model proof.
