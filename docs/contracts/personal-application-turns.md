<!-- doc-tier: agent | canonical-for: personal-application-turns | budget: 1800tok -->
# Personal application turns

This additive contract uses StudioChat sessions, messages and registered-host
execution leases. It stores accepted input and committed application state. It
does not run a model or repository worker. Legacy personal sessions remain
storage-only; their Claude/plan defaults never become application configuration.

The instance must explicitly configure `:personal_chat_applications` as a map
from application ID to `%{workspace_id:, host_id:, version:, contract_version:}`.
Absent or changed configuration refuses use. The binding names an already
registered, unrevoked machine in the same workspace. No HTTP request chooses a
host, provider, model, tools, callback URL, system prompt or owner. Existing rows
cannot acquire a binding through a title/draft edit.

## Personal input

The following routes share the existing login/MFA/current workspace-seat gate
under `/w/:workspace_slug/v1/personal-chat`. Cookie mutations retain CSRF checks;
API tokens, host credentials, grants and anonymous callers do not substitute for
a personal login.

| Method and suffix | Body or result |
|---|---|
| `POST /applications/:application_id/sessions` | Optional `title`; returns `id`, revision 0 and `runtime_available:false`. |
| `GET /sessions/:id/application` | Last committed revision, context, selection, source identities, contract version, last turn and typed answer, plus latest turn status. Expired work becomes terminal on read. |
| `POST /sessions/:id/turns` | Exactly `query`, `request_id`, `expected_revision`; returns accepted turn ID, epoch, base revision, digest and status. |
| `POST /sessions/:id/turns/:turn_id/cancel` | Cancels pending work and advances its fence. A committed turn cannot be cancelled retrospectively. |

Ownership comes from the verified user/workspace. Acceptance stores the raw
question and original login-session ID, never its bearer. The question is capped
at 6,400 UTF-8 bytes, request ID at 100 bytes and context revision at 2,147,483,646.
One pending turn may use a committed revision. Same request and payload replay
the durable turn; changed payload or stale revision conflicts. The accepted work
lives in Postgres, independently of the process-local host command queue.

Title and draft remain reader-editable. Neither is authoritative application
context. A personal caller cannot submit assistant history, inferred reader facts,
selection, source identities or a context snapshot.

## Executor work and commit

The existing `Authorization: Host <credential>` gate protects:

- `GET /v1/chat-host/application-turns/:turn_id`
- `POST /v1/chat-host/application-turns/:turn_id/commit`

Fetch returns the persisted question, actor user/workspace, contract version and
last committed context/selection/source identities. It does not return the reader
credential or accepting session ID. The host must match the immutable binding;
host credentials alone cannot create a personal input turn.

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

The configured contract version must match. Context is a JSON object; selection
has at most three entries, source identities at most 100, answer ID at most 200
bytes, answer text at most 64,000 bytes and the complete result at most 128,000
bytes. The application validates the domain-specific contents before committing
and when consuming them. The required `presentation` object preserves typed
statements/citations under that application version in existing message metadata.
State GET returns one bounded last-committed answer envelope, not an unbounded
history. The generic plain-text history route gains no typed-source authority.
Backend version/bounds validation establishes neither
semantic truth nor source permission.

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

On a follow-up, stored source identities are references to re-read, not a grant
to reuse old prose, source text or rights. Source withdrawal/cancellation and a
final currentness check remain responsibilities of the application's guarded
evidence operation. Reject a result before commit if its evidence is no longer
available. Before displaying restored licensed text, recheck current personal
source-use authority. Withdrawal retains the user question and an unavailable
answer notice, not stale source prose. Historical storage is not proof of current
permission.

## Privacy and verification

Account export includes committed context and message metadata. Existing session
deletion/erasure cascades accepted leases; no attachments or provider process are
created by this contract. An external executor must observe refusal/cancellation;
storage fencing prevents its late commit and does not promise zero model billing.

Source owners: `StudioChat.ApplicationTurns`, `ApplicationBinding`,
`ApplicationChatController`, `RequirePersonalChatAccess`, `RequireChatHost`.
Run the strict wrapper over `studio_chat_application_turns_test.exs` and
`application_chat_controller_test.exs`, plus personal/legacy/host regressions.
The tests use real local Ecto transactions and fictional payloads. They cannot
establish deployed compatibility, a usable reader sign-in, model quality or
permission to activate an application.
