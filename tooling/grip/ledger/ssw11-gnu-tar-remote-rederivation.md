# ssw11 verifier [gnu-tar-remote] — re-derivation recipes

All rows produced 2026-07-30 against origin/main @ 05111256892857da8de458ae4767662f72bb5804.
Host under test: guerrilla 157.180.90.121 (Ubuntu 24.04.4, x86_64, GNU tar 1.35, Python 3.12.3,
Elixir 1.18.4 / OTP 27 via `/root/.asdf/shims`). Guerrilla's checkout == origin/main and
`api/lib/barkpark/sites/prebuilt_artifact.ex` is byte-identical (sha256 cd7f9e00ce9625d25a8b304d1e2e5ba91e04d4b81839740da1680652602fdfa2).

Helper scripts staged on the box during the run (recreate from this file's sibling recipes):
  /tmp/probe.py       — walks 512-byte blocks, reads typeflag at byte 156, name 0..100,
                        prefix 345..500, size 124..136 octal; prints TYPEFLAG SEQ.
  /tmp/mutate.py      — block-RELATIVE size over-declaration + checksum recompute + verify.
                        (An absolute-offset version silently corrupts block 0 — the first
                        attempt in this session did exactly that and had to be discarded.)
  /tmp/stage_probe.exs — calls the REAL Barkpark.Sites.PrebuiltArtifact.stage/4 and lists the
                        staged tree with per-file byte sizes.

## R1 — GNU tar's default format election (L1, no inference)
    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'tar --version | head -1; tar --show-defaults'
  => `tar (GNU tar) 1.35` / `--format=gnu -f- -b20 …`

## R2 — GNU tar 1.35 name-shape census (typeflags at byte 156 of raw blocks)
    # build dists for ascii / NFC / NFD / 121-byte unsplittable component, then:
    ( cd /tmp/gt/dist_$k && tar czf /tmp/gt/$k.tgz . )
    python3 /tmp/probe.py /tmp/gt/{ascii,nfc,nfd,long}.tgz
  => ascii/nfc/nfd: `5 0 5 0` (plain USTAR, RAW UTF-8 in the name field, magic `ustar `)
  => long:          `5 L 5 L 0 0` (GNU @LongLink, NOT pax)

## R3 — the real extractor's verdict on those same bytes (lifts L3 census cells to L1)
    PC=/opt/barkpark/api/_build/prod/lib/plug_crypto/ebin
    cp /opt/barkpark/api/lib/barkpark/sites/prebuilt_artifact.ex /tmp/gt/pa.ex
    elixirc -o /tmp/gt/ebin /tmp/gt/pa.ex            # only warning: Plug.Crypto not in path
    elixir -pa /tmp/gt/ebin -pa "$PC" /tmp/stage_probe.exs /tmp/gt/*.tgz

## R4 — over-declared size, typeflag 0 vs typeflag 5
    python3 /tmp/mutate.py /tmp/gt/ascii.tgz /tmp/gt/overfile.tar ./index.html 1024
    python3 /tmp/mutate.py /tmp/gt/ascii.tgz /tmp/gt/overdir.tar  ./cafe/     1024
    tar tvf …; tar xf … -C …; echo RC=$?      # GNU side
    gzip -c … > ….tgz; elixir … /tmp/stage_probe.exs ….tgz   # extractor side

## R5 — NFC/NFD divergence on the staged tree
    ls /tmp/gt/staged_nf{c,d}_tgz | while read -r n; do printf %s "$n" | xxd -p; done
    test -f "/tmp/gt/staged_nfd_tgz/$(python3 -c 'import unicodedata;print(unicodedata.normalize("NFC","café"))')/index.html"

## R6 — code-side anchors (no box needed)
    git show origin/main:api/lib/barkpark/sites/prebuilt_artifact.ex | sed -n '470,600p'
    git show origin/main:api/test/barkpark/sites/prebuilt_artifact_test.exs | sed -n '195,215p;485,548p'
    git grep -c 'erl_tar' origin/main -- api/test/barkpark/sites/prebuilt_artifact_test.exs
