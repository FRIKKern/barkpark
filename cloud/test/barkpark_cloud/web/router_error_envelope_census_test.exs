defmodule BarkparkCloud.Web.RouterErrorEnvelopeCensusTest do
  @moduledoc """
  THE ENVELOPE-SHAPE CENSUS (cch-w62-bl) — a guard over the CLASS, not the
  instance.

  Router error emitters answer in two shapes: FLAT `%{error: "slug"}` (the
  majority, and the only shape the wave-37 per-field `details` ladder can
  reach) and NESTED `%{error: %{code: "slug"}}` (four route families). One
  route mixing both is how `PATCH /v1/barkparks/:id/autoupdate` shipped a
  permanent validation refusal that rendered as a generic: its 404 arms were
  flat, its 422 arm nested and details-less, and `friendly()` (app.js) read
  `data.error` as a string key.

  THREE ARMS:

    * ARM 1 — THE NESTED POPULATION IS PINNED with `==`, never `>=`. A new
      nested emitter is a DECISION (its slug misses the flat-keyed curated
      map unless the seam unwraps it, and its `details` — if nested inside
      `error` — are invisible to the ladder); joining the set must red this
      census and be recorded here, not drift in.

    * ARM 2 — THE AUTOUPDATE ROUTE IS ALL-FLAT. cch-w62-bl flattened its 422
      arm into the details-ladder shape (`%{error: "invalid", details:
      errors(cs)}`); this arm keeps the route one-shape forever.

    * ARM 3 — THE CONSOLE SEAM READS BOTH SHAPES while any nested emitter
      exists: `friendly()` must keep its D740 unwrap line
      (`if (key && typeof key === "object") key = key.code;`, app.js). The
      Go CLI's `decodeRouteErrorCode` (internal/cloudclient/client.go) is the
      other consumer and tries object-then-string; it is fenced to the DR
      epic's tree, so its guard lives in its own Go tests, not here.

  WHY AN AST WALK: emitters span lines and prose mentions envelopes freely; a
  grep census here would be the instrument-that-cannot-fail this epic exists
  to kill. `Code.string_to_quoted!` + `Macro.prewalk` sees each `json(conn,
  status, body)` call once, with line metadata.

  THE PIN IS MEASURED, NEVER COMPUTED (the payload census's own law): set it
  absurd, run this file, read the refusal line back, write that number.

  MUTATION PROOF (re-run to reproduce; observed runs quoted in the landing
  PR): (a) re-nest the autoupdate 422 arm -> ARM 2 reds by line and ARM 1
  reds on the count; (b) delete the unwrap line from app.js -> ARM 3 reds.
  """
  use ExUnit.Case, async: true

  @router "lib/barkpark_cloud/web/router.ex"
  @app_js "priv/static/app.js"

  # Measured by the 999-technique on this tree, never computed: pin set absurd
  # (999), ARM 1 run, its refusal line read back. This tree measured 29; the
  # same instrument over origin/main's router.ex read 30 before cch-w62-bl
  # flattened the autoupdate 422 — the delta is exactly that one arm.
  @nested_pinned 29

  @unwrap_line ~s[if (key && typeof key === "object") key = key.code;]

  defp emitters do
    ast = @router |> File.read!() |> Code.string_to_quoted!()

    {_, sites} =
      Macro.prewalk(ast, [], fn
        {:json, meta, [_conn, status, {:%{}, _, kvs}]} = node, acc when is_list(kvs) ->
          # A literal 2xx/3xx status is a success body; anything else — a 4xx/5xx
          # literal OR a status VARIABLE (relay helpers forward upstream codes) —
          # is an error emitter when the body carries `:error`. Excluding
          # variable-status calls here is exactly how this census once missed
          # `json(conn, status, %{ok: false, error: %{code: code}})`.
          if is_integer(status) and status < 400 do
            {node, acc}
          else
            case List.keyfind(kvs, :error, 0) do
              {:error, value} ->
                {node, [{meta[:line], classify(value)} | acc]}

              _ ->
                {node, acc}
            end
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(sites)
  end

  defp classify(value) when is_binary(value), do: :flat
  defp classify({:%{}, _, _}), do: :nested
  defp classify(_), do: :dynamic

  test "ARM 1 — the nested-envelope emitter population is pinned exactly" do
    nested = for {line, :nested} <- emitters(), do: line

    assert length(nested) == @nested_pinned,
           """
           #{length(nested)} nested `%{error: %{…}}` emitter(s) in router.ex; the
           pin is EXACTLY #{@nested_pinned}. A route JOINING the nested set is a
           decision, not a drift: its slug misses the flat-keyed curated map
           unless the console seam unwraps it, and details nested inside `error`
           are invisible to the per-field ladder. Prefer the flat details-ladder
           shape. If the change is deliberate, re-measure the pin by the
           999-technique and record the decision in this file's moduledoc.
           Nested emitter lines now: #{inspect(nested)}
           """
  end

  test "ARM 2 — PATCH /v1/barkparks/:id/autoupdate emits ONE shape: flat" do
    src = File.read!(@router)
    ast = Code.string_to_quoted!(src)

    {_, blocks} =
      Macro.prewalk(ast, [], fn
        {:patch, _, ["/v1/barkparks/:id/autoupdate", _]} = node, acc ->
          {node, [node | acc]}

        node, acc ->
          {node, acc}
      end)

    assert length(blocks) == 1, "expected exactly one autoupdate route block"

    {_, shapes} =
      Macro.prewalk(hd(blocks), [], fn
        {:json, meta, [_conn, status, {:%{}, _, kvs}]} = node, acc when is_list(kvs) ->
          if is_integer(status) and status < 400 do
            {node, acc}
          else
            case List.keyfind(kvs, :error, 0) do
              {:error, value} -> {node, [{meta[:line], classify(value)} | acc]}
              _ -> {node, acc}
            end
          end

        node, acc ->
          {node, acc}
      end)

    refute shapes == [], "the route lost its error emitters — census anchor broke"

    for {line, shape} <- shapes do
      assert shape == :flat,
             "router.ex:#{line} — the autoupdate route emits a #{shape} envelope; " <>
               "cch-w62-bl settled this route on ONE shape (flat, details-ladder). " <>
               "See this census's moduledoc before changing that."
    end
  end

  test "ARM 3 — while nested emitters exist, friendly() keeps the D740 unwrap" do
    nested = for {line, :nested} <- emitters(), do: line

    if nested != [] do
      assert String.contains?(File.read!(@app_js), @unwrap_line),
             """
             router.ex still has #{length(nested)} nested `%{error: %{…}}`
             emitter(s) (lines #{inspect(nested)}) but app.js `friendly()` no
             longer carries the D740 unwrap line:

                 #{@unwrap_line}

             Without it, a nested refusal keys the curated map with an OBJECT
             and the humanized-slug fallback calls `.replace` on it — a
             TypeError in copy code whose whole job is to never crash. Restore
             the unwrap or empty the nested set first.
             """
    end
  end
end
