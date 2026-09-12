defmodule BarkparkWeb.ScimStartIndexBoundTest do
  @moduledoc """
  ROUTE-DRIVEN guard for the `startIndex` ceiling in `BarkparkWeb.ScimResponse`.

  `clamp_start/1` floored `startIndex` at 1 (RFC 7644 §3.4.2.4 Table 6) and had
  no ceiling, while its neighbour `clamp_count/1` capped `count` at `@max_page`.
  `startIndex` becomes a literal Postgres `OFFSET` in `Barkpark.Scim.paginate/2`,
  so the caller picked the bind value.

  WHAT THAT ACTUALLY DID, measured on unmodified main before the fix — the
  filing's premise ("Postgres walks a billion rows") is NOT what happens, because
  a `Limit` node discards only the rows that exist:

      GET /scim/v2/Users?startIndex=999999999&count=1
        -> 200, Resources [], totalResults 3, startIndex 999999999, 9.7ms
      GET /scim/v2/Groups?startIndex=999999999&count=1
        -> 200, Resources [], totalResults 0, startIndex 999999999, 2.6ms
      GET /scim/v2/Users?startIndex=99999999999999999999999999&count=1
        -> ** (DBConnection.EncodeError) Postgrex expected an integer in
           -9223372036854775808..9223372036854775807, got 99999999999999999999999998

  So the real defects were (a) a caller-chosen 500 as soon as the value leaves the
  int8 domain, and (b) a ListResponse echoing a `startIndex` that is not the
  effective offset. Both are gone once the value is bounded above.

  These tests drive the ROUTE. `clamp_start/1` is private and a test calling it
  proves nothing about the door.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.{Scim, Tenancy}
  alias BarkparkWeb.ScimResponse

  # Above any corpus, and still comfortably inside int8.
  @huge 999_999_999
  # Outside int8 — this is the one that used to raise out of Postgrex.
  @beyond_int8 99_999_999_999_999_999_999_999_999

  defp org_with_ws(slug) do
    {:ok, org} = Tenancy.create_organization(%{slug: slug, name: slug})
    {:ok, ws} = Tenancy.create_workspace(%{slug: slug <> "-ws", name: "WS"})
    {:ok, ws} = Tenancy.assign_workspace_to_organization(ws, org.id)
    {:ok, {token, _}} = Scim.mint_token(org.id, "test")
    %{org: org, ws: ws, token: token}
  end

  defp scim(token) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("content-type", "application/json")
  end

  defp provision(token, email) do
    scim(token)
    |> post("/scim/v2/Users", Jason.encode!(%{"userName" => email}))
    |> json_response(201)
  end

  defp create_group(token, name, role) do
    scim(token)
    |> post("/scim/v2/Groups", Jason.encode!(%{"displayName" => name, "role" => role}))
    |> json_response(201)
  end

  defp list(token, path, query) do
    conn = scim(token) |> get(path <> "?" <> query)
    refute_rate_limited!(conn)
    json_response(conn, 200)
  end

  describe "startIndex is bounded ABOVE as well as below" do
    test "GET /Users reports the bound as the effective offset, not the input" do
      %{token: token} = org_with_ws("sibu")
      for e <- ~w(a@sibu.com b@sibu.com c@sibu.com), do: provision(token, e)

      body = list(token, "/scim/v2/Users", "startIndex=#{@huge}&count=1")

      # THE RED ASSERTION on unmodified main: `startIndex` came back 999999999.
      assert body["startIndex"] == ScimResponse.max_start_index()
      # RFC 7644 §3.4.2.4 Table 7 — a page past the end is a well-formed answer,
      # not an error: empty Resources, itemsPerPage 0, totalResults intact.
      assert body["Resources"] == []
      assert body["itemsPerPage"] == 0
      assert body["totalResults"] == 3
    end

    test "GET /Groups reports the bound as the effective offset, not the input" do
      %{token: token} = org_with_ws("sibg")
      create_group(token, "Alphas", "admin")
      create_group(token, "Betas", "member")

      body = list(token, "/scim/v2/Groups", "startIndex=#{@huge}&count=1")

      assert body["startIndex"] == ScimResponse.max_start_index()
      assert body["Resources"] == []
      assert body["itemsPerPage"] == 0
      assert body["totalResults"] == 2
    end

    test "a startIndex outside the int8 domain no longer reaches Postgres" do
      %{token: token} = org_with_ws("sibx")
      provision(token, "a@sibx.com")

      # Unmodified main raised DBConnection.EncodeError here (a 500 in prod):
      # the bind value left -2^63..2^63-1. The clamp keeps it in domain.
      for path <- ["/scim/v2/Users", "/scim/v2/Groups"] do
        body = list(token, path, "startIndex=#{@beyond_int8}&count=1")
        assert body["startIndex"] == ScimResponse.max_start_index()
      end
    end

    test "the ceiling leaves the RFC's floor alone (startIndex < 1 is still 1)" do
      %{token: token} = org_with_ws("sibf")
      provision(token, "a@sibf.com")

      # RFC 7644 §3.4.2.4 Table 6: "A value less than 1 SHALL be interpreted as 1."
      body = list(token, "/scim/v2/Users", "startIndex=0&count=1")
      assert body["startIndex"] == 1
      assert [%{"userName" => "a@sibf.com"}] = body["Resources"]
    end
  end

  describe "the ceiling does not truncate an ordinary page walk" do
    test "a client walking /Users from startIndex 1 to exhaustion sees every row exactly once" do
      %{token: token} = org_with_ws("sibw")
      emails = ~w(a@sibw.com b@sibw.com c@sibw.com d@sibw.com e@sibw.com)
      for e <- emails, do: provision(token, e)

      page_size = 2

      # A shrinking fixture must fail LOUDLY rather than pass with nothing to page.
      assert length(emails) > page_size,
             "this test proves multi-page paging; a corpus of #{length(emails)} " <>
               "fits in one page of #{page_size} and would prove nothing"

      walked = walk(token, page_size)

      assert walked == emails, "the walk must return every row exactly once, in order"
      assert length(walked) == length(Enum.uniq(walked)), "no row may repeat across pages"
    end
  end

  # A real SCIM client's loop: start at 1, advance by itemsPerPage, stop when the
  # page is empty or the walk has covered totalResults (RFC 7644 §3.4.2.4).
  defp walk(token, page_size), do: walk(token, page_size, 1, [])

  defp walk(_token, _page_size, start_index, acc) when start_index > 10_000, do: acc

  defp walk(token, page_size, start_index, acc) do
    body = list(token, "/scim/v2/Users", "startIndex=#{start_index}&count=#{page_size}")
    names = Enum.map(body["Resources"], & &1["userName"])

    assert body["startIndex"] == start_index,
           "a legitimate walk must never be clamped: asked #{start_index}, " <>
             "got #{body["startIndex"]}"

    case names do
      [] -> acc
      _ -> walk(token, page_size, start_index + length(names), acc ++ names)
    end
  end
end
