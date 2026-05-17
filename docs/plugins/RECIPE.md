# Plugin Recipe — building "Vlie" from scratch

> A worked walkthrough. For the formal contract every file conforms to, see
> [ARCHITECTURE.md](ARCHITECTURE.md). For the retrospective on why the
> contract exists, see [INTEGRATION_LESSONS.md](INTEGRATION_LESSONS.md).

This recipe builds a plausible fictional plugin called **Vlie** — a Dutch
ONIX 3.0 distributor that ingests book metadata via REST and reports sync
status. Vlie does not own a schema (it rides on OnixEdit's `book` schema)
but it does own:

- A schema-declared `publish_to_vlie` modal action with dryrun + real stages
- An `ExternalSync` registry entry so the Studio pill shows Vlie status
  alongside Bokbasen
- An HTTP client to Vlie's API
- An Oban worker for async publish + status polling
- A status read/write façade for the `bp_vlie_status` document field
- A test asserting the action dispatches cleanly

No LiveView. No HEEx. No CSS. No JavaScript. No new route (the host serves
all Studio pages; Vlie has no file-download endpoint). Eight code files
and three small edits to host files. The whole feature lights up by
restarting the server.

## The eight new files

```
api/
├── lib/barkpark/plugins/
│   ├── vlie.ex
│   └── vlie/
│       ├── actions.ex
│       ├── client.ex
│       ├── publish_worker.ex
│       └── status.ex
├── priv/plugins/vlie/
│   └── plugin.json
└── test/barkpark/plugins/vlie/
    └── actions_test.exs
```

## The three host edits

1. One new entry in `Barkpark.ExternalSync.@entries` (so the pill renders).
2. One new clause in `StudioLive.dispatch_action/4` (so the schema action
   routes to Vlie).
3. One new entry in OnixEdit's `book.json` `actions` array (so the editor
   header surfaces the button) — OR, if Vlie owns its own schema, one new
   entry in its own JSON.

All three edits are single lines. Total host footprint: ~10 lines.

## File 1 — `priv/plugins/vlie/plugin.json`

```json
{
  "plugin_name": "vlie",
  "version": "0.1.0",
  "description": "Vlie — Dutch ONIX 3.0 distributor sync (publish + status).",
  "capabilities": ["external_sync"],
  "module": "Barkpark.Plugins.Vlie",
  "schemas": []
}
```

Notes:

- `capabilities` declares what the plugin contributes. Vlie ships no
  schemas, so the array is empty. (`schemas` capability would be listed if
  it did.)
- `module` is the Elixir entry module the bootstrap will load.

## File 2 — `lib/barkpark/plugins/vlie.ex`

```elixir
defmodule Barkpark.Plugins.Vlie do
  @moduledoc """
  Vlie — Dutch ONIX 3.0 distributor sync plugin.

  Rides on OnixEdit's existing `book` schema; contributes no schemas of its
  own. The plugin's `register_schemas/1` returns `[]` (the default).

  Surfaces:

    * `Barkpark.Plugins.Vlie.Actions.publish_to_vlie/3` — schema-action
      handler dispatched by StudioLive on the editor's `publish_to_vlie`
      modal action.

    * `Barkpark.Plugins.Vlie.Client` — REST client for Vlie's publish +
      status endpoints. Authenticates via a token fetched from
      `Plugins.Settings` (encrypted at rest).

    * `Barkpark.Plugins.Vlie.PublishWorker` — Oban worker that POSTs
      ONIX XML and polls for status. Writes transitions through
      `Vlie.Status.write/2`, which broadcasts on the generic
      `external_sync:vlie:<doc_id>` topic so the native `ExternalSyncPill`
      flips without a plugin component.

  No LiveView. No HEEx. No CSS. The host renders everything.
  """

  use Barkpark.Plugin,
    manifest_path: "../../../priv/plugins/vlie/plugin.json"

  @plugin_name "vlie"

  @doc "Plugin discriminator name."
  @spec plugin_name() :: String.t()
  def plugin_name, do: @plugin_name

  @impl Barkpark.Plugin
  def register_schemas(_opts), do: []
end
```

