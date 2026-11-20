defmodule BarkparkCloud.OAuthConfigSandbox do
  @moduledoc """
  Patch `BarkparkCloud.OAuth`'s config for THIS PROCESS ONLY.

  The replacement for `Application.put_env(:barkpark_cloud, OAuth, patched)` in
  tests. That call swaps ONE value for the WHOLE NODE, so while it is held every
  concurrent test sees the patched config — which is why the whole family of
  config-seam modules was pinned `async: false` by
  `hg-w1-async-seam-ban-and-scanner`. That is serialization, not isolation, and
  it costs wall-clock that grows with every new such test.

  `OAuth.config/0` consults a process-dictionary override before Application env
  (see the seam comment beside it), so a patch written here is invisible to every
  other process and the module can go back to `async: true` and stay correct BY
  CONSTRUCTION rather than by being kept away from its peers.

  ## Use

      import BarkparkCloud.OAuthConfigSandbox

      patch_oauth_config!(fn cfg ->
        put_in(cfg[:providers]["github"][:client_secret], nil)
      end)

  The override lives in the calling process's dictionary and dies with it, so no
  teardown is required for isolation. `clear_oauth_config!/0` exists for a test
  that wants the real config back mid-body.
  """

  alias BarkparkCloud.OAuth

  @doc """
  Replace this process's view of the OAuth config with `fun.(current_config)`.

  `fun` receives the config the module would otherwise read (Application env on
  a first call), so a patch is expressed as a diff from reality rather than as a
  hand-built map that silently drifts from `config/test.exs`.
  """
  @spec patch_oauth_config!((keyword() -> keyword())) :: keyword()
  def patch_oauth_config!(fun) when is_function(fun, 1) do
    patched = fun.(current())
    Process.put(OAuth.__config_override_key__(), patched)
    patched
  end

  @doc "Set this process's OAuth config outright."
  @spec put_oauth_config!(keyword()) :: keyword()
  def put_oauth_config!(config) when is_list(config) do
    Process.put(OAuth.__config_override_key__(), config)
    config
  end

  @doc "Drop the override so this process reads Application env again."
  @spec clear_oauth_config!() :: :ok
  def clear_oauth_config! do
    Process.delete(OAuth.__config_override_key__())
    :ok
  end

  @doc """
  The config this process currently sees — the override if one is set, otherwise
  Application env. The same resolution `OAuth.config/0` performs, so a test can
  assert on what the module will actually read.
  """
  @spec current() :: keyword()
  def current do
    case Process.get(OAuth.__config_override_key__()) do
      nil -> Application.get_env(:barkpark_cloud, OAuth, [])
      override -> override
    end
  end
end
