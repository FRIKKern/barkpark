defmodule BarkparkWeb.EndpointTest do
  @moduledoc "LOW-15 — the session cookie is Secure only when served over HTTPS."
  use ExUnit.Case, async: false

  alias BarkparkWeb.Endpoint

  setup do
    prior = Application.get_env(:barkpark, :session_secure)
    on_exit(fn -> Application.put_env(:barkpark, :session_secure, prior) end)
    :ok
  end

  test "session cookie is not Secure on plain HTTP (default / prod-HTTP caveat)" do
    Application.put_env(:barkpark, :session_secure, false)
    refute Keyword.get(Endpoint.session_options(), :secure, false)
  end

  test "session cookie IS Secure when PHX_SCHEME=https drives :session_secure" do
    Application.put_env(:barkpark, :session_secure, true)
    assert Keyword.get(Endpoint.session_options(), :secure) == true
    # The base options (signing) survive untouched.
    assert Keyword.get(Endpoint.session_options(), :key) == "_barkpark_key"
  end
end
