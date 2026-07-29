#!/usr/bin/env python3
"""Validate PPCC2-S041's immutable read-only survey report and evidence receipts."""
from __future__ import annotations
import hashlib, json, re, sys
from html.parser import HTMLParser
from pathlib import Path
HERE=Path(__file__).resolve().parent
BOUND=Path('/Volumes/SATECHI/github/barkpark/.omx/state/paper-perfection-successor-2026-07-29/survey-cycle/bound-assignments/PPCC2-S041.json')
AUTHORITY=Path('/Volumes/SATECHI/github/barkpark/.omx/state/paper-perfection-successor-2026-07-29/survey-authority/assignments/PPCC2-S041.json')
EXPECTED_BOUND_SHA='b426b73f27afa0c45f887013d173af0e57fc907f7c82d4c5252ada3f97487876'
EXPECTED_SOURCE_SHA='92f518982ee234992b00d8c97f880a87770f7759ec3393b1829a1f11faaf8cce'
EXPECTED_WAVE_REV='552a7065-368e-4e45-9eec-5113e60510a3'
ALLOWED={'keep','repair','merge-candidate','superseded','blocked'}
SURFACES={'Studio','TUI80','email','public','CLI/API'}
EDITORIAL={'purpose_and_larger_goal','opening_and_criteria','outline_and_hierarchy','human_voice_and_precision','compression_and_restraint','evidence_and_truth','duplicate_disposition','rationale'}
LEGACY={'portabledoc-render-unification-w5-2026-07-16','portabledoc-render-unification-w6-2026-07-16','portabledoc-render-unification-w7-2026-07-16','portabledoc-render-unification-wave-2026-07-16'}
def load(p): return json.loads(p.read_text())
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
class SemanticCounter(HTMLParser):
    TAGS={'h1','h2','h3','h4','p','li','pre','table','blockquote'}
    def __init__(self): super().__init__(); self.count=0
    def handle_starttag(self,tag,attrs):
        if tag in self.TAGS: self.count += 1
