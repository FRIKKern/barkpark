# Site Spawner wave 11 — box locale + accented staging — re-derivation recipes (2026-07-30)

Lane: `box-locale-and-staging`. Every command below runs ON guerrilla
(157.180.90.121) because macOS physically cannot host the latin1 name-mode case
(it forces `utf8`). Nothing here mutates the box outside `/tmp` — the ephemeral
Caddy binds `127.0.0.1:8791` and is killed in the same command.

Box state when measured: `/opt/barkpark` HEAD `05111256892857da8de458ae4767662f72bb5804`
(== `origin/main`), green slot beams built `Jul 30 03:40 UTC`, OTP 27 /
Elixir 1.18.4, GNU tar 1.35, go1.24.2, Caddy v2.11.4.

## R0 — the running unit is `barkpark-slot@green`, NOT `barkpark.service`

    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 \
      'systemctl is-active barkpark.service; systemctl show barkpark-slot@green.service -p MainPID --value'

Expect: `inactive`, then a live PID. The assignment's
`systemctl show barkpark.service -p Environment` prints `Environment=` — an
EMPTY answer that is not the unit's environment, only the unit that is not
running. Read `/proc/<MainPID>/environ` instead.

## R1 — `file:native_name_encoding()` under the unit's OWN environment

    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'PID=$(systemctl show barkpark-slot@green.service -p MainPID --value)
    tr "\0" "\n" < /proc/$PID/environ > /tmp/slot.env
    ERL=/root/.asdf/installs/erlang/27.3.4/bin/erl
    env -i $(grep -E "^(LANG|LC_ALL|LC_CTYPE|HOME|PATH|ROOTDIR|BINDIR)=" /tmp/slot.env | tr "\n" " ") \
      $ERL -noshell -eval "io:format(\"~p~n\",[file:native_name_encoding()]),halt()."
    env -i HOME=/root PATH=/usr/bin:/bin $ERL -noshell -eval "io:format(\"~p~n\",[file:native_name_encoding()]),halt()."'

Expect: `utf8` for the unit env, `latin1` with no `LANG`. The `utf8` comes from
`LANG=en_US.UTF-8` inherited from systemd's manager environment
(`/etc/default/locale`) — the unit file sets NO `Environment=LANG`, and
`ELIXIR_ERL_OPTIONS=+fnu` appears nowhere in `deploy/**` or `api/start.sh`
(`cloud/Dockerfile:63` pins LANG for the control-plane container only).

## R2 — build the accented twins and read their typeflags from raw 512-blocks

    scp -i ~/.ssh/barkpark_indx <scratchpad>/mk_accent.py root@157.180.90.121:/tmp/
    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'python3 /tmp/mk_accent.py'

Expect `typeflags=0 5 0` for both (Python tarfile FORCED to USTAR — the one
producer/shape combination that survives all four name shapes) with name bytes
`63 61 66 c3 a9` (NFC) and `63 61 66 65 cc 81` (NFD).

## R3 — the real `stage/4`, without `mix` (the box's `deps/` is behind `mix.exs`)

`mix run` refuses: *"Unchecked dependencies for environment prod: decimal … got
2.3.0"*. Do NOT `mix deps.get` on the box. Drive the already-compiled slot beams:

    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'export PATH=/root/.asdf/shims:$PATH
    PA=$(for d in /opt/barkpark/api/_build_green/prod/lib/*/ebin; do printf -- "-pa %s " $d; done)
    env -u LC_ALL -u LC_CTYPE LANG=en_US.UTF-8 elixir --erl "$PA" /tmp/accent_stage2.exs'

Swap `LANG=en_US.UTF-8` for `-u LANG` to re-measure the latin1 mode. Both modes
return `{:ok, %{entries: 3}}` for BOTH twins.

## R4 — byte-exactness of the staged names (never `File.ls`, which decodes)

    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 \
      'for d in /tmp/accent-staged-nfc /tmp/accent-staged-nfd; do find "$d" | while IFS= read -r p; do
         printf "%s  %s\n" "$(printf "%s" "$p" | od -An -tx1 | tr -d " \n")" "$p"; done; done'

Expect `...636166c3a9` and `...636165cc81` — no normalisation either direction.
`:file.list_dir_all/1` from Elixir is a TRAP here: in `utf8` mode it returns
decoded CODEPOINT lists (`[99,97,102,233]`, and `769` for U+0301 which
`iolist_to_binary/1` then rejects), so an Elixir readback measures the decoder,
not the disk.

## R5 — oracle diff (two oracles, both agree)

    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'mkdir -p /tmp/o1 && python3 -c "import tarfile;tarfile.open(\"/tmp/ssw11/nfc.tar.gz\").extractall(\"/tmp/o1\")" && diff -r /tmp/o1 /tmp/accent-staged-nfc && echo SAME'

Same shape with `erl_tar:extract/2`. Both print `SAME`; staged modes are
`755 d` / `644 f`.

## R6 — the 24-cell producer x name-shape census, RUN against the real stage/4

    scp -i ~/.ssh/barkpark_indx <scratchpad>/ssw11-census-box.sh root@157.180.90.121:/tmp/
    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'bash /tmp/ssw11-census-box.sh'   # typeflags
    # then /tmp/census_stage.exs via the R3 invocation                                # accept/refuse

Producers: GNU tar 1.35 default, GNU tar `--format=ustar`, Python tarfile
DEFAULT (pax), Python tarfile USTAR, `:erl_tar` (OTP 27), and a verbatim replica
of `sites_tarball.go:335/341` (`tar.FileInfoHeader` + `hdr.Name =
filepath.ToSlash(rel)`, `hdr.Format` never assigned) built with the box's own
go1.24.2.

## R7 — the served hop: real Caddy over the staged accented tree

    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'cat > /tmp/cf <<EOF
    { admin off
      auto_https off }
    :8791 {
      handle_path /sites/accentnfc/* { root * /tmp/accent-staged-nfc
        file_server }
      handle_path /sites/accentnfd/* { root * /tmp/accent-staged-nfd
        file_server } }
    EOF
    caddy validate --adapter caddyfile --config /tmp/cf
    nohup caddy run --config /tmp/cf --adapter caddyfile >/tmp/cf.log 2>&1 & sleep 2
    for u in "accentnfc/caf%C3%A9" "accentnfc/cafe%CC%81" "accentnfd/cafe%CC%81" "accentnfd/caf%C3%A9"; do
      curl -s -o /dev/null -w "$u %{http_code}\n" "http://127.0.0.1:8791/sites/$u/index.html"; done
    pkill -f "caddy run --config /tmp/cf"'

The block replicates `deploy/site-deploy.sh:1866` (`root * $ROOT/current` +
`file_server`, inside `handle_path /sites/<slug>/*`) verbatim. Expect
`200 / 404 / 200 / 404` — the NFC↔NFD mismatch is a MEASURED 404 that no tar
fix reaches, and `HEALTH` cannot catch it because
`deploy/site-deploy.sh:291` probes exactly `http://127.0.0.1:$port/index.html`.
