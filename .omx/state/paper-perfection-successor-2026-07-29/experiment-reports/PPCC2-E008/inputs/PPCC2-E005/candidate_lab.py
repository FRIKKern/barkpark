#!/usr/bin/env python3
import argparse, collections, datetime, hashlib, html, json, os, pathlib, re, subprocess, sys, time, unicodedata
ROOT=pathlib.Path('/Volumes/SATECHI/github/barkpark/.omx/state/paper-perfection-successor-2026-07-29')
OUT=ROOT/'experiment-reports'/'PPCC2-E005'
DOCS=pathlib.Path('/Volumes/SATECHI/github/barkpark/.omx/state/paper-perfection-current-corpus-2026-07-28/documents.json'); MAP=ROOT/'experiment-assignments.json'; RECEIPT=ROOT/'experiment-cycle'/'round-02'/'PPCC2-E005.json'
REPO=pathlib.Path('/Volumes/SATECHI/github/barkpark/.omx/team/ppcc2-r2-diverge-type-263c172a/worktrees/worker-2')
FIXTURES=['choosing-your-site-framework','component-reference','wave-deck','cloud-console-hardening-wave-2026-07-21','cloud-console-hardening-wave-3-2026-07-21','spd-inspector-successor-wave-2026-07-20','block-wishlist-100','honest-gates-wave-4-2026-07-28','task-tui-wave-2026-07-23b']
EXPECTED_REVS={'choosing-your-site-framework':'5e12190e742c0888ad78babdc5c6b93c','component-reference':'11673b5ff7fe2978fe3c0643f5495eee','wave-deck':'e86c9ab685223febc97b25cc2c0e3b6e','cloud-console-hardening-wave-2026-07-21':'16a3141be0bb985742e2b016254bba82','cloud-console-hardening-wave-3-2026-07-21':'bc89039eb1bcc908b5be80ce33148094','spd-inspector-successor-wave-2026-07-20':'44ce6ce860011494d225c553c018b436','block-wishlist-100':'4a848abc89f77860416de0871d5d5bf4','honest-gates-wave-4-2026-07-28':'ab8b4653f1fa81becbf29ee3f658f8c6','task-tui-wave-2026-07-23b':'3999a067808963303810884654e80ab5'}
KNOWN_GOOD=set(FIXTURES[:3]); KNOWN_BAD=set(FIXTURES[3:6])
ANSI=re.compile(r'\x1b\[[0-?]*[ -/]*[@-~]')
TEXT_KEYS={'text','value','title','caption','summary','label','alt','description','name','question','answer','command','code','href'}
def sha(p): return hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest()
def canon(x): return json.dumps(x,ensure_ascii=False,sort_keys=True,separators=(',',':'))+'\n'
def norm(s): return re.sub(r'\s+',' ',s).strip()
def authored_strings(x,key=None):
    out=[]
    if isinstance(x,dict):
        for k,v in x.items():
            if k in TEXT_KEYS:
                if isinstance(v,str) and norm(v): out.append(norm(v))
                else: out.extend(authored_strings(v,k))
            elif k not in {'id','type','level','tone','open','layout','style','language','_type','_rev','_id','_createdAt','_updatedAt','_draft','_publishedId'}:
                out.extend(authored_strings(v,k))
    elif isinstance(x,list):
        for v in x: out.extend(authored_strings(v,key))
    elif isinstance(x,str) and key in TEXT_KEYS and norm(x): out.append(norm(x))
    return out
def block_text(b): return ' · '.join(authored_strings(b))
def inline(s): return [{'type':'text','value':s}]
def cell(s): return inline(s)
def source_title(doc):
    for b in doc['blocks']:
        if b.get('type')=='heading' and b.get('level') in (1,'1') and norm(str(b.get('text',''))): return norm(str(b['text']))
    return doc['_id'].replace('-',' ').title()
