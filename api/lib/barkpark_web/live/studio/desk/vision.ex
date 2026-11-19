defmodule BarkparkWeb.Studio.Desk.Vision do
  @moduledoc """
  The desk's Vision, the TanStack Studio's query tool (`Vision.tsx`, J37):
  write a query, Fetch it (or Ctrl/Cmd+Enter), and read the result as a
  folding JSON tree, with the query's URL to copy, how long it took, and
  Save result as JSON.

  A query is GROQ, read through Barkpark's GROQ endpoint (the one `bp doc
  groq` reads, `GET …/v1/data/groq/:dataset`), or Barkpark's older form, a
  type and a query string (`post?filter[title][contains]=x&limit=5`, read
  at `GET …/v1/data/query/:dataset/:type`). Anything else is sent as GROQ,
  in the query parameter, so it never reaches Barkpark as a path. Reads
  only: both are GETs, sent by the browser with the editor's own session,
  so the endpoint's own auth, tenancy and limits (`docs/contracts/
  groq-query.md`, `query-surface-limits.md`) answer it as they answer any
  other caller. A URL past the GROQ read's 32,753 bytes is refused here
  before it is sent.

  The page is the desk's (`DeskLive`, workspace admins only) at
  `…/studio/_desk/_tools/vision`, so it keeps the desk's navbar, drawer and
  dialogs. `bp-desk-vision.js` runs it (named here for the first load, and
  loaded by the desk's hook after a live patch); this draws the form and
  hands the script its words. The form is `phx-update="ignore"`: what the script
  draws stays through the page's patches.

  Not yet here, as TanStack has them: Params, Listen, the dataset and API
  version pickers, saved queries and Save as CSV.
  """
  use Phoenix.Component
  use Gettext, backend: BarkparkWeb.Gettext

  alias BarkparkWeb.Icons

  @example ~s(*[_type == "post"] | order(_updatedAt desc\)[0...5]{_id, title})

  attr :dataset, :string, required: true
  attr :scope_prefix, :string, default: ""

  @doc "The Vision tool: the query on the left, the result on the right."
  def tool(assigns) do
    assigns = assign(assigns, example: @example, words: words())

    ~H"""
    <div
      id="dk-vision"
      class="dk-vision"
      phx-update="ignore"
      data-desk-vision
      data-api={@scope_prefix <> "/v1/data"}
      data-dataset={@dataset}
      {@words}
    >
      <h1 class="sr-only">{gettext("Vision")}</h1>
      <div class="dk-vision-top">
        <label class="dk-vision-field">
          <span class="dk-vision-label">{gettext("Perspective")}</span>
          <select class="dk-vision-input" data-vision-perspective>
            <option value="raw">{gettext("No perspective (raw)")}</option>
            <%!-- Sanity's names are the API's own codes, the `perspective=`
                  the query URL sends, so they read as sent in every
                  language, as TanStack's nb keeps them. --%>
            <option :for={code <- ~w(published drafts)} value={code} selected={code == "drafts"}>
              {code}
            </option>
          </select>
        </label>
        <div class="dk-vision-url" data-vision-url hidden>
          <span class="dk-vision-label">
            <label for="dk-vision-url">{gettext("Query URL")}</label>
            <button type="button" class="dk-vision-copy" data-vision-copy>
              [{gettext("Copy to clipboard")}]
            </button>
            <span class="dk-vision-copied" role="status" data-vision-copied></span>
          </span>
          <span class="dk-vision-url-row">
            <input id="dk-vision-url" class="dk-vision-input" readonly />
            <button
              type="button"
              class="icon-btn"
              aria-label={gettext("Copy URL")}
              title={gettext("Copy URL")}
              data-vision-copy
            >
              <Icons.desk_icon name="copy" size={21} />
            </button>
          </span>
        </div>
      </div>
      <div class="dk-vision-body">
        <section class="dk-vision-query">
          <div class="dk-vision-pane">
            <label for="dk-vision-query" class="dk-vision-label">{gettext("Query")}</label>
            <textarea
              id="dk-vision-query"
              class="dk-vision-code"
              spellcheck="false"
              aria-keyshortcuts="Control+Enter Meta+Enter"
            >{@example}</textarea>
          </div>
          <div class="dk-vision-actions">
            <button
              type="button"
              class="dk-vision-fetch"
              aria-keyshortcuts="Control+Enter Meta+Enter"
              data-vision-fetch
            >
              <Icons.desk_icon name="play" size={21} />{gettext("Fetch")}
            </button>
          </div>
        </section>
        <section class="dk-vision-result" aria-label={gettext("Result")} aria-busy="false">
          <div class="dk-vision-label">{gettext("Result")}</div>
          <div class="dk-vision-out dk-vision-code" data-vision-out></div>
          <footer class="dk-vision-foot">
            <span data-vision-ms>{gettext("Execution: %{time}", time: gettext("n/a"))}</span>
            <span data-vision-total>{gettext("End-to-end: %{time}", time: gettext("n/a"))}</span>
            <span class="dk-vision-save" data-vision-save hidden>
              {gettext("Save result as")}
              <a class="dk-vision-save-btn" href="#" download={"vision-#{@dataset}.json"} data-vision-json>
                <Icons.desk_icon name="document" size={21} />JSON
              </a>
            </span>
          </footer>
        </section>
      </div>
      <div class="sr-only" role="status" data-testid="announcer" data-vision-said></div>
      <%!-- For the first page load, run as the form is parsed (it is small,
            and the form is above it), so a query typed at once is not lost
            while the desk's hook loads it. The hook's load is for a live
            patch here, where this tag does not run. --%>
      <script src={BarkparkWeb.StaticAssets.path("bp-desk-vision.js")}></script>
    </div>
    """
  end

  # The script's words, as `data-t-*`, each `%{name}` kept for the script to fill.
  defp words do
    %{
      "data-t-na" => gettext("n/a"),
      "data-t-execution" => gettext("Execution: %{time}", time: "%{time}"),
      "data-t-total" => gettext("End-to-end: %{time}", time: "%{time}"),
      "data-t-item" => pgettext("json tree", "1 item"),
      "data-t-items" => pgettext("json tree", "%{count} items", count: "%{count}"),
      "data-t-property" => pgettext("json tree", "1 property"),
      "data-t-properties" => pgettext("json tree", "%{count} properties", count: "%{count}"),
      "data-t-more" => gettext("Show %{count} more", count: "%{count}"),
      "data-t-empty" => gettext(~s(Write a GROQ query, like *[_type == "post"][0...10])),
      "data-t-long" => gettext("The query is too long to send: its URL is over 32,753 bytes"),
      "data-t-failed" => gettext("Query failed: %{error}", error: "%{error}"),
      "data-t-error" => gettext("Query error: %{error}", error: "%{error}"),
      "data-t-one" => gettext("1 result in %{ms} ms", ms: "%{ms}"),
      "data-t-many" => gettext("%{count} results in %{ms} ms", count: "%{count}", ms: "%{ms}"),
      "data-t-done" => gettext("Query done in %{ms} ms", ms: "%{ms}"),
      "data-t-copied" => gettext("The URL is copied to the clipboard"),
      "data-t-not-copied" => gettext("The URL could not be copied")
    }
  end
end