The `use Barkpark.Plugin, manifest_path: ...` macro reads and validates the
JSON manifest at compile time — no runtime evaluation (Decision D7).
`register_schemas/1` returning `[]` is explicit; the default behaviour is
the same, but stating the intent saves a future reader the lookup.

## File 3 — `lib/barkpark/plugins/vlie/client.ex`

```elixir
defmodule Barkpark.Plugins.Vlie.Client do
  @moduledoc """
  HTTP client for Vlie's metadata-import REST API.

  Two endpoints:

      POST  /v1/onix/publish       → {:ok, %{submission_id, poll_url}}
      GET   /v1/onix/status/<id>   → {:ok, %{status, details}}

  Auth via bearer token stored in `Plugins.Settings` (encrypted) under
  the `"vlie"` row. Token-fetch is lazy — first call resolves it.
  """

  alias Barkpark.Plugins.Settings

  @default_base "https://api.vlie.example.com"
  @default_timeout_ms 30_000

  @spec publish(binary(), keyword()) ::
          {:ok, %{submission_id: String.t(), poll_url: String.t()}}
          | {:error, term()}
  def publish(onix_xml, opts \\ []) when is_binary(onix_xml) do
    url = base_url(opts) <> "/v1/onix/publish"
    headers = auth_headers() ++ [{"content-type", "application/xml"}]

    case do_request(:post, url, headers, onix_xml, opts) do
      {:ok, %{status: s, body: body}} when s in [200, 201, 202] ->
        case Jason.decode(body) do
          {:ok, %{"submission_id" => sid, "poll_url" => pu}} ->
            {:ok, %{submission_id: sid, poll_url: pu}}

          _ ->
            {:error, {:bad_response, body}}
        end

      {:ok, resp} ->
        {:error, {:http_error, resp.status, resp.body}}

      {:error, _} = err ->
        err
    end
  end

  @spec poll(String.t(), keyword()) ::
          {:ok, %{status: :pending | :accepted | :rejected, details: map()}}
          | {:error, term()}
  def poll(submission_id, opts \\ []) when is_binary(submission_id) do
    url = base_url(opts) <> "/v1/onix/status/#{submission_id}"

    case do_request(:get, url, auth_headers(), nil, opts) do
      {:ok, %{status: 200, body: body}} ->
        with {:ok, %{"status" => state} = m} <- Jason.decode(body),
             {:ok, atom} <- atomize(state) do
          {:ok, %{status: atom, details: m}}
        else
          _ -> {:error, {:bad_response, body}}
        end

      {:ok, resp} ->
        {:error, {:http_error, resp.status, resp.body}}

      {:error, _} = err ->
        err
    end
  end

  # ── private ─────────────────────────────────────────────────────────────

  defp do_request(method, url, headers, body, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout_ms)

    req_opts =
      [
        url: url,
        method: method,
        headers: headers,
        receive_timeout: timeout,
        retry: false,
        decode_body: false
      ]
      |> maybe_put_body(body)

    try do
      Req.request(Req.new(req_opts))
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  defp maybe_put_body(opts, nil), do: opts
  defp maybe_put_body(opts, body), do: Keyword.put(opts, :body, body)

  defp auth_headers do
    case Settings.get("vlie") do
      {:ok, %{"api_token" => token}} when is_binary(token) ->
        [{"authorization", "Bearer " <> token}]

      _ ->
        []
    end
  end

  defp base_url(opts) do
    case Keyword.get(opts, :base_url) do
      url when is_binary(url) and url != "" -> url
      _ ->
        case Settings.get("vlie") do
          {:ok, %{"api_base" => url}} when is_binary(url) and url != "" -> url
          _ -> @default_base
        end
    end
  end

  defp atomize("pending"), do: {:ok, :pending}
  defp atomize("accepted"), do: {:ok, :accepted}
  defp atomize("rejected"), do: {:ok, :rejected}
  defp atomize(_), do: :error
end
```

