defmodule Barkpark.Auth.TokenSeatRepair do
  @moduledoc """
  Seat an existing API token in more workspaces, from the server itself. It
  is the repair for a token that lost seats, such as an admin token Barkpark
  Cloud rotated before the rotation carried every seat
  (task-86e3a3a0c885097a). Over HTTP a token gains a seat only from a mint by
  a principal that administers that workspace (`Auth.mint_delegated_token/3`);
  this path is for the operator with a root shell on the box, the same
  authority as `Barkpark.Auth.AdminTokenRecovery`.

      cd api && MIX_ENV=prod nice -n 19 mix barkpark.token_seat \\
        --token <token id> --workspace <slug> [--workspace <slug>] [--apply]

  A run without `--apply` changes nothing and prints what it would seat. The
  role is `Tenancy.Auth.role_for_permissions/1` of the token's permissions,
  the role a mint gives its home seat. A workspace the token is already seated
  in is left as it is. Each new seat and a `token/token_seated` audit row
  commit in one transaction. Only ids, slugs and roles are printed.
  """

  import Ecto.Query, warn: false

  alias Barkpark.{Audit, Repo, Tenancy}
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @type plan :: %{
          token_id: binary(),
          role: String.t(),
          seat: [String.t()],
          already: [String.t()]
        }

  @doc """
  Seat `token_id` in `slugs`. Options: `:apply` (default `false`, a dry run).
  Returns the plan, and with `:apply` the seats are written. Errors:
  `:token_not_found`, `:token_not_live` (revoked, expired or not an `api`
  token), `{:unknown_workspace, slug}`, `:no_workspace`, or a write error.
  """
  @spec seat(binary(), [String.t()], keyword()) :: {:ok, plan()} | {:error, term()}
  def seat(token_id, slugs, opts \\ []) when is_binary(token_id) and is_list(slugs) do
    apply? = Keyword.get(opts, :apply, false) == true

    with {:ok, token} <- live_token(token_id),
         {:ok, workspaces} <- workspaces(slugs) do
      role = TenancyAuth.role_for_permissions(token.permissions || [])

      {already, seat} =
        Enum.split_with(workspaces, &(TenancyAuth.membership_role(token.id, &1.id) != nil))

      plan = %{
        token_id: token.id,
        role: role,
        seat: Enum.map(seat, & &1.slug),
        already: Enum.map(already, & &1.slug)
      }

      if apply? and seat != [], do: write(token, seat, role, plan), else: {:ok, plan}
    end
  end

  defp live_token(token_id) do
    now = DateTime.utc_now()

    with uuid when is_binary(uuid) <- Repo.uuid_or_nil(token_id),
         %ApiToken{} = token <- Repo.get(ApiToken, uuid) do
      live? =
        token.kind == "api" and is_nil(token.revoked_at) and
          (is_nil(token.expires_at) or DateTime.compare(token.expires_at, now) == :gt)

      if live?, do: {:ok, token}, else: {:error, :token_not_live}
    else
      _ -> {:error, :token_not_found}
    end
  end

  defp workspaces(slugs) do
    slugs
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> case do
      [] ->
        {:error, :no_workspace}

      list ->
        Enum.reduce_while(list, {:ok, []}, fn slug, {:ok, acc} ->
          case Tenancy.get_workspace_by_slug(slug) do
            nil -> {:halt, {:error, {:unknown_workspace, slug}}}
            ws -> {:cont, {:ok, acc ++ [ws]}}
          end
        end)
    end
  end

  defp write(token, workspaces, role, plan) do
    Repo.transaction(fn ->
      Enum.each(workspaces, fn ws ->
        with {:ok, _} <- TenancyAuth.create_membership(ws.id, token.id, role, "api_token"),
             {:ok, _} <- audit(token, ws, role) do
          :ok
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

      plan
    end)
    |> case do
      {:ok, plan} ->
        Enum.each(workspaces, &Barkpark.Tenancy.Members.announce_seats_changed(&1.id))
        {:ok, plan}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp audit(token, ws, role) do
    Audit.emit(%{
      category: "token",
      action: "token_seated",
      subject: token.id,
      actor_type: "system",
      actor_id: "server-side token seat",
      workspace_id: ws.id,
      metadata: %{
        "via" => "server-side seat (mix barkpark.token_seat)",
        "label" => token.label,
        "role" => role
      }
    })
  end

  @doc """
  Parse command-line arguments, seat, and print the outcome. Returns the exit
  status: 0 done (or dry run), 1 refused, 2 usage.
  """
  @spec cli([String.t()]) :: 0 | 1 | 2
  def cli(argv) do
    case OptionParser.parse(argv,
           strict: [token: :string, workspace: :keep, apply: :boolean, help: :boolean]
         ) do
      {opts, [], []} ->
        cond do
          opts[:help] -> usage(:stdio, 0)
          is_nil(opts[:token]) -> usage(:stderr, 2)
          true -> run(opts)
        end

      _ ->
        usage(:stderr, 2)
    end
  end

  defp run(opts) do
    apply? = opts[:apply] == true

    case seat(opts[:token], Keyword.get_values(opts, :workspace), apply: apply?) do
      {:ok, plan} ->
        verb = if apply?, do: "Seated", else: "Would seat (dry run, pass --apply)"
        IO.puts("Token #{plan.token_id}, role #{plan.role}.")
        IO.puts("#{verb}: #{list(plan.seat)}")
        IO.puts("Already seated: #{list(plan.already)}")
        0

      {:error, reason} ->
        IO.puts(:stderr, "token-seat: " <> message(reason))
        1
    end
  end

  defp list([]), do: "none"
  defp list(slugs), do: Enum.join(slugs, ", ")

  defp message(:token_not_found), do: "no token has that id."
  defp message(:token_not_live), do: "that token is revoked, expired or not an API token."
  defp message({:unknown_workspace, slug}), do: "no workspace has the slug #{inspect(slug)}."
  defp message(:no_workspace), do: "name at least one --workspace."
  defp message(other), do: "seat failed: #{inspect(other)}. Nothing was written."

  defp usage(device, status) do
    IO.puts(device, """
    usage: mix barkpark.token_seat --token <id> --workspace <slug> [--workspace <slug>] [--apply]

    Seats an existing API token in the named workspaces with the role its
    permissions give. Without --apply nothing is written.\
    """)

    status
  end
end
