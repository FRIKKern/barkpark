defmodule Barkpark.Media.Storage.Actor do
  @moduledoc """
  Who holds an asset's checkout lock — the ONE stamp `checkedOutBy` is written
  with and compared against (task-36a302b2e981d5e1).

  Ruling (lead, run7 2026-10-06): a human principal is stamped by stable id,
  never by email.

    * an account session → `"user:<user_id>"`
    * an API token       → its label (unchanged)
    * anything else      → `"api"`

  `V1.MediaController` (checkout / undo-checkout) and `Media.Storage.Access`
  (the metadata-edit gate) both read it, so the lock a principal takes is the
  lock the gate recognises. Before this they had two copies: the controller
  stamped the account email, the gate had no account arm and answered `"api"`,
  so an editor was locked out of an asset they had checked out themselves.

  BACK-COMPAT, read side only: rows written before this carry the account email.
  `aliases` holds the current account's email, so `holds?/2` still matches that
  legacy stamp to the same account, and the next checkout or release rewrites it
  to `"user:<id>"`. No bulk migration.
  """

  @enforce_keys [:label]
  defstruct label: "api", aliases: []

  @type t :: %__MODULE__{label: String.t(), aliases: [String.t()]}

  @doc "The actor for a conn, socket or assigns map."
  @spec of(Plug.Conn.t() | Phoenix.LiveView.Socket.t() | map()) :: t()
  def of(%{assigns: assigns}) when is_map(assigns), do: of_assigns(assigns)
  def of(assigns) when is_map(assigns), do: of_assigns(assigns)

  defp of_assigns(assigns) do
    case assigns[:api_token] do
      %{label: label} when is_binary(label) and label != "" ->
        %__MODULE__{label: label}

      _ ->
        case assigns[:current_user] do
          %{id: id} = user when is_binary(id) ->
            %__MODULE__{label: "user:" <> id, aliases: legacy_aliases(user)}

          _ ->
            %__MODULE__{label: "api"}
        end
    end
  end

  defp legacy_aliases(%{email: email}) when is_binary(email) and email != "", do: [email]
  defp legacy_aliases(_), do: []

  @doc "Whether `holder` (a `checkedOutBy` value) is this actor."
  @spec holds?(t(), term()) :: boolean()
  def holds?(%__MODULE__{label: label, aliases: aliases}, holder) when is_binary(holder),
    do: holder == label or holder in aliases

  def holds?(_actor, _holder), do: false

  @doc """
  How a `checkedOutBy` value is shown to `viewer`: `nil` when nobody holds it,
  `"you"` for the viewer's own lock, a token's label as is, the holder's
  display name (task-cfb6ca3f5ffaf099) when it's a `"user:<id>"` stamp and
  that account has one set, and `"another editor"` for any other account —
  including a `"user:<id>"` stamp whose account has no display name set, or a
  legacy email stamp from before the no-email ruling. Never an email, never a
  raw `user:` id.
  """
  @spec display(term(), t() | nil) :: String.t() | nil
  def display(holder, _viewer) when holder in [nil, ""], do: nil

  def display(holder, viewer) when is_binary(holder) do
    cond do
      viewer && holds?(viewer, holder) -> "you"
      true -> account_display(holder)
    end
  end

  def display(_holder, _viewer), do: nil

  defp account_display("user:" <> id) do
    case Barkpark.Accounts.get_user(id) do
      %{display_name: name} when is_binary(name) and name != "" -> name
      _ -> "another editor"
    end
  end

  defp account_display(holder) do
    if String.contains?(holder, "@"), do: "another editor", else: holder
  end
end
