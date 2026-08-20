# cch-w30 [error-shape-L1] — re-derivation recipes (2026-08-04)

Tree: `origin/main` = `49345a98c1dbd9c768f3312185be0f5483878241`.
Boot: `cd cloud && mix run --no-halt` (Bandit :4100, dev config, local Postgres). No code change, no fixture.

## R1 — the shapeless-error class, live (3 arms, zero code defect needed)

```
curl -i -sS -X POST http://127.0.0.1:4100/v1/notifications/test -H 'content-type: application/json' -d '{'
curl -sS -o /dev/null -w 'http=%{http_code} size=%{size_download} ct=[%{content_type}]\n' \
     -X POST http://127.0.0.1:4100/v1/notifications/test -H 'content-type: application/json' -d '{'
curl -sS -o /dev/null -w 'http=%{http_code} size=%{size_download} ct=[%{content_type}]\n' \
     -X POST http://127.0.0.1:4100/v1/notifications/test -H 'content-type: text/plain' -d 'hi'
python3 -c "print('{\"a\":\"'+'x'*20000000+'\"}')" > /tmp/big.json
curl -sS -o /dev/null -w 'http=%{http_code} size=%{size_download} ct=[%{content_type}]\n' \
     -X POST http://127.0.0.1:4100/v1/auth/login -H 'content-type: application/json' --data-binary @/tmp/big.json
```

Expected today: `400 / 415 / 413`, each `size_download=0`, `content_type=[]`, response headers
only `connection: close` (no `date`, no `content-length`). Contrast arm (envelope intact):

```
curl -i -sS -X POST http://127.0.0.1:4100/v1/notifications/test -H 'content-type: application/json' -d '{}'   # 401 {"error":"unauthorized"}
curl -i -sS http://127.0.0.1:4100/v1/nope                                                                      # 404 {"error":"not_found"}
```

## R2 — friendly() census by fallback class

```
git show origin/main:cloud/priv/static/app.js > /tmp/appjs-main.js
grep -c 'friendly(' /tmp/appjs-main.js          # 84 grep LINES (incl. 15 comment/def lines)
```
Real call sites = 69. Classifier: second string literal argument, bucketed
`^(Check|Please check)` = blame-input, `^(Please try again|Something went wrong|Try again)` = vague,
no 2nd arg = bare, else designed. Counts today: blame 6 / vague 29 / bare 9 / designed 25.
Blame lines: 2110, 2540, 3601, 9203, 17118, 17314.

## R3 — the remedy-shape decision (run the real source, do not read it)

```
node -e 'const fs=require("fs");const s=fs.readFileSync("/tmp/appjs-main.js","utf8").split("\n");
eval(s.slice(128,176).join("\n"));                       // ERRORS (129) .. friendly end (176)
console.log(friendly({}, "Check the details and try again."));                       // blame copy
console.log(friendly({error:"internal_error"}, "Check the details and try again.")); // STILL blame
ERRORS.internal_error="Something broke on our end.";
console.log(friendly({error:"internal_error"}, "Check the details and try again.")); // fixed
console.log(friendly({error:{code:"internal_error"}}, "Check the details and try again.")); // nested = blame
console.log(Object.keys(ERRORS).length);'
```

FLAT is necessary (nested loses even when registered) but NOT sufficient — the slug must also be
added to `ERRORS` (19 keys today, none server-fault). A shaped 500 must ALSO set
`content-type: application/json`, or `api()` (app.js:113-116) never parses the body at all.
