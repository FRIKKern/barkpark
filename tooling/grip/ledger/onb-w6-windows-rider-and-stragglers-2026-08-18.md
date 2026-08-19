<!-- doc-tier: cold | canonical-for: onb-w6-windows-rider-stragglers-rederive | budget: 900tok -->

# Onboarding wave 6 — windows-smoke rider + PR stragglers (re-derivation)

Verifier evidence for the #12062 windows-smoke stamp wording, the D36 client.go
fence, and the LAST-SEEN builder brief. Re-derive:

## (a) windows-smoke.yml runs — has the rider fired on a real install-cli.ps1 PR?

    gh run list --workflow=windows-smoke.yml --limit 20 --json headBranch,event,conclusion,createdAt,displayTitle
    git show origin/main:.github/workflows/windows-smoke.yml | sed -n '/^on:/,/jobs:/p'
    gh pr view 12062 --json files,mergeCommit,mergedAt,headRefName

VERDICT: NO. Only TWO runs ever, both from #12062's own introduction:
  - pull_request run on branch loop-epic/windows-smoke-yml-install-cli-ps1-actual-3-r @ 2026-08-17T21:57:12Z (success)
  - push run on main @ 2026-08-17T22:09:59Z (success, = the merge of 05d777e6)
#12062 added ONLY .github/workflows/windows-smoke.yml (191 add / 0 del) — it did
NOT touch scripts/install-cli.ps1. The workflow is paths-filtered to
install-cli.ps1 + itself; both runs fired because the WORKFLOW FILE changed, not
because the installer changed. No install-cli.ps1-touching PR has landed since.

HONEST STAMP: the guard EXISTS and its hermetic self-test ran GREEN on
windows-latest twice (PR-branch + post-merge main). It has NOT yet fired as a
rider on an actual install-cli.ps1 change — that path is unexercised. Do NOT
stamp "guarded a real installer change."

## (b) #11901 final state (D36 fence client.go contender)

    gh pr view 11901 --json state,mergeCommit,closedAt

MERGED, sha ed048f293a9d4e6e91107668dfcaf6a3544797ac, 2026-08-17T21:19:07Z.
No longer an OPEN contender — the fence can drop/retire it (it landed).

## (c) #10129 / #10811 / #10720 — still open, stale? (client.go / cloud_status_cmd.go fence)

    for n in 10129 10811 10720; do gh pr view $n --json number,state,updatedAt; done

ALL OPEN, all stale (no activity ~10-11 days):
  - #10129 OPEN, updated 2026-08-07T05:57:03Z
  - #10811 OPEN, updated 2026-08-08T11:38:52Z
  - #10720 OPEN, updated 2026-08-08T11:09:13Z
These are real live contenders touching the deploy census / cloud status —
they justify fencing client.go + cloud_status_cmd.go OUT of the LAST-SEEN build.
