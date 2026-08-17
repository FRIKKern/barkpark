defmodule BarkparkCloud.RegistryClaimHostTwins.Extract do
  @moduledoc """
  Reads BOTH claim-host normalisers out of `registry.ex`'s source — the Elixir
  twin `normalize_claim_host/1` and the SQL fragment inside
  `provisioning_fqdn_claim/2` — so one corpus can be driven through the two of
  them and their outputs compared.

  Why the AST and not an import. `normalize_claim_host/1` is `defp`, and it must
  STAY `defp`: promoting a private function so a test can reach it changes the
  shipped module's public surface to serve the test. So the function's BODY is
  read off the AST (`Code.string_to_quoted!/1`, the `fun_ast/3` pattern this
  suite already uses in `registry_name_claim_census_test.exs`) and evaluated as
  an anonymous function. `registry.ex`'s function heads are untouched.

  Why the source and not a hand-copied SQL literal. The fragment is the thing
  under test; a copy in the test file would be a THIRD implementation, free to
  agree with a stale idea of the shipped one. `sql_normalise_expr/1` lifts the
  literal out of `provisioning_fqdn_claim/2`, keeps the left-hand side of the
  `= ?` comparison, and rebinds the one remaining placeholder to `$1` so
  `Repo.query/2` can run exactly the expression the WHERE clause runs.

  Both mutation helpers rewrite the SOURCE, which is what makes this file
  self-proving: `without_elixir_trim/1` and `without_sql_btrim/1` reconstruct
  the pre-fix twins, so the test can demonstrate the divergence it guards
  against instead of asserting that someone once saw it.
  """

  @doc "The Elixir twin `normalize_claim_host/1`, as a 1-arity function."
  @spec elixir_twin(binary) :: (binary -> binary)
  def elixir_twin(source) when is_binary(source) do
    body =
      source
      |> fun_ast(:normalize_claim_host, 1)
      |> Keyword.fetch!(:do)

    {fun, _} = Code.eval_quoted({:fn, [], [{:->, [], [[{:host, [], nil}], body]}]})
    fun
  end

  @doc """
  The SQL normalisation expression from `provisioning_fqdn_claim/2`'s fragment,
  with the stored-url placeholder rebound to `$1` and the `= ?` comparison
  dropped — i.e. the expression that produces the url side of the match.
  """
  @spec sql_normalise_expr(binary) :: binary
  def sql_normalise_expr(source) when is_binary(source) do
    fragment =
      source
      |> fun_ast(:provisioning_fqdn_claim, 2)
      |> binaries()
      |> Enum.find(&(&1 =~ "regexp_replace"))

    fragment ||
      raise "no regexp_replace fragment inside provisioning_fqdn_claim/2 — was the " <>
              "url normalisation moved? This census then reads NOTHING and is vacuous."

    [expr | _] = String.split(fragment, " = ?")

    String.replace(expr, "?", "$1")
  end

  @doc """
  Just the `characters` argument of the fragment's `btrim(lower(?), …)` — the
  SQL literal naming the whitespace alphabet, as Postgres receives it.

  Lifted rather than retyped because the defect this suite exists to catch lives
  INSIDE this literal: `E'\\v'` is U+000B on PostgreSQL 16+ and the LETTER v on
  15, and a hand-copied set in the test would be read by the same lexer with the
  same blind spot, agreeing with the shipped bug.
  """
  @spec sql_btrim_set(binary) :: binary
  def sql_btrim_set(source) when is_binary(source) do
    expr = sql_normalise_expr(source)

    case Regex.run(~r/btrim\(lower\(\$1\), (E'[^']*')\)/, expr) do
      [_, set] ->
        set

      _ ->
        raise "no btrim(lower($1), E'…') in the fragment — the whitespace alphabet " <>
                "moved or was deleted, and every membership census below is vacuous."
    end
  end

  @doc "MUTATION: the Elixir twin with its `String.trim/1` step deleted."
  @spec without_elixir_trim(binary) :: binary
  def without_elixir_trim(source) when is_binary(source) do
    replace_exactly_once(source, "|> String.trim()\n", "")
  end

  @doc "MUTATION: the SQL fragment with its `btrim(...)` step deleted (the pre-fix shape)."
  @spec without_sql_btrim(binary) :: binary
  def without_sql_btrim(source) when is_binary(source) do
    case Regex.scan(~r/btrim\(lower\(\?\), E'[^']*'\)/, source) do
      [[match]] ->
        String.replace(source, match, "lower(?)")

      other ->
        raise "expected exactly one btrim(lower(?), …) in the source, found #{length(other)}"
    end
  end

  defp replace_exactly_once(source, pattern, replacement) do
    case String.split(source, pattern) do
      [before, rest] ->
        before <> replacement <> rest

      parts ->
        raise "expected exactly one #{inspect(pattern)} in the source, found #{length(parts) - 1}"
    end
  end

  ## AST plumbing (the registry_name_claim_census_test.exs pattern)

  # The def/defp body for name/arity. `:when`-guarded heads are unwrapped: an
  # AST match that forgets to is silently blind to every guarded clause.
  defp fun_ast(source, name, arity) do
    {_, found} =
      source
      |> Code.string_to_quoted!(emit_warnings: false)
      |> Macro.prewalk(nil, fn
        {kind, _, [head, body]} = node, acc when kind in [:def, :defp] ->
          case head_sig(head) do
            {^name, ^arity} -> {node, body}
            _ -> {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    found || raise "#{name}/#{arity} not found — did it get renamed or deleted?"
  end

  defp head_sig({:when, _, [head | _]}), do: head_sig(head)
  defp head_sig({name, _, args}) when is_atom(name) and is_list(args), do: {name, length(args)}
  defp head_sig(_), do: nil

  defp binaries(ast) do
    {_, bins} =
      Macro.prewalk(ast, [], fn
        b, acc when is_binary(b) -> {b, [b | acc]}
        node, acc -> {node, acc}
      end)

    Enum.reverse(bins)
  end
end

defmodule BarkparkCloud.RegistryClaimHostNormaliserTest do
  @moduledoc """
  The two claim-host normalisers agree on a hostile corpus — and the leading
  whitespace class, on which they DID NOT agree, is fixed in the fragment.

  ## The divergence this file was cut for (measured 2026-08-17, pre-fix)

  `Registry.provisioning_fqdn_claim/2` compares two normalisations of one
  hostname: the candidate through the Elixir `normalize_claim_host/1`, the
  stored `url` column through a SQL `regexp_replace` chain. The Elixir twin
  trimmed; the SQL twin did not. Its scheme-stripping regex is ANCHORED
  (`'^[a-z][a-z0-9+.-]*://'`), so for a stored url spelled `" https://host"` the
  scheme survived, and the next step (`'[^a-z0-9.-].*$'`) then ate the string
  from its very first character — the whole url normalised to `""`. The row was
  invisible to the walk and the claim answered `:free` for a hostname a LIVE box
  serves, which is exactly the hole cch-w68-s3 (#11708) closed for six other
  spellings. Reproduced pre-fix for space, tab, CR/LF, NBSP, VT, FF and the
  ideographic space; all now agree (`describe "the twins agree"`).

  ## The SECOND divergence, and why this file grew (measured 2026-08-17, in CI)

  The `btrim` that closed the above was spelled `E'\\t\\n\\v\\f\\r …'`, and that
  passed locally on PostgreSQL 17 while failing in CI on PostgreSQL 15. PG15's
  escape-string lexer has no `\\v` case, so there `E'\\v'` is the LETTER v ("any
  other character following a backslash is taken literally"); 16+ reads U+000B.
  The set was 25 characters long on both, so nothing that counted could see it.
  It broke the twins in BOTH directions on 15:

    * U+000B was not in the set, so a VT-led url normalised to `""` again — the
      original hole, reopened for one spelling.
    * the letter `v` WAS in the set, so `https://gyldendal.tv` normalised to
      `gyldendal.t` on the SQL side against `gyldendal.tv` on the Elixir side.
      An ORDINARY hostname, no hostile spelling, reading `:free` while a live box
      serves it.

  Every C0 control in the fragment's set is now spelled `\\uXXXX`, which is
  documented and reads identically on every supported server.

  And the reason a six-spelling corpus could not see any of this: 19 of the 25
  codepoints were never driven. The whitespace corpus is now GENERATED from the
  codepoint list, and `"the corpus drives EVERY codepoint String.trim/1 strips"`
  derives Elixir's real trim alphabet by scanning the whole Unicode range and
  compares — so the completeness claim is enforced rather than asserted in prose.
  Two membership arms bracket the fragment's set from both sides: it must strip
  every whitespace codepoint, and it must not touch the hostname alphabet.

  ## Reachability, framed exactly

  LIVE divergence, PLATFORM-CREDENTIAL-reachable, NOT customer-reachable. The
  door is the worker route `POST /v1/internal/barkparks` (`web/router.ex`,
  `Auth.require_worker`): it passes the body's `url` VERBATIM into the
  changeset, `:url` is cast with NO `validate_format`, and
  `barkparks_url_unique_idx` is on the RAW column, so a whitespace-led url both
  stores and evades the uniqueness index. The customer-facing CLI adopt path
  self-defeats — its slug is derived from the same fqdn and reds on
  `@slug_format` — so no customer token reaches this. It needs the worker token.

  ## What this file proves, in three arms

    * TWIN EQUALITY (rung 1) — a 43-class corpus through both normalisers (42
      compared for byte equality, 1 pinned as a measured divergence), compared
      output-for-output. Byte equality, not "both non-empty". 25 of the classes
      are generated, one per Unicode `White_Space` codepoint, and the generator's
      codepoint list is itself checked against `String.trim/1`'s real behaviour.
    * BEHAVIOUR (rung 2) — a row stored with a whitespace-led url, inserted
      through the same `Ecto.Changeset.change/2` fixture the custom-host suite
      uses, and the PUBLIC `provisioning_fqdn_claim/2` asked for the clean
      spelling. `{:held, …}`. RED before the fragment fix, with `:free`.
    * MUTATION (rung 3) — the guard is proved able to LOSE, from both sides:
      delete `String.trim/1` from the Elixir twin and the whitespace classes
      diverge; delete `btrim(…)` from the fragment and they diverge again. Both
      mutations are performed on the source INSIDE this file, so the proof is
      re-run by CI rather than remembered from a transcript.

  ## The honest limits

  ONE corpus class is pinned as DIVERGENT rather than equal, and deliberately:
  Unicode case folding. `lower('İ')` in Postgres yields `i` (one codepoint),
  while `String.downcase/1` yields `i` + U+0307 COMBINING DOT ABOVE, which the
  hostname-alphabet cut then truncates at. That is collation-dependent — it can
  differ per database — so it is asserted as "the twins differ HERE, measured",
  never as a hardcoded string. It is also not a hole in the direction that
  matters: the divergence makes the SQL side normalise to MORE of the hostname,
  so the stored row still matches the ASCII candidate a thief can actually ask
  for (`@slug_format` admits no `İ`). Widening this would mean ICU-equal case
  folding on both sides, which is not this slice.

  TWO further copies of "hostname out of a stored url" exist and are documented
  here, NOT absorbed (see `describe "the third and fourth copies"`):

      copy                                | trims? | folds case? | strips port/path? | trailing dot?
      ------------------------------------|--------|-------------|-------------------|--------------
      normalize_claim_host/1 (twin)       | yes    | yes         | yes               | stripped
      the SQL fragment (twin)             | yes    | yes         | yes               | stripped
      Barkpark.subdomain_from_url/1       | NO     | NO          | NO                | kept
      DomainStatus.platform_host/1        | yes    | NO          | yes               | kept

  `subdomain_from_url/1` mints the DNS label AND the Hetzner box name from the
  raw url, so its divergence is a provisioning-side seam, not a claim-side one —
  owned by the backlog row `cch-w69-bl-dns-label-minted-from-raw-url`.
  `platform_host/1` only decides which hostname a status panel checks. Neither
  is unified here: this slice's contract is that the two normalisers the CLAIM
  compares agree, and quietly rewriting a DNS-label derivation under that
  heading would ship a provisioning change inside a tenancy fix.
  """
  use BarkparkCloud.DataCase, async: true

  alias BarkparkCloud.{Accounts, Registry, Repo}
  alias BarkparkCloud.Registry.Barkpark
  alias BarkparkCloud.RegistryClaimHostTwins.Extract

  @source_path Path.expand("../../lib/barkpark_cloud/registry.ex", __DIR__)

  # The corpus. Every class is a spelling the `url` column can actually hold —
  # the worker route casts it verbatim. `:equal` classes MUST normalise the same
  # on both sides; `:divergent` classes are the measured, documented exception
  # (see the moduledoc's honest limits).
  #
  # No expected STRINGS here on purpose: this censuses that the twins agree with
  # EACH OTHER. A hardcoded table would pass with both twins broken identically,
  # and for the case-folding rows it would pin a collation this test does not own.
  @host "a.barkpark.cloud"

  # Unicode `White_Space` — the alphabet `String.trim/1` strips, and the set the
  # fragment's `btrim` must mirror. Named per codepoint so a failure says WHICH
  # one broke. The list cannot quietly fall behind Elixir's Unicode tables or
  # quietly shrink: "the corpus drives every codepoint String.trim/1 strips"
  # derives the real alphabet by scanning the whole Unicode range and compares.
  @white_space [
    {0x0009, "CHARACTER TABULATION"},
    {0x000A, "LINE FEED"},
    {0x000B, "LINE TABULATION"},
    {0x000C, "FORM FEED"},
    {0x000D, "CARRIAGE RETURN"},
    {0x0020, "SPACE"},
    {0x0085, "NEXT LINE"},
    {0x00A0, "NO-BREAK SPACE"},
    {0x1680, "OGHAM SPACE MARK"},
    {0x2000, "EN QUAD"},
    {0x2001, "EM QUAD"},
    {0x2002, "EN SPACE"},
    {0x2003, "EM SPACE"},
    {0x2004, "THREE-PER-EM SPACE"},
    {0x2005, "FOUR-PER-EM SPACE"},
    {0x2006, "SIX-PER-EM SPACE"},
    {0x2007, "FIGURE SPACE"},
    {0x2008, "PUNCTUATION SPACE"},
    {0x2009, "THIN SPACE"},
    {0x200A, "HAIR SPACE"},
    {0x2028, "LINE SEPARATOR"},
    {0x2029, "PARAGRAPH SEPARATOR"},
    {0x202F, "NARROW NO-BREAK SPACE"},
    {0x205F, "MEDIUM MATHEMATICAL SPACE"},
    {0x3000, "IDEOGRAPHIC SPACE"}
  ]

  # One class per whitespace codepoint, in the LEADING position — the position
  # the anchored scheme regex makes discriminating. A TRAILING run is eaten by
  # the hostname-alphabet cut whether or not anyone trimmed, so it cannot tell a
  # trimming fragment from a non-trimming one and would dilute the mutation arms.
  #
  # Generated, not hand-listed, because hand-listing is exactly how the first
  # version of this guard shipped green while broken: it drove SIX spellings and
  # never asked about the other 19 codepoints. `\v` sat in the fragment's set as
  # the LETTER v on PostgreSQL 15 and nothing noticed.
  @ws_classes (for {cp, name} <- @white_space do
                 hex = cp |> Integer.to_string(16) |> String.pad_leading(4, "0")
                 {:equal, "leading U+#{hex} #{name}", <<cp::utf8>> <> "https://" <> @host}
               end)

  @structural_classes [
    {:equal, "plain https origin", "https://a.barkpark.cloud"},
    # Two codepoints, and the ONE class that stays split when neither side
    # trims — load-bearing for the both-deleted mutation arm.
    {:equal, "leading CRLF", "\r\nhttps://a.barkpark.cloud"},
    {:equal, "trailing whitespace", "https://a.barkpark.cloud \t\n"},
    {:equal, "whitespace on both ends", " https://a.barkpark.cloud "},
    {:equal, "uppercase scheme and host", "HTTPS://A.BARKPARK.CLOUD"},
    {:equal, "http scheme", "http://a.barkpark.cloud"},
    {:equal, "no scheme at all", "a.barkpark.cloud"},
    {:equal, "multiple trailing dots", "https://a.barkpark.cloud..."},
    {:equal, "explicit port, path, query and fragment",
     "https://a.barkpark.cloud:4000/studio?x=1#frag"},
    {:equal, "userinfo in the authority", "https://u:p@a.barkpark.cloud"},
    {:equal, "bracketed IPv6 authority", "https://[::1]:4000/"},
    {:equal, "bare IPv4", "10.0.0.1"},
    {:equal, "embedded newline mid-host", "https://a.barkpark\n.cloud"},
    # Ordinary hostnames that begin and end with the LETTER v — the second half
    # of the PG15 `E'\v'` defect. With `v` in the trim set the fragment answered
    # `gyldendal.t` where the Elixir twin answered `gyldendal.tv`, so a live
    # `.tv` box read `:free`. No hostile spelling required, which is why these
    # sit in the plain corpus rather than the whitespace family.
    {:equal, "hostname ending in v (.tv)", "https://gyldendal.tv"},
    {:equal, "hostname starting with v", "https://vpn.barkpark.cloud"},
    {:equal, "empty string", ""},
    {:equal, "whitespace only", " \t "},
    {:divergent, "Unicode dotted capital I (collation-dependent case folding)",
     "https://İxample.barkpark.cloud"}
  ]

  @corpus @ws_classes ++ @structural_classes

  # The classes a trim is REQUIRED for: every single whitespace codepoint, plus
  # the CRLF pair.
  @whitespace_classes Enum.map(@ws_classes, fn {_, label, _} -> label end) ++ ["leading CRLF"]

  # The alphabet the chain must never erode. `btrim` takes a SET of characters,
  # so one stray letter in it silently truncates every hostname that begins or
  # ends with that letter — invisible to any length check on the set.
  @hostname_alphabet String.graphemes("abcdefghijklmnopqrstuvwxyz0123456789.-")

  defp source, do: File.read!(@source_path)

  defp sql_normalise(expr, input) do
    %Postgrex.Result{rows: [[out]]} = Repo.query!("SELECT " <> expr, [input])
    out
  end

  # `btrim($1, <set>)` with the set inlined as the SQL literal the fragment
  # carries — so the SERVER's reading of its escapes is what gets measured, which
  # is the whole point: `E'\v'` differs between PostgreSQL 15 and 16+.
  defp sql_btrim(set, input) do
    %Postgrex.Result{rows: [[out]]} = Repo.query!("SELECT btrim($1, #{set})", [input])
    out
  end

  defp server_version do
    %Postgrex.Result{rows: [[v]]} = Repo.query!("SELECT current_setting('server_version')", [])
    v
  end

  defp hex(cp), do: cp |> Integer.to_string(16) |> String.pad_leading(4, "0")

  # Both twins over the whole corpus: %{label => {elixir_out, sql_out}}.
  defp twin_outputs(src) do
    elixir_twin = Extract.elixir_twin(src)
    expr = Extract.sql_normalise_expr(src)

    Map.new(@corpus, fn {_kind, label, input} ->
      {label, {elixir_twin.(input), sql_normalise(expr, input)}}
    end)
  end

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  # The custom-host suite's fixture shape: a row that HAS phoned home, so the
  # abandoned-ghost carve-out cannot release its name, holding `url` verbatim.
  defp live_row_holding_url(url) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team_fixture(), %{name: "BP #{n}", slug: "bp-#{n}"})

    {:ok, bp} =
      bp
      |> Ecto.Changeset.change(url: url, last_seen_at: DateTime.utc_now())
      |> Repo.update()

    bp
  end

  ## ─────────────────────────────────────────────────────────────────────────
  ## RUNG 1 — twin equality over the corpus
  ## ─────────────────────────────────────────────────────────────────────────

  describe "the twins agree" do
    test "the corpus drives EVERY codepoint String.trim/1 strips" do
      # The completeness claim, made enforceable. The first version of this guard
      # asserted "the fragment's set is exactly the 25 codepoints String.trim/1
      # strips" in a COMMENT while driving six spellings, so five of them could
      # be — and one was — broken in silence. Elixir's real trim alphabet is
      # derived here by scanning the whole Unicode range, not restated, so this
      # also reds if a future Elixir adds a White_Space codepoint.
      trimmed_by_elixir =
        for cp <- 0..0x10FFFF,
            cp not in 0xD800..0xDFFF,
            String.trim(<<cp::utf8>>) == "",
            do: cp

      driven = for {cp, _name} <- @white_space, do: cp

      assert MapSet.new(driven) == MapSet.new(trimmed_by_elixir),
             """
             The corpus no longer drives exactly the codepoints String.trim/1 strips.

               undriven (Elixir trims, corpus is silent): #{inspect(Enum.sort(trimmed_by_elixir -- driven), base: :hex)}
               overdriven (corpus claims, Elixir keeps):  #{inspect(Enum.sort(driven -- trimmed_by_elixir), base: :hex)}

             Every undriven codepoint is a spelling the fragment can normalise
             differently from its twin with this suite still green — which is the
             hole that let `E'\\v'` ship as the letter v on PostgreSQL 15.
             """

      # And each driven codepoint really is a corpus class, not just a list entry.
      for {cp, _name} <- @white_space do
        assert Enum.any?(@corpus, fn {_kind, _label, input} ->
                 String.starts_with?(input, <<cp::utf8>>)
               end)
      end
    end

    test "the fragment's btrim set strips every whitespace codepoint — MEMBERSHIP, not length" do
      # Length is not the invariant: the pre-fix set was 25 characters long on
      # PostgreSQL 15 too. It just held the letter `v` instead of U+000B.
      set = Extract.sql_btrim_set(source())

      for {cp, name} <- @white_space do
        assert sql_btrim(set, <<cp::utf8>> <> "x") == "x",
               "the fragment's btrim set does not strip U+#{hex(cp)} #{name} on " <>
                 "PostgreSQL #{server_version()} — a url led by it normalises to \"\" " <>
                 "while the Elixir twin names its host, so the claim reads :free for a live box"
      end
    end

    test "the fragment's btrim set does NOT touch the hostname alphabet" do
      # The other direction, and the one that caught the second half of the PG15
      # `\v` defect: a stray letter in the set truncates every hostname that
      # begins or ends with it. `https://gyldendal.tv` normalised to
      # `gyldendal.t`, and no whitespace was involved.
      set = Extract.sql_btrim_set(source())

      for c <- @hostname_alphabet do
        subject = c <> "x" <> c

        assert sql_btrim(set, subject) == subject,
               "the fragment's btrim set eats #{inspect(c)}, a hostname character — " <>
                 "every host starting or ending with it normalises short on the SQL " <>
                 "side only, and reads :free while a live box serves it"
      end
    end

    test "the corpus covers at least 40 classes and both twins were actually read" do
      assert length(@corpus) >= 40

      src = source()

      # The extractors are the load-bearing part: if either silently read
      # NOTHING, every equality below would compare two empty strings and pass.
      assert Extract.elixir_twin(src).("https://Read.Me.barkpark.cloud:4000/x") ==
               "read.me.barkpark.cloud"

      expr = Extract.sql_normalise_expr(src)
      assert expr =~ "regexp_replace"
      assert expr =~ "$1"
      refute expr =~ " = "

      assert sql_normalise(expr, "https://Read.Me.barkpark.cloud:4000/x") ==
               "read.me.barkpark.cloud"
    end

    test "every :equal corpus class normalises byte-identically on both sides" do
      outputs = twin_outputs(source())

      for {:equal, label, input} <- @corpus do
        {elixir_out, sql_out} = Map.fetch!(outputs, label)

        assert elixir_out == sql_out,
               """
               THE CLAIM-HOST TWINS DISAGREE on #{label}.

                    input: #{inspect(input)}
                   Elixir: #{inspect(elixir_out)}   (normalize_claim_host/1)
                      SQL: #{inspect(sql_out)}   (the provisioning_fqdn_claim/2 fragment)

               The candidate goes through the Elixir twin and the stored url
               through the SQL one, so a disagreement means a stored spelling of
               a hostname a LIVE box serves is INVISIBLE to the claim walk and
               provisioning_fqdn_claim/2 answers :free for it. That is the
               #11708 hole, re-opened by spelling.
               """
      end
    end

    test "the whitespace classes normalise to the SAME host as the clean spelling" do
      # Equality alone would be satisfied by both twins collapsing to "" — the
      # exact pre-fix SQL behaviour. This pins the VALUE: a whitespace-led url
      # must still name its host.
      outputs = twin_outputs(source())
      {clean, clean} = Map.fetch!(outputs, "plain https origin")

      for label <- @whitespace_classes do
        assert Map.fetch!(outputs, label) == {clean, clean},
               "#{label} did not normalise to #{inspect(clean)} on both sides — " <>
                 "got #{inspect(Map.fetch!(outputs, label))}"
      end
    end

    test "DOCUMENTED DIVERGENCE: Unicode case folding still differs (collation-dependent)" do
      outputs = twin_outputs(source())

      {elixir_out, sql_out} =
        Map.fetch!(outputs, "Unicode dotted capital I (collation-dependent case folding)")

      refute elixir_out == sql_out,
             """
             The Unicode case-folding class now AGREES (#{inspect(elixir_out)}).

             That is good news, not a defect — but this test pinned the
             divergence as measured, so update the moduledoc's honest-limits
             section and move this row to :equal rather than deleting the check.
             """

      # And the direction is the safe one: SQL keeps MORE of the hostname, so a
      # stored İ-spelled url still matches the ASCII candidate a caller can ask
      # for. If this ever inverts, the guard should be revisited.
      assert String.length(sql_out) > String.length(elixir_out)
    end
  end

  ## ─────────────────────────────────────────────────────────────────────────
  ## RUNG 2 — behaviour through the public function
  ## ─────────────────────────────────────────────────────────────────────────

  describe "provisioning_fqdn_claim/2 on a whitespace-led stored url" do
    test "answers {:held, …} — the row is not invisible because of a leading space" do
      host = "whitespace#{System.unique_integer([:positive])}.barkpark.cloud"
      victim = live_row_holding_url(" https://" <> host)

      assert {:held, leg, why} = Registry.provisioning_fqdn_claim(host),
             "a row storing #{inspect(victim.url)} did not hold #{host} — the claim walk " <>
               "read its url as \"\" and would hand a live host to the next tenant"

      assert is_atom(leg)
      assert why =~ victim.id
    end

    test "the whole whitespace family holds, each on its own hostname" do
      # Each spelling gets its OWN hostname: sharing one would let an earlier
      # iteration's row satisfy a later assertion even if that spelling
      # normalised to nothing.
      for {label, lead} <- [
            {"space", " "},
            {"tab", "\t"},
            {"CRLF", "\r\n"},
            {"NBSP", " "},
            {"ideographic space", "　"}
          ] do
        host = "ws#{System.unique_integer([:positive])}.barkpark.cloud"
        _victim = live_row_holding_url(lead <> "https://" <> host)

        assert {:held, _, _} = Registry.provisioning_fqdn_claim(host),
               "leading #{label} let #{host} read as :free"
      end
    end

    test "a clean stored url is unaffected (no regression from the btrim)" do
      host = "clean#{System.unique_integer([:positive])}.barkpark.cloud"
      _victim = live_row_holding_url("https://" <> host)

      assert {:held, _, _} = Registry.provisioning_fqdn_claim(host)
      assert :free = Registry.provisioning_fqdn_claim("unrelated-#{host}")
    end

    test "the asking row still excludes itself (the /2 self_id head)" do
      host = "self#{System.unique_integer([:positive])}.barkpark.cloud"
      mine = live_row_holding_url(" https://" <> host)

      assert :free = Registry.provisioning_fqdn_claim(host, mine.id)
    end
  end

  ## ─────────────────────────────────────────────────────────────────────────
  ## RUNG 3 — the guard is proved able to LOSE, from both sides
  ## ─────────────────────────────────────────────────────────────────────────

  describe "MUTATION" do
    test "deleting String.trim/1 from the Elixir twin diverges the whitespace classes" do
      mutated = Extract.without_elixir_trim(source())

      # The mutation must actually change the source, or the proof is vacuous.
      refute mutated == source()

      diverging = diverging_whitespace_classes(mutated)

      assert diverging == @whitespace_classes,
             "dropping the Elixir trim should diverge every whitespace class; diverged: " <>
               inspect(diverging)
    end

    test "deleting btrim(…) from the SQL fragment diverges them too (the pre-fix tree)" do
      mutated = Extract.without_sql_btrim(source())

      refute mutated == source()
      refute Extract.sql_normalise_expr(mutated) =~ "btrim"

      diverging = diverging_whitespace_classes(mutated)

      assert diverging == @whitespace_classes,
             "dropping the fragment's btrim should diverge every whitespace class; diverged: " <>
               inspect(diverging)

      # And the pre-fix SQL side collapsed to "" — the value that made the claim
      # answer :free. Named here so the mechanism, not just the inequality, is
      # on the record.
      expr = Extract.sql_normalise_expr(mutated)
      assert sql_normalise(expr, " https://a.barkpark.cloud") == ""
    end

    test "deleting BOTH keeps them equal — why an equality census alone is not enough" do
      mutated = source() |> Extract.without_elixir_trim() |> Extract.without_sql_btrim()

      # All but ONE class re-agree, and the exception is worth naming: with no
      # trim on either side, `"\r\nhttps://…"` still splits the twins, because
      # Elixir's `.`/`$` are line-oriented (`.` does not match a newline, `$`
      # matches before the trailing one) while Postgres's `.` matches newlines
      # too. So the untrimmed regexes were never equivalent even in principle —
      # a second, independent reason the trim belongs in the fragment rather
      # than being tuned out of the Elixir twin.
      assert diverging_whitespace_classes(mutated) == ["leading CRLF"]

      # Equality is restored by breaking both sides identically, which is
      # precisely why rung 2 asks the PUBLIC function for a {:held, …} and rung 1
      # pins the whitespace classes to the clean spelling's VALUE.
      expr = Extract.sql_normalise_expr(mutated)
      assert sql_normalise(expr, " https://a.barkpark.cloud") == ""
      assert Extract.elixir_twin(mutated).(" https://a.barkpark.cloud") == ""
    end
  end

  defp diverging_whitespace_classes(src) do
    outputs = twin_outputs(src)

    Enum.filter(@whitespace_classes, fn label ->
      {elixir_out, sql_out} = Map.fetch!(outputs, label)
      elixir_out != sql_out
    end)
  end

  ## ─────────────────────────────────────────────────────────────────────────
  ## The other two copies — documented, NOT absorbed
  ## ─────────────────────────────────────────────────────────────────────────

  describe "the third and fourth copies" do
    test "subdomain_from_url/1 does NOT normalise like the claim twins (backlog row)" do
      # Owned by cch-w69-bl-dns-label-minted-from-raw-url: this label becomes a
      # DNS record AND a Hetzner box name, so a hostile url spelling lands in
      # provisioning, not in the claim walk. Pinned, not fixed, here.
      raw = " https://Gyldendal.barkpark.cloud."
      bp = %Barkpark{url: raw}

      label = Barkpark.subdomain_from_url(bp)
      claim_twin = Extract.elixir_twin(source())

      refute label == "gyldendal",
             "subdomain_from_url/1 now normalises like the claim twins — if that is " <>
               "intended, close cch-w69-bl-dns-label-minted-from-raw-url and update the " <>
               "divergence table in this file's moduledoc"

      # Measured: not one of its three `String.replace_*` steps fires. The scheme
      # prefix misses on the leading space and the zone suffix misses on the
      # trailing dot, so the "DNS label" is the whole raw url, verbatim.
      assert label == raw
      assert claim_twin.(" https://Gyldendal.barkpark.cloud.") == "gyldendal.barkpark.cloud"
    end
  end
end
