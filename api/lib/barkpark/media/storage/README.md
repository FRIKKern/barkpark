<!-- doc-tier: human | canonical-for: media-pending-cleanup | budget: 500tok -->
# Pending local cleanup

`Media.commit_pending_delete/2` is an internal database operation. Existing HTTP
delete routes still call `Media.delete_file/2`; they do not adopt it.

The transaction captures the raw media row, supplied Windows observation and
matching asset documents, then removes the row and documents with a durable
`pending_cleanup` record. Outer rollback restores these changes. An
outer receipt says `awaiting_outer_commit`; it never claims physical removal or
permission to recover.

Retries require the same request, caller scope and database reservation. Insert,
update and COPY triggers reserve ASCII keys across scopes and case aliases.
Ordinary co-owners and legacy addresses remain valid; intent preparation
requires one physical claimant and a validated Windows-relative key. Migration
rollback refuses to discard retained operations.

Physical writers can write before inserting rows. Native cleanup stays disabled
until they share the reservation. Windows paths are compared after separator and
drive normalization; observations expire and cannot authorize later deletion.
Native identity, HTTP receipts, admission, remote storage, event/rendition retries
and complete collection remain separate integration work.

Release tests: `api/test/barkpark/media/media_pending_delete_live.exs`
and `media_pending_delete_interrupt_live.exs`. They require an owned fresh
database and native-observed fixtures through `C105_PROOF_INPUT`; never use a
person's library. Barkdown C105 retains evidence.
Host-local operations and reservations are excluded from workspace bundles;
unresolved operations refuse ordinary and development export before copy.
This is a preflight refusal; an export-time writer/snapshot fence remains open.

13 October: upstream integration and migration/media/export regressions are
in validation. Full upstream gates remain required.