def main():
    checks=[]
    def check(name, condition, evidence): checks.append({'name':name,'status':'PASS' if condition else 'FAIL','evidence':evidence})
    bound, authority, report, index=load(BOUND),load(AUTHORITY),load(HERE/'report.json'),load(HERE/'readback-index.json')
    check('bound-snapshot-sha',sha(BOUND)==EXPECTED_BOUND_SHA,sha(BOUND))
    check('source-snapshot-sha',sha(AUTHORITY)==EXPECTED_SOURCE_SHA,sha(AUTHORITY))
    check('bound-identity',bound.get('assignment_id')=='PPCC2-S041' and bound.get('status')=='cyclefleet_bound' and bound.get('unit_count')==9,{'assignment_id':bound.get('assignment_id'),'status':bound.get('status'),'unit_count':bound.get('unit_count')})
    check('immutable-wave-binding',bound.get('authority',{}).get('wave_revision')==EXPECTED_WAVE_REV and bound.get('source_snapshot',{}).get('sha256')==EXPECTED_SOURCE_SHA,report.get('cyclefleet_binding'))
    check('report-identity',report.get('assignment_id')=='PPCC2-S041' and report.get('agent_type')=='epic-surveyor' and report.get('worker')=='worker-2' and report.get('phase')=='survey',{'assignment_id':report.get('assignment_id'),'worker':report.get('worker')})
    check('ordered-checked-unit-ids',report.get('checked_unit_ids')==bound.get('unit_ids'),report.get('checked_unit_ids'))
    verdicts=report.get('unit_verdicts',[]); byid={v.get('unit_id'):v for v in verdicts}
    check('one-verdict-per-unit',len(verdicts)==9 and [v.get('unit_id') for v in verdicts]==bound.get('unit_ids'),len(verdicts))
    metadata_ok=all((v:=byid.get(u['unit_id'])) and v.get('document_id')==u['document_id'] and v.get('document_rev')==u['document_rev'] for u in bound['units'])
    check('verdict-metadata-pinned',metadata_ok,'all document ids and immutable revisions match')
    check('allowed-verdicts-and-counts',all(v.get('verdict') in ALLOWED for v in verdicts) and sum(report.get('verdict_counts',{}).values())==9 and report.get('verdict_counts')=={'keep':4,'repair':3,'superseded':2},report.get('verdict_counts'))
    editorial_ok=all(EDITORIAL <= set(v) and all(isinstance(v[f],str) and v[f].strip() for f in EDITORIAL) for v in verdicts)
    check('editorial-dimensions-complete',editorial_ok,sorted(EDITORIAL))
    ref_ok=True; ref_evidence=[]
    for v in verdicts:
        raw=load(HERE/'readbacks'/f"{v['document_id']}.json")
        blocks=raw.get('blocks',[])
        counter=SemanticCounter(); counter.feed(raw.get('body_html',''))
        for item in v.get('best_pattern_evidence',[])+v.get('failure_evidence',[]):
            m=re.fullmatch(r'(blocks|body_html)\[(\d+)\]',item.get('block_ref',''))
            exists=False
            if m:
                kind,idx=m.group(1),int(m.group(2))
                exists=(kind=='blocks' and idx<len(blocks)) or (kind=='body_html' and idx<counter.count)
                if v['document_id'] in LEGACY: exists=exists and kind=='body_html'
                else: exists=exists and kind=='blocks'
            ref_ok=ref_ok and exists and bool(item.get('evidence','').strip())
            ref_evidence.append({'document_id':v['document_id'],'ref':item.get('block_ref'),'exists':exists})
    check('specific-existing-evidence-refs',ref_ok,ref_evidence)
    check('five-reader-risks',all(SURFACES <= {x.split(':',1)[0] for x in v.get('reader_risks',[])} for v in verdicts),sorted(SURFACES))
    att=report.get('mutation_attestation',{})
    check('read-only-mutation-attestation',att.get('production_papers_mutated') is False and att.get('cyclefleet_mutated') is False and att.get('bp_cycle_assign_called') is False and att.get('bp_cycle_result_called') is False,att)
    check('unvisited-scope-empty',report.get('unvisited_scope')==[],report.get('unvisited_scope'))
    reads=index.get('reads',[]); rows={x['document_id']:x for x in reads}
    rb_ok=index.get('all_pinned_revisions_read') is True and index.get('count')==9 and len(reads)==9
    representation_ok=True
    for u in bound['units']:
        p=HERE/'readbacks'/f"{u['document_id']}.json"; raw=load(p); row=rows.get(u['document_id'],{})
        rb_ok=rb_ok and raw.get('_id')==u['document_id'] and raw.get('_rev')==u['document_rev'] and row.get('document_rev')==u['document_rev'] and row.get('readback_sha256')==sha(p)
        if u['document_id'] in LEGACY: representation_ok=representation_ok and len(raw.get('blocks',[]))==0 and bool(raw.get('body_html','').strip())
        else: representation_ok=representation_ok and len(raw.get('blocks',[]))>0
    check('readbacks-exact-and-hashed',rb_ok,'all 9 raw ids/revisions and SHA-256 receipts match')
    check('native-and-legacy-representation',representation_ok and sum(x.get('block_count',0) for x in reads)==343 and sum(x.get('body_html_chars',0) for x in reads if x.get('document_id') in LEGACY)==146392,{'native_block_total':sum(x.get('block_count',0) for x in reads),'legacy_html_chars':sum(x.get('body_html_chars',0) for x in reads if x.get('document_id') in LEGACY)})
    check('purpose-based-duplicate-analysis',all(set(x)>={'candidate_set','basis','disposition'} and len(x.get('candidate_set',[]))>=2 for x in report.get('duplicate_candidates',[])),report.get('duplicate_candidates'))
    valid=all(x['status']=='PASS' for x in checks)
    result={'schema_version':'paper-perfection-successor-survey-report-validation/v1','assignment_id':'PPCC2-S041','valid':valid,'checks':checks,'summary':{'pass':sum(x['status']=='PASS' for x in checks),'fail':sum(x['status']=='FAIL' for x in checks)}}
    print(json.dumps(result,indent=2,ensure_ascii=False)); return 0 if valid else 1
if __name__=='__main__': sys.exit(main())
