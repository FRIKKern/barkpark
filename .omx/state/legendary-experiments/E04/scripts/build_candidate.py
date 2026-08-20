#!/usr/bin/env python3
"""Build the isolated E04 canonical-native repair candidate."""
from __future__ import annotations

import argparse
import hashlib
import html
import json
import re
import time
from html.parser import HTMLParser
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
E03 = ROOT.parent / "E03"
SOURCE = ROOT / "fixtures" / "source-documents.json"
MANIFEST = ROOT / "fixtures" / "manifest.json"
OUTPUT = ROOT / "output" / "repair-packet.json"
TRANSFORMATIONS = ROOT / "transformation-manifest.json"

TASK_REQUIREMENTS = {
    "executable": ["title", "description", "acceptance_criteria", "lifecycle_status", "priority"],
    "goal": ["title", "description", "acceptance_criteria", "lifecycle_status", "priority", "children"],
    "decision_or_human_gate": ["title", "description", "decision_required", "lifecycle_status", "evidence"],
    "done_or_cancelled_history": ["title", "description", "lifecycle_status", "completion_evidence"],
    "deferred": ["title", "description", "lifecycle_status", "defer_reason", "revisit_trigger"],
    "probe": ["title", "description", "lifecycle_status", "probe_question", "retirement_rule"],
}
SUPPORTED = {"heading", "paragraph", "list", "table", "code", "quote"}


