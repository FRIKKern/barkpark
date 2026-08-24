defmodule BarkparkWeb.LegacyController do
  @moduledoc "Backward-compatible API matching the Go TUI's original endpoints."

  use BarkparkWeb, :controller

  import BarkparkWeb.ScopeHelpers, only: [scope_opts: 1]
  import BarkparkWeb.ParamCoercion, only: [bin: 1]

  alias Barkpark.Content
  alias Barkpark.Content.{CallerContext, Envelope, Schema}
  alias BarkparkWeb.AnonPerspective

  action_fallback BarkparkWeb.FallbackController

  @dataset "production"

  # The legacy list serves up to 10_000 documents — the number this route has
  # always PASSED as `:limit`, and never actually received (see `index/2`).
  # Ten pages of the server's 1000-row page cap is that same ceiling, now
  # honestly reached and honestly reported.
  @list_page_size 1000
  @list_max_pages 10

  def index(conn, %{"type" => type} = params) do
    # `bin/1` collapses a non-binary `?filter[]=x` / `?filter[k]=v` to nil
    # BEFORE parse_legacy_filter's `String.split/2` — which would otherwise
    # 500 with a FunctionClauseError on a list/map. nil → the empty-filter path.
    with {:ok, filter_map} <- parse_legacy_filter(bin(Map.get(params, "filter"))) do
      schema = fetch_schema(conn, type)
      caller_context = CallerContext.from_conn(conn)

      # WS-B MEDIUM-4 (legacy path): a `filter=field=value` over a field the caller
      # may not SEE turns row-selection + `count` into an equality oracle on a
      # hidden value, even though the response BODY is redacted. Reject BEFORE the
      # query so the WHERE never runs over a forbidden field — the same guard
      # /v1/data/query enforces, now closed on the legacy surface too.
      case forbidden_filter_field(filter_map, schema, caller_context) do
        nil ->
          # DRAFTS-LIST CLAMP (api-read-path-security-sweep w3) — the LIST twin
          # of the show/2 by-id clamp above. `list_documents` defaults to the
          # `:raw` perspective (content/query.ex:57 — the identity apply at :166),
          # so `drafts.` rows ARE in the result set. QueryController.index has
          # always narrowed anon reads via `perspective: AnonPerspective.resolve`
          # (query_controller.ex:66); this action passed no perspective, so the
          # LIST arm had the same latent shape the show/2 clamp closed on the
          # by-id arm. Pin an `anon_pinned?` caller to `:published` here too.
          #
          # `anon_pinned?`-SCOPED, never a blanket `:published`: read-tier draft
          # LISTING is the legacy contract (legacy_crud_test pins an admin token
          # seeing `drafts.lc-list-2`), so an unconditional clamp would break it —
          # non-anon callers keep the `:raw` default. Latent today only because
          # `pipeline :require_token` mounts Plugs.PublicRead, which 403s the one
          # anon_pinned principal that can reach this route (a public-read token)
          # two plugs upstream — so a future allowlist change cannot re-open the
          # list arm alone while the show/2 arm stays clamped.
          perspective = if AnonPerspective.anon_pinned?(conn), do: :published, else: :raw

          # THE CAP THIS ROUTE NEVER GOT. It asked `list_documents/3` for
          # `limit: 10_000` — but that function CLAMPS :limit to 1000, so the
          # request was silently answered with a 1000-row PREFIX and the
          # response then reported `count: length(documents)` = 1000 as though
          # 1000 were the total. A client with 4,000 documents of a type was
          # told, in the API's own words, that it had exactly 1000.
          #
          # WALK instead, bounded to the same @list_ceiling this route always
          # meant to serve, and SAY SO when the ceiling cut the corpus short:
          # `truncated` is the signal the old shape could not carry, and
          # `count` is now the number of documents actually in `documents`
          # (which, when `truncated` is false, IS the corpus total).
          {documents, walk} =
            Content.collect_all_documents(
              type,
              @dataset,
              [
                perspective: perspective,
                filter_map: filter_map,
                page_size: @list_page_size,
                max_pages: @list_max_pages
              ] ++ scope_opts(conn)
            )

          json(conn, %{
            type: type,
            documents: Enum.map(documents, &render_legacy_doc(&1, schema, caller_context)),
            count: length(documents),
            truncated: walk == :cap
          })

        field ->
          {:error, {:forbidden_field, field}}
      end
    end
  end

  def show(conn, %{"type" => type, "id" => doc_id}) do
    cond do
      # DRAFTS-BY-ID CLAMP (api-read-path-security-sweep w2) — the guard
      # QueryController.show/2 has always carried (query_controller.ex:371),
      # absent here: this action passed the RAW id straight to get_document, so
      # a `drafts.` id was fetchable by any published-pinned principal. Latent
      # today only because `pipeline :require_token` mounts Plugs.PublicRead,
      # which 403s the one anon_pinned principal that can reach this route (a
      # public-read token) two plugs upstream — NOT RequireToken, which accepts
      # any verified token (require_token.ex only 403s a share-token off its
      # surface). Defense in depth, so a future mount/allowlist change cannot
      # re-open a drafts read here. Rejected as not-found BEFORE get_document,
      # the same 404 the action already returns for a missing id.
      #
      # `anon_pinned?`-SCOPED, never a blanket prefix block: read-tier draft
      # access by id IS the legacy contract (legacy_crud_test pins a 200 on
      # `drafts.lc-show-1` for an admin/read/write token), and a bare
      # String.starts_with? guard would break it.
      AnonPerspective.anon_pinned?(conn) and String.starts_with?(doc_id, "drafts.") ->
        {:error, :not_found}

      true ->
        with {:ok, doc} <- Content.get_document(doc_id, type, @dataset, scope_opts(conn)) do
          json(
            conn,
            render_legacy_doc(doc, fetch_schema(conn, type), CallerContext.from_conn(conn))
          )
        end
    end
  end

  def create(conn, %{"type" => type} = params) do
    attrs = Map.drop(params, ["type"])

    # Map legacy format to internal format
    doc_id = Map.get(attrs, "id") || Map.get(attrs, "doc_id")

    internal_attrs = %{
      "doc_id" => doc_id,
      "title" => Map.get(attrs, "title"),
      "status" => Map.get(attrs, "status", "draft"),
      "content" => Map.drop(attrs, ["id", "doc_id", "title", "status", "updatedAt"])
    }

    case Content.upsert_document(
           type,
           internal_attrs,
           @dataset,
           [source: :api] ++ scope_opts(conn)
         ) do
      {:ok, doc} ->
        # Echo the created doc through the REAL caller (same redaction boundary
        # as a read), not the :internal no-redaction sentinel — uniform with the
        # mutation echo. The caller supplied this content, so redaction only
        # hides schema-default private values it never set; admins see all.
        conn
        |> put_status(:created)
        |> json(render_legacy_doc(doc, fetch_schema(conn, type), CallerContext.from_conn(conn)))

      # Both a plugin lifecycle veto ({:halted, reason}) and an Ecto changeset
      # error route through action_fallback → FallbackController → the canonical
      # error envelope. (The halt used to be a bare %{error: "halted", reason:
      # reason} with no code/request_id — invisible to the bp CLI + SDK.)
      {:error, _} = err ->
        err
    end
  end

  def delete(conn, %{"type" => type, "id" => doc_id}) do
    case Content.delete_document(doc_id, type, @dataset, [source: :api] ++ scope_opts(conn)) do
      # RECEIPT LAW (pds w39): render the row the write returned, never the
      # request. `delete_document/4` returns `{:ok, target}` — the document it
      # actually removed (content/lifecycle.ex:694) — and `rev` is the store's
      # own value, absent from the request, so an echo-of-`doc_id` revert reds.
      {:ok, deleted} ->
        json(conn, %{deleted: deleted.doc_id, type: deleted.type, rev: deleted.rev})

      # Halts + other errors fall through to action_fallback for the canonical
      # envelope (was a bare %{error: "halted", reason: reason}).
      {:error, _} = err ->
        err
    end
  end

  def schemas(conn, _params) do
    # ANON FIELD DISCLOSURE (api-read-path-security-sweep w2): this route is
    # deliberately NOT token-gated (see router.ex — public schema discovery),
    # and it echoed `fields` for EVERY schema, private ones included — the full
    # field definition of every private type to any anonymous reader (guerrilla:
    # 39 schemas, 31 of them private-declared). Filter to explicitly-public
    # schemas through the SAME predicate the query route, the anonymous search
    # allowlist and the corpus graph use, so a schema flipped to private drops
    # out of this list on the very next read — never a hardcoded public set.
    #
    # The 200 and the array shape are UNCHANGED on purpose: every external
    # consumer of this route (deploy.sh, the docker-compose healthcheck,
    # cloud/support.go) probes reachability/parse-ability, not membership.
    schemas =
      @dataset
      |> Content.list_schemas(scope_opts(conn))
      |> Enum.filter(&Schema.public_schema?/1)

    json(
      conn,
      Enum.map(schemas, fn s ->
        %{
          name: s.name,
          title: s.title,
          icon: s.icon,
          fields: s.fields
        }
      end)
    )
  end

  # WS-B MEDIUM-4 guard (legacy): the first filtered field NOT readable by this
  # caller (per schema + CallerContext), or nil when every key is allowed.
  # Mirrors QueryController.forbidden_query_field — internal/admin callers and
  # undeclared/promoted fields pass through `Envelope.field_readable?/3`.
  defp forbidden_filter_field(filter_map, schema, caller_context) do
    Map.keys(filter_map)
    |> Enum.find(fn field -> not Envelope.field_readable?(schema, field, caller_context) end)
  end

  # Parse legacy "field=value" filter string into a map for list_documents/3.
  # Nil/empty means "no filter" (unchanged). A non-empty string that doesn't
  # parse to a field=value pair (e.g. "price>10") used to fall through to a
  # bare `%{}` — silently returning EVERY document instead of erroring, the
  # same fail-open class query_controller.ex guards for its filter operators.
  # Fail CLOSED here too: route it through action_fallback as a 400.
  defp parse_legacy_filter(nil), do: {:ok, %{}}
  defp parse_legacy_filter(""), do: {:ok, %{}}

  defp parse_legacy_filter(s) do
    case String.split(s, "=", parts: 2) do
      [field, value] -> {:ok, %{field => value}}
      _ -> {:error, {:invalid_filter, s}}
    end
  end

  # Resolve the type's schema for field-visibility redaction, under the same
  # tenant scope as the read. Nil on miss — redaction then falls back to the
  # schema-free encrypted-ciphertext guard.
  defp fetch_schema(conn, type) do
    case Content.get_schema(type, @dataset, scope_opts(conn)) do
      {:ok, schema} -> schema
      _ -> nil
    end
  end

  # WS-B HIGH-1: this legacy surface formerly dumped raw `doc.content` into
  # `:values`, bypassing the Envelope redaction boundary. Route the content
  # through `Envelope.render/3` (the single chokepoint) so a `private` /
  # `owner_only` / `readable_by` / encrypted field is dropped for a
  # non-authorized caller, then re-nest the SURVIVING content fields under
  # `:values` to preserve the legacy wire shape. With no private fields the
  # output is byte-identical to before.
  defp render_legacy_doc(doc, schema, caller_context) do
    base = %{
      id: doc.doc_id,
      title: doc.title,
      status: doc.status,
      updatedAt: doc.updated_at
    }

    values =
      doc
      |> Envelope.render(schema, caller_context)
      |> Map.reject(fn {k, _v} -> String.starts_with?(k, "_") or k == "title" end)

    if map_size(values) > 0 do
      Map.put(base, :values, values)
    else
      base
    end
  end
end
