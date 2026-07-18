# Publishes the review Paper per charter D20: birth (wall-gated) + /ops batches with ifRev.
import json, sys, time, urllib.request

SERVER = "https://guerrilla.barkpark.cloud"
TOKEN = json.load(open("/Users/pelle/.config/barkpark/config.json"))["token"]
SLUG = "block-wishlist-100-review"
blocks = json.load(open("review_blocks.json"))

def call(method, path, payload):
    req = urllib.request.Request(
        SERVER + path, data=json.dumps(payload).encode() if payload is not None else None,
        headers={"Authorization": "Bearer " + TOKEN, "Content-Type": "application/json"},
        method=method)
    try:
        with urllib.request.urlopen(req) as r:
            return r.status, json.load(r)
    except urllib.error.HTTPError as e:
        try: body = json.load(e)
        except Exception: body = {"raw": e.read().decode(errors="replace")[:800]}
        return e.code, body

def current_rev():
    st, doc = call("GET", f"/v1/data/doc/production/paper/{SLUG}", None)
    if st == 200:
        d = doc.get("result", doc)
        if isinstance(d, dict) and "document" in d: d = d["document"]
        return int(d.get("rev"))
    raise SystemExit(f"rev read failed: {st} {doc}")

BIRTH_N = 5  # eyebrow, h1 title, ingress, method callout, verdict heading
birth = {
    "slug": SLUG,
    "style": "article",
    "blocks": blocks[:BIRTH_N],
    "description": "The Usefulness Review of the Block Wishlist 100: all 100 PortableDoc block candidates scored on the D5 rubric (demand 35 / frequency 25 / unlock 25 / reach 15) and ranked S/A/B/C; the S tier is the filed, ready-to-build backlog.",
    "tags": [
        {"tag": "portabledoc", "strength": 90, "rationale": "Ranks the PortableDoc block wishlist."},
        {"tag": "block", "strength": 70, "rationale": "Usefulness review of 100 block candidates."},
        {"tag": "docs", "strength": 50, "rationale": "Published review paper + filed S-tier backlog."},
    ],
}
st, body = call("POST", "/v1/plugins/bulldocs/papers", birth)
print("birth:", st, json.dumps(body)[:400])
if st != 200:
    sys.exit(1)
rev = int(body["rev"])

rest = blocks[BIRTH_N:]
BATCH = 16
i = 0
while i < len(rest):
    chunk = rest[i:i+BATCH]
    ops = [{"op": "append-block", "block": b} for b in chunk]
    for attempt in range(4):
        st, body = call("POST", f"/v1/plugins/bulldocs/papers/{SLUG}/ops", {"ops": ops, "ifRev": rev})
        if st == 200:
            rev = int(body["rev"])
            print(f"ops batch {i}-{i+len(chunk)-1}: ok rev={rev}")
            break
        elif st == 412:
            print(f"ops batch {i}: 412, re-reading rev (was {rev})")
            rev = current_rev()
            time.sleep(0.5)
        else:
            print(f"ops batch {i}: FAILED {st} {json.dumps(body)[:500]}")
            sys.exit(1)
    else:
        sys.exit("exhausted retries")
    i += BATCH

print("DONE. final rev:", rev)
