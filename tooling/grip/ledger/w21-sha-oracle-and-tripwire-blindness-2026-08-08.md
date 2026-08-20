# W21 verify — sha oracle + tripwire blindness (re-derivation recipes)

Verifier: wave 21, deploy-reliability. Every row below is a single command that
re-derives the stated fact from scratch. No repo state is assumed.

## 1. The GitHub compare API answers the ancestor question with no checkout at all

```
gh api repos/FRIKKern/barkpark/compare/7f5f10b8d...572d51e13fa41fd4aace729661f6fc0119bfa8f2 --jq '.status,.ahead_by,.behind_by'
# -> ahead / 10 / 0
gh api repos/FRIKKern/barkpark/compare/572d51e13fa41fd4aace729661f6fc0119bfa8f2...7f5f10b8d --jq '.status,.ahead_by,.behind_by'
# -> behind / 0 / 10
gh api repos/FRIKKern/barkpark/compare/572d51e13fa41fd4aace729661f6fc0119bfa8f2...572d51e13fa41fd4aace729661f6fc0119bfa8f2 --jq '.status'
# -> identical
```

Fail-closed on garbage head (covers the jq-null trap for free):

```
gh api repos/FRIKKern/barkpark/compare/572d51e13fa41fd4aace729661f6fc0119bfa8f2...null --jq '.status'
# -> {"message":"Not Found",...}  gh: Not Found (HTTP 404)  [nonzero]
gh api repos/FRIKKern/barkpark/compare/572d51e13fa41fd4aace729661f6fc0119bfa8f2...deadbeefdeadbeefdeadbeefdeadbeefdeadbeef --jq '.status'
# -> HTTP 404
```

## 2. merge-base needs BOTH depth 0 AND a fetch that carries the served commit

Runner simulation (default actions/checkout = depth 1 at github.sha):

```
cd /tmp && rm -rf runnersim && mkdir runnersim && cd runnersim && git init -q . \
  && git remote add origin file:///Volumes/SATECHI/github/barkpark
git fetch -q --depth 1 origin 7f5f10b8d038b3fb77ecdadb0382ae42840b89d4 && git checkout -q FETCH_HEAD
git merge-base --is-ancestor 7f5f10b8d038b3fb77ecdadb0382ae42840b89d4 572d51e13fa41fd4aace729661f6fc0119bfa8f2; echo "RC=$?"
# -> fatal: Not a valid commit name 572d51e13...   RC=128
git fetch -q --depth 1 origin main   # a plain in-step fetch DOES NOT deepen
git merge-base --is-ancestor 7f5f10b8d038b3fb77ecdadb0382ae42840b89d4 572d51e13fa41fd4aace729661f6fc0119bfa8f2; echo "RC=$?"
# -> still RC=128
```

Full history, both objects present — the oracle then works in both directions:

```
cd /tmp && rm -rf runnersim3 && mkdir runnersim3 && cd runnersim3 && git init -q . \
  && git remote add origin file:///Volumes/SATECHI/github/barkpark
git fetch -q origin 'refs/remotes/origin/main:refs/remotes/origin/main'
git merge-base --is-ancestor 7f5f10b8d038b3fb77ecdadb0382ae42840b89d4 572d51e13fa41fd4aace729661f6fc0119bfa8f2; echo "RC=$?"  # 0
git merge-base --is-ancestor 572d51e13fa41fd4aace729661f6fc0119bfa8f2 7f5f10b8d038b3fb77ecdadb0382ae42840b89d4; echo "RC=$?"  # 1
```

RC=128 (object absent) is NOT RC=1 (behind). Any `if git merge-base ...; then`
form collapses the two.

## 3. jq stringifies null

```
echo '{"git_sha":null}' | jq -r '.git_sha'          # -> null   (the literal 4 chars)
echo '{"git_sha":null}' | jq -r '.git_sha // empty' # -> (empty)
```

## 4. The tripwire extractor is blind to a NEW step

```
S=$(mktemp -d); git archive origin/main deploy scripts .github | tar -x -C $S
# insert a step named "Assert serving sha" immediately BEFORE the control-plane
# "- name: Smoke test", then:
awk '/^  [a-zA-Z0-9_-]+:/ {job=$0;sub(/^  /,"",job);sub(/:.*$/,"",job);instep=0}
     job=="control-plane" && /^      - name: / {instep=($0 ~ /Smoke test/)?1:0}
     job=="control-plane" && instep {print}' $S/mutated-newstep.yml | grep -c 'git_sha\|compare'
# -> 0
bash $S/scripts/check-deploy-smoke.sh $S/mutated-newstep.yml; echo "RC=$?"
# -> OK[mutated-newstep.yml]: ... RC=0
```

## 5. --selftest has zero callers; the workflow runs the bare form

```
git grep -n 'check-deploy-smoke' origin/main
# -> .github/workflows/deploy.yml:91:  run: bash scripts/check-deploy-smoke.sh   (no --selftest)
```

## 6. /health's git_sha is env-injected, not compiled in

```
git grep -n 'BARKPARK_GIT_SHA' origin/main
# cloud/lib/barkpark_cloud/health.ex:62  System.get_env("BARKPARK_GIT_SHA")
# deploy/cp-deploy.sh:58                 export BARKPARK_GIT_SHA="$NEW"   ($NEW = tip after git pull)
curl -s https://barkpark.cloud/health
```

## 7. cp-deploy.sh has no exit-0 path that leaves an ancestor serving

```
git show origin/main:deploy/cp-deploy.sh | grep -n 'exit \|flock\|git pull\|abort_deploy'
# lock timeout -> exit 15; pull fail -> exit 11; no .env -> exit 12; build/boot -> exit 13;
# unhealthy/DB-probe/Caddy -> exit 14 (all abort BEFORE the flip, active slot keeps OLD).
# Every exit-0 path passes through the Caddy flip to the slot booted at $NEW = tip-at-pull.
```
