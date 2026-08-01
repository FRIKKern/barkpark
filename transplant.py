import subprocess,re,sys
p="cloud/priv/static/__preview__/overflow-guard.mjs"
subprocess.run(["git","checkout","--ours","--",p],check=True)
theirs=subprocess.run(["git","show",":3:"+p],capture_output=True,text=True).stdout
s=open(p).read()
def block(txt,D):
    i=txt.find('if (requested.includes("%s"))'%D)
    j=txt.index("{",i); depth=0; k=j
    while k<len(txt):
        if txt[k]=="{": depth+=1
        elif txt[k]=="}":
            depth-=1
            if depth==0: break
        k+=1
    return txt[txt.rfind("\n    // ──",0,i):k+1]
names=re.findall(r'requested\.includes\("([^"]+)"\)',theirs)
missing=[n for n in names if 'requested.includes("%s")'%n not in s]
print("missing legs:",missing)
for D in missing:
    leg=block(theirs,D)
    reg=re.findall(r'\n  "(W\d+-[^"]+)",',s)
    anchor='\n  "%s",'%reg[-1]
    s=s.replace(anchor,anchor+'\n  "%s",'%D,1)
    i2=s.find('if (requested.includes("%s"))'%reg[-1])
    j2=s.index("{",i2); depth=0; k2=j2
    while k2<len(s):
        if s[k2]=="{": depth+=1
        elif s[k2]=="}":
            depth-=1
            if depth==0: break
        k2+=1
    s=s[:k2+1]+"\n"+leg+s[k2+1:]
    print("  inserted",D,"after",reg[-1],len(leg),"bytes")
open(p,"w").write(s)
