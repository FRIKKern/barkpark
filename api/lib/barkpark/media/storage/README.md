<!-- doc-tier: human | canonical-for: media-pending-cleanup | budget: 500tok -->
# Pending local cleanup

`Media.commit_pending_delete/2` is internal. HTTP delete still uses
`Media.delete_file/2`; native cleanup is not enabled.

The transaction retains the migration-versioned raw row, supplied Windows
observation and matching asset documents before removing the row and documents.
Outer rollback restores them. Receipts distinguish `awaiting_outer_commit` from
committed `pending_cleanup`; neither grants physical settlement or recovery.
Retries require the same request, scope and database reservation. Insert, update
and COPY cannot reclaim a reserved address. Unknown schemas refuse; SQL changes
require a forward migration and digest. Rollback cannot discard retained intent.

When write admission is configured, `LocalWrite.run/2` takes the preparation
transaction's media-table lock before original-blob copy, byte write or delete.
Unresolved addresses refuse before I/O; unsupported Windows aliases refuse
conservatively. Unrelated supported keys remain writable. Ordinary servers
retain their existing admission path. Managed delete reports filesystem errors.

Physical-effect admission retains pending evidence on owner/child death or
failed/unverified I/O, even before a hold. The journal survives restart.
A database lock alone cannot prove filesystem settlement after connection loss.
Renditions, caches, remote writers, native identity, HTTP receipt propagation,
full writer coverage and reconciliation remain separate integration work.

[Windows release proof](../../../../../docs/media/evidence/C109-windows-managed-blob/README.md)
uses the three live scripts in `api/test/barkpark/media/`. Use owned fresh databases and native-observed
fixtures through `C105_PROOF_INPUT`; the writer proof also needs `C109_JOURNALS`.
Host-local operations/reservations never enter workspace bundles; unresolved
intent refuses export before copy. An export-time snapshot fence remains open.
