import os,sys,json,yaml,itertools,re
D=sys.argv[1]; wf=os.path.join(D,'.github/workflows')
spec=json.load(open(os.path.join(D,'.github/required-checks.json')))
req={c['context'] for c in spec['protection']['required_status_checks']['checks']}
exc={e['context']:e['reason'] for e in spec['exclusions']}
NAMEBLOCK=re.compile(r'\(blocking\)',re.I)
PROSE=re.compile(r'\bBLOCKING\b|\bblocks the merge\b|\bmust block\b',re.I)
def render(key,j):
    name=j.get('name') or key
    st=j.get('strategy') if isinstance(j.get('strategy'),dict) else None
    mx=(st or {}).get('matrix')
    if isinstance(mx,dict):
        keys=[k for k in mx if k not in ('include','exclude')]
        vals=[mx[k] if isinstance(mx[k],list) else [mx[k]] for k in keys]
        combos=list(itertools.product(*vals)) if keys else []
        out=[]
        if '${{' in str(name):
            for c in combos:
                n=name
                for k,v in zip(keys,c): n=re.sub(r'\$\{\{\s*matrix\.'+re.escape(k)+r'\s*\}\}',str(v),n)
                out.append(n)
        elif combos: out=['%s (%s)'%(name,', '.join(map(str,c))) for c in combos]
        return out or [name]
    return [name]
files={}; raw={}
for f in sorted(os.listdir(wf)):
    if f.endswith(('.yml','.yaml')):
        files[f]=yaml.safe_load(open(os.path.join(wf,f))); raw[f]=open(os.path.join(wf,f)).read().splitlines()
blocking_keys=set()
for f,doc in files.items():
    jobs=(doc or {}).get('jobs') or {}
    seeds=[k for k,j in jobs.items() if isinstance(j,dict) and set(render(k,j))&req]
    st=list(seeds); seen=set()
    while st:
        k=st.pop()
        if (f,k) in seen: continue
        seen.add((f,k)); blocking_keys.add((f,k))
        j=jobs.get(k)
        if isinstance(j,dict):
            nd=j.get('needs') or []; nd=[nd] if isinstance(nd,str) else nd; st.extend(nd)
def jobline(f,k):
    pat=re.compile(r'^  '+re.escape(k)+r':\s*(#.*)?$')
    for i,l in enumerate(raw[f]):
        if pat.match(l): return i
    return None
def scoped_prose(f,k):
    i=jobline(f,k)
    if i is None: return []
    out=[]; j=i-1
    while j>=0 and (raw[f][j].strip().startswith('#') or raw[f][j].strip()==''):
        if raw[f][j].strip().startswith('#') and PROSE.search(raw[f][j]): out.append(raw[f][j].strip())
        j-=1
        if i-j>25: break
    return out
rows=[]
for f,doc in files.items():
    for k,j in ((doc or {}).get('jobs') or {}).items():
        if isinstance(j,dict):
            for r in render(k,j): rows.append((f,k,r,j))
A=[x for x in rows if x[2] in exc and re.match(r'^S[2467]',exc[x[2]])]
B=[x for x in rows if x[2] not in req and (x[0],x[1]) not in blocking_keys]
def ev(f,k,j,r):
    e=[]
    if NAMEBLOCK.search(r): e.append(('name',r))
    for s in (j.get('steps') or []):
        if isinstance(s,dict) and s.get('name') and NAMEBLOCK.search(str(s['name'])): e.append(('step',s['name']))
    for p in scoped_prose(f,k): e.append(('prose-scoped',p))
    return e
for lab,mem in (('SET A',A),('SET B',B)):
    print('=== %s (%d members) — NARROW evidence: job-name token / own step names / prose in the comment block directly above the job key ==='%(lab,len(mem)))
    n=0
    for f,k,r,j in mem:
        e=ev(f,k,j,r)
        if e:
            n+=1
            print('  RED %-26s %-58s [%s] steps=%d'%(f,r[:58],','.join(sorted({t for t,_ in e})),sum(1 for t,_ in e if t=='step')))
            for t,v in e[:2]: print('       %-12s %s'%(t,str(v)[:110]))
    print('  -> would RED on %d of %d\n'%(n,len(mem)))
