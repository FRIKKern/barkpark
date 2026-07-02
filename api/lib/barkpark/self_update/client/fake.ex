defmodule Barkpark.SelfUpdate.Client.Fake do
  @moduledoc """
  Test double for `Barkpark.SelfUpdate.Client` (selected via test.exs
  `client:`). Scripted per-test through Application env — prime with e.g.

      Application.put_env(:barkpark, Barkpark.SelfUpdate.Client.Fake,
        latest: {:ok, %{release: "0.2.24", tag: "v0.2.24"}},
        digest: {:ok, ["fix: something"]}
      )

  Reads the env on EVERY call, so tests can re-prime between checks
  without restarting anything. Unprimed keys degrade safely (`:latest` →
  `{:error, :fake_not_primed}`, `:digest` → `{:ok, []}`).
  """

  @behaviour Barkpark.SelfUpdate.Client

  @impl true
  def latest_release(repo) do
    # Per-repo scripting (fork tests need the fork and the canonical repo to
    # answer differently): `:latest_by_repo` is a %{"owner/name" => response}
    # map consulted first; the flat `:latest` stays the single-repo default.
    by_repo = Keyword.get(cfg(), :latest_by_repo, %{})
    Map.get(by_repo, repo) || Keyword.get(cfg(), :latest, {:error, :fake_not_primed})
  end

  @impl true
  def digest(_repo, _from_tag, _to_tag) do
    Keyword.get(cfg(), :digest, {:ok, []})
  end

  defp cfg, do: Application.get_env(:barkpark, __MODULE__, [])
end
