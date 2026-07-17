defmodule BarkparkCloud.Web.RouterModuledocTableTest do
  @moduledoc """
  Tripwire: the `Router` `@moduledoc` "Route table" is a hand-maintained mirror of
  the `Plug.Router` match clauses, and it drifts silently the moment someone adds a
  route without touching the table (that is exactly how `/v1/onboarding`,
  `/v1/archives`, and the `/v1/admin/*` fleet routes ended up undocumented).

  This test re-derives BOTH sets from the router SOURCE — the `get|post|put|patch|
  delete "..."` (and `get("...")`) match macros on one side, the `METHOD  PATH`
  rows of the moduledoc table on the other — and fails if they disagree in either
  direction. It reads the file text (never the running router), so it is a pure,
  DB-free parse. Regex-over-source is the same render-from-data lever the
  `usage.go` noun-line mirror uses (#3973): the documented copy is checked against
  the code that is the source of truth, so it can never quietly rot.

  When this test fails: add the new route to the "## Route table" block in
  `router.ex` (or delete the row for the route you removed).
  """
  use ExUnit.Case, async: true

  @router_source Path.expand("../../../lib/barkpark_cloud/web/router.ex", __DIR__)

  # A route declaration: `get "/path" do`, `post("/path", do: ...)`, etc.
  # `[\s(]` after the verb matches both the space form and the parenthesized form.
  @route_re ~r/^\s*(get|post|put|patch|delete)[\s(]+"([^"]+)"/

  # A moduledoc table row: `      GET     /v1/me   user   ...`. Requires >=4 leading
  # spaces so it never collides with the 2-space `## GET ...` prose comments in the
  # body. The `*` catch-all row is documentation-only and excluded from the diff.
  @row_re ~r/^\s{4,}(GET|POST|PUT|PATCH|DELETE)\s+(\S+)/

  defp source, do: File.read!(@router_source)

  defp declared_routes do
    source()
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case Regex.run(@route_re, line) do
        [_, method, path] -> [{String.upcase(method), path}]
        _ -> []
      end
    end)
    |> MapSet.new()
  end

  defp moduledoc_block do
    case Regex.run(~r/@moduledoc\s+"""(.*?)"""/s, source()) do
      [_, block] -> block
      _ -> flunk("could not locate the Router @moduledoc block")
    end
  end

  defp documented_routes do
    moduledoc_block()
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case Regex.run(@row_re, line) do
        [_, method, path] -> [{method, path}]
        _ -> []
      end
    end)
    |> MapSet.new()
  end

  defp fmt(set) do
    set
    |> Enum.sort()
    |> Enum.map_join("\n", fn {m, p} -> "  #{String.pad_trailing(m, 7)} #{p}" end)
  end

  test "the router source actually parses (guard against a vacuous green)" do
    # If either extractor silently matched nothing, every diff below would be empty
    # and the tripwire would pass while measuring nothing. Pin a realistic floor.
    assert MapSet.size(declared_routes()) > 100,
           "expected >100 declared routes; the @route_re stopped matching the source"

    assert MapSet.size(documented_routes()) > 100,
           "expected >100 documented rows; the @row_re stopped matching the table"
  end

  test "every declared route appears in the moduledoc route table" do
    missing = MapSet.difference(declared_routes(), documented_routes())

    assert MapSet.size(missing) == 0, """
    #{MapSet.size(missing)} route(s) are declared in router.ex but MISSING from the
    "## Route table" in its @moduledoc. Add a row for each:

    #{fmt(missing)}
    """
  end

  test "every moduledoc route-table row still maps to a declared route" do
    stale = MapSet.difference(documented_routes(), declared_routes())

    assert MapSet.size(stale) == 0, """
    #{MapSet.size(stale)} row(s) in the "## Route table" no longer match any route
    declared in router.ex. Delete the stale row (or fix the METHOD/PATH):

    #{fmt(stale)}
    """
  end
end