The client uses `Barkpark.Plugins.Settings.get/1` for credentials —
encrypted-at-rest via Cloak, no env-var leakage, audited on read/write.
Configure once via `Plugins.Settings.put("vlie", %{"api_token" =>
"demo-token", "api_base" => "https://api.vlie.example.com"})`.

## File 4 — `lib/barkpark/plugins/vlie/status.ex`

```elixir
defmodule Barkpark.Plugins.Vlie.Status do
  @moduledoc """
  Read/write façade for `bp_vlie_status` on a book document.

  Stored as a native composite map under `document.content["bp_vlie_status"]`.
  Every write merges the patch over the current composite, stamps
  `updated_at`, persists via `Document.changeset/2`, and broadcasts on the
  generic `external_sync:vlie:<doc_id>` topic. The `ExternalSyncPill`
  rendered by StudioLive picks up the broadcast and re-renders without a
  plugin component.
  """

  alias Barkpark.Content.Document
  alias Barkpark.ExternalSync
  alias Barkpark.Repo

  @spec read(Document.t() | map() | nil) :: map()
  def read(%Document{content: content}) when is_map(content) do
    content |> Map.get("bp_vlie_status") |> normalize()
  end

  def read(%{} = content) do
    content |> Map.get("bp_vlie_status") |> normalize()
  end

  def read(_), do: %{}

  @spec write(Document.t(), map()) :: Document.t()
  def write(%Document{} = doc, patch) when is_map(patch) do
    fresh = Repo.get!(Document, doc.id)
    current = read(fresh)

    merged =
      current
      |> Map.merge(stringify_keys(patch))
      |> Map.put("updated_at", DateTime.utc_now() |> DateTime.to_iso8601())

    new_content = Map.put(fresh.content || %{}, "bp_vlie_status", merged)

    {:ok, updated} =
      fresh
      |> Document.changeset(%{"content" => new_content})
      |> Repo.update()

    ExternalSync.broadcast("vlie", doc.doc_id, merged["state"], merged)
    updated
  end

  # ── private ─────────────────────────────────────────────────────────────

  defp normalize(nil), do: %{}
  defp normalize(""), do: %{}
  defp normalize(%{} = m), do: m
  defp normalize(_), do: %{}

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
end
```

The single `ExternalSync.broadcast("vlie", ...)` call is the entire UI
integration. No plugin component, no `phx-update`, no custom CSS class.
The host's `ExternalSyncPill` reads its own registry entry (next file) and
flips colour automatically.

## File 5 — `lib/barkpark/plugins/vlie/publish_worker.ex`

