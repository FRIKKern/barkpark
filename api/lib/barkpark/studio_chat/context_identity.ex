defmodule Barkpark.StudioChat.ContextIdentity do
  @moduledoc """
  WHICH HOST RUNS THIS SESSION, AGAINST WHICH SERVER AND SCOPE — the Studio half
  of the chat context identity (`chat-local-cloud-context-w3`, criterion 2). The
  CLI half is `internal/chat/context.go`; this module speaks the SAME vocabulary
  so the two surfaces cannot answer the same question differently.

  A Studio chat runs either on the server itself or on an enrolled chat host
  (the `chat_execution_leases` fence), in a `cwd` recorded on the session row,
  against the session's own workspace — and the transcript header used to show
  none of it. This module is the projection that fixes that: a list of typed
  fields, resolved from SERVER TRUTH, rendered by `ChatLive`.

  ## The two laws, carried over verbatim from the CLI half

  1. **A displayed value comes from the ACTUAL binding wherever one exists.**
     The execution host is the host holding the session's live lease — the
     fence a host report is validated against — never the `execution_host_id`
     the session row happens to remember. The workspace is the session's own
     `owner_workspace_id`, never the workspace the viewer happens to be
     browsing. Where the two disagree the field shows the ACTUAL value and
     REPORTS the disagreement beside it (`mismatch?: true`, which `ChatLive`
     paints as ⚠). A surface that prints the viewer's scope while the session
     runs in another is precisely how a wrong session reads as a right one.

  2. **Absence is visible and TYPED.** `(not set)` (measured — nothing is
     configured), `(unknown)` (nobody can answer), `(not a git repo)` (measured
     — the directory is outside a work tree) and `(server-local)` (measured —
     no host lease, the server itself runs it) are four different facts. None
     renders as a blank, and none renders as a plausible default. This matters
     most on DATASET: `ChatLive`'s mount substitutes `default_dataset()` (the
     first dataset, else the literal `"production"`) because no chat route
     carries a `:dataset` segment — so an unset dataset would otherwise reach
     the eye as the word "production", the single value most likely to be
     wrong, wearing the costume of a deliberate choice. The absence stays the
     headline and the substitution is reported next to it.

  ## What the repository root can and cannot be

  The REPO field is the one place Studio cannot match the CLI's confidence.
  For a `registered_host` session the repository root is a HOST-side fact, and
  the chat-host protocol carries no such report: a host declares `name`,
  `approved_roots` and provider `capabilities` at enrollment
  (`Barkpark.ChatHosts.RegisteredHost`) and afterwards emits only execution
  events and state reports — nothing that names a git work tree. So the honest
  rendering is `(unknown)`, with the session's `cwd` named beside it, and NOT
  a probe run on the server against a path that does not exist there. For a
  `managed` session the cwd IS a server-local path, so the probe is a real
  measurement and `(not a git repo)` is a real, reachable answer.

  Nothing here renders. `ChatLive` paints it.
  """

  alias Barkpark.StudioChat.ContextIdentity.Field

  defstruct fields: []

  @type t :: %__MODULE__{fields: [Field.t()]}

  # The absence markers. Distinct strings on purpose (law 2): a reader must be
  # able to tell "nothing is set" from "nobody can tell" from "the server runs
  # it" from a real value at a glance, and none of them can be mistaken for a
  # value — every one is parenthesised, which no host name, slug, URL or path
  # ever is.
  @unset "(not set)"
  @unknown "(unknown)"
  @no_repo "(not a git repo)"
  @server_local "(server-local)"

  @doc "The marker for a measured, empty value."
  def unset_marker, do: @unset

  @doc "The marker for a value nobody can answer."
  def unknown_marker, do: @unknown

  @doc "The marker for a cwd that is outside a git work tree."
  def no_repo_marker, do: @no_repo

  @doc "The marker for a session no enrolled host holds a lease on."
  def server_local_marker, do: @server_local

  @doc "The field names, in paint order. The band renders exactly these six."
  def field_names, do: ~w(host server workspace project dataset repo)

  defmodule Field do
    @moduledoc """
    One line-item of the identity: a name, a three-way status, the value when
    there is one, the visible marker when there is not, and — when two truths
    disagree — the disagreement, in text.
    """

    defstruct name: nil, status: :unknown, value: nil, absent: nil, note: nil, mismatch?: false

    @type status :: :set | :unset | :unknown
    @type t :: %__MODULE__{
            name: String.t(),
            status: status(),
            value: String.t() | nil,
            absent: String.t() | nil,
            note: String.t() | nil,
            mismatch?: boolean()
          }

    @doc """
    The field's rendered text. It can NEVER return an empty string: a band that
    renders "" where a value belongs is the exact failure mode this module
    exists to prevent, so the fallback is the loudest honest marker rather than
    a blank. The note (a disagreement, or a qualification) rides after it.
    """
    def display(%__MODULE__{} = field) do
      base =
        case field do
          %{status: :set, value: value} when is_binary(value) and value != "" -> value
          %{absent: absent} when is_binary(absent) and absent != "" -> absent
          _ -> "(unknown)"
        end

      case field.note do
        note when is_binary(note) and note != "" -> base <> " " <> note
        _ -> base
      end
    end
  end

  @doc """
  Build the identity from server truth.

  `facts` is a plain map — every key is a fact somebody else measured, so this
  function is pure apart from `:repo_probe`, which owns the one syscall:

    * `:lease_host` — name of the host holding the session's LIVE execution
      lease (`ChatHosts.live_report_fence/2`), or nil when none does
    * `:reporting_host` — name of the host that sent the session's most recent
      execution event, or nil
    * `:endpoint` — this Barkpark server's runtime URL
    * `:viewer_workspace` — the workspace slug the VIEWER is acting in
    * `:session_workspace` — the slug of the session's `owner_workspace_id`
    * `:project` — the project slug in the viewer's scope, or nil
    * `:scope_dataset` — the dataset named by the URL scope, or nil
    * `:mount_dataset` — the dataset `ChatLive` actually uses
    * `:execution_target` — `"managed"` or `"registered_host"`
    * `:cwd` — the session's working directory
    * `:repo_probe` — `(cwd -> {:ok, root} | {:error, :not_a_repo} | {:error, :unknown})`
  """
  def resolve(facts) when is_map(facts) do
    %__MODULE__{
      fields: [
        host_field(fact(facts, :lease_host), fact(facts, :reporting_host)),
        server_field(fact(facts, :endpoint)),
        workspace_field(fact(facts, :viewer_workspace), fact(facts, :session_workspace)),
        project_field(fact(facts, :project)),
        dataset_field(fact(facts, :scope_dataset), fact(facts, :mount_dataset)),
        repo_field(
          fact(facts, :execution_target),
          fact(facts, :cwd),
          Map.get(facts, :repo_probe) || (&repo_probe_default/1)
        )
      ]
    }
  end

  @doc """
  The named field. The lookup exists so tests and callers address a field BY
  NAME rather than by position — a positional read is how a reordered list
  turns into a silently wrong reading, and this list is reordered by anyone
  who redesigns the band.
  """
  def field(%__MODULE__{fields: fields}, name) when is_binary(name),
    do: Enum.find(fields, &(&1.name == name))

  @doc "The fields whose two truths disagree — what ⚠ is painted on."
  def mismatches(%__MODULE__{fields: fields}), do: Enum.filter(fields, & &1.mismatch?)

  # ── the six fields ──────────────────────────────────────────────────────────

  # The EXECUTION HOST. The live lease is the actual binding (it is the fence a
  # host report is validated against), so it is what the band displays. A
  # session no host holds is not "unknown" and certainly not blank — it runs
  # HERE, and `(server-local)` says exactly that. A last report from a host
  # OTHER than the lease holder is the lease-transfer anomaly: the lease wins
  # the headline (it is who may speak next) and the reporter is named beside it.
  defp host_field(lease_host, reporting_host) do
    field = %Field{name: "host", status: :unset, absent: @server_local}

    case {blank_to_nil(lease_host), blank_to_nil(reporting_host)} do
      {nil, nil} ->
        field

      {nil, reporter} ->
        %{field | mismatch?: true, note: "— the last report came from #{quoted(reporter)}"}

      {lease, reporter} when reporter in [nil, lease] ->
        %{field | status: :set, value: lease, absent: nil}

      {lease, reporter} ->
        %{
          field
          | status: :set,
            value: lease,
            absent: nil,
            mismatch?: true,
            note: "— the last report came from #{quoted(reporter)}"
        }
    end
  end

  # The BARKPARK SERVER. One truth only — the endpoint this node actually
  # serves on, read at runtime. There is no config claim to reconcile against,
  # so a missing value is UNKNOWN and never a guess.
  defp server_field(endpoint) do
    case blank_to_nil(endpoint) do
      nil -> %Field{name: "server", status: :unknown, absent: @unknown}
      url -> %Field{name: "server", status: :set, value: url}
    end
  end

  # The WORKSPACE. The session's own `owner_workspace_id` is the actual truth —
  # it is what every store gate compares against — so it is the headline, and
  # the viewer's scope is reported when the two disagree. A NULL-owned legacy
  # session genuinely has no workspace: that is `(not set)`, qualified by what
  # the viewer is scoped to, NOT a ⚠ (nothing disagrees when one side is empty).
  defp workspace_field(viewer, session_workspace) do
    field = %Field{name: "workspace", status: :unset, absent: @unset}

    case {blank_to_nil(viewer), blank_to_nil(session_workspace)} do
      {nil, nil} ->
        field

      {nil, session_ws} ->
        %{field | status: :set, value: session_ws}

      {viewer_ws, nil} ->
        %{field | note: "— the viewer is scoped to #{quoted(viewer_ws)}"}

      {viewer_ws, session_ws} when session_ws == viewer_ws ->
        %{field | status: :set, value: session_ws}

      {viewer_ws, session_ws} ->
        %{
          field
          | status: :set,
            value: session_ws,
            mismatch?: true,
            note: "— the viewer is scoped to #{quoted(viewer_ws)}"
        }
    end
  end

  # The PROJECT. One truth: the project in the viewer's URL scope. The flat
  # `/studio/chat` mount carries none — measured, empty, `(not set)`.
  defp project_field(project) do
    case blank_to_nil(project) do
      nil -> %Field{name: "project", status: :unset, absent: @unset}
      slug -> %Field{name: "project", status: :set, value: slug}
    end
  end

  # The DATASET — law 2's sharpest case. No chat route carries a `:dataset`
  # segment, so `scope_dataset` is nil and `ChatLive` runs on a SUBSTITUTED
  # dataset it chose for itself. Rendering that substitution alone would print
  # "production" as though someone picked it. The absence is the headline; the
  # substitution is reported, and it is a ⚠ because the value the chat actually
  # subscribes to was chosen by nobody.
  defp dataset_field(scope_dataset, mount_dataset) do
    field = %Field{name: "dataset", status: :unset, absent: @unset}

    case {blank_to_nil(scope_dataset), blank_to_nil(mount_dataset)} do
      {nil, nil} ->
        field

      {nil, substituted} ->
        %{field | mismatch?: true, note: "— the chat mount substitutes #{quoted(substituted)}"}

      {scoped, actual} when actual in [nil, scoped] ->
        %{field | status: :set, value: scoped}

      {scoped, actual} ->
        %{
          field
          | status: :set,
            value: actual,
            mismatch?: true,
            note: "— the scope names #{quoted(scoped)}"
        }
    end
  end

  # The REPOSITORY ROOT. See the moduledoc: host-executed sessions are
  # `(unknown)` because no host reports a work-tree root, and saying so with
  # the cwd named is the honest answer — inventing a server-side probe for a
  # path that lives on someone else's machine would answer confidently and
  # wrongly. A managed session's cwd IS server-local, so it is measured.
  defp repo_field(execution_target, cwd, probe) do
    field = %Field{name: "repo", status: :unset, absent: @unset}

    case {blank_to_nil(cwd), execution_target} do
      {nil, _} ->
        field

      {dir, "registered_host"} ->
        %{
          field
          | status: :unknown,
            absent: @unknown,
            note: "— #{quoted(dir)} on the execution host, which reports no repository root"
        }

      {dir, _managed} ->
        case probe.(dir) do
          {:ok, root} when is_binary(root) and root != "" ->
            %{field | status: :set, value: root, absent: nil}

          {:error, :not_a_repo} ->
            %{field | absent: @no_repo}

          _ ->
            %{field | status: :unknown, absent: @unknown}
        end
    end
  end

  # ── the one syscall ─────────────────────────────────────────────────────────

  @git_timeout 3_000

  @doc """
  The repo-root probe in force. Swappable through application config so tests
  drive every arm — a value, a determinate "not a repo", a probe that could not
  answer — without needing a machine that happens to be in that state.
  """
  def repo_probe,
    do: Application.get_env(:barkpark, :studio_chat_repo_root_probe, &__MODULE__.git_toplevel/1)

  @doc """
  Ask git for `cwd`'s work-tree root. It separates the two failures that look
  identical from the outside: git ANSWERING "not a work tree" (a determinate
  absence) from git never answering at all — missing binary, timeout, a cwd
  that is not even a directory (an unknown). Collapsing them would let "I could
  not run git" reach the eye as "you are not in a repo".

  Bounded at #{@git_timeout}ms: a transcript header must not hang because a
  network filesystem made `rev-parse` stall. A timeout is UNKNOWN, and unknown
  is a thing the band can say.
  """
  def git_toplevel(cwd) when is_binary(cwd) do
    # A cwd that is not a directory would make `git -C` exit 128 exactly as a
    # non-repo does; refusing it here keeps `(not a git repo)` meaning what it
    # says.
    if File.dir?(cwd) do
      run_git_toplevel(cwd)
    else
      {:error, :unknown}
    end
  end

  def git_toplevel(_), do: {:error, :unknown}

  defp run_git_toplevel(cwd) do
    task =
      Task.async(fn ->
        System.cmd("git", ["-C", cwd, "rev-parse", "--show-toplevel"], stderr_to_stdout: true)
      end)

    case Task.yield(task, @git_timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {out, 0}} ->
        case String.trim(out) do
          "" -> {:error, :unknown}
          root -> {:ok, root}
        end

      {:ok, {_out, 128}} ->
        {:error, :not_a_repo}

      _ ->
        {:error, :unknown}
    end
  end

  defp repo_probe_default(cwd), do: repo_probe().(cwd)

  # ── helpers ─────────────────────────────────────────────────────────────────

  defp fact(facts, key) do
    case Map.get(facts, key) do
      value when is_binary(value) -> String.trim(value)
      _ -> nil
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp quoted(value), do: inspect(to_string(value))
end
