# Re-derivation recipes — deploy fence width, the two missing rows, and the cp-deploy silences (wave 21 verify)

Taken 2026-08-08 against `origin/main`. Every row is one literal command.

## 1. #9644 is an ISSUE, not a PR

    gh api repos/FRIKKern/barkpark/pulls/9644            # -> 404 Not Found
    gh api repos/FRIKKern/barkpark/issues/9644 --jq '{number,state,title,labels:[.labels[].name]}'

## 2. The PDS fence's actual width — PDS-D716, not the task-body paraphrase

    git show origin/main:.claude/workflows/bp-pds-charter.md | sed -n '15026,15048p'

Tree-scoped `deploy/**` IN, with `deploy/site-deploy*` explicitly FENCED OUT to deploy-reliability wave 1,
and `cloud/**` + `.github/workflows/**` OUT.

## 3. Wave 20 crossed the fence on cp-deploy.sh, not on site-deploy*

    git log origin/main --oneline -3 -- deploy/cp-deploy.sh
    git log origin/main --oneline -2 -- deploy/site-deploy.sh deploy/site-deploy-node.sh

## 4. Both-hosts blast radius of any `deploy/**` byte

    git show origin/main:.github/workflows/deploy.yml | sed -n '79,87p'

## 5. The three backlog rows all resolve (no null)

    bp task get dr-w20-bl-provisioner-restart-cannot-fail-the-deploy -o json | head -c 400
    bp task get dr-w20-bl-arm-and-flip-paths-with-no-selftest-row -o json | head -c 300
    bp task get dr-w20-bl-instance-target-has-no-serving-sha -o json | head -c 300

## 6. Line drift in the provisioner row's cites (194/196/214 -> 202/204/222)

    git show origin/main:deploy/cp-deploy.sh | grep -n 'systemctl restart barkpark-provisioner\|is-active barkpark-provisioner\|DONE — control plane\|^set '

## 7. The smoke tripwire is control-plane-only

    git show origin/main:scripts/check-deploy-smoke.sh | sed -n '48,60p'

## 8. Live CP state of the two silenced units

    ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 'systemctl is-active barkpark-provisioner; systemctl is-enabled barkpark-image-bake.timer; systemctl show barkpark-provisioner -p NRestarts -p Result'

## 9. Incidence over 150 successful deploy.yml runs (118 with a control-plane job)

    bash /private/tmp/claude-501/-Volumes-SATECHI-github-barkpark/47ba8708-cd1d-47ac-93d4-7cb707cf3e3c/scratchpad/scan.sh

Inlined (portable form):

    gh run list --workflow=deploy.yml --branch=main --status=success --limit=150 --json databaseId --jq '.[].databaseId' \
      | while read -r id; do gh run view "$id" --log 2>/dev/null | grep -E 'provisioner: |image-bake timer: '; done \
      | grep -oE 'provisioner: [a-z-]+|image-bake timer: [a-z-]+' | sort | uniq -c

Result: `118 provisioner: active`, `118 image-bake timer: enabled`, zero other values.
BOUND: GitHub log retention caps the window at ~2026-08-01T20:49Z — this is 7 days, not all time.