```elixir
defmodule Barkpark.Plugins.Vlie.PublishWorker do
  @moduledoc """
  Oban worker driving a single Vlie publish + poll cycle.

  State machine:

      :pending → :staging → :staged → :polling → :accepted
                                               ↘ :rejected
                                               ↘ :failed

  Stage step POSTs the ONIX XML, persists the `submission_id`, and snoozes
  for an initial poll delay. Poll step GETs status; on `:pending` it
  re-snoozes; on terminal status it writes the final state and returns
  `:ok`. Re-runs against the same document with an existing
  `submission_id` skip the stage and resume polling — idempotent against
  Oban retries.
  """

  use Oban.Worker, queue: :vlie, max_attempts: 5

  require Logger

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Plugins.OnixEdit.Export
  alias Barkpark.Plugins.Vlie.Client
  alias Barkpark.Plugins.Vlie.Status

  @poll_initial_delay_s 5

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    doc_id = args["document_id"]
    type = args["type"] || "book"
    dataset = args["dataset"] || "production"

    case Content.get_document(doc_id, type, dataset) do
      {:error, :not_found} ->
        {:cancel, :document_missing}

      {:ok, %Document{} = doc} ->
        status = Status.read(doc)

        case status["submission_id"] do
          sid when is_binary(sid) and sid != "" -> poll_step(doc, sid)
          _ -> stage_step(doc)
        end
    end
  end

  defp stage_step(%Document{} = doc) do
    Status.write(doc, %{"state" => "staging"})
    book_doc = book_doc_from(doc)

    with {:ok, iodata} <- Export.to_iodata(book_doc),
         binary = IO.iodata_to_binary(iodata),
         {:ok, %{submission_id: sid, poll_url: pu}} <- Client.publish(binary) do
      Status.write(doc, %{
        "state" => "staged",
        "submission_id" => sid,
        "poll_url" => pu,
        "staged_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      })

      {:snooze, @poll_initial_delay_s}
    else
      {:error, {:xsd_invalid, reasons}} ->
        Status.write(doc, %{
          "state" => "failed",
          "last_error" => %{"type" => "xsd_invalid", "details" => Enum.join(reasons, "; ")}
        })

        {:cancel, :xsd_invalid}

      {:error, reason} ->
        Status.write(doc, %{
          "state" => "failed",
          "last_error" => %{"type" => "publish_failed", "details" => inspect(reason)}
        })

        {:cancel, :publish_failed}
    end
  end

  defp poll_step(%Document{} = doc, sid) do
    case Client.poll(sid) do
      {:ok, %{status: :pending}} ->
        Status.write(doc, %{"state" => "polling"})
        {:snooze, 10}

      {:ok, %{status: :accepted, details: details}} ->
        Status.write(doc, %{
          "state" => "accepted",
          "accepted_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "details" => details
        })

        :ok

      {:ok, %{status: :rejected, details: details}} ->
        Status.write(doc, %{
          "state" => "rejected",
          "rejected_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "details" => details
        })

        :ok

      {:error, reason} ->
        Logger.warning("Vlie.PublishWorker poll failed for #{sid}: #{inspect(reason)}")
        {:snooze, 30}
    end
  end

  defp book_doc_from(%Document{} = doc) do
    (doc.content || %{})
    |> Map.delete("bp_vlie_status")
    |> Map.put("_id", doc.doc_id)
    |> Map.put("_type", doc.type)
  end
end
```

Notice the worker reuses `Barkpark.Plugins.OnixEdit.Export` — the ONIX 3.0
emitter is plugin-owned but plugin-namespaced; nothing prevents another
plugin from calling into it. Composition across plugins is fine when the
boundary is a pure function.

## File 6 — `lib/barkpark/plugins/vlie/actions.ex`

```elixir
defmodule Barkpark.Plugins.Vlie.Actions do
  @moduledoc """
  Schema-action handlers for the Vlie plugin.

  Dispatched by `BarkparkWeb.Studio.StudioLive`'s `dispatch_action/4` clause
  for `"publish_to_vlie"`. The two modes mirror Bokbasen:

    * `:dryrun` — render the document as ONIX XML in memory, return a
      preview map. Does NOT enqueue any job.
    * `:real`   — enqueue `Vlie.PublishWorker` and mark the document as
      pending. The worker drives staging + polling.
  """

  alias Barkpark.Content
  alias Barkpark.Plugins.OnixEdit.Export
  alias Barkpark.Plugins.Vlie.PublishWorker
  alias Barkpark.Plugins.Vlie.Status

  @type mode :: :dryrun | :real

  @spec publish_to_vlie(String.t(), String.t(), mode()) ::
          {:ok, map()} | {:error, term()}
  def publish_to_vlie(doc_id, dataset, :dryrun) do
    with {:ok, doc} <- load_book(doc_id, dataset),
         book_doc = book_doc_from(doc),
         {:ok, iodata} <- Export.to_iodata(book_doc) do
      xml = IO.iodata_to_binary(iodata)
      {:ok, %{kind: :xml, xml: xml, summary: %{byte_size: byte_size(xml)}}}
    else
      {:error, _} = err -> err
    end
  end

  def publish_to_vlie(doc_id, dataset, :real) do
    with {:ok, doc} <- load_book(doc_id, dataset),
         args = %{"document_id" => doc.doc_id, "type" => doc.type, "dataset" => dataset},
         {:ok, job} <- Oban.insert(PublishWorker.new(args)) do
      updated = Status.write(doc, %{"state" => "pending", "last_error" => nil})
      {:ok, %{status: Status.read(updated), job: job}}
    else
      {:error, _} = err -> err
    end
  end

  defp load_book(doc_id, dataset) do
    draft = Content.draft_id(doc_id)
    pub = Content.published_id(doc_id)

    case Content.get_document(draft, "book", dataset) do
      {:ok, doc} -> {:ok, doc}

      _ ->
        case Content.get_document(pub, "book", dataset) do
          {:ok, doc} -> {:ok, doc}
          _ -> {:error, :no_doc}
        end
    end
  end

  defp book_doc_from(doc) do
    (doc.content || %{})
    |> Map.delete("bp_vlie_status")
    |> Map.put("_id", doc.doc_id)
    |> Map.put("_type", doc.type)
  end
end
```

