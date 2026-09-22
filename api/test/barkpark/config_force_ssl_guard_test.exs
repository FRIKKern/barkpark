defmodule Barkpark.ConfigForceSslGuardTest do
  @moduledoc """
  task-b2b81f3c1e3bd3ff — `force_ssl` stays out of `api/config/**`.

  Golden Rule #5 / Past Mistake #5 (root `CLAUDE.md`): TLS terminates at the
  reverse proxy (Caddy in prod, the platform edge on the Cloud hosts) and the
  app speaks plain HTTP behind it. Phoenix therefore only ever sees `http` on
  the wire, so `force_ssl` 301-redirects to https, the proxy re-forwards as
  http, and the request loops forever — the recorded outage in which every API
  call returned empty.

  Two assertions, and they are NOT the same strength:

    * **The bare `force_ssl: [hsts: true]` form must not appear anywhere in
      `config/`, comment or code.** This is the RED-before assertion: before
      this test landed, `config/runtime.exs` carried exactly that string in the
      stock Phoenix "## SSL Support" boilerplate, recommending the one shape
      that guarantees the loop (no `rewrite_on:`, so a proxied request is always
      read as plaintext) *and* pins browsers to https for a year while it loops.
      A comment is enough to fail: the boilerplate's whole failure mode was that
      it read as sanctioned advice sitting 250 lines below the correct guidance
      in the same file.

    * **No live (uncommented) line may set `force_ssl:`.** A standing guard —
      it already held when this test was written, and exists so re-enabling
      `force_ssl` cannot land silently.

  The commented `force_ssl: [rewrite_on: [:x_forwarded_proto]]` block that
  `config/prod.exs` carries is deliberately allowed: it is the only safe form
  (it trusts the proxy's `X-Forwarded-Proto`) and is the documented recipe for
  the day TLS terminates at the app tier.

  ## pws-bl-force-ssl-tripwire — the third assertion

  The two assertions above share two weaknesses, and the third closes both.

  **They scan `config/` only.** `force_ssl:` is not a mechanism, it is sugar:
  `Phoenix.Endpoint` reads the key and inserts `Plug.SSL`. A `plug Plug.SSL,
  hsts: true` written straight into `lib/barkpark_web/endpoint.ex` produces the
  identical 301 loop and the identical outage, and a `config/`-scoped scan
  never sees it. The third assertion scans `config/**` AND `lib/**`, and treats
  `Plug.SSL` as an enforcement site in its own right.

  **Their expected value is a constant.** "force_ssl must be absent" is true
  today because of a FACT about the deployment — the app tier has no HTTPS
  listener — that the assertions never read. The third assertion derives its
  expectation from that fact instead: HTTPS enforcement is permitted exactly
  when a live `https:` listener key exists in the Endpoint configuration (the
  key Phoenix/Bandit requires to bind a TLS socket). A DIFFERENT key from the
  one being guarded, so the guard cannot agree with whatever it finds. The day
  someone genuinely terminates TLS at the app tier, they add `https:` and this
  assertion stops objecting — without anyone editing the test.

  ## The predicate, stated, and what it cannot see

  ENFORCEMENT SITE — a line under `api/config/**` or `api/lib/**` whose code
  half (everything before the first `#`) contains the token `force_ssl` or the
  token `Plug.SSL`. A predicate, not a list of today's spellings: it catches
  the endpoint keyword, a module attribute holding it, a keyword list assembled
  at runtime, and the desugared plug — anything that writes the atom's name.

  APP-TIER TLS — a line in the same corpus whose code half matches `https:`
  followed by whitespace: a keyword KEY, which `https://…` inside a URL is not.

  Honest blind spots, all of them textual-scan limits:

    * An atom built without writing its name — `String.to_atom("force_" <> x)`,
      or a key read from an env var — is invisible. Nothing short of booting
      the endpoint and reading `Plug.SSL` out of the plug pipeline sees that.
    * `Plug.SSL` reached through an alias (`alias Plug.SSL, as: X; plug X`).
    * Comment stripping splits on the FIRST `#`, so a `force_ssl` that follows
      a `\#{}` interpolation or a `?#` literal on the same line reads as a
      comment. Conservative in the wrong direction; recorded, not fixed.
    * Heredoc tracking is a `\"\"\"`-fence parity count, so a `\"\"\"` inside a
      single-line string or a `~s` sigil desynchronises the rest of that file.
      Single-line `"…"` strings and `~s|…|` sigils are NOT stripped, so a
      `force_ssl` inside one still counts as a site (the safe direction).
    * `api/` only. `cloud/`, `deploy/` and `deps/` configs are out of scope
      here (a different fence owns them).
  """
  use ExUnit.Case, async: true

  @config_dir Path.expand("../../config", __DIR__)

  defp config_files do
    files = Path.wildcard(Path.join(@config_dir, "*.exs"))

    # Non-vacuity: if the glob ever stops resolving (moved dir, renamed files)
    # every assertion below would pass over an empty list.
    assert length(files) >= 3,
           "expected the config/*.exs corpus, found #{inspect(files)} under #{@config_dir}"

    assert Enum.any?(files, &(Path.basename(&1) == "runtime.exs")),
           "config/runtime.exs missing from #{inspect(Enum.map(files, &Path.basename/1))}"

    files
  end

  test "no config file carries the bare `force_ssl: [hsts: true]` boilerplate" do
    offenders =
      for path <- config_files(),
          {line, n} <- Enum.with_index(String.split(File.read!(path), "\n"), 1),
          String.contains?(line, "force_ssl: [hsts: true]"),
          do: "#{Path.basename(path)}:#{n}: #{String.trim(line)}"

    assert offenders == [],
           """
           `force_ssl: [hsts: true]` must not appear in api/config/** — not even
           in a comment. Without `rewrite_on: [:x_forwarded_proto]` it 301-loops
           behind the TLS-terminating proxy (Golden Rule #5 / Past Mistake #5)
           and its HSTS header pins browsers to https for a year mid-loop.

           The only safe form, already commented in config/prod.exs, is:
               force_ssl: [rewrite_on: [:x_forwarded_proto]]

           Offending lines:
           #{Enum.join(offenders, "\n")}
           """
  end

  test "no config file sets force_ssl in live (uncommented) code" do
    offenders =
      for path <- config_files(),
          {line, n} <- Enum.with_index(String.split(File.read!(path), "\n"), 1),
          # Strip any trailing comment, then look for a live `force_ssl:` set.
          code = line |> String.split("#", parts: 2) |> hd(),
          String.contains?(code, "force_ssl"),
          do: "#{Path.basename(path)}:#{n}: #{String.trim(line)}"

    assert offenders == [],
           """
           force_ssl is DELIBERATELY off (Golden Rule #5 / Past Mistake #5): TLS
           terminates at the reverse proxy and the app tier has no HTTPS
           listener, so enabling it 301-loops every request.

           Do not re-enable without a real app-tier HTTPS listener; when that
           day comes the form is `force_ssl: [rewrite_on: [:x_forwarded_proto]]`
           (see docs/ops/adding-a-domain.md).

           Offending lines:
           #{Enum.join(offenders, "\n")}
           """
  end

  # ── pws-bl-force-ssl-tripwire ───────────────────────────────────────────────
  #
  # Everything below is PURE over its corpus: the scanners take the file list
  # (or raw {path, contents} pairs) as an argument, so the derivation can be
  # driven with synthetic sources and proven to flip in BOTH directions. A
  # guard that can only be exercised by editing the real tree is one whose
  # positive case nobody ever runs.

  @api_root Path.expand("../..", __DIR__)

  defp scanned_sources do
    files =
      Path.wildcard(Path.join(@api_root, "config/**/*.exs")) ++
        Path.wildcard(Path.join(@api_root, "lib/**/*.ex")) ++
        Path.wildcard(Path.join(@api_root, "lib/**/*.exs"))

    # Non-vacuity. Both globs must resolve; an empty lib/ corpus would make the
    # widened assertion pass precisely where the old one already passed.
    assert Enum.count(files, &String.ends_with?(&1, ".exs")) >= 3,
           "expected the config/**.exs corpus under #{@api_root}"

    assert Enum.count(files, &String.ends_with?(&1, ".ex")) >= 50,
           "expected the lib/**.ex corpus under #{@api_root}, found #{length(files)} files"

    assert Enum.any?(files, &String.ends_with?(&1, "barkpark_web/endpoint.ex")),
           "lib/barkpark_web/endpoint.ex missing from the scanned corpus"

    Enum.map(files, &{Path.relative_to(&1, @api_root), File.read!(&1)})
  end

  # The CODE half of each line: `""` for anything inside a `\"\"\"` heredoc
  # (a @moduledoc discussing force_ssl is prose, not configuration), and
  # otherwise everything before the first `#`. Both exclusions were forced by
  # the real corpus, not guessed: without the heredoc arm,
  # lib/barkpark_web/plugs/api_security_headers.ex's moduledoc line
  # "HSTS / force_ssl — HTTPS is terminated upstream" reads as an enforcement
  # site. See the blind spots in the moduledoc.
  defp code_lines(body) do
    body
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.map_reduce(false, fn {line, n}, in_heredoc ->
      fences = length(String.split(line, ~s(\"\"\"))) - 1
      code = if in_heredoc, do: "", else: line |> String.split("#", parts: 2) |> hd()
      next = if rem(fences, 2) == 1, do: not in_heredoc, else: in_heredoc
      {{n, line, code}, next}
    end)
    |> elem(0)
  end

  defp live_lines(sources, matcher) do
    for {path, body} <- sources,
        {n, line, code} <- code_lines(body),
        matcher.(code),
        do: "#{path}:#{n}: #{String.trim(line)}"
  end

  @doc false
  # An ENFORCEMENT SITE writes the name of the thing that turns HTTPS
  # enforcement on — the sugar (`force_ssl`) or what it desugars into
  # (`Plug.SSL`).
  def enforcement_sites(sources) do
    live_lines(sources, fn code ->
      String.contains?(code, "force_ssl") or String.contains?(code, "Plug.SSL")
    end)
  end

  @doc false
  # THE INDEPENDENT EXPECTATION. Read from the `https:` LISTENER key, never
  # from `force_ssl` itself, so the guard cannot agree with whatever it finds.
  #
  # The key opens a keyword list at a keyword position: start of line or just
  # after `,` `[` `{`, then `https:`, then a `[`. Both narrowings were forced
  # by the corpus — `"https://barkpark.cloud"` in a check_origin list and
  # `connect-src 'self' https: ws:` in paper_reader_csp.ex's CSP string each
  # matched a looser form.
  def app_tier_https_listener(sources) do
    live_lines(sources, &Regex.match?(~r/(?:^|[,\[{])\s*https:\s*\[/, &1))
  end

  describe "the derivation flips in both directions (synthetic corpora)" do
    @no_tls [
      {"config/prod.exs", "config :barkpark, BarkparkWeb.Endpoint, url: [scheme: \"http\"]\n"}
    ]
    @with_tls [
      {"config/prod.exs",
       "config :barkpark, BarkparkWeb.Endpoint,\n  https: [port: 443, cipher_suite: :strong]\n"}
    ]

    test "a URL is not a listener" do
      assert app_tier_https_listener([{"c.exs", ~s|check_origin: ["https://barkpark.cloud"]\n|}]) ==
               []
    end

    test "a live `https:` key IS a listener" do
      assert [_] = app_tier_https_listener(@with_tls)
    end

    test "a commented `https:` key is not a listener" do
      assert app_tier_https_listener([{"c.exs", "#  https: [port: 443]\n"}]) == []
    end

    # REGRESSION CONTROLS — both of these reddened the real corpus while the
    # predicates were looser. They are here so a future loosening cannot.
    test "a CSP source-list `https:` is not a listener" do
      csp = ~s|  "connect-src 'self' https: ws: wss:; " <>\n|
      assert app_tier_https_listener([{"lib/csp.ex", csp}]) == []
    end

    test "force_ssl discussed inside a @moduledoc is not an enforcement site" do
      prose = ~s|  @moduledoc \"\"\"\n  HSTS / force_ssl — terminated upstream.\n  \"\"\"\n|
      assert enforcement_sites([{"lib/x.ex", prose}]) == []
    end

    test "force_ssl in live code one line AFTER a closed heredoc is still seen" do
      body =
        ~s|  @moduledoc \"\"\"\n  force_ssl is prose here.\n  \"\"\"\n  force_ssl: [hsts: true]\n|

      assert [site] = enforcement_sites([{"lib/x.ex", body}])
      assert site =~ "x.ex:4"
    end

    test "the plug form is an enforcement site the config-keyed assertions miss" do
      sources = [{"lib/barkpark_web/endpoint.ex", "  plug Plug.SSL, hsts: true\n"}]
      assert [site] = enforcement_sites(sources)
      assert site =~ "Plug.SSL"
      # ...and the config-only shape of the two older assertions does not.
      refute String.contains?(site, "force_ssl")
    end

    test "a runtime-assembled keyword still writes the atom's name" do
      sources = [
        {"lib/x.ex", "  opts = Keyword.put(opts, :force_ssl, rewrite_on: [:x_forwarded_proto])\n"}
      ]

      assert [_] = enforcement_sites(sources)
    end

    test "the VERDICT is a function of both, not of force_ssl alone" do
      # No TLS + enforcement = the outage. TLS + enforcement = fine.
      offending = fn sources ->
        if app_tier_https_listener(sources) == [], do: enforcement_sites(sources), else: []
      end

      enforcing = [{"config/prod.exs", "  force_ssl: [rewrite_on: [:x_forwarded_proto]]\n"}]

      assert [_] = offending.(enforcing ++ @no_tls)
      assert [] == offending.(enforcing ++ @with_tls)
    end
  end

  test "HTTPS enforcement is live only where an app-tier HTTPS listener is configured" do
    sources = scanned_sources()
    listeners = app_tier_https_listener(sources)
    sites = enforcement_sites(sources)

    # The expectation is DERIVED, not asserted: if the app tier ever grows a
    # real TLS listener, enforcement becomes legitimate and this test goes
    # quiet on its own.
    if listeners == [] do
      assert sites == [],
             """
             An app-tier HTTPS listener does NOT exist (no live `https:` key in
             any api/config/** or api/lib/** source), yet HTTPS enforcement is
             live. Phoenix will 301 every plaintext request to https, the
             TLS-terminating proxy re-forwards it as http, and the request
             loops until it dies — the recorded outage in which every API call
             returned empty (Golden Rule #5 / Past Mistake #5).

             Either remove the enforcement, or add the `https:` listener that
             makes it honest (port 443 + `cipher_suite:` — see
             docs/ops/adding-a-domain.md and config/runtime.exs's SSL section).

             Enforcement sites:
             #{Enum.join(sites, "\n")}
             """
    else
      # The other side of the fork. Enforcement is now legitimate — but only
      # in the form that trusts the proxy's X-Forwarded-Proto. A bare
      # `hsts: true` still loops behind a proxy that has not been retired.
      unsafe = Enum.reject(sites, &String.contains?(&1, "rewrite_on"))

      assert unsafe == [],
             """
             An app-tier HTTPS listener exists (#{Enum.join(listeners, ", ")}),
             so HTTPS enforcement is legitimate — but only as
             `force_ssl: [rewrite_on: [:x_forwarded_proto]]`. These sites
             enforce without it:
             #{Enum.join(unsafe, "\n")}
             """
    end
  end
end
