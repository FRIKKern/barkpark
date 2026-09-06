defmodule BarkparkWeb.Plugs.ScimMediaType do
  @moduledoc """
  The SCIM media type, both directions (RFC 7644 §3.1: *"the SCIM protocol uses
  the HTTP media type `application/scim+json`"*).

  This plug replaces `plug(:accepts, ["json"])` on the `:scim` pipeline. The gap
  it closes is the RESPONSE side: every SCIM answer went out as
  `application/json`, so a client that keys on the media type never saw SCIM's
  own.

  MEASURED, not assumed, about the request side: `:accepts` did NOT reject
  `application/scim+json`. `:mime` resolves the structured `+json` suffix, so
  `MIME.extensions("application/scim+json")` already returned `["json"]` and the
  header negotiated fine. A moduledoc here previously claimed the opposite (a
  `Phoenix.NotAcceptableError` → 406 for SCIM's own media type); that premise is
  false — reverting the pipeline to `plug(:accepts, ["json"])` leaves
  `scim_conformance_test.exs`'s "Accept: application/scim+json is served" test
  GREEN. It is kept as a regression guard on this plug, not as evidence of a
  bug it fixed.

  ## Requests

  Accepted `Accept` values: absent, `*/*`, `application/*`, `application/json`,
  `application/scim+json` — with `;q=`/parameters and comma-separated lists
  tolerated, since a client only has to offer ONE type we can serve. Anything
  else is refused with a SCIM Error envelope (406) rather than the HTML
  exception page `:accepts` raises — the one behaviour change on this side.

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
