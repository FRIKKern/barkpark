defmodule BarkparkWeb.TicketsTwoMinuteStoryTest do
  @moduledoc """
  The 2-minute story, as CI truth (Barkpark Tickets, charter Decision 6 +
  wave-2 item 7): "mint-to-first-ticket in 2 curl-able minutes" must be TRUE,
  not aspirational.

  This is the tripwire the whole epic hangs on — it exercises the FULL lifecycle
  end-to-end THROUGH THE ROUTER (never by calling controller actions directly):

    1. An operator (admin) mints a named ticket key. The response carries the
       raw `bptk_` key ONCE plus the forwardable `quickstart` handoff card.
    2. We PARSE THE CARD TEXT ITSELF — the exact string the operator forwards —
       with a small in-test curl parser. If the card can't be parsed the card
       ROTTED, and this test fails loudly (never silently green). The first
       curl's JSON body is asserted to carry EXACTLY the `{subject, body}` keys
       the charter pins.
    3. We execute the card's three curls VERBATIM (method / path / headers /
       body rebuilt from what we parsed, dispatched through the endpoint) — file,
       list, read — and drive the rest of the conversation to a close.
    4. The blast-radius coda proves Decision 1's paused-vs-revoked distinction
       over the wire: a paused key is a distinguishable 403; a revoked key is a
       401 byte-identical to presenting no token at all.

  No production code is touched: if the story exposes a product bug, THIS test
  goes red and the fix belongs in the owning slice, not here.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.TenancyFixtures

  # The operator's real credential. Global admin perm satisfies the flat
  # `:require_admin` mint gate; the same bearer answers/closes on the operator
  # `:token_root` surface, and its LABEL becomes the operator author name.
  @operator_token "barkpark-dev-token"
  @operator_label "Support Desk"

  @mint_path "/v1/plugins/tickets/keys"

  setup do
    # Land everything in the seeded Default workspace/project — the scope the
    # flat routes' AssignDefaultScope resolves for BOTH the admin mint (the
    # key's workspace binding) and the operator surface, so the operator can
    # actually see what the key filed. Register the ticket schema in that scope
    # (boot registration lives outside the per-test sandbox).
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]
    register_ticket_schema!(scope)

    Auth.create_token(@operator_token, @operator_label, "production", ["read", "write", "admin"])
    :ok
  end

  test "the whole 2-minute story runs verbatim from the handoff card" do
    # ── 1. Operator mints a named key ────────────────────────────────────────
    mint =
      admin_conn()
      |> post(@mint_path, Jason.encode!(%{name: "Gyldendal — Kari"}))
      |> json_response(201)

    raw = mint["raw"]
    key_id = mint["key"]["id"]
    card = mint["quickstart"]

    assert is_binary(raw) and String.starts_with?(raw, "bptk_"),
           "mint must return the raw key once, `bptk_`-prefixed; got: #{inspect(raw)}"

    assert mint["key"]["name"] == "Gyldendal — Kari"
    assert mint["key"]["status"] == "live"
    assert is_binary(card) and card =~ "curl", "mint must carry a quickstart handoff card"

    # ── 2. Parse the card the operator FORWARDS (not Handoff.card/2 directly) ─
    curls = parse_curls(card)

    assert length(curls) == 3,
           "the handoff card must expose exactly 3 curls (file/list/read); parsed #{length(curls)} — the card rotted"

    [file_curl, list_curl, read_curl] = curls

    # The raw key the operator hands over IS the key we minted — no drift.
    assert raw in headers_bearer(file_curl),
           "the card's curl must carry the minted raw key as its Bearer"

    # Charter-pinned promise: curl #1 is POST /v1/tickets with a body of EXACTLY
    # {"subject", "body"} — no more, no fewer keys.
    assert file_curl.method == "POST"
    assert file_curl.path == "/v1/tickets"
    assert {"content-type", "application/json"} in downcase_headers(file_curl.headers)

    file_body = Jason.decode!(file_curl.body)

    assert Enum.sort(Map.keys(file_body)) == ["body", "subject"],
           "curl #1 body must be EXACTLY {subject, body} keys; got #{inspect(Map.keys(file_body))}"

    assert list_curl.method == "GET" and list_curl.path == "/v1/tickets"
    assert read_curl.method == "GET" and read_curl.path == "/v1/tickets/TICKET_ID"

    # ── 3. Execute curl #1 VERBATIM → 201, a fresh OPEN ticket ───────────────
    filed = run_curl(file_curl) |> json_response(201)

    assert filed["ok"] == true
    ticket = filed["ticket"]
    ticket_id = ticket["id"]
    assert is_binary(ticket_id)
    assert ticket["status"] == "open", "a freshly-filed ticket is the operator's move (open)"
    assert ticket["key_name"] == "Gyldendal — Kari", "identity is the key name, from the credential"
    assert [first_msg] = ticket["messages"]
    assert first_msg["author_kind"] == "submitter"
    # The first message body is what the card's verbatim JSON carried.
    assert first_msg["body"] == file_body["body"]

    # ── 4. Execute curl #2 (list) VERBATIM → the ticket appears ──────────────
    listed = run_curl(list_curl) |> json_response(200)
    listed_ids = Enum.map(listed["tickets"], & &1["id"])
    assert ticket_id in listed_ids, "the just-filed ticket must show up in the key's own list"
    # List rows are lean — no full thread leaks into the index.
    refute Enum.any?(listed["tickets"], &Map.has_key?(&1, "messages"))

    # ── 5a. Operator answers (plain, no close) → answered ────────────────────
    answered =
      operator_conn()
      |> post("/v1/tickets/#{ticket_id}/answer", Jason.encode!(%{body: "Try clearing your cookies."}))
      |> json_response(200)

    assert answered["ticket"]["status"] == "answered", "an answered ticket is the submitter's move"
    last = List.last(answered["ticket"]["messages"])
    assert last["author_kind"] == "operator"
    assert last["author_name"] == @operator_label, "operator identity is the token label"
    assert last["body"] == "Try clearing your cookies."

    # ── 5b. STRING-coercion path — `close` arriving as the query string "true" ─
    # Exercised on a SEPARATE throwaway ticket so it can't perturb the main
    # lifecycle. The charter's --close seam: the flag arrives as the STRING
    # "true" (a query param), which `maybe_chain_close` must coerce to a close.
    coerce_id = run_curl(file_curl) |> json_response(201) |> get_in(["ticket", "id"])

    coerced =
      operator_conn()
      |> post("/v1/tickets/#{coerce_id}/answer?close=true", Jason.encode!(%{body: "Done."}))
      |> json_response(200)

    assert coerced["ticket"]["status"] == "closed",
           ~s|answer with `close` as the STRING "true" must chain a close (query-param coercion)|

    # ── 6. Execute curl #3 VERBATIM (TICKET_ID substituted) → answer seen ─────
    read = run_curl(read_curl, ticket_id) |> json_response(200)
    assert read["ticket"]["status"] == "answered"

    read_bodies = Enum.map(read["ticket"]["messages"], & &1["body"])
    assert "Try clearing your cookies." in read_bodies, "the submitter must see the operator's answer"

    # The delivery signal (Decision 3): the submitter's read stamped
    # submitter_seen_at. Prove it PERSISTED by polling the doc as the operator —
    # not by trusting the same response that did the stamping.
    seen_via_operator =
      operator_conn()
      |> get("/v1/tickets/inbox/#{ticket_id}")
      |> json_response(200)

    assert is_binary(seen_via_operator["ticket"]["submitter_seen_at"]),
           "reading an answered ticket must stamp submitter_seen_at (the delivery signal)"

    # ── 7. Submitter reply → auto-reopen, waiting_since reset ────────────────
    waiting_before = seen_via_operator["ticket"]["waiting_since"]

    reopened =
      submitter_conn(raw)
      |> post("/v1/tickets/#{ticket_id}/messages", Jason.encode!(%{body: "Still broken."}))
      |> json_response(200)

    assert reopened["ticket"]["status"] == "open",
           "a submitter reply on an answered ticket auto-reopens it (the ball is back on the operator)"

    assert length(reopened["ticket"]["messages"]) == 3

    waiting_after = reopened["ticket"]["waiting_since"]
    assert is_binary(waiting_after)

    refute waiting_after == waiting_before,
           "auto-reopen must RESET waiting_since (oldest-waiting triage must count from the reopen)"

    assert not_earlier?(waiting_after, waiting_before),
           "the reset waiting_since must not move backwards in time"

    # ── 8. Operator close → closed ───────────────────────────────────────────
    closed =
      operator_conn()
      |> post("/v1/tickets/#{ticket_id}/close", "")
      |> json_response(200)

    assert closed["ticket"]["status"] == "closed"

    # ── 9. Blast-radius coda (Decision 1: paused vs revoked) ─────────────────
    # A missing-token baseline: presenting NO credential on the submitter
    # surface — the byte-identical shape a revoked key must collapse into.
    missing = build_conn() |> get("/v1/tickets")
    assert missing.status == 401
    missing_body = json_response(missing, 401)

    # Pause the key → the next submitter call is a DISTINGUISHABLE 403.
    assert admin_conn() |> post("/v1/plugins/tickets/keys/#{key_id}/pause", "") |> response(200)

    paused = submitter_conn(raw) |> get("/v1/tickets")
    assert paused.status == 403, "a paused key is a distinguishable 403, not a silent 401"
    assert json_response(paused, 403)["error"]["message"] =~ "key paused"

    # Revoke the key → indistinguishable from presenting no token at all:
    # SAME status AND byte-identical body.
    assert admin_conn() |> delete("/v1/plugins/tickets/keys/#{key_id}") |> response(200)

    revoked = submitter_conn(raw) |> get("/v1/tickets")
    assert revoked.status == 401, "a revoked key is a 401 (indistinguishable from missing)"
    assert without_request_id(json_response(revoked, 401)) == without_request_id(missing_body),
           "a revoked key's 401 body must be identical to a missing token's, save the per-request trace id (no existence oracle)"
  end

  # Drop the per-request trace id (`error.request_id`) — it legitimately varies
  # between two requests, so it must NOT count against the "revoked looks exactly
  # like missing" auth-oracle check. Everything else (code, message, shape) must
  # match byte-for-byte.
  defp without_request_id(%{"error" => error} = body) when is_map(error),
    do: %{body | "error" => Map.delete(error, "request_id")}

  defp without_request_id(body), do: Map.delete(body, "request_id")

  # ── Conn builders ──────────────────────────────────────────────────────────

  defp admin_conn do
    build_conn()
    |> put_req_header("authorization", "Bearer #{@operator_token}")
    |> put_req_header("content-type", "application/json")
  end

  defp operator_conn do
    build_conn()
    |> put_req_header("authorization", "Bearer #{@operator_token}")
    |> put_req_header("content-type", "application/json")
  end

  defp submitter_conn(raw) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{raw}")
    |> put_req_header("content-type", "application/json")
  end

  # ── Verbatim curl execution ────────────────────────────────────────────────

  # Rebuild a conn from the PARSED curl and dispatch it through the endpoint.
  # `ticket_id` (optional) substitutes the card's literal TICKET_ID placeholder
  # in the path. GETs carry no body; POSTs send the parsed JSON body raw so the
  # real Plug.Parsers path (accepts json) decodes it — proving the card's exact
  # bytes work end-to-end, not a re-encoded map.
  defp run_curl(curl, ticket_id \\ nil) do
    path =
      case ticket_id do
        nil -> curl.path
        id -> String.replace(curl.path, "TICKET_ID", id)
      end

    conn = apply_headers(build_conn(), curl.headers)

    case curl.method do
      "GET" -> get(conn, path)
      "POST" -> post(conn, path, curl.body || "")
    end
  end

  defp apply_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {name, value}, acc ->
      put_req_header(acc, String.downcase(name), value)
    end)
  end

  # ── The in-test curl parser (the card is the contract; parse it, don't fake) ─

  # Turn the handoff card into a list of `%{method, path, headers, body}`. Joins
  # shell line-continuations (`\` + newline), keeps only the `curl` lines, and
  # tokenizes each respecting single-quoted arguments. A parse failure here means
  # the card's shape drifted from what a human would paste — a real regression.
  defp parse_curls(card) do
    card
    |> String.replace("\\\n", " ")
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&String.starts_with?(&1, "curl"))
    |> Enum.map(&parse_curl/1)
  end

  defp parse_curl(line) do
    tokens = tokenize(line)

    %{
      method: method_of(tokens),
      path: path_of(tokens),
      headers: headers_of(tokens),
      body: body_of(tokens)
    }
  end

  # Split on whitespace but keep '...single-quoted...' arguments intact.
  defp tokenize(line) do
    ~r/'[^']*'|\S+/
    |> Regex.scan(line)
    |> Enum.map(fn [tok] -> tok end)
  end

  # `-X POST` → the explicit method; a bare `curl <url>` defaults to GET.
  defp method_of(tokens) do
    case index_after(tokens, "-X") do
      nil -> "GET"
      m -> String.upcase(m)
    end
  end

  # The lone URL token (starts with http); reduced to its path so it dispatches
  # against the router regardless of the card's host.
  defp path_of(tokens) do
    url = Enum.find(tokens, &String.starts_with?(&1, "http"))
    url && URI.parse(url).path
  end

  # Every `-H '<name>: <value>'` → `{name, value}`.
  defp headers_of(tokens) do
    tokens
    |> Enum.with_index()
    |> Enum.filter(fn {tok, _i} -> tok == "-H" end)
    |> Enum.map(fn {_tok, i} -> Enum.at(tokens, i + 1) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&unquote_arg/1)
    |> Enum.map(fn h ->
      case String.split(h, ": ", parts: 2) do
        [name, value] -> {name, value}
        [name] -> {name, ""}
      end
    end)
  end

  # The `-d '<body>'` payload (nil for a bodyless GET).
  defp body_of(tokens) do
    case index_after(tokens, "-d") do
      nil -> nil
      raw -> unquote_arg(raw)
    end
  end

  # The token immediately after `flag`, single-quotes stripped, or nil.
  defp index_after(tokens, flag) do
    case Enum.find_index(tokens, &(&1 == flag)) do
      nil -> nil
      i -> tokens |> Enum.at(i + 1) |> unquote_arg()
    end
  end

  defp unquote_arg(nil), do: nil

  defp unquote_arg(tok) do
    if String.starts_with?(tok, "'") and String.ends_with?(tok, "'") do
      tok |> String.slice(1..-2//1)
    else
      tok
    end
  end

  # The Bearer values across a parsed curl's headers (for the "no drift" check).
  defp headers_bearer(curl) do
    curl.headers
    |> Enum.filter(fn {name, _v} -> String.downcase(name) == "authorization" end)
    |> Enum.map(fn {_name, value} -> String.replace_prefix(value, "Bearer ", "") end)
  end

  defp downcase_headers(headers) do
    Enum.map(headers, fn {name, value} -> {String.downcase(name), String.downcase(value)} end)
  end

  # ── Misc ───────────────────────────────────────────────────────────────────

  # True when ISO8601 `a` is at or after `b` — waiting_since must move forward,
  # never backwards, on a reset.
  defp not_earlier?(a, b) do
    with {:ok, da, _} <- DateTime.from_iso8601(a),
         {:ok, db, _} <- DateTime.from_iso8601(b) do
      DateTime.compare(da, db) in [:gt, :eq]
    else
      _ -> false
    end
  end

  # Register the `ticket` schema (all definitions the plugin declares) into the
  # given tenancy scope — mirrors ticket_key_route_sweep / tickets_controller
  # test setup. Boot-time registration lives outside the per-test sandbox.
  defp register_ticket_schema!(scope) do
    for schema_def <- Barkpark.Plugins.Tickets.register_schemas([]) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, "production", scope)
    end
  end
end
