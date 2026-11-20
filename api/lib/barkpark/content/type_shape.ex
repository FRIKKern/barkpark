defmodule Barkpark.Content.TypeShape do
  @moduledoc """
  A value of the wrong shape for its field's type, as the TanStack Studio
  finds it (`lib/validation.ts` `typeRule`, Sanity's own validators): a
  `url` field must hold an absolute http or https address with no user name
  or password in it.

  The walk is the TanStack Studio's: every field of the document, the fields
  of an object, and every item of an array. An object item is checked under
  its kind (`options.typeField`), so only the fields that kind shows
  (`options.fieldsByType`) count; an item of a plain type by that type's
  rule; an item of a typed array (`of` a list) by the fields of the member
  its `_type` names. A blank value is never checked here: `required` is
  `Validation`'s.

  THIS IS NOT ON THE WRITE PATH. The TanStack Studio checks a value's shape
  in the browser: it is listed, and an error blocks Publish, but a save is
  never refused for it. So here: the desk's Validation panel lists these
  findings beside `Validation.check_findings/3`'s and its Publish is
  disabled while one is there, and nothing that saves calls this module.
  Rows already stored with such a value keep saving as they did; refusing
  them would be a new refusal on existing data, which is the owner's call.

  A finding is `Validation.finding()`'s shape (`path`, `message`, `code`,
  `params`) with the English sentence the TanStack Studio shows, so a caller
  that renders its own words keys them by `code`.
  """

  @typedoc "One finding: its path in the document (`/links/0/url`), as `Validation`'s."
  @type finding :: %{path: String.t(), message: String.t(), code: atom(), params: map()}

  @codes [:url_invalid, :url_scheme, :url_credentials]

  @doc "The codes `findings/2` can emit."
  @spec codes() :: [atom()]
  def codes, do: @codes

  @doc "Every finding in `content` under `schema`'s fields, in the fields' order."
  @spec findings(map() | nil, map() | list() | nil) :: [finding()]
  def findings(content, schema) when is_map(content),
    do: Enum.flat_map(fields(schema), &check(&1, Map.get(content, &1["name"]), "/" <> &1["name"]))

  def findings(_content, _schema), do: []

  @doc """
  What is wrong with `value` as an address, or nil: `:url_invalid` when it
  is not an absolute URL, `:url_scheme` when it is not http or https,
  `:url_credentials` when it names a user or a password.
  """
  @spec url_problem(String.t()) :: :url_invalid | :url_scheme | :url_credentials | nil
  def url_problem(value) when is_binary(value) do
    text = String.trim(value)

    with [_, scheme, rest] <- Regex.run(~r/^([A-Za-z][A-Za-z0-9+.\-]*):(.*)$/s, text),
         scheme = String.downcase(scheme),
         {:ok, userinfo} <- authority(scheme, rest) do
      cond do
        scheme not in ["http", "https"] -> :url_scheme
        userinfo not in [nil, "", ":"] -> :url_credentials
        true -> nil
      end
    else
      _ -> :url_invalid
    end
  end

  # A URL of a special scheme (WHATWG's, `file` aside) must name a host; any
  # other scheme parses as it is. Answers the user info before the host, or
  # an error when there is no usable host.
  @special ~w(http https ws wss ftp)
  defp authority(scheme, rest) when scheme in @special do
    after_slashes = String.replace(rest, ~r/^[\/\\]*/, "")
    [authority | _] = String.split(after_slashes, ~r/[\/\\?#]/, parts: 2)

    {userinfo, hostport} =
      case String.split(authority, "@") do
        [hostport] -> {nil, hostport}
        parts -> {parts |> Enum.drop(-1) |> Enum.join("@"), List.last(parts)}
      end

    if host_ok?(hostport), do: {:ok, userinfo}, else: :error
  end

  defp authority(_scheme, _rest), do: {:ok, nil}

  # A host with no forbidden character (WHATWG's forbidden host code points),
  # and a port, when there is one, of digits under 65536.
  defp host_ok?(hostport) do
    {host, port} =
      case Regex.run(~r/^(\[[^\]]*\]|[^:]*)(?::(.*))?$/s, hostport) do
        [_, host] -> {host, ""}
        [_, host, port] -> {host, port}
        _ -> {"", ""}
      end

    host_ok =
      Regex.match?(~r/^\[[0-9A-Fa-f:.]+\]$/, host) or
        (host != "" and not Regex.match?(~r/[\x00-\x20#%\/:<>?@\[\\\]^|]/, host))

    host_ok and port_ok?(port)
  end

  defp port_ok?(""), do: true
  defp port_ok?(port), do: Regex.match?(~r/^\d{1,5}$/, port) and String.to_integer(port) < 65_536

  defp check(field, value, path) do
    own(field["type"], value, path) ++ inside(field, value, path)
  end

  defp own("url", value, path) when is_binary(value) and value != "" do
    case url_problem(value) do
      nil -> []
      code -> [finding(path, code)]
    end
  end

  defp own(_type, _value, _path), do: []

  # An object's fields; an array's items.
  defp inside(%{"of" => of}, list, path) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, i} -> item(of, item, "#{path}/#{i}") end)
  end

  defp inside(%{"fields" => fields}, %{} = value, path) when is_list(fields) do
    fields
    |> Enum.filter(&named?/1)
    |> Enum.flat_map(&check(&1, Map.get(value, &1["name"]), path <> "/" <> &1["name"]))
  end

  defp inside(_field, _value, _path), do: []

  # An object item: the fields its kind shows. A plain item: its type's rule.
  defp item(%{"fields" => fields} = of, %{} = row, path) when is_list(fields) do
    shown = shown(of, row)

    fields
    |> Enum.filter(&(named?(&1) and (shown == :all or &1["name"] in shown)))
    |> Enum.flat_map(&check(&1, Map.get(row, &1["name"]), path <> "/" <> &1["name"]))
  end

  defp item(%{"type" => type} = of, value, path) when is_binary(type),
    do: own(type, value, path) ++ inside(of, value, path)

  defp item(members, %{"_type" => type} = row, path) when is_list(members) do
    case Enum.find(members, &(is_map(&1) and (&1["name"] || &1["type"]) == type)) do
      %{"fields" => fields} when is_list(fields) -> item(%{"fields" => fields}, row, path)
      _ -> []
    end
  end

  defp item(_of, _value, _path), do: []

  defp shown(of, row) do
    type_field = get_in(of, ["options", "typeField"])
    by_type = get_in(of, ["options", "fieldsByType"])
    kind = is_binary(type_field) && row[type_field]

    case is_binary(kind) && is_map(by_type) && by_type[kind] do
      names when is_list(names) -> names
      _ -> :all
    end
  end

  defp finding(path, code) do
    %{path: path, code: code, message: message(code), params: %{}}
  end

  defp message(:url_invalid), do: "Not a valid URL"
  defp message(:url_scheme), do: "Does not match allowed protocols/schemes"
  defp message(:url_credentials), do: "Username/password not allowed"

  defp fields(%{fields: fields}) when is_list(fields), do: Enum.filter(fields, &named?/1)
  defp fields(%{"fields" => fields}) when is_list(fields), do: Enum.filter(fields, &named?/1)
  defp fields(fields) when is_list(fields), do: Enum.filter(fields, &named?/1)
  defp fields(_schema), do: []

  defp named?(%{"name" => name}) when is_binary(name) and name != "", do: true
  defp named?(_field), do: false
end
