<!-- doc-tier: cold | canonical-for: legendary-paper-restart-operational-incident | budget: 1800tok -->
# Legendary Paper restart — operational incident and recovery

During restart Verify 10–12, the temporary campaign worktree became unreachable twice and the shared main repository directory was moved to the SATECHI volume Trash. No destructive deletion was observed. The repository was located at `/Volumes/SATECHI/.Trashes/501/barkpark` and restored with a direct move to its original path. The main checkout returned at commit `a31faa52d` with its pre-existing user-owned changes intact.

The campaign branch remained committed through `706e82340`. Once the main Git directory was restored, the temporary worktree and its three uncommitted Verify 10–12 ledgers became reachable again. They passed diff/doc-budget checks and were committed as `2acc10604`. No committed campaign evidence was lost.

To remove dependence on temporary-directory cleanup, a persistent repository-owned worktree was created at `.omx/worktrees/legendary-paper-upgrade-20260805` on branch `feat/legendary-paper-reader-upgrade-20260805-persistent`, starting exactly at `2acc10604`. The original branch remains at the same commit for traceability. Subsequent agents are forbidden from deleting, trashing, or moving any repository/worktree/cwd/parent; cleanup is restricted to an explicit self-created `/private/tmp` directory whose literal path is validated before removal.

After recovery, live Cycle authority and the campaign Paper's embedded `{cycle_ledger,fleet}` projection hashed identically. Verify 10–12 results were then appended normally and the Paper was republished before Verify 13–15 assignments.

Separately, Verify 11 reported that two credential values were unintentionally printed in internal diagnostic output. The values are omitted from every ledger, Cycle payload, commentary update, and commit. No credential was changed. The guerrilla admin API token and cloud token require rotation through the credential-owning operational path; this campaign cannot safely perform that credential-gated external action implicitly.

## Proven boundary

- Main repository: restored, pre-existing changes preserved.
- Campaign commits: preserved through `2acc10604`.
- Verify 10–12 ledgers: recovered, validated, committed.
- Barkpark Task/Paper/Cycle: no evidence lost; exact projection re-established.
- Credentials: values not repeated; rotation still required.
- Root cause: not proven. The incident is recorded as cleanup/path-scope failure, not attributed to a person or command without evidence.
