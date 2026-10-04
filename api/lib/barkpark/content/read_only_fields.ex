defmodule Barkpark.Content.ReadOnlyFields do
  @moduledoc """
  Enforces a schema field's `"readOnly" => true` on the client write doors
  (owner ruling #35, item 5).

  `readOnly` used to be advice for Studio only. A write token could patch a
  ticket's `key_id` to another submitter key through `POST /v1/data/mutate` and
  hand that key holder the whole thread, or rewrite a form submission's `site`
  or `source`.

  WHO IS REFUSED. A write whose `opts` carry `source: :api` (the default, as for
  the task guards in `Content.Mutations`) and a NON-ADMIN
  `Barkpark.Content.CallerContext`. Admin callers keep the write. Replication
  (`source: :sync`) mirrors upstream rows verbatim. A write with no caller
  context at all is server code, never a client door: both HTTP doors always
  set one (`BarkparkWeb.ScopeHelpers.scope_opts/1`).

  WHAT IS A CHANGE. Each readOnly field is compared, by value, between the row
  the write starts from and the content it will store. A field sent at its
  stored value is not a change, so re-saving a whole document passes. Removing
  a stored value (`unset`, a `createOrReplace` without it) is a change. On a
  create the base is the published row when one exists, otherwise empty, so a
  client that supplies a readOnly value on a new document is refused.

  WHAT IT DOES NOT COVER. Plugin code that writes through `Content` directly
  (the ticket thread, form ingestion) never reaches these doors, so the server
  keeps setting the fields it owns. Only top-level `content` keys are checked;
  `readOnly` inside an object field's own `fields` is not.
  """

  alias Barkpark.Content
  alias Barkpark.Content.CallerContext

  @doc """
  `:ok`, or `{:error, {:read_only_fields, names}}` naming every readOnly field
  whose value `merged` changes from `base`.

  `base` is the stored content map, or a zero-arity function returning it, so a
  create only reads the published row when the check actually applies.
  """
  @spec check(String.t() | nil, map() | (-> map()), map(), String.t(), keyword()) ::
          :ok | {:error, {:read_only_fields, [String.t()]}}
  def check(type, base, merged, dataset, opts) do
    with true <- enforced?(opts),
         [_ | _] = names <- read_only_names(type, dataset, opts) do
      base = if is_function(base, 0), do: base.(), else: base
      base = if is_map(base), do: base, else: %{}
      merged = if is_map(merged), do: merged, else: %{}

      case Enum.filter(names, &(Map.get(base, &1) != Map.get(merged, &1))) do
        [] -> :ok
        changed -> {:error, {:read_only_fields, changed}}
      end
    else
      _ -> :ok
    end
  end

  defp enforced?(opts) do
    Keyword.get(opts, :source, :api) == :api and
      match?(%CallerContext{is_admin: false}, Keyword.get(opts, :caller_context))
  end

  @doc "The top-level field names `type`'s schema marks readOnly."
  @spec read_only_names(String.t() | nil, String.t(), keyword()) :: [String.t()]
  def read_only_names(type, dataset, opts) when is_binary(type) do
    case Content.resolve_schema(type, dataset, opts) do
      {:ok, %{fields: fields}} when is_list(fields) ->
        for f when is_map(f) <- fields,
            read_only?(f),
            name = field_name(f),
            is_binary(name),
            do: name

      _ ->
        []
    end
  end

  def read_only_names(_type, _dataset, _opts), do: []

  defp read_only?(f), do: Map.get(f, "readOnly") == true or Map.get(f, :readOnly) == true

  defp field_name(f), do: Map.get(f, "name") || Map.get(f, :name)
end
