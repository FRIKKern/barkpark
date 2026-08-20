import os,sys,json,yaml,itertools,re
D=sys.argv[1]; wf=os.path.join(D,'.github/workflows')
spec=json.load(open(os.path.join(D,'.github/required-checks.json')))
req={c['context'] for c in spec['protection']['required_status_checks']['checks']}
exc={e['context']:e['reason'] for e in spec['exclusions']}
PROSE=re.compile(r'\bBLOCKING\b|\bblocks the merge\b|\bmust block\b|\bmerge gate\b',re.I)
def render(key,j):
    name=j.get('name') or key
    mx=(j.get('strategy') or {}).get('matrix') if isinstance(j.get('strategy'),dict) else None
    if isinstance(mx,dict):
        ks=[k for k in mx if k not in('include','exclude')]
        vs=[mx[k] if isinstance(mx[k],list) else [mx[k]] for k in ks]
        cs=list(itertools.product(*vs)) if ks else []
        out=[]
        if '${{' in str(name):
            for c in cs:
                n=name
                for k,v in zip(ks,c): n=re.sub(r'\$\{\{\s*matrix\.'+re.escape(k)+r'\s*\}\}',str(v),n)
                out.append(n)
        elif cs: out=['%s (%s)'%(name,', '.join(map(str,c))) for c in cs]
        return out or [name]
    return [name]
files={f:yaml.safe_load(open(os.path.join(wf,f))) for f in sorted(os.listdir(wf)) if f.endswith(('.yml','.yaml'))}
raw={f:open(os.path.join(wf,f)).read().splitlines() for f in files}
blocking=set()
for f,doc in files.items():
    jobs=(doc or {}).get('jobs') or {}
    st=[k for k,j in jobs.items() if isinstance(j,dict) and set(render(k,j))&req]; seen=set()
    while st:
        k=st.pop()
        if (f,k) in seen: continue
        seen.add((f,k)); blocking.add((f,k))
        j=jobs.get(k)
        if isinstance(j,dict):
            nd=j.get('needs') or []; nd=[nd] if isinstance(nd,str) else nd; st.extend(nd)
print('FILE-LEVEL RULE: header prose asserts blocking/merge-gate AND no job in the file is required-or-transitively-blocking')
n=0
for f,doc in files.items():
    jobs=(doc or {}).get('jobs') or {}
    hits=[l.strip() for l in raw[f][:45] if l.strip().startswith('#') and PROSE.search(l)]
    anyblock=any((f,k) in blocking for k in jobs)
    if hits and not anyblock:
        n+=1; print('  RED %-28s jobs=%d  first-claim: %s'%(f,len(jobs),hits[0][:95]))
    elif hits and anyblock:
        print('  ok  %-28s (file DOES host a blocking context)'%f)
print('  -> file-level reds:',n)
print()
print('security.yml jobs in blocking closure:',[k for k in (files["security.yml"]["jobs"]) if ("security.yml",k) in blocking])
print('elixir.yml  jobs in blocking closure:',[k for k in (files["elixir.yml"]["jobs"]) if ("elixir.yml",k) in blocking])
