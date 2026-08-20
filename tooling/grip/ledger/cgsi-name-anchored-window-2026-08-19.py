import os,sys,json,yaml,itertools,re
D=sys.argv[1]; wf=os.path.join(D,'.github/workflows')
spec=json.load(open(os.path.join(D,'.github/required-checks.json')))
req={c['context'] for c in spec['protection']['required_status_checks']['checks']}
exc={e['context']:e['reason'] for e in spec['exclusions']}
ASSERT=re.compile(r'blocking|blocks the merge|must block|merge gate|required check',re.I)
W=200
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
raw={f:open(os.path.join(wf,f)).read() for f in files}
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
rows=[(f,k,r) for f,doc in files.items() for k,j in ((doc or {}).get('jobs') or {}).items() if isinstance(j,dict) for r in render(k,j)]
A={r for f,k,r in rows if r in exc and re.match(r'^S[2467]',exc[r])}
B={r for f,k,r in rows if r not in req and (f,k) not in blocking}
for lab,S_ in (('SET A',A),('SET B',B)):
    hits=[]
    for f,txt in raw.items():
        low=txt.lower()
        for c in S_:
            cl=c.lower(); i=0
            while True:
                p=low.find(cl,i)
                if p<0: break
                win=txt[p+len(c):p+len(c)+W]
                if ASSERT.search(win): hits.append((f,c,win.replace('\n',' ')[:80]))
                i=p+1
    seen=set(); u=[]
    for h in hits:
        if (h[0],h[1]) in seen: continue
        seen.add((h[0],h[1])); u.append(h)
    print('MIRROR SHAPE (name-anchored, %d-char forward window) on %s (%d members): %d contexts RED'%(W,lab,len(S_),len(u)))
    for f,c,w in u: print('   %-26s %-50s | %s'%(f,c[:50],w))
    print()
