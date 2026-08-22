# FIXTURE — clean. Every printed command here MUST parse.

This file is a FIXTURE, not documentation. It exists so the `--selftest` has a
corpus it OWNS: the live `templates/**` READMEs get edited by other rows (the
`--barkpark` defects were repaired by #6941, and `stw11-claim-ledger` edits them
again), so a selftest anchored to them stops proving anything the moment someone
repairs a README — and stays green while it does.

It also covers the four markup shapes a printed command appears in, because a
pattern written for one shape silently UNDER-counts the rest.

Fenced, one per line:

```sh
bp login --device
bp cloud site deploy <slug>
bp cloud status
```

Fenced with a `$ ` prompt and a trailing shell comment:

```sh
$ bp cloud site status <slug>          # streams the six stages
```

Fenced and backslash-continued — ONE command across two lines. Unjoined, the
first line alone would RED for the required flags that live on the second:

```sh
bp cloud site create --name my-search --dataset default/default/production \
  --instance <your-box> --kind node --framework nextjs --template search-starter
```

Inline in prose: `bp cloud site rollback <slug>` reverts the previous slot, and
`bp cloud site create --template search-starter` names one flag mid-sentence —
an illustration, not a complete invocation, so required-flag checking must NOT
fire on it.
