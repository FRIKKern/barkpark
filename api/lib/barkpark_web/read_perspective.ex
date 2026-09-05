defmodule BarkparkWeb.ReadPerspective do
  @moduledoc """
  ONE validator for the `?perspective` query param across every read route that
  declares it, and ONE refusal envelope for the values it does not honour.

  THE DEFECT THIS CLOSES. `?perspective` was parsed by four private, forked
  functions, three of which ended in a silent catch-all mapping every
  unrecognised string to `:published`:

    * `BarkparkWeb.AnonPerspective.parse/1`                     — `def parse(_), do: :published`
    * `BarkparkWeb.SearchController.parse_perspective/1`        — a byte-identical duplicate of the above
    * `BarkparkWeb.TasksController.Params.parse_perspective/1`  — graph's narrower set + the `?drafts=true` alias

  So `?perspective=drafst` returned 200 over the PUBLISHED set on
  `/v1/data/search/:dataset` and `/v1/graph/:id`, telling the caller nothing.
  `/v1/data/counts` refused it, and #13588 made doc-get and query refuse it, but
  each of those grew its OWN private `unsupported_*` + `refuse_*` pair — a
  fourth and fifth fork, in the direction of the fix this time. Three lenient
  forks are how the defect reached two surfaces; two strict forks are how a
  sixth surface would miss the fix. Both collapse here.

  THE SUPPORTED SET IS PER-ROUTE, and the caller passes it, because the routes
  genuinely differ — this is the reason a single hardcoded list would be WRONG:

      /v1/data/doc/…, /v1/data/query/…, /v1/data/search/…   published | drafts | raw
      /v1/graph/:id                                          published | drafts
      /v1/data/counts                                        published

  `raw` is not offered on `/v1/graph/:id`: the manifest declares that route's
  contract as `published (default) | drafts (live extract over the drafts
  corpus)`, so refusing `raw` there is CORRECT, not a missing branch. The list
  each caller passes must be the list ITS entry in `Barkpark.Plugins.Capabilities`
  declares — that is what makes `docs/openapi.json` an honest description of the
  server rather than an aspiration.

  ORDERING IS LOAD-BEARING. Every caller invokes this AFTER its
  existence-hiding 404, never before, so a 400 can never become an existence
  probe ("this document exists but your perspective is wrong" to a caller the
  endpoint is meant to tell nothing). `/v1/graph/:id` especially — it is the
  route with the draft-leak history (`graph_draft_leak_test.exs`).

  WHAT THIS DOES NOT DO. It does not narrow the lenient parsers. Their
  fail-safe `_ -> :published` default is relied on by every caller reached
  through some path OTHER than a declared `?perspective` route (forced preview
  perspectives, share reads, the loopback search fast-path), and a caller that
  never reaches this validator must still degrade CLOSED. Validation at the
  route edge and a fail-safe default underneath are two different jobs.
  """

  alias BarkparkWeb.ErrorResponse

  @doc """
  Returns the offending `?perspective` value, or `nil` when the request carries
  a value this route honours (or none at all).

  `nil` (absent) is always fine — omitting the param means the route default.
  The offending value is RETURNED rather than a bare `false` so the refusal can
  name back what the caller actually sent; a refusal that will not quote the
  input is the same unhelpful silence in a different envelope.

  A non-binary value (`?perspective[]=x` parses to a list, `?perspective[a]=b`
  to a map) is unsupported by construction and comes back as-is.
  """
  # @canonical capability:read-perspective-validate aka:perspective,unsupported_perspective,parse_perspective,silent downgrade,strict perspective doc:docs/api-v1.md
  @spec unsupported(map(), [String.t()]) :: nil | term()
  def unsupported(params, supported) when is_map(params) and is_list(supported) do
    case Map.get(params, "perspective") do
      nil -> nil
      value when is_binary(value) -> if value in supported, do: nil, else: value
      other -> other
    end
  end

  @doc """
  Emit the §9 `malformed` 400 for an unsupported `?perspective`.

  The details map is the shape #13588 established and `/v1/data/counts` has
  always used: `%{parameter: "perspective", supported: [...], received: value}`.
  `:message` overrides the human sentence for a route whose refusal needs to say
  something route-specific; the code, status and details stay canonical either
  way.
  """
  @spec refuse(Plug.Conn.t(), term(), [String.t()], keyword()) :: Plug.Conn.t()
  def refuse(conn, value, supported, opts \\ []) when is_list(supported) do
    ErrorResponse.emit_custom(
      conn,
      400,
      "malformed",
      Keyword.get(opts, :message) || default_message(value, supported),
      %{parameter: "perspective", supported: supported, received: value}
    )
  end

  defp default_message(value, supported) do
    "unsupported perspective #{inspect(value)} — supported values are " <>
      humanize(supported) <> "; omit ?perspective for published"
  end

  # "published, drafts and raw" — the sentence form, not the JSON form. The
  # machine-readable list rides `details.supported`; this is for the human
  # reading a curl body.
  defp humanize([one]), do: one
  defp humanize([a, b]), do: "#{a} and #{b}"

  defp humanize(list) do
    {init, [last]} = Enum.split(list, -1)
    Enum.join(init, ", ") <> " and " <> last
  end
end
