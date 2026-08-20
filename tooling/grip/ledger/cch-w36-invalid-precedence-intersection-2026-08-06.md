# cch-w36 — the invalid/details precedence INTERSECTION, re-derivable

Authority: origin/main `070c7584b`. Every row below re-derives from that ref.
NOTE: this checkout's worktree copy of `cloud/priv/static/app.js` is DIRTY and
~1856 lines short of origin/main — never grep the worktree for this population.

## Materialise origin/main out-of-tree (the suite needs 4 sibling trees)

    S=/tmp/om && rm -rf $S && mkdir -p $S
    git archive origin/main cloud/priv/static cloud/lib \
      internal/taskboard/testdata internal/pdrender/testdata deploy | tar -x -C $S
    node $S/cloud/priv/static/__app.test.mjs 2>&1 | tail -8   # 887/887 pass, baseline

## The population

    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex > /tmp/r.ex

    # every slug that ships `details` anywhere in the router (the whole universe)
    grep -n details /tmp/r.ex | grep -o 'error: "[a-z_]*"' | sort | uniq -c
    #   48 error: "invalid"          <- 1 is the comment at :4975 -> 47 real
    #    2 error: "validation_failed" <- only :8531 carries details
    #    1 error: "already_invited"   <- :4762, 409, NOT in ERRORS -> EXCLUDE

    # no multi-line details emitters exist (proves the one-line grep is complete)
    grep -n details /tmp/r.ex | grep -v 'error:'          # 5 hits, all comments/vars

    # router.ex is the ONLY details emitter in cloud/lib
    git grep -n 'details:' origin/main -- cloud/lib | grep -v router.ex   # empty

    # all 47 are status 422
    grep -n 'error: "invalid"' /tmp/r.ex | grep details | grep -c ', 422,'   # 47

    # the DYNAMIC emitter the literal grep misses
    grep -n 'error: "#{' /tmp/r.ex     # :8530 %{error: "#{field}_invalid", details:}
    grep -n register_error /tmp/r.ex   # fan-in at :1003 (register) and :1057 (reset)

## The registration side (which of them are actually overwritten)

    git show origin/main:cloud/priv/static/app.js | sed -n '179,240p'   # ERRORS + friendly

## Nothing pins the two generic sentences

    git grep -n "That didn't work" origin/main            # app.js:193 only (the def)
    git grep -n "Please check the form and try again" origin/main  # app.js:184 only
    grep -n 'friendly(' $S/cloud/priv/static/__app.test.mjs   # :11074 is the ONLY
    # details test and it uses an UNREGISTERED slug ("x"), so a generic-slug fence
    # reds nothing in the 887-test suite.

## The slug-vs-422 ruling, run rather than argued

Drive the REAL friendly() on the four boundary payloads:

    node -e '
    const fs=require("fs");
    const src=fs.readFileSync("'$S'/cloud/priv/static/app.js","utf8");
    const s=src.indexOf("  var ERRORS = {");
    const e=src.indexOf("\n  }\n",src.indexOf("function friendly(data, fallback)"));
    const {ERRORS,friendly}=new Function(src.slice(s,e+4)+"\nreturn {ERRORS,friendly};")();
    for (const p of [
      {error:"invalid",details:{name:["can'"'"'t be blank"]}},
      {error:"validation_failed",details:{email:["has invalid format"]}},
      {error:"already_invited",details:{email:["has already been taken"]}},
      {error:"password_invalid",details:{password:["should be at least 12 character(s)"]}},
    ]) console.log(p.error,"->",friendly(p,"fb"));'

Expected: the first two render curated generic copy (the defect), the third
renders its details (works TODAY — must not be swept), the fourth renders
curated NARROW copy that a 422-keyed guard would replace with raw Ecto text.

## Verdict this recipe supports

Key the exception on the GENERIC SLUG SET {invalid, validation_failed}, not on
status 422: friendly(data, fallback) has no status argument (a 422 key needs an
arity change across 67 real call sites, or lives in faultCopy which reaches only
10 of them and whose own comment says "4xx = the caller's designed fallback").
