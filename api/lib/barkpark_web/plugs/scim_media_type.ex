defmodule BarkparkWeb.Plugs.ScimMediaType do
  @moduledoc """
  The SCIM media type, both directions (RFC 7644 §3.1: *"the SCIM protocol uses
  the HTTP media type `application/scim+json`"*).

  This plug replaces `plug(:accepts, ["json"])` on the `:scim` pipeline, because
  that plug REFUSED the SCIM media type. Phoenix's accept negotiation resolves
  an `Accept` header through `MIME.extensions/1`; `application/scim+json` is not
  a registered type in this app's `:mime` config, so `MIME.extensions/1`
  returned `[]`, no format matched `["json"]`, and Phoenix raised
  `Phoenix.NotAcceptableError` → **406**. An IdP that asks for SCIM's own media
  type by name got a 406 from a SCIM server.

  ## Requests

  Accepted `Accept` values: absent, `*/*`, `application/*`, `application/json`,
  `application/scim+json` — with `;q=`/parameters and comma-separated lists
  tolerated, since a client only has to offer ONE type we can serve. Anything
  else is refused with a SCIM Error envelope (406), not an HTML exception page.

  Request BODIES need nothing here: `Plug.Parsers.JSON` already decodes any
  `application/*+json` subtype (`plug/lib/plug/parsers/json.ex`), so a `POST` /
  `PUT` / `PATCH` sent as `application/scim+json` was always parsed — it was
  only the response side and the `Accept` header that were JSON-only. This plug
  deliberately does NOT add a 415 for unrecognised request content types: the
  endpoint's parser passes `*/*` through for every other surface, and narrowing
  it here would be a new refusal this task did not ask for.

  ## Responses

  Stamps `content-type: application/scim+json; charset=utf-8` up front.
  `Phoenix.Controller.json/2` only sets `application/json` when no content-type
  is present yet (`ensure_resp_content_type/2`), so stamping here makes every
  SCIM body — resources, ListResponses, and Error envelopes alike — go out under
  the SCIM media type without touching a single controller.
  """
  import Plug.Conn

  alias BarkparkWeb.ScimResponse

  @scim_json "application/scim+json"

  def init(opts), do: opts

  def call(conn, _opts) do
    conn = conn |> put_resp_content_type(@scim_json) |> Phoenix.Controller.put_format("json")

    case get_req_header(conn, "accept") do
      [] ->
        conn

      values ->
        if Enum.any?(values, &acceptable?/1) do
          conn
        else
          conn
          |> ScimResponse.error(
            406,
            "this endpoint serves #{@scim_json} (or application/json) only"
          )
          |> halt()
        end
    end
  end

  # One header line may offer several types; any single servable offer is enough.
  defp acceptable?(header) when is_binary(header) do
    header
    |> String.split(",")
    |> Enum.any?(fn offer ->
      case Plug.Conn.Utils.media_type(offer) do
        {:ok, "*", _subtype, _params} -> true
        {:ok, "application", "*", _params} -> true
        {:ok, "application", "json", _params} -> true
        {:ok, "application", "scim+json", _params} -> true
        _ -> false
      end
    end)
  end

  defp acceptable?(_), do: false
end
