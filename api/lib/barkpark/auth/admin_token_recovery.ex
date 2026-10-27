defmodule Barkpark.Auth.AdminTokenRecovery do
  @moduledoc """
  Mint a new admin token from the server itself, for an operator who has lost
  the admin token file.

  It is the supported recovery path on a self-hosted box. On a VM:

      sudo /opt/barkpark/api/start.sh admin-token --label "admin (recovered)"

  In the container image (`az containerapp exec`):

      /app/bin/admin-token --label "admin (recovered)" --file /tmp/admin-token

  The token goes to the default workspace with `read`, `write` and `admin`,
  the same grant the clean seed gives its first admin token. The raw value is
  written only to `file` (mode 0600, default `/etc/barkpark/admin-token`) and
  the row id to `file <> ".id"`. Nothing prints the raw value.

  An existing `file` is left alone unless `force: true`. The token is written
  to a temporary file in the same directory first and renamed into place only
  after the database row exists, so a failed mint never replaces a working
  file.

  The mint and a `token/admin_token_recovery_mint` audit row commit in one
  transaction.
  """

  alias Barkpark.{Audit, Auth, Repo, Tenancy}

  # The clean seed's dataset (`Barkpark.Seeds.Shared.dataset/0`). Written as a
  # literal so auth does not depend on seeds; the boundary baseline has no
  # auth>seeds edge.
  @dataset "production"
  @default_file "/etc/barkpark/admin-token"
  @permissions ["read", "write", "admin"]

  @doc "The token file used when the caller names none."
  def default_file, do: @default_file

  @type result :: %{
          id: binary(),
          file: String.t(),
          id_file: String.t(),
          workspace_id: binary()
        }

  @doc """
  Mint the token. Options:

    * `:label` (required) - the token label.
    * `:file` - where the raw token goes. Default `#{@default_file}`.
    * `:force` - replace an existing `:file`.

  Errors: `:missing_label`, `{:file_exists, path}`, `:no_default_workspace`,
  `{:write_failed, path, reason}`, or the mint or audit error.
  """
  @spec mint(keyword()) :: {:ok, result()} | {:error, term()}
  # The path is OPERATOR input from a root shell (--file, or the fixed
  # /etc/barkpark default). No request path reaches this module; its callers
  # are a mix task and a release eval, so there is no traversal to steer.
  # sobelow_skip ["Traversal.FileModule"]
  def mint(opts) do
    label = opts |> Keyword.get(:label, "") |> to_string() |> String.trim()
    file = Keyword.get(opts, :file) || @default_file
    force? = Keyword.get(opts, :force, false) == true

    with :ok <- check_label(label),
         :ok <- check_free(file, force?),
         {:ok, workspace} <- default_workspace(),
         raw = "bp_admin_" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false),
         {:ok, tmp} <- write_private(file, raw) do
      case insert(raw, label, file, workspace) do
        {:ok, token} ->
          finish(tmp, file, token, workspace)

        {:error, _} = err ->
          File.rm(tmp)
          err
      end
    end
  end

  defp check_label(""), do: {:error, :missing_label}
  defp check_label(_), do: :ok

  defp check_free(file, true = _force?) when is_binary(file), do: :ok

  defp check_free(file, false) do
    if File.exists?(file), do: {:error, {:file_exists, file}}, else: :ok
  end

  defp default_workspace do
    case Tenancy.get_default_workspace() do
      nil -> {:error, :no_default_workspace}
      workspace -> {:ok, workspace}
    end
  end

  # Create the directory (0700 when this call creates it), then a temporary
  # file that is chmod 0600 before any byte of the token is written.
  # sobelow_skip ["Traversal.FileModule"]
  defp write_private(file, raw) do
    dir = Path.dirname(file)
    tmp = Path.join(dir, ".#{Path.basename(file)}.#{System.unique_integer([:positive])}.tmp")

    with :ok <- ensure_dir(dir),
         {:ok, io} <- File.open(tmp, [:write, :exclusive, :binary]) do
      result =
        with :ok <- File.chmod(tmp, 0o600) do
          IO.binwrite(io, raw <> "\n")
        end

      File.close(io)

      case result do
        :ok ->
          {:ok, tmp}

        {:error, reason} ->
          File.rm(tmp)
          {:error, {:write_failed, file, reason}}
      end
    else
      {:error, reason} -> {:error, {:write_failed, file, reason}}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp ensure_dir(dir) do
    if File.dir?(dir) do
      :ok
    else
      with :ok <- File.mkdir_p(dir), do: File.chmod(dir, 0o700)
    end
  end

  defp insert(raw, label, file, workspace) do
    Repo.transaction(fn ->
      with {:ok, token} <-
             Auth.create_token(raw, label, @dataset, @permissions, workspace.id),
           {:ok, _event} <-
             Audit.emit(%{
               category: "token",
               action: "admin_token_recovery_mint",
               subject: token.id,
               actor_type: "system",
               actor_id: "server-side recovery",
               workspace_id: workspace.id,
               metadata: %{
                 "via" => "server-side recovery mint (mix barkpark.admin_token)",
                 "label" => token.label,
                 "permissions" => token.permissions,
                 "file" => file,
                 "host" => host()
               }
             }) do
        token
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp finish(tmp, file, token, workspace) do
    id_file = file <> ".id"

    with :ok <- rename(tmp, file) do
      result = %{id: token.id, file: file, id_file: id_file, workspace_id: workspace.id}

      with {:ok, id_tmp} <- write_private(id_file, token.id),
           :ok <- rename(id_tmp, id_file) do
        {:ok, result}
      else
        {:error, {:write_failed, _, reason}} -> {:error, {:id_file_failed, result, reason}}
      end
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp rename(from, to) do
    case File.rename(from, to) do
      :ok ->
        :ok

      {:error, reason} ->
        File.rm(from)
        {:error, {:write_failed, to, reason}}
    end
  end

  defp host do
    case :inet.gethostname() do
      {:ok, name} -> to_string(name)
      _ -> "unknown"
    end
  end

  @doc """
  Parse command-line arguments, mint, and print the outcome. Returns the exit
  status. Shared by `mix barkpark.admin_token` and `Barkpark.Release`.
  """
  @spec cli([String.t()]) :: 0 | 1 | 2
  def cli(argv) do
    case OptionParser.parse(argv,
           strict: [label: :string, file: :string, force: :boolean, help: :boolean]
         ) do
      {opts, [], []} ->
        if opts[:help], do: usage(:stdio, 0), else: run(opts)

      _ ->
        usage(:stderr, 2)
    end
  end

  defp run(opts) do
    case mint(opts) do
      {:ok, r} ->
        IO.puts("""
        Admin token id: #{r.id}
        Token written to #{r.file} (mode 0600). Id written to #{r.id_file}.
        Workspace: #{r.workspace_id} (default).
        If BARKPARK_OPERATOR_EMAILS or BARKPARK_OPERATOR_FAIL_CLOSED is set, add
        the id to BARKPARK_OPERATOR_TOKEN_IDS and restart to reach operator routes.\
        """)

        0

      {:error, reason} ->
        IO.puts(:stderr, "admin-token: " <> message(reason))
        1
    end
  end

  defp message(:missing_label), do: "--label is required."

  defp message({:file_exists, file}),
    do: "#{file} already exists. Pass --force to replace it, or name another file with --file."

  defp message(:no_default_workspace),
    do: "this instance has no default workspace. Run the seed first."

  defp message({:write_failed, file, reason}),
    do:
      "could not write #{file}: #{:file.format_error(reason)}. Name a writable path with --file. No token was minted."

  defp message({:id_file_failed, r, reason}),
    do:
      "token #{r.id} was minted and written to #{r.file}, but #{r.id_file} could not be written: #{:file.format_error(reason)}."

  defp message(other), do: "mint failed: #{inspect(other)}. No token was minted."

  defp usage(device, status) do
    IO.puts(device, """
    usage: admin-token --label <label> [--file <path>] [--force]

    Mints an admin token in the default workspace. The token goes to <path>
    (default #{@default_file}, mode 0600) and its id to <path>.id. Only the id
    and the path are printed. An existing <path> is kept unless --force.\
    """)

    status
  end
end
