PR #13001 carries TWO distinct column-0 trailers, one of which names an open row.
`scripts/pr-task-gate.sh` refuses that body rather than resolving it by position (head -1 and
tail -1 are equally wrong). The sweep mirrors the refusal: counted and shown, never credited.
