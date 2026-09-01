defmodule BarkparkWeb.ShareLinkController do
  @moduledoc """
  ITEM share links (P7) — Google-Docs-style direct links to ONE item.

    * `GET /s/:token` — PUBLIC. Resolves the opaque link and serves that single
      item, scoped to the LINK's own workspace/project/dataset (NOT the request
      path), so it is independent of any section share. A paper renders its
      reader page; another doc returns its published data; media serves the file.
    * `POST/GET/DELETE /v1/shares/links` — ADMIN. Mint (raw token shown once),
      list an item's links, revoke one.

  A link's `ref_id` is a PUBLISHED id, and that is now IMPLEMENTED rather than
  merely asserted: `Sharing.Links.published_ref_id/1` strips a `drafts.` prefix
  at the context boundary, so `create/1` cannot persist a draft ref whichever
  door minted it, `mint` validates existence against the id it will actually
  store, and `show` re-applies it when serving a row minted before the clamp
  existed. Corrected 2026-08-24 (`arpss-w8-bl-share-link-drafts-ref-id`): this
  paragraph used to state the clamp as a fact while NOTHING in this file checked
  the prefix — the normalisation lived only in `item_share.ex`, i.e. on the
  Studio door and not on this one. It stood unrevised from the feature commit
  (b523b2e3a4, 2026-06-09) through four later correction passes over this
  moduledoc, because it sits ABOVE the first `##` and every audit swept the
  sections.

  READ VS EDIT IS NOT A SERVE-PATH DISTINCTION, and the old wording implied it
  was. `show` does not branch on `link.access` — both levels take the same path
  and receive the same published bytes. `access` governs what the RECIPIENT
  SURFACE grants (an edit link is what the scoped editor accepts), never which
  data this controller resolves.

  ## Tenancy confinement on `/v1/shares/links` (arpss-w8)

  `:require_admin` is a GLOBAL-permission gate — it proves the caller holds
  `"admin"` somewhere, not that it may act on THIS tenant. The three admin
  actions therefore additionally require the caller to be an ADMIN MEMBER of the
  workspace the request TARGETS (`Tenancy.Auth.workspace_admin?/2`, the
  grant-reading chokepoint), mirroring the sibling half in
  `BarkparkWeb.ShareController` verbatim:

    * `mint` — against the SCOPE's workspace (403). Ungated it minted a real
      `access: "edit"` credential INTO a foreign workspace.
    * `list` — against the SCOPE's workspace (403). Ungated it serialised
      foreign rows through `link_json/1`, whose `url:` carries the PLAINTEXT
      `/s/<token>` (see `Barkpark.Sharing.ShareLink` — the raw token IS stored),
      i.e. it handed a stranger a LIVE credential, not merely metadata.
    * `revoke` — against the TARGET ROW's own workspace (404, byte-identical to
      a missing row).

  `show` (`GET /s/:token`, browser pipe) is DELIBERATELY UNGATED: the token IS
  the authorization there, and it is the whole point of the feature.

  The predicate is `workspace_admin?/2`, never `Tenancy.Auth.authorize/3`:
  authorize/3's api_token arm is `member? AND the token's GLOBAL permissions[]`,
  so a global-admin token holding a plain `member` row in workspace B PASSES
  `authorize(tok, B, :admin)` while `workspace_admin?(tok, B)` denies. The
  leak-closed test is written against exactly that shape, so swapping the call
  turns it RED.

  In BOTH `mint` and `list` the gate sits immediately after
  `Tenancy.get_workspace_by_slug/1` and BEFORE `Tenancy.get_project/2`. Placed
  later it leaves an oracle: after `get_project/2` an existing project slug in B
  answers 403 while a ghost answers 422 (project enumeration), and after
  `ensure_item_exists` an existing item answers 403 while a missing one answers
  422 (item enumeration, whose loudest positive form is the 201 leak itself).
  Placing it before the query is also what makes the fix AUTHORIZE-BEFORE-
  SERIALIZE structurally: `link_json/1` is unreachable for a row the caller
  cannot administer, so a foreign token is never rendered into a string at all —
  not hidden afterwards, not redacted afterwards.

  ## Denial-shape law — THE SHAPE FOLLOWS THE INPUT, NOT THE VERB

  The discriminant is WHERE the name arrives:

    * PATH-ADDRESS slug, unknown → 404; exists but no authority → 403
      (`RequireWorkspaceScope`, resolve_workspace.ex:76 / :134).
    * PAYLOAD/QUERY value, unresolvable → 422, UNCHANGED (there is no tenant to
      confine to). `mint`'s "no such item in this scope" and both actions'
      malformed-scope 422 keep their contract.
    * PAYLOAD/QUERY value that EXISTS but the caller cannot administer → 403
      (`mint`, `list`). Emitted as
      `ErrorResponse.emit(conn, {:error, :forbidden}, "workspace access required")`.
    * OPAQUE ROW ID belonging to a foreign tenant → 404, BYTE-IDENTICAL to a
      missing row (`revoke`): both arms reach the SAME
      `not_found_json(conn, "link not found")` call site, which is an
      instruction to reuse one call site rather than a property to assert about
      the framework.
    * An id that is nil or non-castable → a DENIAL, never a 500. Every id goes
      through `Repo.uuid_or_nil/1` first — inside `Sharing.Links` since the
      predicate moved there, not in this file.
    * NO named target → 200 with foreign rows simply absent. Not reachable here
      (`list` requires a `scope`), stated so the law is complete.

  ACCEPTED SIGNAL, with its reason: even at the early placement a caller still
  distinguishes an EXISTING foreign workspace (403) from a nonexistent slug
  (422). That is the reviewed consequence of the resolve-first/authorize-second
  ordering the sibling half established — checking edit-shared/scope config
  first would leak the foreign share CONFIG, which is strictly worse. It is a
  workspace-slug oracle only, never a contents oracle. TWO DISCRIMINANTS THIS
  WAVE DOES NOT CLOSE: response HEADERS (the denial happens inside the same
  action, after the same plugs, so headers match — but nothing pins that) and
  TIMING (the foreign path runs one extra membership query). KNOWN EXCEPTION,
  named so the law is not refuted by the first grep: `GET|DELETE
  /v1/access/:id` answers 403 for a foreign grant id and 404 for a missing one
  (access_controller.ex:100/106/118/119 over an unscoped `Access.get_grant/1`).
  It is filed as `arpss-w8-bl-access-grant-id-existence-oracle` and is NOT fixed
  here — access_controller.ex is outside this slice's fence.

  ## BEHAVIOUR CHANGE THAT SHIPS

  An admin token that is not an ADMIN MEMBER of the target workspace — including
  a GLOBAL-admin token holding only a plain `member` membership there — can no
  longer mint, list or revoke that workspace's item share links. That flow used
  to succeed and returned live `/s/<token>` credentials; it is the cross-tenant
  disclosure this closes. Host/self-hosted admins are unaffected:
  `Auth.create_token/5` writes the caller's home membership in the resolved
  workspace, so the real-install admin passes.

  The Studio LiveView revoke arm's own unscoped-id class is CLOSED (corrected
  2026-08-23, was: "REMAINS OPEN"): `arpss-item-share-revoke-unscoped-revoke`
  landed in PR #12707 (0f293badc2, closing #12362). `studio_live/handlers/
  item_share.ex`'s `revoke_scoped/2` now resolves the `ShareLink` row first and
  authorizes the actor against the ROW's OWN workspace via
  `Tenancy.Auth.workspace_admin?/2` — the same predicate and the same denial
  shape (a non-castable id, a missing row, and a foreign row all collapse to
  `{:error, :not_found}`) as `revoke_scoped/2` here — before ever calling
  `Sharing.Links.revoke/1`. A link id from ANOTHER workspace is now denied, with
  a committed cross-tenant test.

  What DID change, and what this paragraph used to get wrong (corrected
  2026-08-19, arpss-w10 / charter D22): this paragraph used to call the
  `Caps.admin?/1` token arm membership-independent, citing caps.ex's own words.
  That claim is OVERTURNED. Both Caps admin answers — `derive/1`'s `:admin` key
  and `admin?/1` — now spell WORKSPACE-SCOPED SEAT AUTHORITY,
  `role_permits?(membership_role, ws_id, :admin)` on the MOUNTED workspace, for
  both principal kinds, and a nil/unresolved workspace DENIES. An
  `admin`-permissioned token must therefore ALSO hold an admin-conferring
  membership ROLE in the workspace whose desk it is standing on. arpss-w10
  narrowed WHO reaches the revoke arm to exactly the principals this controller
  admits; `arpss-item-share-revoke-unscoped-revoke` (above) separately narrowed
  WHICH ids the arm will act on. Both are now closed.

  ## Proof limits, stated rather than implied

  The host-admin proof (`share_link_test.exs`, "a host admin ... end to end") is
  a PERMISSIVE assertion and structurally CANNOT red under a full reversion of
  the confinement — removing a gate cannot break a request the gate allowed. It
  is therefore mutation-verified against OVER-confinement instead. Calling it
  mutation-verified without such an arm would be a hollow stamp.

  TWO ARMS WERE CLAIMED HERE AND ONLY ONE OF THEM IS REAL. Corrected 2026-08-21
  rather than left standing. Both were re-run against origin/main in an isolated
  tree; baseline `share_link_test.exs` is 18 tests / 0 failures.

    * ROLE FLOOR RAISED TO `"owner"` in `workspace_admin?/2` — REDS, 13 failures,
      including "HOST-ADMIN PRESERVED: a real-install admin does list -> show ->
      revoke end to end", which fails `403 "workspace access required"` at mint.
    * BINDING THE ACTOR'S OWN WORKSPACE (`actor.workspace_id == ws_id` — the
      predicate #12404 proposed and this wave rejected) — REDS, the same 13.
    * A DEFAULT-WORKSPACE MEMBERSHIP REFUSED — REDS NOTHING. This arm was claimed
      and does not hold. It cannot bite, because the suite's own FIXTURE REPAIR
      (`share_link_test.exs:37-44`) grants the admin its membership in `link-ws`,
      so the link's workspace is never the Default one. The repair that made
      these tests express tenancy at all is what removed the scenario this arm
      was written to probe. Both changes are individually correct; the claim that
      survived them was not.

  The green was self-tested before being believed: forcing the refusal helper to
  return true unconditionally reds 13, and forcing it true only when
  `get_default_workspace()` resolves also reds 13. So the mutation site is live
  and a Default workspace does exist in the test env — the arm is VACUOUS, not
  dead code. A proof arm that cannot fail is worth less than no arm at all,
  because it reads as coverage.

  `share_link_test.exs`'s older "list shows an item's links (no token/hash)"
  refutes two absent MAP KEYS and passed on the LEAKING code, because the secret
  rode in `url`. It is left in place as this wave's own resident failure mode and
  is the reason the leak proof asserts on the SERIALIZED BODY (`resp_body =~`),
  not on the shape of the map.
  """
  use BarkparkWeb, :controller

  alias Barkpark.{Content, Media, Tenancy}
  alias Barkpark.Content.CallerContext
  alias Barkpark.Content.Envelope
  alias Barkpark.Content.Errors
  alias Barkpark.Content.Labels
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.PortableDoc.Render
  alias Barkpark.Sharing
  alias Barkpark.Sharing.{Links, ShareLink}
  alias BarkparkWeb.ErrorResponse

  # ── PUBLIC resolver ──────────────────────────────────────────────────────

  def show(conn, %{"token" => token}) do
    case Links.resolve(token) do
      # The clamp is re-applied on READ, not only on write: rows minted before
      # `Links.create/1` normalised can still carry a `drafts.` ref, and fixing
      # only the mint path would leave every already-issued link live.
      {:ok, link} -> serve(conn, published_link(link), token)
      {:error, _} -> not_found_html(conn)
    end
  end

  defp published_link(%ShareLink{ref_id: ref_id} = link),
    do: %{link | ref_id: Links.published_ref_id(ref_id)}

  # P5 (Scoped-by-URL): a PAPER short link 302s to its CANONICAL scoped
  # address with the token riding as ?share= — the recipient lands on the
  # real, copyable URL and gets the LIVE reader (per-block streaming)
  # instead of this controller's static render. RequireShareScope's
  # item-token arm re-validates the token against that exact scope + slug,
  # so the redirect grants nothing the token didn't already grant. Falls
  # back to the static render when the link's scope no longer resolves.
  defp serve(conn, %ShareLink{kind: "doc", ref_type: "paper"} = link, raw_token) do
    tenancy = conn.private[:share_link_tenancy] || Tenancy

    with ws_id when is_binary(ws_id) <- link.workspace_id,
         %{slug: ws_slug} <- tenancy.get_workspace_by_id(ws_id),
         %{slug: proj_slug} <- tenancy.get_project_by_id(link.project_id) do
      redirect(conn,
        to:
          "/w/#{ws_slug}/p/#{proj_slug}/papers/#{link.ref_id}?share=" <>
            URI.encode_www_form(raw_token)
      )
    else
      _ -> serve_paper_static(conn, link)
    end
  end

  defp serve(conn, %ShareLink{} = link, _raw_token), do: serve(conn, link)

  defp serve_paper_static(conn, %ShareLink{} = link) do
    with %Content.Document{} = paper <-
           Content.get_paper(link.ref_id, link.dataset, scope(link)),
         {:ok, body_html} <- paper_body_html(paper, link) do
      # Social-share head (preview-contract pc-w2): a share link IS the sharing
      # flow, so this static render must carry the og/twitter/JSON-LD too. The
      # `:bulldocs` root layout reads `:preview` + `:page_title`.
      preview = paper_preview(paper, link.ref_id)

      conn
      |> put_root_layout(html: {BarkparkWeb.Layouts, :bulldocs})
      |> put_layout(false)
      |> put_view(BarkparkWeb.ScopedPaperHTML)
      |> render(:show,
        article?: paper_article?(paper),
        body_html: body_html,
        preview: preview,
        page_title: preview["title"],
        slug: link.ref_id,
        # The shared ScopedPaperHTML :show template unconditionally renders
        # @backlinks_html / @driven_tasks_html ("" ⇒ no markup). This static
        # fallback serves the bare article — without these the render
        # KeyErrors (charter A8's latent bug).
        backlinks_html: "",
        driven_tasks_html: ""
      )
    else
      # The reader authority refused this paper. Answer with the SAME status the
      # live reader would have — see `paper_body_html/2` below for why the
      # anonymous surface must not soften it.
      {:error, :not_found} -> not_found_html(conn)
      {:error, _reason} -> unprocessable_html(conn)
      _ -> not_found_html(conn)
    end
  end

  # Preview manifest for the share-link static render (preview-contract pc-w2).
  defp paper_preview(%{content: content} = paper, slug) when is_map(content),
    do:
      BarkparkWeb.ShareMeta.manifest(content, "/papers/#{slug}", "paper", Map.get(paper, :title))

  defp paper_preview(_paper, slug),
    do: BarkparkWeb.ShareMeta.manifest(%{}, "/papers/#{slug}", "paper", slug)

  defp serve(conn, %ShareLink{kind: "doc"} = link) do
    case Content.get_document(link.ref_id, link.ref_type, link.dataset, scope(link)) do
      {:ok, doc} ->
        # A public share link is an ANONYMOUS read — `from_conn` yields the
        # most-restrictive baseline, so `private` fields are dropped here too.
        schema =
          case Content.get_schema(link.ref_type, link.dataset, scope(link)) do
            {:ok, s} -> s
            _ -> nil
          end

        json(conn, Envelope.render(doc, schema, CallerContext.from_conn(conn)))

      _ ->
        not_found_json(conn)
    end
  end

  # @sobelow_skip — both findings on this clause are accepted false-positives:
  #   * Traversal.SendFile (send_file/3): `file` is resolved by
  #     `Media.get_file/2` scoped to the LINK's own workspace/project; `.path` is
  #     a server-generated `uploads/YYYY/MM/slug-rand.ext` (`unique_filename/1`
  #     strips directory parts). No request-controlled path reaches `send_file`.
  #   * XSS.ContentType (put_resp_content_type/2): pinned through
  #     `MediaFile.serve_content_type/1` + `nosniff` + an `attachment` disposition
  #     for dangerous types — a stored text/html blob downloads, never executes.
  # sobelow_skip ["Traversal.SendFile", "XSS.ContentType"]
  defp serve(conn, %ShareLink{kind: "media"} = link) do
    case Media.get_file(link.ref_id, scope(link)) do
      {:ok, file} ->
        # PUBLIC anonymous path — the same stored-XSS defense the MediaController
        # serve edge applies (nosniff + collapse svg/html/xml/js to a
        # non-executable octet-stream + `attachment`). Ingest neutralizes NEW
        # uploads and the backfill migration fixed existing rows, but harden the
        # edge too so no future write path can serve an executable type here.
        # The redirect branch (object-storage backend) bakes the SAME collapsed
        # type + disposition into the presigned query, so the bucket echoes them.
        mime = file.mime_type || "application/octet-stream"
        disposition = if MediaFile.dangerous_mime?(mime), do: "attachment", else: "inline"

        case Barkpark.Media.Blobstore.serve_strategy(file.path,
               response_content_type: MediaFile.serve_content_type(mime),
               response_content_disposition: disposition
             ) do
          {:file, full} ->
            conn
            |> put_resp_content_type(MediaFile.serve_content_type(mime))
            |> put_resp_header("x-content-type-options", "nosniff")
            |> put_resp_header("content-disposition", disposition)
            |> send_file(200, full)

          {:redirect, url} ->
            conn
            |> put_resp_header("cache-control", "private, max-age=0, must-revalidate")
            |> redirect(external: url)

          {:error, :not_found} ->
            not_found_json(conn)
        end

      _ ->
        not_found_json(conn)
    end
  end

  # ── ADMIN management ──────────────────────────────────────────────────────

  @doc "POST /v1/shares/links — mint an item link (raw token shown ONCE)."
  def mint(conn, params) do
    with {:ok, {ws, proj, dataset}} <- scope_triple(params["scope"]),
         %Tenancy.Workspace{} = workspace <- Tenancy.get_workspace_by_slug(ws),
         :ok <- ensure_workspace_admin(conn, workspace.id),
         %Tenancy.Project{} = project <- Tenancy.get_project(ws, proj),
         {:ok, kind, ref_type, ref_id} <- item_ref(params),
         access <- access_of(params),
         :ok <- ensure_item_exists(kind, ref_type, ref_id, dataset, workspace, project) do
      attrs = %{
        workspace_id: workspace.id,
        project_id: project.id,
        dataset: dataset,
        kind: kind,
        ref_type: ref_type,
        ref_id: ref_id,
        access: access,
        label: params["label"],
        ttl: parse_ttl(params["ttl"])
      }

      case Links.create(attrs) do
        {:ok, {raw, link}} ->
          conn
          |> put_status(:created)
          |> json(%{token: raw, url: share_url(raw), link: link_json(link)})

        {:error, _changeset} ->
          unprocessable(conn, "could not create link")
      end
    else
      # MUST precede the is_binary arm and the catch-all: a denial that falls
      # into either becomes a 422 and the whole confinement silently voids.
      {:error, :forbidden} ->
        forbidden(conn)

      {:error, msg} when is_binary(msg) ->
        unprocessable(conn, msg)

      _ ->
        unprocessable(conn, "scope, kind (doc|media), ref_id (+ ref_type for docs) are required")
    end
  end

  @doc "GET /v1/shares/links?scope=&kind=&ref_type=&ref_id= — list an item's links."
  def list(conn, params) do
    with {:ok, {ws, proj, _dataset}} <- scope_triple(params["scope"]),
         %Tenancy.Workspace{} = workspace <- Tenancy.get_workspace_by_slug(ws),
         :ok <- ensure_workspace_admin(conn, workspace.id),
         %Tenancy.Project{} <- Tenancy.get_project(ws, proj),
         {:ok, kind, ref_type, ref_id} <- item_ref(params) do
      links = Links.list_for(workspace.id, kind, ref_type, ref_id) |> Enum.map(&link_json/1)
      json(conn, %{links: links})
    else
      # Explicit, ahead of the catch-all — without it the denial is 422 and the
      # foreign-token confinement reads as a validation error.
      {:error, :forbidden} ->
        forbidden(conn)

      _ ->
        unprocessable(conn, "scope, kind, ref_id (+ ref_type for docs) are required")
    end
  end

  @doc "DELETE /v1/shares/links/:id — revoke one link."
  def revoke(conn, %{"id" => id}) do
    case revoke_scoped(conn, id) do
      # RECEIPT LAW (pds w39): `Links.revoke/1` returns the UPDATED link
      # (sharing/links.ex:91-109). The old body was a literal `true` plus an echo
      # of the `:id` path param; both now descend from the returned row's own
      # `revoked_at` stamp, which the request never carries.
      {:ok, revoked} ->
        json(conn, %{
          revoked: not is_nil(revoked.revoked_at),
          id: revoked.id,
          revoked_at: revoked.revoked_at
        })

      {:error, :not_found} ->
        not_found_json(conn, "link not found")

      _ ->
        unprocessable(conn, "could not revoke link")
    end
  end

  # ── tenancy confinement ───────────────────────────────────────────────────
  #
  # The predicate itself now lives at the CONTEXT boundary
  # (`Sharing.Links.workspace_admin?/2`), which both doors onto this surface
  # cross — this controller and `StudioLive.Handlers.ItemShare`. It used to be
  # mirrored as a private helper in each, which is how the `drafts.` clamp came
  # to exist on one door and not the other. Unified by
  # `arpss-w8-bl-links-context-boundary-predicate` now that both halves have
  # merged; the totality reasoning and the authorize/3-vs-workspace_admin?/2
  # ruling moved WITH it and are stated there.
  #
  # The ACTOR is still extracted here, and still as `conn.assigns[:api_token]`
  # SPECIFICALLY — never a generic principal helper, because
  # `CallerContext.from_conn/1` prefers `:caller_context`, which raises. Only
  # the authorization crossed the boundary; principal extraction is web-layer
  # work and stayed put.
  defp workspace_admin?(conn, workspace_id),
    do: Links.workspace_admin?(conn.assigns[:api_token], workspace_id)

  # The denial term is NON-BINARY on purpose: `mint`'s else carries
  # `{:error, msg} when is_binary(msg) -> unprocessable/2`, so a string denial
  # would answer 422 and the confinement would look like a validation quibble.
  defp ensure_workspace_admin(conn, workspace_id) do
    if workspace_admin?(conn, workspace_id), do: :ok, else: {:error, :forbidden}
  end

  # Authorize-and-revoke is `Links.revoke_scoped/2` now; the denial shape (every
  # failure collapsing to one `{:error, :not_found}`, so a foreign row is
  # byte-identical to a missing one) is stated and tested there.
  defp revoke_scoped(conn, id),
    do: Links.revoke_scoped(conn.assigns[:api_token], id)

  defp forbidden(conn) do
    ErrorResponse.emit(conn, {:error, :forbidden}, "workspace access required")
  end

  # ── helpers ────────────────────────────────────────────────────────────

  defp scope(link), do: [workspace_id: link.workspace_id, project_id: link.project_id]

  defp scope_triple(scope) when is_binary(scope), do: Sharing.scope_triple(scope)
  defp scope_triple(_), do: {:error, "scope is required (ws[/project[/dataset]])"}

  # kind=doc needs ref_type + ref_id; kind=media needs ref_id only.
  # `published_ref_id/1` is applied HERE, before `ensure_item_exists/6`, so the
  # existence check runs against the id `Links.create/1` will actually persist.
  # Normalising only at the context would mint a link to a published id whose
  # row does not exist whenever a paper exists ONLY as a draft — a dead `/s/`
  # URL instead of a 422.
  defp item_ref(%{"kind" => "media", "ref_id" => ref_id}) when is_binary(ref_id) and ref_id != "",
    do: {:ok, "media", nil, Links.published_ref_id(ref_id)}

  defp item_ref(%{"kind" => "doc", "ref_type" => rt, "ref_id" => ref_id})
       when is_binary(rt) and rt != "" and is_binary(ref_id) and ref_id != "",
       do: {:ok, "doc", rt, Links.published_ref_id(ref_id)}

  defp item_ref(_), do: {:error, "kind must be doc (with ref_type) or media, plus ref_id"}

  defp access_of(%{"access" => "edit"}), do: "edit"
  defp access_of(_), do: "read"

  defp ensure_item_exists("doc", "paper", ref_id, dataset, ws, proj) do
    case Content.get_paper(ref_id, dataset, workspace_id: ws.id, project_id: proj.id) do
      %Content.Document{} -> :ok
      _ -> {:error, "no such paper in this scope"}
    end
  end

  defp ensure_item_exists("doc", ref_type, ref_id, dataset, ws, proj) do
    case Content.get_document(ref_id, ref_type, dataset, workspace_id: ws.id, project_id: proj.id) do
      {:ok, _} -> :ok
      _ -> {:error, "no such document in this scope"}
    end
  end

  defp ensure_item_exists("media", _rt, ref_id, _dataset, ws, proj) do
    case Media.get_file(ref_id, workspace_id: ws.id, project_id: proj.id) do
      {:ok, _} -> :ok
      _ -> {:error, "no such media file in this scope"}
    end
  end

  defp parse_ttl(t) when is_integer(t) and t > 0, do: t

  defp parse_ttl(t) when is_binary(t) do
    case Integer.parse(t) do
      {n, _} when n > 0 -> n
      _ -> nil
    end
  end

  defp parse_ttl(_), do: nil

  defp link_json(%ShareLink{} = l) do
    %{
      id: l.id,
      kind: l.kind,
      ref_type: l.ref_type,
      ref_id: l.ref_id,
      access: l.access,
      dataset: l.dataset,
      label: l.label,
      # the STABLE, re-copyable link (P7 UX) on the advertised share host (tunnel
      # / LAN / domain). Present whenever the raw token was stored; `token_hash`
      # (the secret-at-rest digest) is never exposed.
      url: l.token && share_url(l.token),
      expires_at: l.expires_at,
      revoked_at: l.revoked_at,
      inserted_at: Map.get(l, :inserted_at)
    }
  end

  # The shareable absolute link on the advertised host (tunnel / domain / LAN),
  # or relative when no share host is detectable (caller prepends its own host).
  defp share_url(token), do: "#{Sharing.share_link_base() || ""}/s/#{token}"

  # Static fallback goes through the SAME authority as every live Paper reader:
  # `Content.Papers.reader_source/3`. It used to pick the source itself —
  # `Projection.read_blocks/1` on the RAW content, else `content["body_html"]`
  # verbatim — which read the two inputs the authority exists to arbitrate and
  # applied none of its rules. That bought this surface three concrete defects,
  # and all three were ANONYMOUS-surface defects specifically:
  #
  #   * NO PROVENANCE CHECK. `reader_source/3` compares the cache against a
  #     fresh render and splits the mismatch by the `content["body_html_sv"]`
  #     renderer stamp: a lagging stamp is DRIFT (blocks are canonical — serve
  #     and restamp), a CURRENT stamp is DIVERGENCE (the row claims this
  #     renderer emitted these bytes from these blocks, the bytes say
  #     otherwise, so the cache carries content the blocks do not). Divergence
  #     is the one population the 422 was built for. This path silently served
  #     the blocks and answered 200, picking a winner in exactly the case the
  #     authority refuses to pick one.
  #   * NO REDACTION. `reader_source/3` reads its blocks off `Envelope.render`
  #     under `CallerContext.anonymous()`, so a `private` field is gone before
  #     a block list is chosen, and a structured source that vanished at that
  #     boundary yields `:redacted_source` rather than falling through to the
  #     cache — because `body_html` is a derived cache of the same prose, so
  #     falling through discloses what redaction just hid. Reading
  #     `Projection.read_blocks/1` off raw `content` skipped that entirely. A
  #     `/s/:token` recipient is an ANONYMOUS reader, which makes this the
  #     surface those rules were written for, not one that may opt out.
  #   * NO SANITIZATION. The `{:html, …}` arm returns `HtmlSanitizer`-filtered
  #     HTML that passed a semantic-content check. The old `nil` arm handed raw
  #     stored `body_html` to `ScopedPaperHTML`'s `raw(@body_html)`.
  #
  # WHY THE ANONYMOUS SURFACE KEEPS THE 422 rather than degrading to a partial
  # render: this render is the FALLBACK for the redirect in `serve/3` above. A
  # recipient whose link scope still resolves lands on `BulldocsLive`, which
  # raises `InvalidSource` (`plug_status: 422`) on any `{:error, _}` from the
  # same call. If this fallback answered 200 with a best-effort body, the
  # public escape hatch would be a SOFTER door than the door it substitutes
  # for — which is the whole shape of the defect. `BulldocsEmailController` and
  # `BulldocsSourceController` refuse at 422 on the same tuple; the status is
  # the house rule for "a paper exists but has no unambiguous readable source",
  # and the rendered page is `ErrorHTML`'s generic card, so the refusal REASON
  # (which would distinguish "redacted content exists here" from "this paper is
  # empty") is never disclosed to the token holder.
  #
  # This deliberately does NOT copy Studio's raw read: an editor is an
  # authenticated author looking at their own document, so it may see the
  # unredacted, unsanitized source. This surface may not.
  #
  # Reference resolution stays bound to the LINK scope (not request/global
  # scope) — `reader_schema_scope/2` only fills in the paper's own ids where
  # the caller passed none, so the ids from `scope/1` win.
  defp paper_body_html(%Content.Document{} = paper, %ShareLink{} = link) do
    case Content.Papers.reader_source(paper, link.dataset, scope(link)) do
      {:blocks, blocks} ->
        render_opts =
          Labels.paper_render_opts(
            link.dataset,
            Map.get(paper.content || %{}, "style"),
            scope(link)
          )

        {:ok, Render.render_blocks(blocks, render_opts)}

      {:html, sanitized_html} ->
        {:ok, sanitized_html}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp paper_body_html(_paper, _link), do: {:error, :not_found}

  defp paper_article?(%{content: content}),
    do: Map.get(content || %{}, "style") in ["article", "article-wide"]

  # Canonical v1 error envelope (code + request_id) for the JSON API paths — the
  # same contract as the content endpoints; was a bare `%{error: msg}` with
  # neither. The HTML reader (not_found_html/1) intentionally stays an HTML page.
  defp unprocessable(conn, msg) do
    env =
      {:error, :malformed}
      |> Errors.to_envelope(conn)
      |> Map.put(:code, "validation_failed")
      |> Map.put(:message, msg)

    conn |> put_status(422) |> json(%{error: Map.delete(env, :status)})
  end

  defp not_found_json(conn, message \\ "link not found or expired") do
    env =
      {:error, :not_found}
      |> Errors.to_envelope(conn)
      |> Map.put(:message, message)

    conn |> put_status(env.status) |> json(%{error: Map.delete(env, :status)})
  end

  defp not_found_html(conn) do
    conn
    |> put_status(:not_found)
    |> put_view(BarkparkWeb.ErrorHTML)
    |> render(:"404")
  end

  # The HTML twin of `unprocessable/2`: the static paper render is a browser
  # page, so an unreadable source answers with the generic `ErrorHTML` card at
  # the same 422 the live reader raises. The refusal reason stays server-side —
  # the page is derived from the template name only.
  defp unprocessable_html(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(BarkparkWeb.ErrorHTML)
    |> render(:"422")
  end
end