Return shape matches the dispatch contract documented in
ARCHITECTURE.md — `{:ok, %{kind: :xml, xml, summary}}` for dryrun,
`{:ok, %{status, job}}` for real, `{:error, reason}` otherwise.

## File 7 — `test/barkpark/plugins/vlie/actions_test.exs`

```elixir
defmodule Barkpark.Plugins.Vlie.ActionsTest do
  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias Barkpark.Plugins.Vlie.Actions

  setup do
    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "book", "title" => "Book", "visibility" => "private", "fields" => []},
        "production"
      )

    {:ok, doc} =
      Content.create_document(
        %{
          "_type" => "book",
          "title" => "Test Book",
          "productIdentifiers" => [%{"productIdType" => "15", "idValue" => "9789999999999"}]
        },
        "book",
        "production"
      )

    %{doc: doc}
  end

  test "dryrun returns an ONIX preview", %{doc: doc} do
    assert {:ok, %{kind: :xml, xml: xml, summary: %{byte_size: bs}}} =
             Actions.publish_to_vlie(doc.doc_id, "production", :dryrun)

    assert is_binary(xml)
    assert bs > 0
  end

  test "unknown doc_id returns :no_doc" do
    assert {:error, :no_doc} =
             Actions.publish_to_vlie("nonexistent", "production", :dryrun)
  end
end
```

The test exercises the action handler directly — no LiveView, no Phoenix.
That's the host's job; the plugin asserts its own surface. The real-mode
test would mock the `Oban.insert` call and is omitted here for brevity.

## The three host edits

### Edit 1 — register Vlie in `ExternalSync`

In `api/lib/barkpark/external_sync.ex`, add one entry to `@entries`:

```elixir
@entries %{
  "bokbasen" => %{ ... },
  "vlie" => %{
    label: "Vlie",
    states: %{
      "pending"  => %{color: "gray",   label: "Pending"},
      "staging"  => %{color: "gray",   label: "Staging"},
      "staged"   => %{color: "blue",   label: "Staged"},
      "polling"  => %{color: "blue",   label: "Polling"},
      "accepted" => %{color: "green",  label: "Accepted"},
      "rejected" => %{color: "red",    label: "Rejected"},
      "failed"   => %{color: "orange", label: "Failed"},
      nil        => %{color: "gray",   label: "Not synced"}
    }
  }
}
```

Once compiled, the host's `ExternalSyncPill` renders Vlie status on any
document that broadcasts `external_sync:vlie:<doc_id>`.

### Edit 2 — dispatch the action in `StudioLive`

In `api/lib/barkpark_web/live/studio/studio_live.ex`, add one clause
above the fall-through `dispatch_action/4`:

```elixir
defp dispatch_action("publish_to_vlie", doc_id, dataset, mode) do
  Barkpark.Plugins.Vlie.Actions.publish_to_vlie(doc_id, dataset, mode)
end
```

