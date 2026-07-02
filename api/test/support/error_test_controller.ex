defmodule BarkparkWeb.ErrorTestController do
  @moduledoc """
  Test-only controller that deliberately raises, so the RenderErrors integration
  tests can prove `BarkparkWeb.ErrorJSON` / `BarkparkWeb.ErrorHTML` render a
  well-formed response end-to-end. The app defends every real request path, so
  nothing user-facing raises — this is the only way to exercise the crash path.

  Mounted only when `:error_test_routes` is set (config/test.exs); the router
  scope is compiled out of dev/prod.
  """
  use Phoenix.Controller, formats: [:json, :html]

  def boom(_conn, _params), do: raise("boom — error-render integration test")
end
