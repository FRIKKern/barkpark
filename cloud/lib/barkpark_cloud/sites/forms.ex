defmodule BarkparkCloud.Sites.Forms do
  @moduledoc """
  The control-plane half of hosted-site forms (task-71082f5541c13b53, N-08
  criterion 2): turn a site's form endpoint on or off, and read, triage and
  export the submissions it collected.

  ## Where the data lives

  Nothing here is stored in the control plane except one bit,
  `sites.forms_enabled`, which the deploy payload reads to hand the build its
  `BARKPARK_FORMS_URL` (the template's opt-in). Everything else lives on the
  box, in the dataset the site is bound to (`bootstrap_workspace` /
  `bootstrap_project` / `bootstrap_dataset`):

      form_endpoint   form-endpoint-<slug>   the opt-in the box's public
                                             intake route reads (enabled,
                                             allowed_origins, fields)
      form_submission one per accepted post  written by the box's intake,
                                             stored as a DRAFT

  Both types are private, so every read and write here goes over the instance
  admin relay (`Registry.relay_admin/4`), always on the SCOPED
  `/w/:ws/p/:proj/v1/data/*` routes of the site's own binding — the same
  workspace, project and dataset the intake writes to, and no other.

  ## Site identity inside a shared dataset

  Two sites may be bound to the same dataset. A submission carries its site
  slug in `content.site`, so:

    * the list reads `filter[site]=<slug>`;
    * a state change reads the one document FIRST and refuses (`:not_found`)
      unless its `site` is this site's slug — an id from another site's inbox
      in the same dataset is not reachable through this site's route;
    * export filters the selected ids through the same site-scoped list.

  ## Why the endpoint document is written and then published

  The intake reads the PUBLISHED `form-endpoint-<slug>` first and falls back
  to the draft. A `createOrReplace` alone writes a draft, so a disable written
  as a draft would sit behind an older published `enabled: true` and change
  nothing. Every write here is `createOrReplace` + `publish` in one atomic
  batch, so what the intake reads is always what the console last set.
  """

  alias BarkparkCloud.Registry
  alias BarkparkCloud.Registry.{Barkpark, Site}

  @submission_type "form_submission"
  @endpoint_type "form_endpoint"

  # The template's contact form posts exactly these (templates/astro-starter
  # `src/lib/forms.ts` `CONTACT_FIELDS`). The box refuses any other field name
  # with a 422, so the two lists must agree.
  @default_fields ~w(name email message)

  @states ~w(new seen)
  @spam_dispositions ~w(clean suspected spam)

  # The box's query route caps `limit` at 1000; the inbox shows the newest 200.
  @list_limit 200
  @export_limit 1000

  @doc "The field names a newly enabled endpoint accepts."
  def default_fields, do: @default_fields

  @doc "Inbox lifecycle states the box's contract accepts."
  def states, do: @states

  @doc "Spam dispositions the box's contract accepts."
  def spam_dispositions, do: @spam_dispositions

  @doc "The deterministic id of the site's `form_endpoint` document on the box."
  def endpoint_doc_id(%Site{slug: slug}), do: "form-endpoint-" <> slug

  @doc """
  The site's content binding as `{:ok, {workspace, project, dataset}}`, or
  `{:error, :no_content_binding}` when any of the three is blank.
  """
  def content_binding(%Site{} = site) do
    triple = {site.bootstrap_workspace, site.bootstrap_project, site.bootstrap_dataset}

    if Enum.all?(Tuple.to_list(triple), &(is_binary(&1) and &1 != "")),
      do: {:ok, triple},
      else: {:error, :no_content_binding}
  end

  @doc """
  The public URL the site's form posts to — the box's intake route for this
  site's binding — or `nil` when the site has no binding or the box no URL.
  """
  def endpoint_url(%Site{} = site, %Barkpark{url: url}) when is_binary(url) and url != "" do
    case content_binding(site) do
      {:ok, {ws, proj, ds}} ->
        String.trim_trailing(url, "/") <>
          "/v1/plugins/forms/w/#{enc(ws)}/p/#{enc(proj)}/d/#{enc(ds)}/sites/#{enc(site.slug)}/submissions"

      _ ->
        nil
    end
  end

  def endpoint_url(_site, _bp), do: nil

  @doc """
  The origins the endpoint accepts posts from: the box's own origin (a hosted
  site is served at `<box>/sites/<slug>/`, so the page's `Origin` is the box's)
  plus `https://<domain>` for every custom domain attached to the site.

  The box origin is shared by every site on that box — `Origin` is a browser
  binding, not authentication (see the intake controller's moduledoc); what
  bounds a post is the URL's scope and the box's two rate buckets.
  """
  def allowed_origins(%Site{} = site, %Barkpark{url: url}) when is_binary(url) do
    box = origin_of(url)

    domains =
      (site.domains || [])
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.map(&("https://" <> String.downcase(&1)))

    Enum.uniq(Enum.reject([box | domains], &is_nil/1))
  end

  # No box row (or one without a URL yet): nothing can post, nothing is allowed.
  def allowed_origins(_site, _bp), do: []

  defp origin_of(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, port: port}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        default = if scheme == "https", do: 443, else: 80
        base = "#{scheme}://#{String.downcase(host)}"
        if port in [nil, default], do: base, else: "#{base}:#{port}"

      _ ->
        nil
    end
  end

  defp origin_of(_), do: nil

  # ── the endpoint document ───────────────────────────────────────────────────

  @doc """
  Read the endpoint's state from the box, with the intake's own precedence:
  `perspective=raw` answers the published document when one exists and the
  draft otherwise — exactly what `Intake.resolve_endpoint/4` on the box reads.

  `{:ok, %{present: false}}` when the box holds no endpoint document for the
  site; `{:ok, %{present: true, enabled:, allowed_origins:, fields:}}` when it
  does. A box without the forms plugin answers `{:error, :forms_unsupported}`.
  """
  def endpoint(%Site{} = site, bp) do
    with {:ok, {ws, proj, ds}} <- content_binding(site),
         :ok <- ensure_plugin(bp) do
      path =
        scoped(ws, proj) <>
          "/v1/data/doc/#{enc(ds)}/#{@endpoint_type}/#{enc(endpoint_doc_id(site))}?perspective=raw"

      case Registry.relay_admin(bp, :get, path) do
        {:ok, status, %{"result" => %{} = doc}} when status in 200..299 ->
          {:ok,
           %{
             present: true,
             enabled: doc["enabled"] == true,
             allowed_origins: list_of_strings(doc["allowed_origins"]),
             fields: list_of_strings(doc["fields"])
           }}

        {:ok, 404, _} ->
          {:ok, %{present: false}}

        other ->
          relay_error(other)
      end
    end
  end

  @doc """
  Write the endpoint document with `enabled` and publish it, in one batch.

  Both directions write the whole document: the default field list (what the
  template's form posts) and the site's CURRENT allowed origins, so turning
  forms off and on again also picks up a domain attached in between. The box
  refuses the write with a 422 if the document breaks the contract; nothing is
  written then.
  """
  def put_endpoint(%Site{} = site, bp, enabled?) when is_boolean(enabled?) do
    with {:ok, {ws, proj, ds}} <- content_binding(site),
         :ok <- ensure_plugin(bp),
         origins when origins != [] <- allowed_origins(site, bp) do
      id = endpoint_doc_id(site)

      doc = %{
        "_id" => id,
        "_type" => @endpoint_type,
        "title" => "Form endpoint — #{site.slug}",
        "content" => %{
          "site" => site.slug,
          "enabled" => enabled?,
          "allowed_origins" => origins,
          "fields" => @default_fields
        }
      }

      body = %{
        "mutations" => [
          %{"createOrReplace" => doc},
          %{"publish" => %{"id" => id, "type" => @endpoint_type}}
        ]
      }

      case Registry.relay_admin(bp, :post, scoped(ws, proj) <> "/v1/data/mutate/#{enc(ds)}", body) do
        {:ok, status, _} when status in 200..299 ->
          {:ok,
           %{present: true, enabled: enabled?, allowed_origins: origins, fields: @default_fields}}

        other ->
          relay_error(other)
      end
    else
      [] -> {:error, :not_live}
      err -> err
    end
  end

  # The box's installed-plugin roster (`GET /v1/plugins`, admin + operator
  # tier — the same tier the site-deploy relay already uses). A box whose
  # roster does not name `forms` has no intake route, so enabling there would
  # store an opt-in nothing reads.
  defp ensure_plugin(bp) do
    case Registry.relay_admin(bp, :get, "/v1/plugins") do
      {:ok, status, %{"plugins" => plugins}} when status in 200..299 and is_list(plugins) ->
        if Enum.any?(plugins, &match?(%{"name" => "forms"}, &1)),
          do: :ok,
          else: {:error, :forms_unsupported}

      other ->
        relay_error(other)
    end
  end

  # ── submissions ─────────────────────────────────────────────────────────────

  @doc """
  The site's submissions, newest first: `{:ok, %{submissions: [...], has_more: bool}}`.

  `opts[:limit]` caps the page (default #{@list_limit}, at most #{@export_limit}).
  """
  def list(%Site{} = site, bp, opts \\ []) do
    limit = opts |> Keyword.get(:limit, @list_limit) |> min(@export_limit) |> max(1)

    with {:ok, {ws, proj, ds}} <- content_binding(site) do
      query =
        URI.encode_query([
          {"perspective", "drafts"},
          {"limit", Integer.to_string(limit)},
          {"order", "received_at:desc"},
          {"filter[site]", site.slug}
        ])

      path = scoped(ws, proj) <> "/v1/data/query/#{enc(ds)}/#{@submission_type}?" <> query

      case Registry.relay_admin(bp, :get, path) do
        {:ok, status, %{"result" => %{"documents" => docs} = result}}
        when status in 200..299 and is_list(docs) ->
          subs =
            docs
            |> Enum.filter(&(is_map(&1) and &1["site"] == site.slug))
            |> Enum.map(&submission_json/1)

          {:ok, %{submissions: subs, has_more: result["hasMore"] == true}}

        # The box has no `form_submission` type at all: the forms plugin is
        # not installed there.
        {:ok, 404, _} ->
          {:error, :forms_unsupported}

        other ->
          relay_error(other)
      end
    end
  end

  @doc """
  Change one submission's `state` and/or `spam`.

  `changes` is a map with `"state"` and/or `"spam"`; anything else is ignored,
  an out-of-contract value is `{:error, :invalid}`. The document is read first
  and must belong to THIS site (`content.site == site.slug`), or the answer is
  `{:error, :not_found}` — the same answer as an id that does not exist.
  """
  def update_submission(%Site{} = site, bp, sub_id, changes)
      when is_binary(sub_id) and is_map(changes) do
    set =
      changes
      |> Map.take(["state", "spam"])
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    cond do
      set == %{} ->
        {:error, :invalid}

      Map.has_key?(set, "state") and set["state"] not in @states ->
        {:error, :invalid}

      Map.has_key?(set, "spam") and set["spam"] not in @spam_dispositions ->
        {:error, :invalid}

      not submission_id?(sub_id) ->
        {:error, :not_found}

      true ->
        with {:ok, {ws, proj, ds}} <- content_binding(site),
             {:ok, doc} <- fetch_submission(site, bp, ws, proj, ds, sub_id) do
          patch = %{
            "id" => doc["_id"],
            "type" => @submission_type,
            "set" => set,
            "ifRevisionID" => doc["_rev"]
          }

          body = %{"mutations" => [%{"patch" => patch}]}

          case Registry.relay_admin(
                 bp,
                 :post,
                 scoped(ws, proj) <> "/v1/data/mutate/#{enc(ds)}",
                 body
               ) do
            {:ok, status, _} when status in 200..299 ->
              {:ok, submission_json(Map.merge(doc, set))}

            {:ok, 412, _} ->
              {:error, :conflict}

            other ->
              relay_error(other)
          end
        end
    end
  end

  def update_submission(_site, _bp, _sub_id, _changes), do: {:error, :invalid}

  defp fetch_submission(site, bp, ws, proj, ds, sub_id) do
    path =
      scoped(ws, proj) <>
        "/v1/data/doc/#{enc(ds)}/#{@submission_type}/#{enc(published_id(sub_id))}?perspective=drafts"

    case Registry.relay_admin(bp, :get, path) do
      {:ok, status, %{"result" => %{"_type" => @submission_type} = doc}}
      when status in 200..299 ->
        if doc["site"] == site.slug, do: {:ok, doc}, else: {:error, :not_found}

      {:ok, status, _} when status in 200..299 ->
        {:error, :not_found}

      {:ok, 404, _} ->
        {:error, :not_found}

      other ->
        relay_error(other)
    end
  end

  @doc """
  The selected submissions of this site, for export. `ids` are the inbox ids
  (`submission_json/1`'s `id`); ids that are not this site's submissions are
  reported in `missing`, never silently dropped.
  """
  def export(%Site{} = site, bp, ids) when is_list(ids) do
    wanted = ids |> Enum.filter(&is_binary/1) |> Enum.map(&published_id/1) |> Enum.uniq()

    with {:ok, %{submissions: subs}} <- list(site, bp, limit: @export_limit) do
      by_id = Map.new(subs, &{&1.id, &1})
      found = wanted |> Enum.map(&Map.get(by_id, &1)) |> Enum.reject(&is_nil/1)
      {:ok, %{submissions: found, missing: wanted -- Enum.map(found, & &1.id)}}
    end
  end

  @doc """
  The inbox's view of one box document: the published id, timestamps,
  lifecycle, spam disposition, the posted fields and where the post came from.
  """
  def submission_json(doc) when is_map(doc) do
    %{
      id: published_id(doc["_publishedId"] || doc["_id"] || ""),
      received_at: doc["received_at"],
      state: doc["state"],
      spam: doc["spam"],
      spam_reasons: list_of_strings(doc["spam_reasons"]),
      fields: if(is_map(doc["fields"]), do: doc["fields"], else: %{}),
      source: if(is_map(doc["source"]), do: doc["source"], else: %{})
    }
  end

  @doc """
  CSV of exported submissions: `id,received_at,state,spam,<field…>,origin`,
  one column per field name any selected row carries (sorted), list values
  joined with `; `. RFC 4180 quoting; a cell that starts with `=`, `+`, `-`
  or `@` is prefixed with `'` so a spreadsheet never evaluates a visitor's
  input as a formula.
  """
  def to_csv(submissions) when is_list(submissions) do
    field_names =
      submissions
      |> Enum.flat_map(&Map.keys(&1.fields))
      |> Enum.uniq()
      |> Enum.sort()

    header = ["id", "received_at", "state", "spam"] ++ field_names ++ ["origin"]

    rows =
      Enum.map(submissions, fn s ->
        [s.id, s.received_at, s.state, s.spam] ++
          Enum.map(field_names, &field_cell(Map.get(s.fields, &1))) ++
          [Map.get(s.source, "origin")]
      end)

    Enum.map_join([header | rows], "", fn row ->
      Enum.map_join(row, ",", &csv_cell/1) <> "\r\n"
    end)
  end

  defp field_cell(v) when is_list(v), do: Enum.join(v, "; ")
  defp field_cell(v), do: v

  defp csv_cell(nil), do: ""

  defp csv_cell(v) do
    s = to_string(v)
    s = if String.starts_with?(s, ["=", "+", "-", "@"]), do: "'" <> s, else: s

    if String.contains?(s, [",", "\"", "\r", "\n"]),
      do: "\"" <> String.replace(s, "\"", "\"\"") <> "\"",
      else: s
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  # Box document ids: the intake's are UUIDs, a `drafts.` prefix on the draft
  # twin. Anything outside this shape is never sent to the box.
  @submission_id ~r/\A(drafts\.)?[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/

  defp submission_id?(id), do: Regex.match?(@submission_id, id)

  defp published_id("drafts." <> rest), do: rest
  defp published_id(id), do: id

  defp scoped(ws, proj), do: "/w/#{enc(ws)}/p/#{enc(proj)}"

  defp enc(s), do: URI.encode(s, &URI.char_unreserved?/1)

  defp list_of_strings(v) when is_list(v), do: Enum.filter(v, &is_binary/1)
  defp list_of_strings(_), do: []

  # Every relay outcome that is not the arm a caller handled becomes one of the
  # refusal atoms the router maps to a status.
  defp relay_error({:error, reason}) when reason in [:not_live, :no_admin_token, :decrypt_failed],
    do: {:error, reason}

  defp relay_error({:error, _}), do: {:error, :instance_error}
  defp relay_error({:ok, status, _}), do: {:error, {:instance, status}}
end
