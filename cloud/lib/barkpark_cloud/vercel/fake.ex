defmodule BarkparkCloud.Vercel.Fake do
  @moduledoc """
  The in-memory `BarkparkCloud.Vercel.Client` — the default in dev/test. No
  network, no platform token, no cost. Deterministic AND inspectable, mirroring
  `GitHub.Fake`:

    * ids/urls/codes are a pure function of their inputs (SHA-256, truncated),
      so tests assert exact values with nothing stored;
    * side effects (deployed projects, minted codes) are recorded in the CALLING
      PROCESS's dictionary — async-safe under `async: true` (the Router runs in
      the test process via `Plug.Test`), no global state to reset.

  ## Failure sentinels

  A project name starting with `"fail-"` makes `deploy_project/3` return
  `{:error, :deploy_failed}`; the project id `invalid_project_id/0` makes
  `create_transfer_code/1` return `{:error, :not_found}` — a known-bad path for
  every context branch without fixtures or a token.

  ## Driving the claim-completion read (cch-w48)

  `claimed?/1` answers `{:ok, false}` by default — a project we just deployed
  is still ours. `mark_claimed/1` makes it answer `{:ok, true}` (the user
  completed the irreversible transfer), and `mark_unreadable/1` makes it answer
  `{:error, :read_failed}` (we cannot tell). Both are per-PROCESS, like the
  other fake state, so the claimed state is reachable from a test without a
  token, a network, or a local column.
  """
  @behaviour BarkparkCloud.Vercel.Client

  @deploys_key :vercel_fake_deploys
  @codes_key :vercel_fake_codes
  @claimed_key :vercel_fake_claimed
  @unreadable_key :vercel_fake_unreadable

  @doc "A sentinel project id the fake ALWAYS rejects as `:not_found`. For tests."
  @spec invalid_project_id() :: String.t()
  def invalid_project_id, do: "prj_invalid"

  @impl true
  def deploy_project(name, files, env_vars)
      when is_binary(name) and is_list(files) and is_list(env_vars) do
    cond do
      String.starts_with?(name, "fail-") ->
        {:error, :deploy_failed}

      files == [] ->
        {:error, :no_files}

      true ->
        project_id = "prj_fake_" <> digest(name)
        url = "https://" <> name <> "-fake.vercel.app"

        record(@deploys_key, %{
          project_id: project_id,
          name: name,
          files: length(files),
          env_keys: Enum.map(env_vars, & &1.key) |> Enum.sort()
        })

        {:ok, %{project_id: project_id, deployment_url: url}}
    end
  end

  @impl true
  def create_transfer_code(project_id) when is_binary(project_id) do
    if project_id == invalid_project_id() do
      {:error, :not_found}
    else
      code = "clm_fake_" <> digest(project_id)
      record(@codes_key, %{project_id: project_id, code: code})
      {:ok, code}
    end
  end

  @impl true
  def claimed?(project_id) when is_binary(project_id) do
    cond do
      project_id in Process.get(@unreadable_key, []) -> {:error, :read_failed}
      project_id in Process.get(@claimed_key, []) -> {:ok, true}
      true -> {:ok, false}
    end
  end

  @doc "Make `claimed?/1` report `project_id` as already transferred, in THIS process."
  @spec mark_claimed(String.t()) :: :ok
  def mark_claimed(project_id) when is_binary(project_id) do
    Process.put(@claimed_key, [project_id | Process.get(@claimed_key, [])])
    :ok
  end

  @doc "Make `claimed?/1` fail for `project_id` — the \"cannot tell\" arm, in THIS process."
  @spec mark_unreadable(String.t()) :: :ok
  def mark_unreadable(project_id) when is_binary(project_id) do
    Process.put(@unreadable_key, [project_id | Process.get(@unreadable_key, [])])
    :ok
  end

  @doc "The deploys recorded in THIS process (for test assertions)."
  @spec deploys() :: [map()]
  def deploys, do: Process.get(@deploys_key, [])

  @doc "The transfer codes minted in THIS process (for test assertions)."
  @spec codes() :: [map()]
  def codes, do: Process.get(@codes_key, [])

  ## Internals ───────────────────────────────────────────────────────────────

  defp record(key, entry), do: Process.put(key, Process.get(key, []) ++ [entry])

  defp digest(input) do
    :crypto.hash(:sha256, to_string(input))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 12)
  end
end
