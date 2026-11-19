defmodule Barkpark.Api.OpenApiRoutesServedTest do
  @moduledoc """
  task-967f2dbbc1e9131f — every operation the OpenAPI document lists must be a
  route `BarkparkWeb.Router` serves.

  The generator writes one operation per manifest command at its flat
  `path_template`, plus the scoped mirror when the command has a
  `scoped_prefix`. A command whose route is mounted ONLY under the prefix (a
  `scoped_*` tier) used to get the flat operation too, and a client that
  followed it got a 404. This pin asks the router itself, through
  `Phoenix.Router.route_info/4`, for each documented method and path.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Api.OpenApi

  # A RATCHET, now empty: task-8990a6a0377d7021 moved the last seven (prefs,
  # codelist.show, doc actions; each served only under the scoped prefix) onto
  # scoped tiers. A new unserved operation is fixed, never added here.
  @unserved_today []

  defp operations do
    for {path, ops} <- OpenApi.spec()["paths"], {method, _op} <- ops do
      {String.upcase(method), path}
    end
  end

  defp served?({method, path}) do
    concrete = Regex.replace(~r/\{\w+\}/, path, "p1")
    Phoenix.Router.route_info(BarkparkWeb.Router, method, concrete, "localhost") != :error
  end

  test "CONTROL: the spec has operations, and a known flat route and a scoped one are served" do
    ops = operations()
    assert length(ops) > 100, "the spec lists only #{length(ops)} operations"

    for op <- [
          {"POST", "/v1/data/mutate/{dataset}"},
          {"POST", "/w/{workspace_slug}/p/{project_slug}/v1/papers/{slug}/ops"}
        ] do
      assert op in ops, "#{inspect(op)} is no longer documented"
      assert served?(op), "#{inspect(op)} is documented but route_info/4 does not resolve it"
    end
  end

  test "MUTANT: a path no router line serves reads as unserved" do
    refute served?({"POST", "/v1/papers/{slug}/ops"})
    refute served?({"POST", "/v1/tokens"})
  end

  test "every documented operation is a route the router serves" do
    unserved = operations() |> Enum.reject(&served?/1) |> Enum.sort()

    assert unserved -- @unserved_today == [],
           "the OpenAPI document lists these, but BarkparkWeb.Router serves no such " <>
             "route, so a client following the spec gets a 404. A command mounted only " <>
             "under /w/:workspace_slug/p/:project_slug needs a scoped_* tier in " <>
             "capabilities.ex; then re-run `mix barkpark.openapi`. " <>
             inspect(unserved -- @unserved_today)

    assert @unserved_today -- unserved == [],
           "these are served now (or no longer documented): remove them from " <>
             "@unserved_today. #{inspect(@unserved_today -- unserved)}"
  end
end
