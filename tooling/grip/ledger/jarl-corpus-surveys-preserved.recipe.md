# Re-derivation recipe — jarl-corpus-surveys (survey corpus preserved out of tmp)

Claim: the whole jarl corpus-survey corpus (7 wave JSONs, 8 identity dumps,
6 empty .err sidecars, build_wave_e.py = 22 files, 328K) now lives in the SHARED
barkpark checkout at `tooling/jarl-corpus-surveys/`, byte-identical to the
volatile session tmp it came from, and every .json parses.

```sh
D=/Users/frikkjarl/Documents/GitHub/barkpark/tooling/jarl-corpus-surveys

# 1. file count + size
ls -1 "$D" | wc -l && du -sh "$D"
# expect: 22 ; 328K

# 2. every .json parses
cd "$D" && python3 -c "import json,glob;[json.load(open(f)) and print(f,'OK') for f in sorted(glob.glob('*.json'))]"
# expect: 15 lines, all OK

# 3. wave-g has exactly 7 records
cd "$D" && python3 -c "import json;d=json.load(open('wave-g.json'));print(len(d),[r['subject'] for r in d])"
# expect: 7 ['SVGLoop (real project: svg-animate-check)', 'Spreadsheet Wizard',
#   'Full Blast (repo: frickin-real-time)', 'Scaffy',
#   'Bulldocs origin (Portable Docs + Paperflow -> Bulldocs)', 'Barkpark Cloud',
#   'GitHub contribution graph (bonus number)']

# 4. narrative record counts per wave (wave-e is NOT a record list — see note)
cd "$D" && python3 -c "
import json,glob
for f in sorted(glob.glob('wave-*.json')):
    d=json.load(open(f)); print(f, len(d) if isinstance(d,list) else 'dict:'+','.join(d))"
# expect: a 14  b 18  c 18  d 16  e dict:stats,repos  f 10  g 7   (= 83 narrative records)

# 5. wave-e is a repo inventory, not narrative records
cd "$D" && python3 -c "import json;d=json.load(open('wave-e.json'));print(list(d),len(d['repos']),len(d['stats']))"
# expect: ['stats', 'repos'] 284 14

# 6. sha256 manifest (recorded 2026-07-31)
cd "$D" && shasum -a 256 *
# wave-a e8c9b338a45e68a6ad1d59018a66bcd13e95d74fd4ba6d5bfca2234ddfe1b52a
# wave-b 9cd53ef963512cfcfe72a029c388ac29e83f646b1f7f33b7f9f29771da50527d
# wave-c b4cc0b2e2df986e7f271093633e1a6529b44126a840f7a4d98e486e7931b1998
# wave-d c05812ec8617e8e0071aaa24d382e546b2b578202ba2f1e1aa7e4d5e563bb282
# wave-e 7054e90c7c9e26096bb82d8d7329c21417fd803b4e69b77660b022cf42d2cacd
# wave-f 79bef5453efac061e966e77f7533cd23c35587c75cc592a0ec4eedaf0ff76b86
# wave-g 4cd1cd9815c660265a7eb7d1f1881144b09bdc62fc283ca218311b04bc3636f8
# build_wave_e.py 3e055fc043c5a4e5c1a2d2e5063b990cceb4c80f9e241516b8ee0d6cb7d10240
# identity: GyldendalDigital 106a71c2718e8f9e040be929d6976a8dee11f9d2e82cbfa1b78d9b79d0a48627
#           Umble-tech       517bd274b15bc5b214ae63a07391498e99381172494d8c6b846c5d0701510586
#           codehouseno      f1b8e6cd5a6230dd27785c18993f5111812c910d45c654b1bceb3b19d1893f7f
#           frikkern         5b1e821de2e460860afd10dc904fd334e3170d0d5a5207b261499eab5b877a17
#           guerrilla        018eb11449a407771fb89789696eac7bd715f2f813dd06ae0a5ebd0d38aea498
#           inligo-as        1e8d7ea074f8ce24d321550ba94dff9538cfd41084232b42c9ed9ba16f30e910
#           kult-byra        3349452fc45e2bd4e9768afd19e4dc7a9281b8e9e8f18538ba854ef4cc910e91
#           pelle-jarl       65763f4e50ed289184941253c17c38ec66c60ddf5fada653cf42f5e758a12d9b
# all six .err are empty (e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855)

# 7. byte-identity against tmp source (only while the tmp session survives)
diff -r '/private/tmp/claude-501/-Users-frikkjarl-Documents-GitHub/2938d290-edae-40dd-bce3-1286cec080a8/scratchpad/corpus-surveys' "$D" && echo CLEAN
# expect: CLEAN (no diff output)
```

Notes:
- The directory is UNTRACKED (`git status --porcelain` → `?? tooling/jarl-corpus-surveys/`).
  Decide chooses whether to commit it.
- The digest's "82 survey records" is off by one against what is on disk: the
  list-shaped waves (a,b,c,d,f,g) hold **83** records. wave-e is a separate shape
  (284-repo GitHub inventory + 14 stats), so it must not be added to that count.

Verified 2026-07-31 on the shared checkout (`main`, no branch switch, no commit).
