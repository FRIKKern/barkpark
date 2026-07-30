# Re-derivation recipe — cloud-console-hardening roster enumeration + n-1 stamp census

Taken 2026-07-30T14:04:47Z .. 14:20Z. Server: guerrilla.barkpark.cloud.

## 1. Full roster in ONE call (preferred; no pagination, no cap)

    bp task get cloud-console-hardening-epic -o json > /tmp/epic.json
    python3 -c "import json;d=json.load(open('/tmp/epic.json'));print(d['child_count'],len(d['children']))"
    # -> 132 132   (child_count == len(children): the children array is COMPLETE, not a page)

Children carry `doc_id`, `title`, `lifecycle_status`, `criteria_progress`, `execution_class`.
They do NOT carry `acceptance_criteria` text.

## 2. Criterion TEXT for all children (paginated walk of the whole queue)

`bp task ls` has NO `--parent` flag:

    bp task ls --parent cloud-console-hardening-epic -o json
    # exit 2 -> {"error":{"code":"usage","message":"unknown flag --parent for task ls"}}

`bp task ls --limit 100 --offset N -o json` DOES carry `parent_id` and full
`content.acceptance_criteria`. Walk the whole queue and filter:

    # 4118 tasks total on 2026-07-30 -> 42 pages. Skip doc_ids starting "drafts.".
    python3 tooling/grip/ledger/_pager.py   # or the inline driver in the wave-8 verifier transcript

Rate limit: bursts trip HTTP 429 on `/v1/capabilities` itself (manifest acquire),
`details.retry_after: 1`. Sleeping 10s between pages + up to 6 retries at 20s
completed all 42 pages. `bp task ls --all` 429s outright under concurrent load.

Cross-validation: the 42-page walk recovered EXACTLY 132 children with the same
status histogram as route 1 (`open 63 / done 58 / cancelled 10 / considering 1`).

## 3. Routes that do NOT enumerate the roster

    bp task ready --limit 400  -> 400 docs   (so "caps at 300" is false)
    bp task ready --limit 1000 -> 1000 docs, 49 epic children
    bp task ready --limit 5000 -> 1000 docs, 49 epic children   (hard cap 1000)

`ready` is a *readiness* projection: 49 of 64 live rows, and its docs have no
`lifecycle_status` key at all. Never use it as a roster read.

## 4. n-1 census (verbatim, with sha1 + zero-based index)

    python3 -c "...criteria_progress['met']==total-1..."   # over route 1's children

Byte-identical merge stamp, sha1 `f34f36da1a47`, verbatim:

    PR merged to main (LEAD closes this criterion, pasting the merge SHA from `gh pr view <n> --json mergeCommit`).

It appears on SEVEN live rows — four at n-1 and THREE at 0/N. Selecting on the
string closes three unbuilt rows. Select on `met == total-1` AND a verified PR.