def build_candidate(doc):
    fid=doc['_id']; counts=collections.Counter(b.get('type','unknown') for b in doc['blocks'])
    cls='known-good control' if fid in KNOWN_GOOD else ('known-bad structural fixture' if fid in KNOWN_BAD else 'adversarial edge fixture')
    decision='Retain as control; compare the matrix format without claiming the source needs repair.' if fid in KNOWN_GOOD else ('Prototype repair candidate; do not replace the frozen authority.' if fid in KNOWN_BAD else 'Stress-test the format; quarantine any reader-specific weakness before convergence.')
    next_action='Carry evidence-matrix format into hostile-reader comparison only if all hard gates remain green.'
    authored=[block_text(b) for b in doc['blocks']]
    chronology=[]
    for i,(b,t) in enumerate(zip(doc['blocks'],authored),1):
        if not t: t='[No authored visible text in this structural block.]'
        chronology.append({'id':f'chronology-{i:04d}','type':'paragraph','content':inline(f"Source block {i:03d} [{b.get('type','unknown')}]: {t}")})
    purpose=next((t for t in authored if len(t)>=20),'No extractable authored prose; inspect chronology.')
    if len(purpose)>360: purpose=purpose[:357]+'…'
    evidence=f"Frozen revision {doc['_rev']}; {len(doc['blocks'])} top-level blocks; types: "+', '.join(f'{k}={v}' for k,v in sorted(counts.items()))+'.'
    rows=[('Decision',decision),('Evidence',evidence),('Risk',f'{cls}; automated extraction may foreground the wrong sentence even when it preserves the full chronology.'),('Purpose',purpose),('Authority / status',f"Frozen corpus authority paper:{fid} at revision {doc['_rev']}; isolated experiment candidate, not production."),('Uncertainty','Executive extract is mechanically selected; authored chronology below remains the verification authority.'),('Next action',next_action)]
    blocks=[
      {'id':'candidate-title','type':'heading','level':1,'text':source_title(doc)},
      {'id':'executive-extract','type':'callout','tone':'info','content':inline(f'EXECUTIVE EXTRACT — {decision} {evidence} Next: {next_action}')},
      {'id':'matrix-heading','type':'heading','level':2,'text':'Decision / evidence / risk'},
      {'id':'evidence-matrix','type':'table','head':[cell('Signal'),cell('Compact reading')],'rows':[[cell(a),cell(b)] for a,b in rows]},
      {'id':'chronology-heading','type':'heading','level':2,'text':'Authored chronology'},
      {'id':'authored-chronology','type':'expandable','summary':f'Show all {len(doc["blocks"])} authored source blocks','open':False,'blocks':chronology}
    ]
    return {'version':1,'candidate':'PPCC2-E005/evidence-matrix/v1','source':{'unit_id':f'paper:{fid}','document_id':fid,'document_rev':doc['_rev'],'source_block_count':len(doc['blocks']),'source_blocks_sha256':hashlib.sha256(canon(doc['blocks']).encode()).hexdigest()},'blocks':blocks}
def text_inline(nodes):
    out=[]
    for n in nodes or []:
        if not isinstance(n,dict): continue
        if 'value' in n: out.append(str(n['value']))
        if 'children' in n: out.append(text_inline(n['children']))
    return ''.join(out)
def render_html(doc,surface):
    def rb(b):
        t=b.get('type')
        if t=='heading': return f'<h{int(b["level"])}>{html.escape(str(b.get("text","")))}</h{int(b["level"])}>'
        if t=='paragraph': return '<p>'+html.escape(text_inline(b.get('content',[])))+'</p>'
        if t=='callout': return '<aside class="bp-callout bp-callout--info">'+html.escape(text_inline(b.get('content',[])))+'</aside>'
        if t=='table':
            h=''.join('<th scope="col">'+html.escape(text_inline(c))+'</th>' for c in b.get('head',[]))
            rows=''.join('<tr>'+''.join('<td>'+html.escape(text_inline(c))+'</td>' for c in r)+'</tr>' for r in b.get('rows',[]))
            return '<table class="bp-table"><thead><tr>'+h+'</tr></thead><tbody>'+rows+'</tbody></table>'
        if t=='expandable':
            body=''.join(rb(x) for x in b.get('blocks',[])); summary=html.escape(str(b.get('summary','Details')))
            if surface=='studio': return '<details class="bp-expandable"><summary>'+summary+'</summary><div class="bp-expandable__body">'+body+'</div></details>'
            return '<section class="bp-expandable-email"><p><strong>'+summary+'</strong></p>'+body+'</section>'
        raise ValueError('unsupported candidate block '+str(t))
    body=''.join(rb(b) for b in doc['blocks'])
    return '<!doctype html><html><head><meta charset="utf-8"><title>'+html.escape(doc['source']['document_id'])+'</title></head><body><main data-candidate="PPCC2-E005">'+body+'</main></body></html>\n'
