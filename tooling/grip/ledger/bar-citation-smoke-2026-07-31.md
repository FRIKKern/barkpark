# bar-citation-smoke — re-derivation recipes (wave 13 VERIFY, 2026-07-31)

Two citations the scrub slice and the band slice were about to lean on.
Both resolved against `origin/main` bytes and the live Barkpark server.

## R1 — Is cloud/DESIGN.md §5's raw-provider-strings row a RULE or a RATIFY item?

    git show origin/main:cloud/DESIGN.md | sed -n '110,170p'
    git show origin/main:cloud/DESIGN.md | grep -n "RATIFY\|^## "

VERDICT: a RULE. The doc header (:8) says "Two items below are marked **RATIFY:**".
The ratification checklist (:176-177) names exactly those two — §3 trial CTA (D57)
and §5 neutral accent (D59). The raw-provider-strings row (:123) is an unqualified
table rule, NOT a checkbox. The scrub slice may cite it.

## R2 — But does §5 COVER all six render sites? (read for coverage, not existence)

    git show origin/main:cloud/DESIGN.md | sed -n '123p'

§5:123 reads: raw provider strings "appear **only** in the timeline's fail/console
fold — never in a pill, never on the home screen". That clause AUTHORISES two of the
six cited sites and CONDEMNS the others. Classify before citing:

    git show origin/main:cloud/priv/static/app.js > /tmp/app.js
    for n in 4371 4372 5485 6054 14052 15283; do \
      awk -v N=$n 'NR<=N && /^ *function [a-zA-Z_]+\(/ {f=NR": "$0} NR==N{print f}' /tmp/app.js; done

## R3 — Does the raw error reach a pill and the home screen? (the rule's two prohibitions)

    grep -n "s\.detail" /tmp/app.js | head
    grep -n "instanceCardHtml(\|attentionReason(" /tmp/app.js

statusOf() (:4368) puts `bp.provision_error` verbatim into `.detail`; statusPill()
renders it at :4396 inside `<span class="status-pill-detail">`; attentionReason()
returns it at :4759 and it paints at :4778 as `.attention-reason`. Both prohibitions
are live.

## R4 — Does the onboarding paper already describe the Kinsta/Vercel bar?

    bp paper view onboarding-composition-wave-2026-07-16          # the verb is `view`, NOT `show`
    bp paper view onboarding-composition-wave-2026-07-16 -o json

VERDICT: NO. `bp paper show` does not exist — that failure looked like absence
(phantom-citation class). The paper is REAL but is a 4-block husk: heading, ingress,
callout, byline. Its own ingress promises "Debrief is the final section" and there is
no final section. Subject is CLI onboarding (bp doctor, ServerEntry, admin token,
env-var names), not the console. Zero coverage of responsive width, error
presentation, or indeterminate progress. Wave 13 must author the bar itself.
