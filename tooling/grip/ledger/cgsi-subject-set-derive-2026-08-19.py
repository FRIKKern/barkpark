import os,sys,json,yaml,itertools,re
D=sys.argv[1]
wf=os.path.join(D,'.github/workflows')
spec=json.load(open(os.path.join(D,'.github/required-checks.json')))
req={c['context'] for c in spec['protection']['required_status_checks']['checks']}
exc={e['context']:e['reason'] for e in spec['exclusions']}

def render(key,j):
    """return list of rendered check-run context names for a job"""
    name=j.get('name') or key
    mx=(j.get('strategy') or {}).get('matrix') if isinstance(j.get('strategy'),dict) else None
    out=[]
    if isinstance(mx,dict):
        keys=[k for k in mx if k not in ('include','exclude')]
        vals=[mx[k] if isinstance(mx[k],list) else [mx[k]] for k in keys]
        combos=list(itertools.product(*vals)) if keys else []
        # substitute ${{ matrix.x }}
        if '${{' in str(name):
            for c in combos:
                n=name
                for k,v in zip(keys,c):
                    n=re.sub(r'\$\{\{\s*matrix\.'+re.escape(k)+r'\s*\}\}',str(v),n)
                out.append(n)
        else:
            if combos:
                for c in combos:
                    out.append('%s (%s)'%(name,', '.join(str(x) for x in c)))
            else:
                out.append(name)
        if not out: out=[name]
    else:
        out=[name]
    return out

allrows=[]   # (file, jobkey, rendered, needs)
byfile={}
for f in sorted(os.listdir(wf)):
    if not f.endswith(('.yml','.yaml')): continue
    try:
        doc=yaml.safe_load(open(os.path.join(wf,f)))
    except Exception as e:
        print('PARSE-FAIL',f,e); continue
    jobs=(doc or {}).get('jobs') or {}
    byfile[f]=jobs
    for k,j in jobs.items():
        if not isinstance(j,dict): continue
        nd=j.get('needs') or []
        if isinstance(nd,str): nd=[nd]
        for r in render(k,j):
            allrows.append((f,k,r,tuple(nd)))

# transitive needs-closure of required contexts, per file
blocking_keys=set()  # (file,jobkey)
for f,jobs in byfile.items():
    # find job keys whose rendered name is in req
    seeds=[k for k,j in jobs.items() if isinstance(j,dict) and set(render(k,j)) & req]
    stack=list(seeds); seen=set()
    while stack:
        k=stack.pop()
        if (f,k) in seen: continue
        seen.add((f,k)); blocking_keys.add((f,k))
        j=jobs.get(k)
        if not isinstance(j,dict): continue
        nd=j.get('needs') or []
        if isinstance(nd,str): nd=[nd]
        stack.extend(nd)

print('=== REQUIRED (%d) ==='%len(req))
for c in sorted(req): print('  ',c)
print()
print('=== SET A: exclusions with reason prefix S2/S4/S6/S7 ===')
A=[c for c,r in exc.items() if re.match(r'^S[2467]',r)]
for c in sorted(A): print('  [%s] %s'%(exc[c][:2],c))
print('SET A size:',len(A))
print()
setB=[]
for f,k,r,nd in allrows:
    if r in req: continue
    if (f,k) in blocking_keys: continue
    setB.append((f,k,r))
print('=== SET B: rendered job contexts NOT required and NOT in transitive needs-closure ===')
for f,k,r in setB: print('  %-30s %-34s %s'%(f,k,r))
print('SET B size:',len(setB))
print()
print('=== SET B members that HAVE an exclusion row ===')
hav=[ (f,k,r) for f,k,r in setB if r in exc]
for f,k,r in hav: print('  [%s] %s | %s'%(exc[r][:2],r,f))
print('count:',len(hav))
print('=== SET B members with NO exclusion row ===',len(setB)-len(hav))
print()
print('=== blocking (required or transitive) job keys ===')
for f,k in sorted(blocking_keys): print('  ',f,k)
