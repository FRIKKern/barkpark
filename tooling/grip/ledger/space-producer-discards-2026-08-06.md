# space-producer-discards — re-derivation recipes (verifier, wave 6, 2026-08-06)

Baseline: origin/main = ef77af2748ceda54fdd6e078f71a6e6044b55439.
NOTE: the primary checkout HEAD (a31faa52d) is NOT a descendant of origin/main and its
`internal/agent/report.go` is 371 lines (origin/main: 1051). The assignment's MUST-RUN
therefore prints "no tests to run" here — a vacuous green. Materialize origin/main first:

    D=$(mktemp -d); git -C /Volumes/SATECHI/github/barkpark archive origin/main | tar -x -C "$D"
    cd "$D" && CC=clang go test ./internal/agent/... -run 'Space|Du|Tree' -v

## 1. Discard-rather-than-half-land, END TO END, on a real loaded box

    cd "$D" && CC=clang GOOS=linux GOARCH=amd64 go test -c ./internal/agent -o /tmp/agent.test
    scp -i ~/.ssh/barkpark_indx /tmp/agent.test root@157.180.90.121:/tmp/agent.test
    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 \
      'VERIFY_DU_ROOT=/ /tmp/agent.test -test.run TestVerifyRealDuKilledMidOutputDiscards -test.v'

(The test lowers duProbeTimeout to 400ms, runs the REAL `nice -n 19 ionice -c3 du -hx -d1 /`
through boundedSpaceRunner, and asserts probe() == (-1, nil, err) and gatherSpace unmeasured.)

## 2. A non-zero du exit does NOT imply truncated output (over-discard hazard)

    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 \
      'rm -rf /tmp/vt; mkdir -p /tmp/vt/a /tmp/vt/b; dd if=/dev/zero of=/tmp/vt/b/f bs=1M count=8 2>/dev/null;
       chmod 000 /tmp/vt/a;
       setpriv --reuid=65534 --regid=65534 --clear-groups du -hx -d1 /tmp/vt 2>&1; echo rc=$?;
       chmod 755 /tmp/vt/a; rm -rf /tmp/vt'

## 3. Two-root du cost, on the box that has the problem

    ssh -i ~/.ssh/barkpark_indx root@91.98.139.58 \
      'uptime; for p in /var/lib /opt/barkpark; do /usr/bin/time -f "%e $p" nice -n 19 ionice -c3 du -hx -d1 $p >/dev/null; done'

## 4. -h vs -k precision, taken through the parser

    ssh -i ~/.ssh/barkpark_indx root@91.98.139.58 \
      'VERIFY_DU_ROOT=/var/lib /tmp/agent.test -test.run TestVerifyHumanUnitPrecisionLoss -test.v'

## 5. The -kx trap: parseHumanBytes accepts a BARE integer as BYTES

    cd "$D" && CC=clang go test ./internal/agent -run TestVerifyMinusKWithoutParserChangeSilentlyUnderstates1024x -v

Test sources used by 1/4/5 live in the scratchpad copy only
(internal/agent/zz_verify_space_test.go, zz_verify_size_test.go); they are not committed here.