That's it. No new socket assigns, no new modal markup — the generic
`ConfirmModal` handles dryrun + real out of the box.

### Edit 3 — declare the action in OnixEdit's `book.json`

In `api/priv/plugins/onixedit/schemas/book.json` (or in
`OnixEdit.document_actions/0` if you prefer the Elixir source of truth),
add one entry to the `actions` array:

```json
{
  "name": "publish_to_vlie",
  "label": "Publish to Vlie",
  "kind": "modal",
  "modal": {
    "title": "Publish to Vlie?",
    "body": "We'll run a dry-run first, then confirm before sending.",
    "steps": ["dryrun", "real"]
  },
  "icon": "send"
}
```

On the next server restart, `Plugins.Bootstrap.register_all_schemas/0`
upserts the refreshed schema. The Studio editor's action bar now shows
"Publish to Vlie" alongside "Publish to Bokbasen" for every `book`
document. Clicking it opens the `ConfirmModal`, dispatches the dryrun via
the clause from Edit 2, and (on confirmation) routes the real call to
`Plugins.Vlie.Actions.publish_to_vlie/3` (Edit 2 again, with `:real`).

If Vlie owned its own document type, Edit 3 would land in the plugin's
own schema JSON instead — the host doesn't care which plugin's schema the
button rides on, as long as one of them declares it.

## Configuring credentials

Vlie reads its API token from `Plugins.Settings` (encrypted at rest).
From an IEx remote console once after deploy:

```elixir
Barkpark.Plugins.Settings.put("vlie", %{
  "api_base" => "https://api.vlie.example.com",
  "api_token" => "demo-token"
})
```

The settings row is encrypted via Cloak before hitting the database. Reads
are telemetry-emitting and audited. The client picks up the new credentials
on the next request — no restart needed.

## What this plugin does NOT need

To reiterate the discipline from ARCHITECTURE.md and INTEGRATION_LESSONS.md:

- **No LiveView.** The host's StudioLive is the only editor LiveView.
- **No HEEx templates or function components.** The host renders the
  editor pane, the action bar, the `ConfirmModal`, and the
  `ExternalSyncPill`.
- **No CSS.** The pill colours are class names the host already ships
  (`bp-pill-gray`, `bp-pill-green`, etc.). Adding a new colour means
  touching `root.html.heex`'s inline `<style>` — a host change, not a
  plugin change.
- **No JavaScript / Web Components.** Modal interactions are stock
  LiveView events; status updates are PubSub broadcasts handled by the
  host's `ExternalSyncPill`.
- **No new route.** Vlie has no file-download endpoint. (If it did, it
  would live under `/v1/plugins/vlie/...` per the convention.)
- **No migration.** Status is stored in `documents.content` JSONB under
  the `bp_vlie_status` key (the `bp_*` prefix marks plugin-custom fields).
  Encrypted credentials go through the host-owned `plugin_settings` table.
- **No plugin LiveView test.** The action handler test asserts the
  plugin's surface; LiveView integration is the host's responsibility.

When you're tempted to ship plugin-specific UI, stop and re-read
INTEGRATION_LESSONS.md. The "best at X" framing means making X first-class
in the host, not making X live in a corner.

## Deploying

```bash
ssh root@89.167.28.206
cd /opt/barkpark
git pull           # post-merge hook rebuilds and restarts
make logs          # tail to verify "registered schema ... from plugin vlie"
```

Verify the action surfaces:

```bash
curl -s -H "Authorization: Bearer barkpark-dev-token" \
  http://89.167.28.206/v1/schemas/production \
  | jq '.[] | select(.name=="book") | .actions[] | .name'
# "export_onix"
# "publish_to_bokbasen"
# "publish_to_vlie"
```

Open a book document in Studio. The action bar shows three buttons. Click
"Publish to Vlie", run a dry-run, see the ONIX preview, confirm. The pill
flips to "Vlie: Pending", then "Staged", then "Accepted" without a single
plugin-specific UI element ever rendering.

That is the contract — and the whole point.
