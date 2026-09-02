defmodule Barkpark.Plugins.Grip.Rerun do
  @moduledoc """
  The `rerun` grammar, server-side: a fail-closed screen plus the authority
  ladder, over the ONE literal shell command that re-derives a `type:fact`.

  ## Why this exists at all, and what it is a copy OF

  Grip's grammar ships as Node — `tooling/grip/level.mjs` (the ladder) and
  `tooling/grip/screen.mjs` (the fail-closed screen). Neither can run on the
  write's stack: `before_publish` hooks fire SYNCHRONOUSLY inside
  `Barkpark.Content.Lifecycle.publish_document/5`, and shelling out to `node`
  from a lifecycle hook would put a process spawn (and a `node` binary the
  release does not ship) between an author and every publish. So the ladder is
  re-expressed here, in Elixir, as the gate the SERVER can actually run.

  That makes this module a deliberate second implementation of a rule that has
  a first one. Two things keep the fork honest:

    1. **The ladder is ported whole.** Quote masking, segment walking, the
       parseability floor, the mention-immunity rule, the `bp scaffy`
       carve-out, the generated-artifact list and `check_ceiling/2` are
       transcribed from `level.mjs`, not re-invented — including the
       comments that say WHY a rule is shaped the way it is, because those
       are the parts a re-invention gets wrong.
    2. **The screen is knowingly a SUBSET, and only in the strict
       direction.** `screen.mjs` is ~2900 lines of per-command, per-flag write
       analysis, because its caller RE-EXECUTES the command — each false-safe
       there is an execution. Nothing here ever executes anything: this screen
       is an ADMISSION test ("is this string a re-derivable command at all?"),
       not an execution guard. It therefore screens at the HEAD token, on an
       allowlist, and refuses what it cannot classify. A command the Node
       screen would refuse on a flag (`npm run build`, `go build -o x`) is
       admitted here on its head — see "The gap" below.

  ## The ladder (`/papers/survey-once-build-forever`, charter D1/D2)

      L1  running system     — ssh to a host, curl/wget to a non-loopback host
      L2  origin/main        — git show <remote-ref>:<path>, gh api, bp/gh
      L3  local checkout     — local read, scoped grep, local test, loopback curl
      L4  generated artifact — a read whose target is a known emitted path
      L5  charters / docs    — never derived here; the ladder keeps the slot
      L6  no command         — or a shape the grammar cannot classify

  The derived level is a **CEILING** (D2): a claim ABOVE it is a LEVEL-SKIP and
  is refused, naming both levels; equal or below is accepted, because an author
  may always honestly under-claim.

  `evidence` is **L6 by construction**: nothing in this module ever reads it.
  A prose-scanning extractor was built first in the Node layer and refuted at
  L1/L2 precision 0.67 over 60 hand-labelled real strings — it stamped L1 on a
  string that began "OPEN — requires a run against the deployed build". Markers
  fire on MENTION; this grammar levels only the INVOCATION.

  ## The two doors, and why they disagree about a missing command

  `derive_level/1` keeps grip's D3 exactly: an unclassifiable or absent command
  DEMOTES to L6, it never rejects — the honest path stays the cheap one.

  `screen/1` is the PUBLISH wall and refuses a blank `rerun` outright
  (`NO-RERUN`). That is not a contradiction of D3: D3 governs what a command
  DERIVES, and this governs what may be PUBLISHED. It is the same split the two
  shipped exemplars already make — `Barkpark.Plugins.Tasks.portable_brief_gate/1`
  lets a brief-less task SAVE and refuses to PUBLISH it, and
  `Barkpark.Plugins.Bulldocs.reject_hollow_paper_publish/1` does the same for a
  hollow paper. Draft authoring stays permissive; publication is the wall.

  ## The gap (report it, do not paper over it)

  Two divergences from the Node layer are known and deliberate:

    * The screen is head-level. It does not reproduce `screen.mjs`'s per-verb
      and per-flag write detection, so a write-shaped invocation of an
      admitted head is admitted here. It is caught in the Node layer before
      anything re-executes it, which is the layer where execution happens.
    * `L5` is never derived, exactly as in `level.mjs` — reading a doc locally
      is mechanically L3. A fact may still CLAIM L5; being below every derived
      rung except L6, such a claim can never be a level-skip.

  Pure: no process, no filesystem, no clock, no `Repo`.
  """

  # ─── the ladder ─────────────────────────────────────────────────────────

  @levels %{"L1" => 1, "L2" => 2, "L3" => 3, "L4" => 4, "L5" => 5, "L6" => 6}
  @ladder "L1 L2 L3 L4 L5 L6"

  # ─── head vocabularies (transcribed from level.mjs) ─────────────────────

  # Local readers / scoped search / local runs — the L3 family. `cd`, `for` and
  # `env` are deliberately ABSENT: a navigation or looping wrapper is not a
  # read, and filing one at L3 would make `cd /opt && curl https://prod/health`
  # derive the LOCAL CHECKOUT's authority for a command that provably reaches
  # production. Compounds are handled by walking the segments instead.
  @l3_heads ~w(
    cat head tail less more sed awk cut sort uniq
    wc ls stat file diff jq grep rg ag find
    node go mix npm pnpm yarn make elixir python
    python3 bash sh zsh git tree shasum md5 openssl
  )

  # Strip leading env assignments (`FOO=bar cmd`) and harmless prefix wrappers
  # so `timeout 10 grep …` still levels on `grep`.
  @prefix_wrappers ~w(timeout time env nice xargs sudo)

  # Shell keywords that can OPEN a segment once a compound is split on `;`.
  # They are NOT L3 heads — they classify nothing on their own.
  @segment_keywords ~w(do then else elif !)

  # Heads that MOVE but never READ. A segment headed by one of these
  # contributes NO level at all; the compound's authority comes from its
  # siblings.
  @navigation_heads ~w(cd pushd popd for while until if case done fi esac export set source .)

  # `bp` and `gh` are REMOTE-API clients, not local tools. Filing either at L3
  # "local checkout" would be a two-level SKIP that labels volatile remote
  # state as checkout-stable; filing them at L1 would be a promotion they have
  # not earned. They sit where `gh api` already sat: L2.
  @remote_api_heads ~w(bp gh)

  # Only reader-shaped heads can reach L4 — `node design/emit.mjs` REGENERATES
  # an artifact (a local run, L3), it does not read one.
  @reader_heads ~w(cat head tail less more jq grep rg sed awk wc diff)

  # Heads a real invocation may plausibly start with. Deliberately MODEST —
  # this is the allowlist that SUPPRESSES a prose demotion, so every entry is a
  # chance to miss prose.
  @known_heads @l3_heads ++
                 @prefix_wrappers ++
                 @navigation_heads ++
                 @remote_api_heads ++
                 ~w(
                   curl wget ssh scp rsync npx echo printf cp mv
                   rm ln mkdir touch chmod chown tar kill pgrep
                   pkill systemctl psql dig docker sleep date which
                   command type test true false tee tr base64 xxd
                   uptime df du ps claude defaults open diskutil pip
                   pip3 cargo gofmt prettier eslint tsc vitest jest
                 )

  # THE SCREEN'S ALLOWLIST. Fail-closed: a segment whose head is not here is
  # refused, never admitted-with-a-warning. Narrower than @known_heads on
  # purpose — @known_heads exists to suppress a PROSE demotion and therefore
  # names writers (`rm`, `mkdir`, `systemctl`) so that a real destructive
  # command is not mistaken for prose; those must not be admitted as the
  # re-derivation of a fact. `export`/`set`/`source`/`.` are likewise dropped:
  # `source x.sh` runs an arbitrary script under a navigation-shaped head.
  @admitted_heads @l3_heads ++
                    @remote_api_heads ++
                    @prefix_wrappers ++
                    ~w(curl wget ssh cd pushd popd for while until if case done fi esac)

  # ─── shapes ─────────────────────────────────────────────────────────────

  # ssh: ALLOW FLAGS between `ssh` and the `user@host` — an adjacency regex
  # false-demoted a genuine `ssh -o BatchMode=yes … root@…` read (charter D2).
  @ssh_read ~r/\bssh\b[^\n]*@/

  # `git show` against a REMOTE ref is an L2 read of what the remote holds.
  # `git show HEAD:…` or a local branch reads the local object store — L3.
  @git_show_remote ~r{\bgit\s+show\s+(?:['"]?)(?:refs/remotes/|origin/|upstream/)\S*:}
  @gh_api ~r/\bgh\s+api\b/

  # Loopback hosts a curl can hit without leaving the laptop. A loopback curl
  # reads the LOCAL running dev system — a property of the checkout, so L3.
  @loopback_host ~r/^(localhost|127(\.\d{1,3}){3}|0\.0\.0\.0|::1)$/i

  # scheme://host[:port]. The host alternation takes a BRACKETED IPv6 literal
  # FIRST: a naive `[^/\s:'"]+` stops at the first colon and captures a bare
  # `[` from `http://[::1]:4000`, which fails the loopback test and FALSELY
  # PROMOTES a local dev-server read to L1.
  @url_token ~r{\b[a-z][a-z0-9+.-]*://(\[[0-9A-Fa-f:.]+\]|[^/\s:'"]+)}i

  @segment_operator ~r/\|\||&&|;;|;|\||\n/

  # The value-taking `bp` global flags, mirrored from internal/cli/globals.go's
  # `valueFlags` map (the arity AUTHORITY). The subcommand anchor must skip the
  # VALUE each consumes, not just the flag.
  @scaffy_anchor_value_globals ~w(
    -s --server --token -w --workspace -p --project
    -d --dataset -o --output --limit --offset --manifest
  )
  @local_scaffy_verbs ~w(validate fmt run remove discover)

  # --- the parseability floor -------------------------------------------
  # A grammar that inspects a head token never asks whether the string PARSES,
  # so any prose containing a blessed token inherits that token's authority.
  # A recipe that cannot be re-run is not a recipe. BIASED TOWARD DEMOTING: a
  # false positive costs an L6 demotion (the safe error direction, D3); a false
  # negative promotes unrunnable prose, which is the failure this exists to stop.
  @placeholder_angle ~r/<[^<>()\s][^<>()\n]{0,78}[^<>()\s]>|<[^<>()\s]>/
  @placeholder_bracket ~r/\[--/
  @elision ~r/(^|\s)(\.\.\.|…)(\s|$)/u
  @slash_joined_head ~r{^[A-Za-z][A-Za-z-]*/[A-Za-z][A-Za-z-]*(/[A-Za-z][A-Za-z-]*)*$}
  @slash_joined_numbers ~r{(^|\s)\d+(/\d+)+(\s|$)}
  # A BACKSLASH-ESCAPED paren is not a group — `find . \( -name a -o -name b \)`
  # is a literal argument, and reading it as prose floored a good `find` L3→L6.
  @paren_group ~r/(^|[^$\w\\\\])\(([^()\n]{0,240})\)/

  # --- generated-artifact paths (L4) ------------------------------------
  # DERIVED FROM THE EMITTERS, NOT GUESSED (level.mjs's census of
  # design/emit.mjs's whole-file emits plus every writeFileSync under tooling/).
  # A MARKER-SPLICED file (root.html.heex, globals.css, …) is deliberately
  # ABSENT: it is mostly hand-authored, and levelling it L4 would DEFLATE an
  # honest source read — the mirror-image bug of the inflation this list stops.
  @generated_artifact_patterns [
    ~r{(^|/)docs/openapi\.json$},
    ~r{\.golden\.json$},
    ~r{(^|/)[^/\s]*_gen\.go$},
    ~r{(^|/)[^/\s]*_gen\.ex$},
    ~r{(^|/)[^/\s]*\.gen\.ts$},
    ~r{(^|/)tooling/[^/\s]+/[^/\s]+-report\.(?:json|html|csv)$},
    ~r{(^|/)tooling/blast-radius/(?:index|last-impact|verdict-cache)\.json$},
    ~r{(^|/)tooling/symbol-graph/symbols\.json$},
    ~r{(^|/)tooling/map/manifest\.json$},
    ~r{(^|/)tooling/file-importance/(?:file-signals|file-batches)\.json$},
    ~r{(^|/)tooling/file-importance/importance-chart\.(?:csv|html)$},
    ~r{(^|/)tooling/consistency/verdict-cache\.json$},
    ~r{(^|/)tooling/fit/scoring-config\.json$},
    ~r{(^|/)tooling/research-coverage/research-ledger\.json$},
    ~r{(^|/)tooling/barkpark-sync/(?:nodes\.json|codebase-graph\.html)$},
    ~r{(^|/)tooling/concept-map/boundary-baseline\.json$},
    ~r{(^|/)tooling/[^/\s]+/(?:batches|review-batches|results|dossiers)/[^/\s]+\.json$},
    ~r{(^|/)tooling/[^/\s]+/(?:batch-count|review-count|issues-stale|taxonomy-input)\.txt$}
  ]

  # --- write shapes the screen refuses ----------------------------------
  @fd_dup ~r/\d?>&\d/
  @discard_redirect ~r{>>?\s*/dev/(null|stderr|stdout)\b}

  # ─── public API ─────────────────────────────────────────────────────────

  @typedoc "A rung of the authority ladder."
  @type level :: String.t()

  @doc """
  The fail-closed publish screen over a `rerun` string.

  Returns `:ok`, or `{:error, message}` naming ONE of four refusal codes:

    * `NO-RERUN` — absent, non-string, or blank. A fact with no command is not
      re-derivable, and publishing it would put an unfalsifiable row in the
      ledger.
    * `NOT-A-COMMAND` — the parseability floor fired: the string carries a
      template slot (`<rev>`, `[--force]`), an elision (`…`), a slash-joined
      shorthand (`gh pr view 1/2/3`) or a prose segment.
    * `NOT-ALLOWLISTED` — a segment's head token is not on the read allowlist.
      Fail-closed: an unrecognised head is REFUSED, never admitted.
    * `WRITE-SHAPED` — an unquoted output redirection to something other than
      `/dev/null` (a file-descriptor dup like `2>&1` is not a write).
  """
  @spec screen(term()) :: :ok | {:error, String.t()}
  def screen(rerun) do
    command = if is_binary(rerun), do: String.trim(rerun), else: ""

    if command == "" do
      {:error,
       "NO-RERUN: a fact must carry ONE literal shell command in `rerun` that " <>
         "re-derives it — a fact with no command cannot be re-derived, and its " <>
         "level would be L6 by construction"}
    else
      screen_command(command, mask_quoted(command))
    end
  end

  @doc """
  Derive the authority level of a `rerun` command string.

  PURE over the command alone. It never receives — and must never be handed —
  the evidence prose, the claim, or any narrative field. Unknown shapes DEMOTE
  to `"L6"` (D3); nothing here raises on honest input.

  A COMPOUND IS WALKED, NOT SNIFFED AT THE HEAD. Every unquoted segment is
  levelled on its own and the STRONGEST wins, because the derived level is a
  CEILING on what the compound could have observed: `cd /opt && curl
  https://prod/health` reaches production, and `curl https://prod/x | jq .`
  must not be demoted to L3 by its pipe consumer. What keeps strongest-wins
  from becoming a promotion engine is the parseability floor, which runs first.
  """
  @spec derive_level(term()) :: level()
  def derive_level(rerun) when is_binary(rerun) do
    command = String.trim(rerun)

    cond do
      command == "" ->
        "L6"

      true ->
        mask = mask_quoted(command)

        if looks_like_prose?(command, mask) do
          "L6"
        else
          walk_levels(command, mask)
        end
    end
  end

  def derive_level(_), do: "L6"

  @doc """
  The derived level is a CEILING. A claim ABOVE it (numerically lower rank —
  higher authority) is a LEVEL-SKIP and is REJECTED, naming both levels. Equal
  or below is accepted: an author may honestly under-claim.
  """
  @spec check_ceiling(term(), term()) :: :ok | {:error, String.t()}
  def check_ceiling(claimed, derived) do
    claimed_rank = rank(claimed)
    derived_rank = rank(derived)

    cond do
      is_nil(claimed_rank) ->
        {:error,
         "UNKNOWN-LEVEL: claimed level #{inspect(claimed)} is not on the ladder #{@ladder}"}

      is_nil(derived_rank) ->
        {:error,
         "UNKNOWN-LEVEL: derived level #{inspect(derived)} is not on the ladder #{@ladder}"}

      claimed_rank < derived_rank ->
        {:error,
         "LEVEL-SKIP: claimed #{claimed} above derived #{derived} — the rerun " <>
           "command re-derives this fact at #{derived}; a #{claimed} claim needs " <>
           "a #{claimed}-shaped command"}

      true ->
        :ok
    end
  end

  @doc """
  `true` when the string is prose rather than a runnable command. Exported so a
  caller can EXPLAIN a demotion rather than merely apply it.
  """
  @spec looks_like_prose?(String.t(), String.t() | nil) :: boolean()
  def looks_like_prose?(command, mask \\ nil) do
    mask = mask || mask_quoted(command)

    cond do
      Regex.match?(@placeholder_angle, mask) -> true
      Regex.match?(@placeholder_bracket, mask) -> true
      Regex.match?(@elision, mask) -> true
      Regex.match?(@slash_joined_numbers, mask) -> true
      parenthetical_is_prose?(mask) -> true
      true -> Enum.any?(split_segments(command, mask), &segment_reads_as_prose?/1)
    end
  end

  @doc "The ladder, as a rung => rank map. Callers compare by rank, never by string arithmetic."
  @spec levels() :: %{String.t() => pos_integer()}
  def levels, do: @levels

  # ─── screen internals ───────────────────────────────────────────────────

  defp screen_command(command, mask) do
    if looks_like_prose?(command, mask) do
      {:error,
       "NOT-A-COMMAND: #{inspect(command)} does not parse as one runnable " <>
         "shell command (template slot, elision, or prose) — a recipe that " <>
         "cannot be re-run is not a recipe"}
    else
      screen_heads(command, mask)
    end
  end

  defp screen_heads(command, mask) do
    case command |> split_segments(mask) |> unadmitted_head() do
      nil ->
        if write_redirect?(mask) do
          {:error,
           "WRITE-SHAPED: #{inspect(command)} redirects output to a file — a " <>
             "rerun command re-derives a fact, it does not produce one"}
        else
          :ok
        end

      head ->
        {:error,
         "NOT-ALLOWLISTED: the segment headed by #{inspect(head)} is not on the " <>
           "read allowlist — the screen is fail-closed, so a head it cannot " <>
           "classify as a read is refused"}
    end
  end

  defp unadmitted_head(segments) do
    Enum.find_value(segments, fn {raw, _mask} ->
      {head, _raw_head, _rest} = head_token(trim_segment(raw))
      if head != "" and head not in @admitted_heads, do: head
    end)
  end

  defp write_redirect?(mask) do
    mask
    |> String.replace(@fd_dup, "")
    |> String.replace(@discard_redirect, "")
    |> String.contains?(">")
  end

  # ─── level internals ────────────────────────────────────────────────────

  defp walk_levels(command, mask) do
    {best, saw_artifact_read?} =
      command
      |> split_segments(mask)
      |> Enum.reduce({nil, false}, fn {raw, seg_mask}, {best, artifact?} ->
        case segment_level(raw, seg_mask) do
          nil -> {best, artifact?}
          "L4" -> {best, true}
          level -> {stronger(best, level), artifact?}
        end
      end)

    # L4 is a statement about the read's TARGET, not a rung competing with
    # L1-L3, and it sits BELOW L3 on the ladder. So a pipeline that reads an
    # artifact and hands it to a local consumer — `cat docs/openapi.json | jq .`
    # — is an artifact read, not a source read; but an artifact read beside a
    # remote one never caps that remote read.
    cond do
      saw_artifact_read? and best in [nil, "L3"] -> "L4"
      is_nil(best) -> "L6"
      true -> best
    end
  end

  defp stronger(nil, level), do: level
  defp stronger(best, level), do: if(rank(level) < rank(best), do: level, else: best)

  # The level of ONE segment, or nil when the segment classifies nothing (a
  # `cd`, a loop keyword, an unknown head).
  defp segment_level(raw, mask_text) do
    command = trim_segment(raw)

    if command == "" do
      nil
    else
      masked = trim_segment(mask_text)
      {head, raw_head, rest} = head_token(command)

      # Mention-immunity: a READER head can never itself BE an ssh/gh/git-show
      # invocation, so a blessed token under one is always a MENTION —
      # including the unquoted `grep -rn ssh root@host docs/`, which quote
      # masking alone cannot see. But a process/command substitution under a
      # reader head is a REAL invocation: `diff <(git show origin/main:x) x`
      # genuinely reads origin, and demoting it would break the standing
      # zero-false-demotion bar.
      mention_only? = head in @reader_heads and not Regex.match?(~r/[<>$]\(/, masked)

      # A segment HEADED BY the command itself is never a mention of it: its
      # own quoted arguments belong to it. `ssh "root@host" uptime` read
      # through the mask demoted a live production read L1→L6.
      probe = fn name -> if head == name, do: command, else: masked end

      classify(head, raw_head, rest, command, mention_only?, probe)
    end
  end

  defp classify(head, raw_head, rest, command, mention_only?, probe) do
    cond do
      # L1 — a running system was touched.
      not mention_only? and Regex.match?(@ssh_read, probe.("ssh")) ->
        "L1"

      head in ["curl", "wget"] ->
        # The URL is read from the ORIGINAL segment, quotes and all. The head
        # gate is what keeps a MENTIONED url — `grep -n 'https://…' src.ts` —
        # from ever reaching this branch.
        if first_remote_url_host(command), do: "L1", else: "L3"

      head == "" ->
        nil

      # L2 — origin/main, or another remote read through a remote-API client.
      not mention_only? and
          (Regex.match?(@git_show_remote, probe.("git")) or
             Regex.match?(@gh_api, probe.("gh"))) ->
        "L2"

      head in @remote_api_heads ->
        cond do
          loopback_only?(command) -> "L3"
          head == "bp" and local_scaffy_invocation?(command) -> "L3"
          true -> "L2"
        end

      # L4 — the read's TARGET is a known generated artifact. Checked BEFORE
      # the generic L3 family: `cat docs/openapi.json` is an artifact read,
      # not a source read.
      head in @reader_heads and Enum.any?(rest, &generated_artifact_path?(unquote_token(&1))) ->
        "L4"

      # L3 — local checkout: reads, scoped grep, local tests, node <script>.
      head in @l3_heads ->
        "L3"

      Regex.match?(~r/^\.{0,2}\//, raw_head) ->
        "L3"

      # A wrapper reads nothing.
      true ->
        nil
    end
  end

  defp generated_artifact_path?(token) do
    Enum.any?(@generated_artifact_patterns, &Regex.match?(&1, token))
  end

  defp unquote_token(token), do: String.replace(token, ~r/^['"]|['"]$/, "")

  # ─── the `bp scaffy` carve-out ──────────────────────────────────────────

  # Five `bp scaffy` verbs are PURE LOCAL and touch no server — scaffy_cmd.go's
  # own header states it. So a URL-free `bp scaffy validate|fmt|run|remove|
  # discover …` re-derives its fact from the LOCAL CHECKOUT (L3), and filing it
  # at the remote-API L2 is a one-level authority INFLATION.
  #
  # THE ANCHOR (why not a bare "is `scaffy` in the tokens"): a bare membership
  # test matches the word ANYWHERE, so a genuine REMOTE read that merely
  # carries it as an ARGUMENT — `bp task get scaffy validate x.scaffy` — was
  # mis-read as a local verb and OVER-DEMOTED L2→L3, making the ceiling refuse
  # an honest L2 claim. The verb counts only when `scaffy` sits at the
  # SUBCOMMAND position.
  defp local_scaffy_invocation?(command) do
    if url_hosts(command) != [] do
      false
    else
      case head_token(command) do
        {"bp", _raw, rest} -> scaffy_verb_is_local?(skip_bp_globals(rest))
        _ -> false
      end
    end
  end

  defp scaffy_verb_is_local?(["scaffy" | tail]) do
    tail
    |> Enum.reject(&String.starts_with?(&1, "-"))
    |> case do
      [verb | _] -> verb in @local_scaffy_verbs
      [] -> false
    end
  end

  defp scaffy_verb_is_local?(_), do: false

  # Walk to the subcommand: skip leading global flags, consuming the value each
  # value-taking global takes vs a boolean/unknown flag. A long `--flag=value`
  # is self-contained; a short `-o=json` is not the globals.go inline form but
  # its value is attached either way, so it lands correctly.
  defp skip_bp_globals([tok | tail] = tokens) do
    if String.starts_with?(tok, "-") do
      inline_long? = String.starts_with?(tok, "--") and String.contains?(tok, "=")

      cond do
        inline_long? -> skip_bp_globals(tail)
        tok in @scaffy_anchor_value_globals -> skip_bp_globals(Enum.drop(tail, 1))
        true -> skip_bp_globals(tail)
      end
    else
      tokens
    end
  end

  defp skip_bp_globals([]), do: []

  # ─── URLs ───────────────────────────────────────────────────────────────

  defp url_hosts(command) do
    @url_token
    |> Regex.scan(command)
    |> Enum.map(fn [_full, host] -> normalize_host(host) end)
  end

  defp normalize_host(host) do
    if String.starts_with?(host, "[") and String.ends_with?(host, "]") and byte_size(host) >= 2 do
      binary_part(host, 1, byte_size(host) - 2)
    else
      host
    end
  end

  defp first_remote_url_host(command) do
    Enum.find(url_hosts(command), &(not Regex.match?(@loopback_host, &1)))
  end

  defp loopback_only?(command) do
    case url_hosts(command) do
      [] -> false
      hosts -> Enum.all?(hosts, &Regex.match?(@loopback_host, &1))
    end
  end

  # ─── the parseability floor ─────────────────────────────────────────────

  # An unquoted parenthetical whose first word is not a plausible command head
  # is an aside: `(count)`, `(restore honest footer)`. A real subshell —
  # `(cd __preview__ && node smoke.mjs)` — opens on a known head and is left
  # alone. A function-call paren (`count(…)`) is attached to a word character
  # and never examined.
  defp parenthetical_is_prose?(mask) do
    @paren_group
    |> Regex.scan(mask)
    |> Enum.any?(fn [_full, _lead, inner] ->
      case String.trim(inner) do
        "" ->
          false

        text ->
          {head, _raw, _rest} = head_token(text)
          head not in @known_heads
      end
    end)
  end

  defp segment_reads_as_prose?({_raw, seg_mask}) do
    {_head, raw_head, _rest} = head_token(trim_segment(seg_mask))

    (raw_head != "" and Regex.match?(@slash_joined_head, raw_head)) or
      segment_is_prose?(seg_mask)
  end

  # A SEGMENT is prose when it has several words, an unrecognisable head that
  # is not path-shaped, and none of the marks an invocation leaves behind — a
  # flag, a path argument, an assignment, a redirection.
  defp segment_is_prose?(seg_mask) do
    trimmed = trim_segment(seg_mask)
    tokens = String.split(trimmed, ~r/\s+/, trim: true)

    if length(tokens) < 3 do
      false
    else
      {head, raw_head, _rest} = head_token(trimmed)

      cond do
        head == "" -> false
        # `probe: add migration_lock: false to …` — a head ending in a colon is
        # a NOTE LABEL. No program is invoked by that name, and the suppressors
        # below (it carries a slash!) would otherwise wave it through.
        String.ends_with?(head, ":") -> true
        head in @known_heads -> false
        Regex.match?(~r{[./]}, raw_head) -> false
        Enum.any?(tokens, &Regex.match?(~r/^-{1,2}[A-Za-z]/, &1)) -> false
        Enum.any?(tokens, &String.contains?(&1, "/")) -> false
        Enum.any?(tokens, &prose_disqualifying_char?/1) -> false
        true -> true
      end
    end
  end

  defp prose_disqualifying_char?(token) do
    String.contains?(token, "=") or String.contains?(token, ">") or String.contains?(token, "<")
  end

  # ─── tokenising ─────────────────────────────────────────────────────────

  # A SAME-LENGTH mask in which the CONTENT of every quoted span becomes `x`.
  # BYTE offsets are preserved so a caller can slice the ORIGINAL string by
  # positions found in the mask. Everything structural — segment splitting, the
  # prose floor — reads the mask, so `grep -n 'a && b' file` is one segment and
  # the `https://…` literal inside `grep -n 'https://…' src.ts` is inert. That
  # literal is the exact string on which the refuted prose scanner stamped L1.
  #
  # Byte-level (not grapheme-level) on purpose: a multi-byte grapheme replaced
  # by a one-byte `x` would shift every later offset and make `binary_part/3`
  # slice the original at the wrong place. Quote characters are ASCII, and a
  # UTF-8 continuation byte can never collide with one.
  defp mask_quoted(command) do
    command
    |> :binary.bin_to_list()
    |> mask_bytes(nil, [])
    |> :erlang.list_to_binary()
  end

  defp mask_bytes([], _quote, acc), do: Enum.reverse(acc)

  defp mask_bytes([byte | rest], nil, acc) when byte in [?', ?"],
    do: mask_bytes(rest, byte, [byte | acc])

  defp mask_bytes([byte | rest], nil, acc), do: mask_bytes(rest, nil, [byte | acc])

  defp mask_bytes([byte | rest], quote, acc) when byte == quote,
    do: mask_bytes(rest, nil, [byte | acc])

  defp mask_bytes([?\n | rest], quote, acc), do: mask_bytes(rest, quote, [?\n | acc])
  defp mask_bytes([_byte | rest], quote, acc), do: mask_bytes(rest, quote, [?x | acc])

  # Split a compound on its UNQUOTED control operators. Positions come from the
  # mask; the slices come from the original, so a segment keeps its real bytes.
  defp split_segments(command, mask) do
    cuts =
      @segment_operator
      |> Regex.scan(mask, return: :index)
      |> Enum.map(fn [{start, len} | _] -> {start, start + len} end)

    {spans, from} =
      Enum.reduce(cuts, {[], 0}, fn {start, stop}, {acc, from} ->
        {[{from, max(start - from, 0)} | acc], stop}
      end)

    [{from, byte_size(command) - from} | spans]
    |> Enum.reverse()
    |> Enum.map(fn {offset, len} ->
      {binary_part(command, offset, len), binary_part(mask, offset, len)}
    end)
    |> Enum.reject(fn {raw, _mask} -> String.trim(raw) == "" end)
  end

  # Trim subshell/group punctuation and redirections that survive the split, so
  # `(cd x` and `tail -1)` still find their head.
  defp trim_segment(text) do
    text
    |> String.replace(~r/^[\s(){}]+/, "")
    |> String.replace(~r/[\s(){}]+$/, "")
    |> String.trim()
  end

  # {head, raw_head, rest} — the first command word past env assignments,
  # segment keywords and harmless prefix wrappers. `head` is the basename (so
  # `/usr/bin/grep` heads as `grep`); `raw_head` keeps the written form,
  # because `./run.sh` levels on its shape, not its name.
  defp head_token(command) do
    command
    |> String.trim()
    |> String.split(~r/\s+/, trim: true)
    |> walk_head()
  end

  defp walk_head([]), do: {"", "", []}

  defp walk_head([token | rest]) do
    if Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*=/, token) do
      walk_head(rest)
    else
      bare = Regex.replace(~r{^.*/}, token, "")

      cond do
        bare in @segment_keywords ->
          walk_head(rest)

        bare in @prefix_wrappers ->
          # `timeout 10 cmd` — skip a numeric duration argument.
          walk_head(drop_duration(rest))

        true ->
          {bare, token, rest}
      end
    end
  end

  defp drop_duration([token | rest]) do
    if Regex.match?(~r/^\d+[smh]?$/, token), do: rest, else: [token | rest]
  end

  defp drop_duration([]), do: []

  defp rank(level) when is_binary(level), do: Map.get(@levels, level)
  defp rank(_), do: nil
end