def stable(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def digest(value):
    data = value if isinstance(value, bytes) else stable(value).encode()
    return hashlib.sha256(data).hexdigest()


def clean_text(value):
    return re.sub(r"\s+", " ", str(value or "")).strip()


def text_fragments(value):
    out = []
    if isinstance(value, str):
        if clean_text(value): out.append(clean_text(value))
    elif isinstance(value, list):
        for item in value: out.extend(text_fragments(item))
    elif isinstance(value, dict):
        for key in ("text", "value", "label", "title", "caption", "alt"):
            if key in value: out.extend(text_fragments(value[key]))
        for key in ("content", "children", "items", "head", "rows", "blocks", "slots"):
            if key in value: out.extend(text_fragments(value[key]))
    return out


class HTMLText(HTMLParser):
    def __init__(self):
        super().__init__(); self.parts = []
    def handle_data(self, data):
        if clean_text(data): self.parts.append(clean_text(data))


def markdown_blocks(text):
    blocks, para, code = [], [], None
    def flush():
        if para:
            blocks.append({"type":"paragraph", "content":[{"type":"text", "value":clean_text(" ".join(para))}]}); para.clear()
    for line in str(text or "").splitlines():
        if line.startswith("```"):
            flush()
            if code is None: code = []
            else: blocks.append({"type":"code", "text":"\n".join(code)}); code = None
        elif code is not None: code.append(line)
        elif m := re.match(r"^(#{1,6})\s+(.*)", line):
            flush(); blocks.append({"type":"heading", "level":len(m.group(1)), "text":clean_text(m.group(2))})
        elif m := re.match(r"^\s*(?:[-*+] |\d+[.)] )(.*)", line):
            flush()
            if blocks and blocks[-1]["type"] == "list": blocks[-1]["items"].append(clean_text(m.group(1)))
            else: blocks.append({"type":"list", "ordered":bool(re.match(r"^\s*\d", line)), "items":[clean_text(m.group(1))]})
        elif clean_text(line): para.append(line)
        else: flush()
    flush()
    if code is not None: blocks.append({"type":"code", "text":"\n".join(code), "unterminated":True})
    return blocks


def canonical_blocks(doc):
    body = doc.get("body")
    raw = body if isinstance(body, list) else body.get("blocks") if isinstance(body, dict) else doc.get("blocks")
    if isinstance(raw, list) and raw:
        blocks = []
        for node in raw:
            if not isinstance(node, dict):
                blocks.append({"type":"paragraph", "content":[{"type":"text", "value":clean_text(node)}]}); continue
            typ = node.get("type", "paragraph")
            parts = text_fragments(node)
            text = clean_text(" ".join(parts))
            if typ == "heading": blocks.append({"type":"heading", "level":max(1,min(6,int(node.get("level",2) or 2))), "text":text})
            elif typ in ("list","bullet_list","ordered_list"):
                items = [clean_text(" ".join(text_fragments(x))) for x in node.get("items",[])]; items = [x for x in items if x]
                blocks.append({"type":"list", "ordered":typ=="ordered_list" or bool(node.get("ordered")), "items":items or ([text] if text else [])})
            elif typ == "table":
                rows = node.get("rows",[]); head = node.get("head",[])
                conv = lambda xs: [[clean_text(" ".join(text_fragments(c))) for c in row] for row in xs]
                blocks.append({"type":"table", "head":conv(head), "rows":conv(rows)})
            elif typ in ("code","code_block"): blocks.append({"type":"code", "text":text})
            elif typ in ("quote","blockquote"): blocks.append({"type":"quote", "content":[{"type":"text", "value":text}]})
            elif text: blocks.append({"type":"paragraph", "content":[{"type":"text", "value":text}]})
        return [b for b in blocks if text_fragments(b)]
    if isinstance(doc.get("body"), str): return markdown_blocks(doc["body"])
    if isinstance(doc.get("body_html"), str):
        parser=HTMLText(); parser.feed(doc["body_html"])
        return [{"type":"paragraph", "content":[{"type":"text", "value":x}]} for x in parser.parts]
    legacy = text_fragments({k:doc.get(k) for k in ("title","description","content")})
    return [{"type":"paragraph", "content":[{"type":"text", "value":x}]} for x in legacy]


def semantic_hash(blocks):
    return digest([clean_text(x).casefold() for x in text_fragments(blocks) if clean_text(x)])


def render_html(blocks):
    rendered=[]
    for b in blocks:
        typ=b["type"]
        if typ=="heading": rendered.append(f'<h{b["level"]}>{html.escape(b["text"])}</h{b["level"]}>')
        elif typ in ("paragraph","quote"):
            tag="blockquote" if typ=="quote" else "p"; rendered.append(f"<{tag}>{html.escape(' '.join(text_fragments(b)))}</{tag}>")
        elif typ=="list":
            tag="ol" if b["ordered"] else "ul"; rendered.append(f"<{tag}>"+"".join(f"<li>{html.escape(x)}</li>" for x in b["items"])+f"</{tag}>")
        elif typ=="table": rendered.append("<table>"+"".join("<tr>"+"".join(f"<td>{html.escape(c)}</td>" for c in r)+"</tr>" for r in b["head"]+b["rows"])+"</table>")
        elif typ=="code": rendered.append(f"<pre><code>{html.escape(b['text'])}</code></pre>")
    return "".join(rendered)


def task_value(doc, field, klass):
    criteria=doc.get("acceptance_criteria") or []
    values={
      "title":doc.get("title") or doc.get("_id"), "description":doc.get("description") or doc.get("title") or doc.get("_id"),
      "acceptance_criteria":criteria or [{"criterion":"Explicit verification required before completion", "met":False}],
      "lifecycle_status":doc.get("lifecycle_status") or "open", "priority":doc.get("priority",3), "children":doc.get("children",[]),
      "decision_required":doc.get("decision_required") or doc.get("title") or "Human decision required",
      "evidence":doc.get("evidence") or ["Preserve source preimage; do not infer approval"],
      "completion_evidence":doc.get("completion_evidence") or [c.get("evidence") for c in criteria if isinstance(c,dict) and c.get("evidence")] or ["Source lifecycle is historical; evidence not invented"],
      "defer_reason":doc.get("defer_reason") or doc.get("description") or "Deferred by source contract",
      "revisit_trigger":doc.get("revisit_trigger") or "Re-evaluate when the documented blocker changes",
      "probe_question":doc.get("probe_question") or doc.get("description") or doc.get("title"),
      "retirement_rule":doc.get("retirement_rule") or "Retire after the probe is answered and evidence is recorded",
    }
    return values[field]


def build(output_path=OUTPUT, transformations_path=TRANSFORMATIONS):
    source=json.load(SOURCE.open()); fm=json.load(MANIFEST.open()); classes={x["id"]:x["class"] for x in fm["tasks"]}
    papers=[]; tasks=[]; quarantined=[]
    for doc in source["papers"]:
        blocks=canonical_blocks(doc); before=semantic_hash(blocks); candidate={"schema":"portable-doc/v1","blocks":blocks}
        after=semantic_hash(candidate["blocks"]); unsupported=sorted({b.get("type") for b in blocks}-SUPPORTED)
        unit={"id":doc["_id"],"kind":"paper","preimage":doc,"preimage_sha256":digest(doc),"canonical":candidate,"derived_html":render_html(blocks),"semantic_hash_before":before,"semantic_hash_after":after,"unsupported_terminal_nodes":unsupported}
        if not blocks or before!=after or unsupported: quarantined.append({"id":doc["_id"],"reasons":["empty_or_semantic_or_schema_failure"],"preimage_sha256":digest(doc)})
        else: papers.append(unit)
    for entry in fm["adversarial"]:
        doc=json.load((ROOT/"fixtures"/entry["path"]).open()); blocks=canonical_blocks(doc); before=semantic_hash(blocks); unsupported=sorted({b.get("type") for b in blocks}-SUPPORTED)
        malformed=any(not isinstance(n,dict) or not isinstance(n.get("type"),str) for n in ((doc.get("body") or {}).get("blocks",[]) if isinstance(doc.get("body"),dict) else doc.get("blocks",[]) or []))
        unit={"id":doc["id"],"kind":"adversarial","fixture_kind":doc["kind"],"preimage":doc,"preimage_sha256":digest(doc),"canonical":{"schema":"portable-doc/v1","blocks":blocks},"derived_html":render_html(blocks),"semantic_hash_before":before,"semantic_hash_after":semantic_hash(blocks),"unsupported_terminal_nodes":unsupported}
        if not blocks or malformed or unsupported:
            quarantined.append({"id":doc["id"],"kind":"adversarial","reasons":["malformed_source" if malformed else "empty_or_schema_failure"],"preimage":doc,"preimage_sha256":digest(doc)})
        else: papers.append(unit)
    for doc in source["tasks"]:
        klass=classes[doc["_id"]]; required=TASK_REQUIREMENTS[klass]; fields={k:task_value(doc,k,klass) for k in required}
        tasks.append({"id":doc["_id"],"kind":"task","class":klass,"required_fields":required,"canonical_fields":fields,"preimage":doc,"preimage_sha256":digest(doc)})
    packet={"schema_version":"legendary-e04-repair-packet/v1","assignment_id":"E04","candidate_id":"candidate-canonical-native","source_manifest_sha256":digest(fm),"papers":papers,"tasks":tasks,"quarantine":quarantined}
    output_path=Path(output_path); transformations_path=Path(transformations_path)
    output_path.parent.mkdir(parents=True,exist_ok=True); output_path.write_text(json.dumps(packet,ensure_ascii=False,sort_keys=True,indent=2)+"\n")
    transformations={"schema_version":"legendary-e04-transformations/v1","assignment_id":"E04","units":[]}
    for u in papers:
        transformations["units"].append({"id":u["id"],"kind":u["kind"],"status":"accepted","preimage_sha256":u["preimage_sha256"],"canonical_sha256":digest(u["canonical"]),"semantic_hash_before":u["semantic_hash_before"],"semantic_hash_after":u["semantic_hash_after"]})
    for u in tasks:
        transformations["units"].append({"id":u["id"],"kind":"task","class":u["class"],"status":"accepted","preimage_sha256":u["preimage_sha256"],"canonical_fields_sha256":digest(u["canonical_fields"]),"required_fields":u["required_fields"]})
    for u in quarantined:
        transformations["units"].append({"id":u["id"],"kind":u["kind"],"status":"quarantined","preimage_sha256":u["preimage_sha256"],"reasons":u["reasons"]})
    transformations_path.parent.mkdir(parents=True,exist_ok=True)
    transformations_path.write_text(json.dumps(transformations,ensure_ascii=False,sort_keys=True,indent=2)+"\n")
    return packet


if __name__ == "__main__":
    ap=argparse.ArgumentParser()
    ap.add_argument("--output",default=str(OUTPUT))
    ap.add_argument("--transformations-output",default=str(TRANSFORMATIONS))
    args=ap.parse_args(); output=Path(args.output); transformations=Path(args.transformations_output)
    start=time.perf_counter(); packet=build(output,transformations); elapsed=time.perf_counter()-start
    print(json.dumps({"assignment_id":"E04","papers":len(packet["papers"]),"tasks":len(packet["tasks"]),"quarantined":len(packet["quarantine"]),"output_sha256":digest(output.read_bytes()),"transformations_sha256":digest(transformations.read_bytes()),"elapsed_seconds":round(elapsed,6)},sort_keys=True))
