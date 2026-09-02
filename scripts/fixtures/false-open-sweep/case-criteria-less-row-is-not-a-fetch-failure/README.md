REGRESSION PIN, found by the instrument's OWN FIRST LIVE RUN.

The sweep refused the entire 243-row live population over ONE row —
`task-85c531c2adbf0dff` ("bp can say a box is suspended and why, but still not since
when"), an open, published row that carries no `acceptance_criteria` at all. That is a
legitimate ledger state, not a failed fetch, and the first draft conflated the two.

A guard that reds on correct data gets worked around, so the two are now separate: a
criteria-less row is COUNTED and DECLARED as arm-B-blind coverage, and the sweep still
runs. Only a missing, zero-byte, unparseable or wrong-id envelope is a refusal —
`case-empty-row-file-refuses` holds that half.

The row here is still reachable by arm A: its trailer receipt is found and reported.
