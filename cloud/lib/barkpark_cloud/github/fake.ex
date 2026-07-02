defmodule BarkparkCloud.GitHub.Fake do
  @moduledoc """
  The in-memory `BarkparkCloud.GitHub.Client` — the default in dev/test. No
  network, no App private key, no cost. Deterministic AND inspectable:

    * ids/tokens/logins are a pure function of their inputs (SHA-256, truncated),
      so tests assert exact values with nothing stored;
    * side effects (created repos, pushed files, registered webhooks) are
      recorded in the CALLING PROCESS's dictionary — async-safe under
      `async: true` (the Router runs in the test process via `Plug.Test`, exactly
      like `StudioLinkFakeHttpClient` / `Notifications.FakeHttpClient`), with no
      global state to reset between tests.

  ## What is a "valid" installation

  An `installation_id` that parses to a POSITIVE integer is treated as a live
  installation whose account login is `"octo-<id>"`; anything else (the sentinel
  `invalid_installation_id/0`, `"0"`) resolves to `{:error, :not_found}`. That
  gives the connect endpoint a known-good and a known-bad id without any stored
  fixtures or a signing secret.
  """
  @behaviour BarkparkCloud.GitHub.Client

  @repos_key :github_fake_repos
  @pushes_key :github_fake_pushes
  @webhooks_key :github_fake_webhooks

  @doc "A sentinel installation id the fake ALWAYS rejects as `:not_found`. For tests."
  @spec invalid_installation_id() :: String.t()
  def invalid_installation_id, do: "0"

  @impl true
  def get_installation(installation_id) do
    case positive_id(installation_id) do
      {:ok, id} -> {:ok, %{account_login: "octo-#{id}"}}
      :error -> {:error, :not_found}
    end
  end

  @impl true
  def exchange_installation_token(installation_id) do
    case positive_id(installation_id) do
      {:ok, id} -> {:ok, "ghs_fake_" <> digest(id)}
      :error -> {:error, :not_found}
    end
  end

  @impl true
  def create_repo(installation_id, name, private?)
      when is_binary(name) and is_boolean(private?) do
    with {:ok, id} <- positive_id(installation_id) do
      repo = %{
        "full_name" => "octo-#{id}/#{name}",
        "name" => name,
        "private" => private?
      }

      record(@repos_key, repo)
      {:ok, repo}
    else
      :error -> {:error, :not_found}
    end
  end

  @impl true
  def push_files(installation_id, repo_full_name, files, message)
      when is_binary(repo_full_name) and is_list(files) and is_binary(message) do
    with {:ok, _id} <- positive_id(installation_id) do
      record(@pushes_key, %{repo: repo_full_name, files: files, message: message})
      {:ok, %{pushed: length(files)}}
    else
      :error -> {:error, :not_found}
    end
  end

  @impl true
  def register_webhook(installation_id, repo_full_name, url, secret)
      when is_binary(repo_full_name) and is_binary(url) and is_binary(secret) do
    with {:ok, _id} <- positive_id(installation_id) do
      hook = %{
        "id" => 1,
        "config" => %{"url" => url, "content_type" => "json"},
        "events" => ["push"],
        "active" => true
      }

      # The secret is recorded for test inspection but is NOT part of the returned
      # map (GitHub never echoes a webhook secret back either). Idempotent by
      # (repo, url): GitHub keeps one hook per delivery url, and a re-connect of
      # the same repo→site REPLACES that hook rather than minting a duplicate —
      # so `registered_webhooks` stays at exactly one entry across re-connects.
      record_webhook(%{repo: repo_full_name, url: url, secret: secret})
      {:ok, hook}
    else
      :error -> {:error, :not_found}
    end
  end

  @impl true
  def list_repos(installation_id) do
    case positive_id(installation_id) do
      {:ok, id} ->
        {:ok, [%{"full_name" => "octo-#{id}/example", "private" => false}]}

      :error ->
        {:error, :not_found}
    end
  end

  ## Test inspection helpers ────────────────────────────────────────────────

  @doc "Every repo created via `create_repo/3` in this process, in call order."
  def created_repos, do: Enum.reverse(Process.get(@repos_key, []))

  @doc "Every `push_files/4` batch in this process, in call order."
  def pushes, do: Enum.reverse(Process.get(@pushes_key, []))

  @doc "Every webhook registered via `register_webhook/4` in this process, in call order."
  def registered_webhooks, do: Enum.reverse(Process.get(@webhooks_key, []))

  @doc "Clear the recorded side effects for this process."
  def reset do
    Process.delete(@repos_key)
    Process.delete(@pushes_key)
    Process.delete(@webhooks_key)
    :ok
  end

  ## Internals ───────────────────────────────────────────────────────────────

  defp record(key, item), do: Process.put(key, [item | Process.get(key, [])])

  # Upsert a webhook by (repo, url): a re-registration to the same delivery url
  # replaces the prior entry (models GitHub's one-hook-per-url), so a re-connect
  # never leaves two hooks behind.
  defp record_webhook(%{repo: repo, url: url} = hook) do
    existing = Process.get(@webhooks_key, [])
    kept = Enum.reject(existing, fn h -> h.repo == repo and h.url == url end)
    Process.put(@webhooks_key, [hook | kept])
  end

  # A positive-integer installation id → {:ok, int}; everything else → :error.
  defp positive_id(id) when is_integer(id) and id > 0, do: {:ok, id}
  defp positive_id(id) when is_integer(id), do: :error

  defp positive_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> :error
    end
  end

  defp positive_id(_), do: :error

  defp digest(term) do
    term
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 24)
  end
end