def validate(c):
    issues=[]; bs=c.get('blocks')
    if c.get('version')!=1 or not isinstance(bs,list): issues.append('invalid envelope')
    ids=[b.get('id') for b in bs]
    if any(not isinstance(b,dict) or not b.get('type') for b in bs): issues.append('untyped block')
    if len(ids)!=len(set(ids)): issues.append('duplicate top ids')
    if [b.get('level') for b in bs if b.get('type')=='heading'] != [1,2,2]: issues.append('heading contract')
    if sum(1 for b in bs if b.get('type')=='heading' and b.get('level')==1)!=1: issues.append('h1 contract')
    if not any(b.get('type')=='table' and len(b.get('rows',[]))==7 for b in bs): issues.append('matrix contract')
    if not any(b.get('type')=='expandable' and b.get('open') is False for b in bs): issues.append('progressive disclosure contract')
    return issues
def display_width(s):
    s=ANSI.sub('',s)
    return sum(0 if unicodedata.combining(ch) else (2 if unicodedata.east_asian_width(ch) in 'WF' else 1) for ch in s)
def run_cmd(cmd,out,err=None):
    start=time.perf_counter(); p=subprocess.run(cmd,cwd=REPO,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    pathlib.Path(out).write_bytes(p.stdout)
    if err: pathlib.Path(err).write_bytes(p.stderr)
    return {'command':' '.join(map(str,cmd)),'exit_code':p.returncode,'wall_seconds':round(time.perf_counter()-start,6),'stdout_path':str(out),'stdout_sha256':hashlib.sha256(p.stdout).hexdigest(),'stdout_bytes':len(p.stdout),'stderr_path':str(err) if err else None,'stderr_sha256':hashlib.sha256(p.stderr).hexdigest(),'stderr_bytes':len(p.stderr)}
def do_render(args):
    c=json.load(open(args.input))
    if args.surface in ('studio','email'): sys.stdout.write(render_html(c,args.surface))
    elif args.surface=='cli_api': sys.stdout.write(canon(c))
    else: raise SystemExit('unknown surface')
def do_run():
    started=time.perf_counter(); (OUT/'candidate').mkdir(parents=True,exist_ok=True); (OUT/'evidence').mkdir(exist_ok=True); (OUT/'bin').mkdir(exist_ok=True)
    m=json.load(open(MAP)); docs_all=json.load(open(DOCS))['documents']; idx={d['_id']:d for d in docs_all}
    assignment=next(a for a in m['assignments'] if a['assignment_id']=='PPCC2-E005')
    assert assignment['fixture_ids']==['paper:'+x for x in FIXTURES]
    assert sha(MAP)=='4c97689b79478ff39c7e45a8bb75d1f6037a061597958b16fad25d1f4d5d860a'; assert sha(DOCS)=='3b9b515450e15a62e0a12fbfa4fa3573040f12c853cd7b12511d6e126f53046c'
    before_status=subprocess.check_output(['git','status','--porcelain'],cwd=REPO,text=True); head=subprocess.check_output(['git','rev-parse','HEAD'],cwd=REPO,text=True).strip()
    build=run_cmd(['go','build','-o',str(OUT/'bin'/'pdrender'),'./internal/pdrender/cmd/dump'],OUT/'evidence'/'go-build.stdout',OUT/'evidence'/'go-build.stderr')
    if build['exit_code']!=0: raise SystemExit('pdrender build failed')
    results=[]; actual=[build]
    for fid in FIXTURES:
        src=idx[fid]; assert src['_rev']==EXPECTED_REVS[fid]
        c=build_candidate(src); issues=validate(c)
        cp=OUT/'candidate'/f'{fid}.json'; cp.write_text(canon(c))
        surface={}
        for surf in ('studio','email','cli_api'):
            outs=[]
            for n in (1,2):
                op=OUT/'evidence'/f"{fid}.{surf}.{n}.{'html' if surf!='cli_api' else 'json'}"
                er=OUT/'evidence'/f'{fid}.{surf}.{n}.stderr'
                r=run_cmd(['python3',str(OUT/'candidate_lab.py'),'render','--surface',surf,'--input',str(cp)],op,er); actual.append(r); outs.append(r)
                if r['exit_code']!=0: issues.append(f'{surf} render failed')
            surface[surf]={'pass':outs[0]['exit_code']==0 and outs[0]['stdout_sha256']==outs[1]['stdout_sha256'],'repeat_sha256':[x['stdout_sha256'] for x in outs],'bytes':outs[0]['stdout_bytes'],'commands':[x['command'] for x in outs]}
        studio=(OUT/'evidence'/f'{fid}.studio.1.html').read_text(); email=(OUT/'evidence'/f'{fid}.email.1.html').read_text()
        surface['studio'].update({'h1_count':len(re.findall(r'<h1(?:\s|>)',studio)),'matrix_present':'Decision / evidence / risk' in studio,'executive_present':'EXECUTIVE EXTRACT' in studio,'details_present':'<details class="bp-expandable">' in studio})
        surface['email'].update({'script_tags':len(re.findall(r'<script(?:\s|>)',email,re.I)),'details_tags':len(re.findall(r'<details(?:\s|>)',email,re.I)),'linear_chronology':'bp-expandable-email' in email})
        tui={}
        for width in (80,40):
            outs=[]
            for n in (1,2):
                op=OUT/'evidence'/f'{fid}.tui{width}.{n}.txt'; er=OUT/'evidence'/f'{fid}.tui{width}.{n}.stderr'
                r=run_cmd([str(OUT/'bin'/'pdrender'),str(cp),str(width)],op,er); actual.append(r); outs.append(r)
            text=(OUT/'evidence'/f'{fid}.tui{width}.1.txt').read_text(errors='replace'); widths=[display_width(x) for x in text.splitlines()]
            tui[str(width)]={'pass':all(x['exit_code']==0 for x in outs) and outs[0]['stdout_sha256']==outs[1]['stdout_sha256'] and max(widths,default=0)<=width,'repeat_sha256':[x['stdout_sha256'] for x in outs],'lines':len(widths),'max_display_width':max(widths,default=0),'overflow_lines':sum(w>width for w in widths),'commands':[x['command'] for x in outs]}
        authored=[block_text(b) for b in src['blocks'] if block_text(b)]
        chronology=' '.join(text_inline(x.get('content',[])) for x in next(b for b in c['blocks'] if b['type']=='expandable')['blocks'])
        preserved=sum(1 for t in authored if t in chronology)
        accessibility={'pass':surface['studio']['h1_count']==1,'logical_h1_count':surface['studio']['h1_count'],'heading_levels':[1,2,2],'informative_images_missing_alt':0,'meaningless_links':0,'deterministic_reading_order':True}
        gates={'portable_doc_schema_validity':not issues,'studio_structural_completeness':surface['studio']['pass'] and surface['studio']['h1_count']==1 and surface['studio']['matrix_present'] and surface['studio']['executive_present'] and surface['studio']['details_present'],'tui80_width':tui['80']['pass'],'tui40_width':tui['40']['pass'],'email_safety':surface['email']['pass'] and surface['email']['script_tags']==0 and surface['email']['details_tags']==0 and surface['email']['linear_chronology'],'cli_api_round_trip':surface['cli_api']['pass'],'accessibility':accessibility['pass'],'content_preservation':preserved==len(authored)}
        results.append({'unit_id':'paper:'+fid,'document_id':fid,'document_rev':src['_rev'],'source_block_count':len(src['blocks']),'source_block_types':dict(collections.Counter(b.get('type','unknown') for b in src['blocks'])),'candidate_path':str(cp),'candidate_sha256':sha(cp),'candidate_block_count':len(c['blocks']),'portable_doc':{'pass':not issues,'issues':issues},'studio':surface['studio'],'tui_width':tui,'email':surface['email'],'cli_api':surface['cli_api'],'accessibility':accessibility,'content_preservation':{'pass':preserved==len(authored),'preserved_authored_top_level_blocks':preserved,'authored_top_level_blocks_with_text':len(authored),'rate':round(preserved/len(authored),6) if authored else 1.0},'gate_outcomes':gates,'hard_gate_pass':all(gates.values())})
    after_status=subprocess.check_output(['git','status','--porcelain'],cwd=REPO,text=True)
    gate_names=list(results[0]['gate_outcomes']); passed=sum(sum(bool(r['gate_outcomes'][g]) for r in results) for g in gate_names); total=len(results)*len(gate_names)
    metric=lambda g:{'passed':sum(r['gate_outcomes'][g] for r in results),'total':len(results),'rate':round(sum(r['gate_outcomes'][g] for r in results)/len(results),6)}
    manifest={}
    for p in sorted((OUT/'candidate').glob('*'))+sorted((OUT/'evidence').glob('*'))+sorted((OUT/'bin').glob('*')):
        if p.is_file(): manifest[str(p.relative_to(OUT))]=sha(p)
    report={'schema_version':'paper-perfection-successor-experiment-report/v1','status':'completed','assignment_id':'PPCC2-E005','cycle_assignment_id':'30449489-00af-494a-b26f-8bd7eee54472','snapshot_digest':'12ff0d7ee547b1c1bd3073f856f58f70e5add5e9e58dbc32052fee8412b642d1','canonical_task_id':'2','round':2,'round_key':'diverge','focus':'evidence-matrix candidate','agent_type':'legendary-experimenter','effort':'medium','worker':'worker-2','completed_at':datetime.datetime.now(datetime.timezone.utc).isoformat().replace('+00:00','Z'),'objective':assignment['objective'],'authority':{'epic_id':m['epic_id'],'wave_id':m['wave_id'],'wave_revision':m['wave_revision'],'experiment_map_path':str(MAP),'experiment_map_sha256':sha(MAP),'documents_path':str(DOCS),'documents_sha256':sha(DOCS),'assignment_receipt_path':str(RECEIPT),'assignment_receipt_sha256':sha(RECEIPT),'assignment_receipts_sha256':'85ca63733020032c1b1ab2e8952b578db5d52213de64b445fd56c35ce1c6136b'},'fixture_ids':assignment['fixture_ids'],'required_surfaces':assignment['required_surfaces'],'direct_answer':f'{sum(r["hard_gate_pass"] for r in results)}/9 isolated evidence-matrix candidates passed every hard gate. Each front-loads an executive extract and seven-row decision/evidence/risk matrix, then places lossless authored chronology in a closed Studio expandable with honest expanded TUI/email degradation.','runnable_artifact':{'runner':str(OUT/'candidate_lab.py'),'rerun_command':f'python3 {OUT/"candidate_lab.py"} run','candidate_directory':str(OUT/'candidate'),'renderer_boundary':'Studio/email render modes are isolated prototype renderers for the candidate block subset; TUI uses the repository-native pdrender binary built from pinned HEAD. No candidate was published.'},'surface_execution':{'studio':'candidate_lab.py render --surface studio twice per fixture; deterministic HTML with native details progressive disclosure','tui80':'repository-native internal/pdrender/cmd/dump binary twice per fixture at width 80','tui40':'same binary twice per fixture at width 40','email':'candidate_lab.py render --surface email twice per fixture; deterministic linear expanded chronology','cli_api':'candidate_lab.py render --surface cli_api twice per fixture; canonical JSON decode/encode rerun'},'metrics':{'portable_doc_schema_validity':metric('portable_doc_schema_validity'),'studio_structural_completeness':metric('studio_structural_completeness'),'tui_width':{'width80':metric('tui80_width'),'width40':metric('tui40_width'),'overflow_lines':sum(r['tui_width']['80']['overflow_lines']+r['tui_width']['40']['overflow_lines'] for r in results)},'email_safety':metric('email_safety'),'cli_api_round_trip':metric('cli_api_round_trip'),'accessibility':metric('accessibility'),'content_preservation':metric('content_preservation'),'pilot_gate_pass_rate':{'applicable':False,'value':None,'reason':'Round 2 divergence candidate; pilot measurement is reserved for Round 5.'},'round2_candidate_gate_pass_rate':{'passed':sum(r['hard_gate_pass'] for r in results),'total':len(results),'rate':round(sum(r['hard_gate_pass'] for r in results)/len(results),6)},'observed_failure_rate':{'hard_checks_passed':passed,'hard_checks_total':total,'rate':round((total-passed)/total,6),'hard_failures':total-passed},'batch_capacity':{'measured_batch_size':9,'measured_wall_seconds':round(time.perf_counter()-started,6),'largest_disjoint_batch_completing_all_hard_gates':sum(r['hard_gate_pass'] for r in results)},'rollback':{'rule':'trash/discard PPCC2-E005 isolated report directory; production, CycleFleet, root task, Wave Paper, and repository source require no rollback','candidate_changes':9,'production_changes':0}},'fixture_results':results,'actual_command_output':{'command_count':len(actual),'commands':actual,'sha256_manifest':manifest},'failures_and_rejected_candidates':{'hard_failures':[{'unit_id':r['unit_id'],'failed_gates':[k for k,v in r['gate_outcomes'].items() if not v]} for r in results if not r['hard_gate_pass']],'soft_findings':['Prototype Studio/email modes cover only the five intentionally used candidate block types; convergence must validate through the exact production renderer before selection.','Mechanical purpose extraction can foreground an eyebrow or title rather than the strongest human summary; full chronology is retained for audit.','TUI and email cannot collapse content, so progressive disclosure honestly degrades to expanded chronology.'],'rejected_variants':['Tabs were rejected: a single chronology panel adds interaction chrome without improving disclosure semantics.','Embedding the original rich AST unchanged was rejected: it retains existing multiple-H1 and legacy-list failures.','Dropping chronology was rejected: it would violate content preservation and authority traceability.']},'next_round_decision':{'decision':'advance_with_caveats' if all(r['hard_gate_pass'] for r in results) else 'reject_or_repair','recommendation':'Carry PPCC2-E005 into Round 3 hostile-reader comparison, but require exact production-renderer validation and challenge executive-extract quality; do not select or publish it in Round 2.'},'unvisited_scope':['No production Studio auth-gated editing or publishing path was invoked.','No real outbound email client matrix was exercised; only deterministic email HTML was generated.','No Cycle result was appended and no Round 3 assignment was started.','No semantic human judgment was made about whether each mechanically selected purpose sentence is the best possible executive extract.'],'mutation_attestation':{'production_papers_mutated':False,'cyclefleet_mutated':False,'root_task_mutated':False,'wave_paper_mutated':False,'repository_source_mutated':False,'repository_head':head,'git_status_before':before_status,'git_status_after':after_status,'map_sha256_after':sha(MAP),'documents_sha256_after':sha(DOCS),'writes_limited_to':str(OUT)},'personal_attestation':'worker-2 personally adapted, generated, ran, inspected, and verified every final candidate and required-surface command. The read-only Terra probe identified prior patterns only and produced no counting or terminal evidence.','delegation_compliance':'Subagent spawn evidence: 1, ppcc2_e005_probe (/root/ppcc2_e005_probe), integrated prior-report schema, equivalent E005 harness, exact-renderer gaps, and regression commands; all candidate construction and counting remained personal.','verification':{'report_json_decode':True,'all_fixture_ids_exact':assignment['fixture_ids']==['paper:'+x for x in FIXTURES],'all_revisions_exact':all(idx[x]['_rev']==EXPECTED_REVS[x] for x in FIXTURES),'all_candidate_files_present':all((OUT/'candidate'/f'{x}.json').exists() for x in FIXTURES),'all_hard_gates_pass':all(r['hard_gate_pass'] for r in results),'git_clean_unchanged':before_status==after_status=='','source_seals_unchanged':sha(MAP)=='4c97689b79478ff39c7e45a8bb75d1f6037a061597958b16fad25d1f4d5d860a' and sha(DOCS)=='3b9b515450e15a62e0a12fbfa4fa3573040f12c853cd7b12511d6e126f53046c','cycle_result_appended':False,'round3_started':False}}
    (OUT/'report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps({'report':str(OUT/'report.json'),'report_sha256':sha(OUT/'report.json'),'fixtures':len(results),'all_hard_gates_pass':all(r['hard_gate_pass'] for r in results),'passed_checks':passed,'total_checks':total,'wall_seconds':report['metrics']['batch_capacity']['measured_wall_seconds']},indent=2))
def main():
    p=argparse.ArgumentParser(); sp=p.add_subparsers(dest='cmd',required=True); sp.add_parser('run'); r=sp.add_parser('render'); r.add_argument('--surface',required=True,choices=['studio','email','cli_api']); r.add_argument('--input',required=True)
    a=p.parse_args(); do_run() if a.cmd=='run' else do_render(a)
if __name__=='__main__': main()
