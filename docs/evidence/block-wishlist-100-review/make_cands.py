# Extracts per-candidate data from the live wishlist Paper block-wishlist-100 into cands.json
# (input for file_tasks.py). Each candidate: {id, name, paras, code}.
# NOTE (review fix): code blocks store their source under the "value" key, NOT "code" —
# the original ad-hoc extraction read the wrong key and shipped empty DATA SHAPE sections.
import json, re, urllib.request

SERVER = "https://guerrilla.barkpark.cloud"
TOKEN = json.load(open("/Users/pelle/.config/barkpark/config.json"))["token"]

req = urllib.request.Request(SERVER + "/v1/data/doc/production/paper/block-wishlist-100",
    headers={"Authorization": "Bearer " + TOKEN})
d = json.load(urllib.request.urlopen(req))
doc = d.get("result", d)
if "document" in doc: doc = doc["document"]
content = doc.get("content", doc)
blocks = content.get("blocks") or content.get("body", {}).get("blocks")

def plain(b):
    c = b.get("content")
    if isinstance(c, list):
        return "".join(s.get("value", "") for s in c if isinstance(s, dict))
    return b.get("text") or ""

cands, cur = [], None
for b in blocks:
    if b.get("type") == "heading" and re.match(r"^B(0\d\d|100)\b", b.get("text") or ""):
        m = re.match(r"^(B\d{3})\s+(.*)$", b["text"])
        cur = {"id": m.group(1), "name": m.group(2).strip(), "paras": [], "code": ""}
        cands.append(cur)
    elif cur is not None:
        if b.get("type") == "paragraph":
            cur["paras"].append(plain(b))
        elif b.get("type") == "code":
            cur["code"] = b.get("value") or b.get("code") or ""
        elif b.get("type") == "heading":
            cur = None

assert len(cands) == 100, f"expected 100 candidates, got {len(cands)}"
missing_code = [c["id"] for c in cands if not c["code"].strip()]
print("candidates:", len(cands), "| missing code:", missing_code or "none")
json.dump(cands, open("cands.json", "w"), indent=1)
