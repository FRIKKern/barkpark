defmodule Barkpark.SelfUpdate.FailureReport do
  @moduledoc """
  What a failed self-update (or rollback) run tells the control plane: the
  phase it failed in and a short, redacted tail of its log.

  Before this, the reason a box's update failed lived only on the box, in
  `.deploy-status.json` (deploy-rebuild.sh's flight record) and the run log, so
  an operator needed SSH to learn whether the build or the migration broke.
  The report rides the EXISTING path: `GET /v1/admin/self-update` (which
  Barkpark Cloud already polls through `Registry.refresh_update_status/1`)
  gains a `failure` key next to `state` / `exit_code`.

  ## Phase

  Taken from deploy-rebuild.sh's flight record when it belongs to this run
  (`source: "deploy_status"`), else from the exit code the scripts document
  (`source: "exit_code"`): 1 build, 13 migrate, 15 restart (unverified),
  2 merge (fast-forward refused), 3 slot (deploy-rebuild refused a slot box),
  -1 runner (port closed), -2 deadline, -3 interrupted. Any other code is
  `fetch` when the log never reached the rebuild, else `unknown`.

  ## Tail

  At most `#{40}` lines, the last ones of the run. Every line goes through
  `Barkpark.Sites.BuildLogScrub.raw/1` (the shared secret-pattern set) and then
  this module's own env redaction: the value of any `NAME=value` assignment
  with an upper-case name is replaced by `[redacted]`, except names on a short
  allowlist that carry no secret (`TARGET_SHA`). Lines are capped at 400 bytes.
  """

  alias Barkpark.Sites.BuildLogScrub

  @max_lines 40
  @max_line_bytes 400

  @code_phases %{
    1 => "build",
    13 => "migrate",
    15 => "restart",
    2 => "merge",
    3 => "slot",
    -1 => "runner",
    -2 => "deadline",
    -3 => "interrupted"
  }

  @failed_outcomes ["failed", "unverified"]

  # Env names whose values carry no secret and help the reader.
  @env_allow ~w(TARGET_SHA MIX_ENV)

  # `NAME=value`, `export NAME=value`, `NAME="va lue"`. The name must start a
  # word so `phase=build` (lower case) and `--flag=x` are left alone.
  @env_assign ~r/(?<![A-Za-z0-9_])([A-Z][A-Z0-9_]*[A-Z0-9])=("[^"]*"|'[^']*'|[^\s"']+)/

  @doc "The tail line cap."
  def max_lines, do: @max_lines

  @doc """
  The failure report for a finished run, or `nil` for a run that is idle,
  running or succeeded (exit 0).

  `log` is the run's lines oldest first; `deploy_status` is deploy-rebuild's
  flight record when it belongs to this run (or `nil`).
  """
  @spec build(integer() | nil, [String.t()], map() | nil) :: map() | nil
  def build(exit_code, log, deploy_status \\ nil)

  def build(code, log, deploy_status) when is_integer(code) and code != 0 do
    {phase, source} = phase(code, log, deploy_status)
    %{phase: phase, source: source, exit_code: code, tail: tail(log)}
  end

  def build(_code, _log, _deploy_status), do: nil

  @doc false
  def phase(_code, _log, %{"phase" => phase, "outcome" => outcome})
      when is_binary(phase) and outcome in @failed_outcomes,
      do: {phase, "deploy_status"}

  def phase(code, log, _deploy_status) do
    case Map.fetch(@code_phases, code) do
      {:ok, phase} -> {phase, "exit_code"}
      :error -> {if(reached_rebuild?(log), do: "unknown", else: "fetch"), "exit_code"}
    end
  end

  defp reached_rebuild?(log),
    do: Enum.any?(List.wrap(log), &(is_binary(&1) and String.contains?(&1, "merge done")))

  @doc "The last `#{40}` lines, scrubbed and env-redacted."
  @spec tail([String.t()]) :: [String.t()]
  def tail(log) do
    log
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.take(-@max_lines)
    |> Enum.map(&redact_line/1)
  end

  @doc "One line through the shared secret scrub, then env-value redaction and the byte cap."
  @spec redact_line(String.t()) :: String.t()
  def redact_line(line) when is_binary(line) do
    line
    |> BuildLogScrub.raw()
    |> redact_env()
    |> cap()
  end

  defp redact_env(line) do
    Regex.replace(@env_assign, line, fn whole, name, _value ->
      if name in @env_allow, do: whole, else: name <> "=[redacted]"
    end)
  end

  defp cap(line) when byte_size(line) <= @max_line_bytes, do: line

  defp cap(line) do
    # Cut on a character boundary, then mark the cut.
    String.slice(line, 0, @max_line_bytes) <> " …[cut]"
  end
end
