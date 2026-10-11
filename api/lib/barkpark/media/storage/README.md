<!-- doc-tier: human | canonical-for: media-pending-cleanup | budget: 500tok -->
# Pending local cleanup

`Media.commit_pending_delete/2` is an internal database operation. Existing HTTP
delete routes still call `Media.delete_file/2`; they do not adopt it.

The transaction captures the raw media row, supplied Windows observation and
matching asset documents, then removes the row and documents with a durable
`pending_cleanup` record. Outer rollback restores these database changes. An
outer receipt says `awaiting_outer_commit`; it never claims physical removal or
permission to recover.

Retries require the same request, caller scope and database reservation. Insert,
update and COPY triggers reserve ASCII keys across scopes and case aliases.
Ambiguous or unsupported existing keys refuse migration installation. Migration
rollback refuses to discard retained operations.

Physical writers can write before inserting rows. Native cleanup stays disabled
until they share the reservation. Windows paths are compared after separator and
drive normalization; observations expire and cannot authorize later deletion.
Native identity, HTTP receipts, admission, remote storage, event/rendition retries
and complete collection remain separate integration work.

Standalone release tests: `api/test/barkpark/media/media_pending_delete_live.exs`
and `media_pending_delete_interrupt_live.exs`. They require an owned fresh
database and native-observed fixtures through `C105_PROOF_INPUT`; never use a
person's library. Barkdown C105 retains build, fixture and restart evidence.

11 October 2026: candidate on the retained Windows runtime. Changed modules were
compiled against carried dependencies. Current-main integration, full upstream
build/tests and the CI formatter remain required.
