# Re-derivation recipe — dr-w8 stamp audit (3 merged-PR-but-open tasks)

Claim: dr-w2-s3 / dr-w3-s5 / dr-w6-s2 each have exactly ONE unmet criterion and it is
the MERGE-GATE criterion ("the LEAD closes this"). The merge happened.

## 1. The unmet criteria (NOTE: acceptance_criteria is nested inside `doc.content`, NOT at doc top level)

    for t in dr-w2-s3-poll-grace-5xx-and-named-refusal dr-w3-s5-door-refuses-box-at-capacity dr-w6-s2-stale-binary-says-so; do
      echo "=== $t"
      bp task get "$t" -o json | python3 -c "
    import json,sys
    d=json.load(sys.stdin)['doc']
    print('progress',d.get('criteria_progress'),'lifecycle',d.get('lifecycle_status'))
    def walk(o):
        if isinstance(o,dict):
            for k,v in o.items():
                if k=='acceptance_criteria': yield v
                else: yield from walk(v)
        elif isinstance(o,list):
            for v in o: yield from walk(v)
    for ac in walk(d.get('content')):
        for i,x in enumerate(ac):
            print(('MET  ' if x.get('met') else 'UNMET'),i,json.dumps(x)[:500])
    "
    done

The naive form (`json.load(...)['doc'].get('acceptance_criteria',[])`) prints NOTHING for
all three — an empty result indistinguishable from "every criterion is met".

## 2. Merge + ancestry + required contexts

    for n in 9730 9827 9929; do
      sha=$(gh pr view $n --json mergeCommit -q .mergeCommit.oid)
      echo "== PR$n merge=$sha"
      git merge-base --is-ancestor "$sha" origin/main && echo "ANCESTOR rc=0"
      gh pr view $n --json statusCheckRollup \
        -q '.statusCheckRollup[]|select(.name=="Elixir gate" or .name=="Cloud gate" or .name=="Console gate" or (.context//"")=="PR references an active task")|"  \(.name // .context)=\(.conclusion // .state)"' | sort -u
    done
    gh api repos/:owner/:repo/branches/main/protection --jq '.required_status_checks.contexts[]'

## 3. The substance is really on main (not just stamped)

    git show origin/main:api/test/barkpark_web/contract/error_code_coverage_test.exs | grep -n box_at_capacity
    git show origin/main:cloud/lib/barkpark_cloud/sites/deploy.ex | grep -n 'transient_refusal?\|box_refusal('
    git show origin/main:internal/cli/doctor_onboarding.go | grep -n 'unreported\|UNREPORTED'

## 4. The one residue

dr-w3-s5's criterion 11 has a SECOND clause beyond the merge: "AFTER an independent second
review of the door-vs-unit race". PR #9827 carries ZERO reviews:

    gh pr view 9827 --json reviews -q '.reviews[]|"\(.author.login) \(.state)"'   # prints nothing
