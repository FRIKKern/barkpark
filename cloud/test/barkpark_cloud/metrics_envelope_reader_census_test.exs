defmodule BarkparkCloud.MetricsEnvelopeReaderCensusTest do
  @moduledoc """
  THE TOP-LEVEL METRICS ENVELOPE'S wire-vs-reader census: every key
  `BarkparkCloud.Metrics.build/3` folds onto `GET /v1/barkparks/:id/metrics` must
  have a NAMED reader, or this reds.

  ## Why this census, when two tripwires already sit next to it

  Two guards already bind parts of this envelope, and BOTH would have stayed
  green through the gap this one closes:

    * `TestMetricTopSpecsCoverTheControlPlaneVitals` (internal/cli) binds the
      SERIES key set (`@vitals`) to `bp cloud instance top`'s render list.
    * `TestCloudInstanceTopScalarsCoverTheControlPlane` (internal/cli,
      cloud_instance_top_scalars_test.go) binds the keys INSIDE the `latest`,
      `pressure` and `space` blocks to that same surface, with an explicit
      "not rendered, and here is why" ledger.

  Neither looks at the envelope's OWN top-level key set. A block added to
  `build/3` — a new sibling of `latest` or `space` — ships on every poll,
  through a fully green build, with no surface reading it. That is the exact
  shape task
  `cch-w51-bl-metrics-latest-block-is-produced-and-rendered-by-nothing` was
  filed on, one level up from where it looked.

  ## SIDE A — what the control plane SERVES

  The top-level keys of the map `Metrics.build/3` returns, parsed from
  `metrics.ex` by INDENTATION: the returned map's own keys sit at six spaces and
  every nested map's keys deeper, so the shallow match is exactly the envelope's
  key set and never its children's. Read off the CODE, never off the `@spec`
  docstring — a docstring is what drifted here (`mem` and `disk` were served by
  `latest/1` and absent from the typespec until this task).

  ## SIDE B — what READS it

  The union of the envelope's two production consumers:

    * `cloud/priv/static/app.js` — `metricsSeries(payload)`, the console's
      Metrics tab fold. Bounded to that function's body, so a `payload.<key>`
      belonging to some OTHER envelope in that 28k-line file cannot count as a
      reader here.
    * `internal/cloudclient/client.go` — `MetricsResult`'s `json:"<key>"` tags,
      the decode the Go TUI's `bp cloud instance top` renders from. This is the
      half the filing missed: `latest` is unread by the console and rendered in
      full by the terminal surface (`storageLines`, `swapStatValue`,
      `spaceLines`' core-count inference).

  A key needs ONE of them, not both — the two surfaces answer different
  questions and neither is obliged to print everything.

  ## Fail-closed (the positive controls)

  A missing source file, a boundary marker that moved, or EITHER side coming
  back empty is a named raise, never a pass. An empty Side A reads as "nothing
  is served, so nothing is unread" and an empty Side B as "nothing is read, so
  everything is" — the first is a vacuous green and the second a false alarm.
  This census refuses both rather than measure nothing.
  """
  use ExUnit.Case, async: true

  @metrics_source Path.expand("../../lib/barkpark_cloud/metrics.ex", __DIR__)
  @app_js Path.expand("../../priv/static/app.js", __DIR__)
  @cloudclient Path.expand("../../../internal/cloudclient/client.go", __DIR__)

  defp source!(path, what) do
    unless File.regular?(path) do
      raise ArgumentError,
            "MetricsEnvelopeReaderCensus: #{what} source not found at #{path}. " <>
              "The file moved or was renamed — re-point the census. Refusing to " <>
              "derive a census side from a source that does not exist."
    end

    File.read!(path)
  end

  # The text strictly between `start` and the first `stop` after it. A marker
  # that no longer appears is a NAMED refusal: the contract moved, and a census
  # that silently measured an empty slice would be worse than no census.
  defp between!(src, start, stop, what) do
    case String.split(src, start, parts: 2) do
      [_, rest] ->
        case String.split(rest, stop, parts: 2) do
          [body, _] ->
            body

          _ ->
            raise ArgumentError,
                  "MetricsEnvelopeReaderCensus: #{what} — #{inspect(start)} is " <>
                    "unterminated (no #{inspect(stop)} after it)."
        end

      _ ->
        raise ArgumentError,
              "MetricsEnvelopeReaderCensus: #{what} no longer contains " <>
                "#{inspect(start)} — the contract moved. Re-point the census."
    end
  end

  defp non_empty!(list, what) do
    if list == [] do
      raise ArgumentError,
            "MetricsEnvelopeReaderCensus: #{what} extracted ZERO entries. " <>
              "The census would be vacuous, so it refuses instead of passing."
    end

    Enum.uniq(list)
  end

  # SIDE A. build/3's returned map, keys at SIX spaces (its nested maps sit
  # deeper and must not count).
  defp served_keys do
    body =
      @metrics_source
      |> source!("control plane")
      |> between!("def build(barkpark, events, opts \\\\ []) do", "\n  end", "metrics.ex build/3")

    ~r/(?m)^      (\w+):/
    |> Regex.scan(body)
    |> Enum.map(fn [_, k] -> k end)
    |> non_empty!("build/3's served key set")
  end

  # SIDE B(i). The console's fold, bounded to metricsSeries' own body (its close
  # is the first `  }` at function indentation).
  defp console_reader_keys do
    body =
      @app_js
      |> source!("console")
      |> between!("function metricsSeries(payload) {", "\n  }", "app.js metricsSeries/1")

    ~r/payload\.(\w+)/
    |> Regex.scan(body)
    |> Enum.map(fn [_, k] -> k end)
    |> non_empty!("app.js metricsSeries' reader set")
  end

  # SIDE B(ii). The Go client's decode of the same envelope.
  defp cli_reader_keys do
    body =
      @cloudclient
      |> source!("cloudclient")
      |> between!("type MetricsResult struct {", "\n}", "client.go MetricsResult")

    ~r/json:"(\w+)"/
    |> Regex.scan(body)
    |> Enum.map(fn [_, k] -> k end)
    |> non_empty!("client.go MetricsResult's reader set")
  end

  test "SIDE A is the envelope this census claims to cover (control)" do
    served = served_keys()

    # The blocks the whole surface exists for. If build/3 stopped folding one of
    # these, the parse below would silently shrink and every later assertion
    # would pass over a smaller envelope.
    for key <- ~w(series latest pressure space service_health) do
      assert key in served,
             "build/3 no longer serves #{key} — either the envelope changed or the " <>
               "six-space parse broke. Re-derived: #{inspect(served)}"
    end
  end

  test "both reader sides are non-empty and disagree (control)" do
    console = console_reader_keys()
    cli = cli_reader_keys()

    # Two readers that returned the SAME set would mean one of the two parses
    # is echoing the other's source rather than reading its own.
    refute MapSet.equal?(MapSet.new(console), MapSet.new(cli)),
           "the console and CLI reader sets came back identical (#{inspect(console)}) — " <>
             "one of the two extractions is not reading the source it names"

    # The half the original filing missed: `latest` IS read, by the terminal
    # surface, and NOT by the console. Both halves of that fact are asserted, so
    # a future change that moves it either way reds here with the reason.
    assert "latest" in cli, "client.go no longer decodes `latest`"
    refute "latest" in console, "app.js now reads payload.latest — update this census' note"
  end

  test "every key build/3 serves has a named reader" do
    served = served_keys()
    readers = MapSet.union(MapSet.new(console_reader_keys()), MapSet.new(cli_reader_keys()))

    orphans = Enum.reject(served, &MapSet.member?(readers, &1))

    assert orphans == [],
           """
           produced-with-no-renderer: #{length(orphans)} key(s) ride the metrics \
           envelope on every poll and NO surface reads them: #{inspect(orphans)}.

           Served (Metrics.build/3): #{inspect(Enum.sort(served))}
           Read (app.js metricsSeries ∪ client.go MetricsResult): \
           #{inspect(Enum.sort(MapSet.to_list(readers)))}

           A payload nobody consumes is bytes on every poll AND a promise in the \
           wire contract. Either render it on a surface, or stop composing it — \
           and if this key is deliberately API-only, that is a decision to write \
           down beside a NAMED consumer, not a green build to hide behind.
           """
  end
end
