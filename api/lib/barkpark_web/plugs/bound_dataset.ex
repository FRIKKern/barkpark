defmodule BarkparkWeb.Plugs.BoundDataset do
  @moduledoc """
  The dataset binding of an API token, decided once, where the token is
  resolved (plan: `/papers/bound-token-dataset-default-plan`).

  A token minted with an explicit dataset (`dataset_bound: true`) is held to
  that dataset for everything. `resolve/2` does both halves:

    * the request NAMES a dataset (the `:dataset` path segment, else a
      `dataset` param) and it is not the token's: `{:error, :forbidden_dataset}`.
      A `dataset` that is not a string (`?dataset[]=x`) names no dataset a bound
      token may have, so it is refused too.
    * the request names NONE: the token's dataset is put into `conn.params`,
      so a controller's own fallback (`params["dataset"] || "production"`)
      never fires. Before this, each controller had to remember the binding,
      and the ones that forgot sent a bound token to `production`.

  An unbound token, a user session and an anonymous caller are returned
  untouched.

  ## Endpoints that cannot take an extra param

  A few endpoints treat every param as input: the chat API refuses unknown
  keys, and the legacy `POST /api/documents/:type` copies its params into the
  document. Their pipelines call `unfill/1`, which removes the param again when
  (and only when) this module put it there. They keep the refusal half, and
  the request stays unfilled: a token plug that runs later does not fill again.
  """

  alias Barkpark.Auth.ApiToken

  @filled :bound_dataset_filled

  @spec resolve(Plug.Conn.t(), term()) :: {:ok, Plug.Conn.t()} | {:error, :forbidden_dataset}
  def resolve(conn, token) do
    case ApiToken.bound_dataset(token) do
      nil -> {:ok, conn}
      bound -> decide(conn, bound, requested(conn))
    end
  end

  @doc "Remove the `dataset` param `resolve/2` filled in. A no-op otherwise."
  @spec unfill(Plug.Conn.t()) :: Plug.Conn.t()
  def unfill(%Plug.Conn{private: %{@filled => true}, params: %{} = params} = conn) do
    %{conn | params: Map.delete(params, "dataset")}
    |> Plug.Conn.put_private(@filled, :unfilled)
  end

  def unfill(conn), do: Plug.Conn.put_private(conn, @filled, :unfilled)

  defp decide(%Plug.Conn{private: %{@filled => :unfilled}} = conn, _bound, :none), do: {:ok, conn}
  defp decide(conn, bound, :none), do: {:ok, fill(conn, bound)}
  defp decide(conn, bound, bound), do: {:ok, conn}
  defp decide(_conn, _bound, _other), do: {:error, :forbidden_dataset}

  # `conn.params` is `%Plug.Conn.Unfetched{}` before Plug.Parsers ran: nothing
  # to read and nothing to fill.
  defp requested(%Plug.Conn{path_params: %{"dataset" => dataset}}), do: dataset
  defp requested(%Plug.Conn{params: %Plug.Conn.Unfetched{}}), do: :none
  defp requested(%Plug.Conn{params: %{"dataset" => nil}}), do: :none
  defp requested(%Plug.Conn{params: %{"dataset" => dataset}}), do: dataset
  defp requested(_conn), do: :none

  defp fill(%Plug.Conn{params: %Plug.Conn.Unfetched{}} = conn, _bound), do: conn

  defp fill(%Plug.Conn{params: params} = conn, bound) do
    %{conn | params: Map.put(params, "dataset", bound)}
    |> Plug.Conn.put_private(@filled, true)
  end
end
