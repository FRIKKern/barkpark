# Re-derivation recipe — the meter's decimal separator, and the four doubted load1 stamps

Host: Darwin 24.5.0, `hw.ncpu` = 10, `LANG=nb_NO.UTF-8`, `LC_ALL` unset.
Base: `origin/main` = `467f7e2837b0690d45a2c8a573e7242b6d720833` (2026-08-05).

## 1. `/usr/bin/time -p` decimal separator IS locale-sensitive on this host

    LC_ALL=C /usr/bin/time -p bash -c 'for i in $(seq 1 200000); do :; done' 2>&1 | tail -3
    /usr/bin/time -p bash -c 'for i in $(seq 1 200000); do :; done' 2>&1 | tail -3

Observed: `real 0.14 / user 0.13 / sys 0.01` under `LC_ALL=C`; `real 0,15 / user 0,15 / sys 0,00`
unpinned. The comma does NOT survive `LC_ALL=C`. Same for `uptime`:
`load averages: 12,71 …` unpinned, `12.71 …` under `LC_ALL=C`.

Round 2's `LC_ALL=C` pin is therefore NOT cosmetic on this host.

## 2. The pin is load-bearing in BOTH directions — awk truncates the wrong separator to 0

    for loc in "" "C"; do for inp in "0.53 0.72" "0,53 0,72"; do … awk '{print $1+$2}'; done; done

| awk locale | input | result |
|---|---|---|
| default (nb_NO) | `0.53 0.72` | `0` |
| default (nb_NO) | `0,53 0,72` | `1,25` |
| `LC_ALL=C` | `0.53 0.72` | `1.25` |
| `LC_ALL=C` | `0,53 0,72` | `0` |

`bc` is loud instead (`Parse error: bad expression`), awk is SILENT. Pinning the METER without
pinning the SUMMER (or vice versa) yields a silent `0`.

## 3. The `tr -d ,` inflation reproduces — and it CANNOT be the four stamps' mechanism

    uptime | awk -F'load averages:' '{print $2}' | awk '{print $1}' | tr -d ,   # -> 3364
    LC_ALL=C uptime | awk -F'load averages:' '{print $2}' | awk '{print $1}'    # -> 33.64

100× inflation, confirmed. BUT the artifact DESTROYS the decimal point (`3364`, an integer).
All four doubted stamps — `load1=41.63`, `79.23`, `24.26`, `26.44`
(`scripts/pds-door-census.sh`, rows at :237 :238 :283-286) — carry a dot and two decimals.
They are not products of `tr -d ,`.

## 4. The "implausible next to 2.1–3.4" premise is a QUIET-HOST premise

    for i in 1 2 3 4 5; do LC_ALL=C uptime | sed 's/.*load averages: //'; sleep 3; done

Observed on 2026-08-05 20:01 under wave load, 10 CPUs:

    47.43 16.54 8.33
    46.84 16.93 8.52
    46.84 16.93 8.52
    45.97 17.25 8.68
    45.89 17.71 8.89

load1 = 47.43 sustained. 24.26 / 26.44 / 41.63 are directly bracketed by a live measurement;
79.23 is within 1.7× of one. `pds-w46-load-stamp-provenance-doubt`'s criterion 2 ("a recorded
rule-out with a reason is an acceptable outcome") is buyable on this evidence.
