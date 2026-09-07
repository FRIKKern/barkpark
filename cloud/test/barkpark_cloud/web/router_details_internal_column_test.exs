defmodule BarkparkCloud.Web.RouterDetailsInternalColumnTest do
  @moduledoc """
  A 422/409 `details` map must never name an INTERNAL COLUMN the person never
  typed — and the console renders it as `field + " " + message`, so the field
  name IS half the sentence.

  ## The mechanism, which is not what the filing guessed

  The leaks were not hand-written maps. They came from `unique_constraint/3`:
  Ecto hangs a MULTI-FIELD constraint's error on the FIRST field of the list,
  and four schemas opened their list with a `belongs_to` foreign key. Every one
  of them then rendered through the router's `errors/1` into `details`, and the
  console's `friendly()` printed the humanized column name in front of a message
  written as if the subject were the team:

      POST /v1/teams/:id/invitations  "team id already has a pending invitation for this email"
      POST /v1/sites                  "team id already has a site with this slug"
      POST /v1/fleet/supports         "team id already has a Barkpark with this slug"

  All three are MEASURED below, before and after. The fix is a field-order
  change plus a re-voiced message; the index `name:` is pinned explicitly in
  each schema so the reorder moves the error field and nothing else.

  ## What was struck from the class, by measurement

    * `token hash`, `user id` on `POST /v1/tokens` — the route 422s on `name`
      first, so the PAT changeset's `validate_required([:token_hash, :name,
      :user_id, :team_id])` never renders. Driven.
    * `value encrypted` — no schema in `cloud/lib` declares the column at all;
      the `env_vars` table it belonged to was dropped. Control grep below.
    * `github webhook secret encrypted` — declared on `Site`, but no validation
      or constraint targets it, so it cannot be an error key. Control grep.
    * `parent id` on `POST /v1/fleet/supports` — REACHABLE, and deliberately
      left alone: the route reads `conn.body_params["parent_id"]`, so it names
      the exact request field an API client fills in. The console never reaches
      that arm (it always posts `mode: "provision"`, which forks earlier).

  ## The guard

  Two text-shape arms over the source, with a DERIVED internal-column set — the
  `belongs_to` foreign keys plus every `*_hash` / `*encrypted*` field declared
  anywhere in `cloud/lib`. Nothing here is a hand-maintained allow-list: adding
  a schema association automatically widens what the guard refuses.

    * ARM A, tree-wide: a multi-field `unique_constraint([...])` may not OPEN
      with an internal column while a non-internal field sits later in the same
      list. That is the whole defect class, stated as a rule.
    * ARM B, router-scoped: no hand-built `details: %{...}` map may key on an
      internal column.

  ### Limits

  Arm A reads LITERAL lists only — `unique_constraint(@conflict_target, ...)`
  (PlatformDelivery) is invisible to it. Arm B reads `details: %{` maps, both
  the one-line and the block form; it does not follow a map built in a
  variable. Both arms carry an exact census floor so a broken extractor REDS
  instead of reporting a clean tree.

  ## MUTATION (run before trusting the green)

  Arm A — restore the old field order in `accounts/team_invitation.ex`
  (`unique_constraint([:team_id, :email], ...)`):

      1) test ARM A: no multi-field unique_constraint opens with an internal column
         these constraints key their error on a column nobody typed, while a
         user-typed field sits later in the same list:
         ["barkpark_cloud/accounts/team_invitation.ex: [:team_id, :email] -> keys on team_id"]

  Arm B — add `details: %{team_id: ["can't be blank"]}` to any router arm:

      2) test ARM B: no hand-built router details map names an internal column
         these details maps name an internal column: ["team_id"]

  The driven half loses the same way: put the field order back and
  `the duplicate-invite 409 names the email, not the team id` reds with
  `"team id already has a pending invitation for this email"`.
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Registry}
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"

  @lib_root Path.expand("../../../lib", __DIR__)
  @router Path.join(@lib_root, "barkpark_cloud/web/router.ex")

  # Exact censuses. A floor AND a ceiling: a new multi-field constraint or a new
  # hand-built details map is a deliberate edit that re-reads this file, not a
  # number that drifts. Without them a typo'd regex and a clean tree look alike.
  @multi_field_constraints 7
  # 10 -> 11 (task-527f2a101b99ebf9, 2026-09-07): POST /v1/billing/cancel gained
  # a `details: %{at_period_end: [...]}` refusal when its immediate arm was
  # removed from the contract. The key is the REQUEST BODY field the caller
  # typed, not a column — `subscriptions` carries `cancel_at_period_end`, a
  # different name — so ARM B below passes on its merits, not by exemption.
  @router_details_maps 11

  ## ────────────────────────────────────────────────────────────────────
  ## PART 1 — the driven reachability table
  ## ────────────────────────────────────────────────────────────────────

  defp user_fixture do
    {:ok, u} =
      Accounts.register_user(%{
        email: "u-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    u
  end

  defp owner_with_team do
    u = user_fixture()
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "T#{n}", slug: "t-#{n}"})
    {:ok, _} = Accounts.add_member(team, u, "owner")
    {:ok, tok} = Accounts.create_user_session_token(u)
    {u, team, tok}
  end

  defp main_barkpark(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "main-#{n}", slug: "main-#{n}"})
    bp
  end

  defp post_json(path, body, tok) do
    conn(:post, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{tok}")
    |> Router.call(@opts)
  end

  # What the console actually shows: `friendly()` renders the first details
  # entry as `field.replace(/_/g," ") + " " + message`. Reproducing that here is
  # the point — the assertion is on the SENTENCE A PERSON READS, not on a key.
  defp rendered(conn) do
    %{"details" => details} = Jason.decode!(conn.resp_body)
    {field, msgs} = details |> Enum.to_list() |> hd()
    String.replace(field, "_", " ") <> " " <> hd(msgs)
  end

  describe "the reachable leaks, driven" do
    test "the duplicate-invite 409 names the email, not the team id" do
      {_u, team, tok} = owner_with_team()
      body = %{"email" => "dup@example.com", "role" => "member"}

      assert post_json("/v1/teams/#{team.id}/invitations", body, tok).status == 201

      conn = post_json("/v1/teams/#{team.id}/invitations", body, tok)
      assert conn.status == 409

      # BEFORE: "team id already has a pending invitation for this email"
      assert rendered(conn) == "email already has a pending invitation for this team"
    end

    test "the duplicate-site-slug 422 names the slug, not the team id" do
      {_u, team, tok} = owner_with_team()
      bp = main_barkpark(team)
      body = %{"barkpark_id" => bp.id, "name" => "Dup Site"}

      assert post_json("/v1/sites", body, tok).status == 201

      conn = post_json("/v1/sites", body, tok)
      assert conn.status == 422

      # BEFORE: "team id already has a site with this slug"
      assert rendered(conn) == "slug is already taken by another site on this team"
    end

    test "the duplicate-support-name 422 names the slug, not the team id" do
      {_u, team, tok} = owner_with_team()
      bp = main_barkpark(team)
      body = %{"name" => "dupsup", "parent_id" => bp.id}

      assert post_json("/v1/fleet/supports", body, tok).status == 201

      conn = post_json("/v1/fleet/supports", body, tok)
      assert conn.status == 422

      # BEFORE: "team id already has a Barkpark with this slug"
      assert rendered(conn) == "slug is already taken by another Barkpark on this team"
    end
  end

  describe "struck from the class by measurement" do
    test "POST /v1/tokens 422s on `name` — token_hash and user_id never render" do
      {_u, _team, tok} = owner_with_team()

      conn = post_json("/v1/tokens", %{}, tok)

      assert conn.status == 422
      assert Jason.decode!(conn.resp_body)["details"] == %{"name" => ["can't be blank"]}

      # The PAT changeset requires [:token_hash, :name, :user_id, :team_id]; the
      # route's own guard answers first, so three of those four are unreachable
      # from this door. That is a MEASUREMENT, not an inference from shape.
    end

    test "parent_id is reachable — and it is the route's own request field" do
      {_u, team, tok} = owner_with_team()
      _bp = main_barkpark(team)

      conn = post_json("/v1/fleet/supports", %{"name" => "sup"}, tok)

      assert conn.status == 422
      assert rendered(conn) == "parent id can't be blank"

      # Left alone deliberately: the route READS that exact body key, so the
      # message names something an API client types. The console never reaches
      # this arm — it posts `mode: "provision"`, which forks earlier.
      assert File.read!(@router) =~ ~s(conn.body_params["parent_id"])
    end
  end

  describe "struck from the class by name" do
    test "no schema in cloud/lib declares value_encrypted" do
      hits =
        for path <- lib_files(),
            File.read!(path) =~ "value_encrypted",
            do: Path.relative_to(path, @lib_root)

      assert hits == [],
             "value_encrypted is back in the tree — re-measure whether it can reach a details map"
    end

    test "github_webhook_secret_encrypted is targeted by no validation or constraint" do
      site = File.read!(Path.join(@lib_root, "barkpark_cloud/registry/site.ex"))

      refute site =~ ~r/validate_\w+\([^)]*:github_webhook_secret_encrypted/
      refute site =~ ~r/unique_constraint\([^)]*:github_webhook_secret_encrypted/

      # Non-vacuity: the column IS declared here, so the two refutes above are
      # measuring absence-of-validation rather than absence-of-field. It is only
      # ever CAST and read for a boolean projection, so it can never be an
      # error key.
      assert site =~ "field :github_webhook_secret_encrypted"
    end
  end

  ## ────────────────────────────────────────────────────────────────────
  ## PART 2 — the guard
  ## ────────────────────────────────────────────────────────────────────

  defp lib_files, do: Path.wildcard(Path.join(@lib_root, "**/*.ex"))

  # Whole-line comments only, the same limit the audit-discard census carries.
  defp code(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.map(fn line -> if String.starts_with?(String.trim(line), "#"), do: "", else: line end)
  end

  # THE DERIVED INTERNAL SET. Not a hand list: every `belongs_to` in the tree
  # contributes its foreign key (honouring an explicit `foreign_key:`), and
  # every declared field whose name ends in `_hash` or mentions `encrypted`
  # joins it. Add an association tomorrow and the guard refuses that column
  # tonight, with no edit here.
  defp internal_columns do
    lib_files()
    |> Enum.flat_map(&code/1)
    |> Enum.flat_map(fn line ->
      cond do
        m = Regex.run(~r/belongs_to\s+:(\w+).*foreign_key:\s*:(\w+)/, line) ->
          [Enum.at(m, 2)]

        m = Regex.run(~r/belongs_to\s+:(\w+)/, line) ->
          [Enum.at(m, 1) <> "_id"]

        m = Regex.run(~r/field\s+:(\w*(?:_hash|encrypted\w*))\b/, line) ->
          [Enum.at(m, 1)]

        true ->
          []
      end
    end)
    |> MapSet.new()
  end

  test "the derived internal-column set is populated (the guard is not vacuous)" do
    internal = internal_columns()

    for expected <- ~w(team_id user_id barkpark_id site_id token_hash) do
      assert MapSet.member?(internal, expected),
             "the belongs_to/field extractor lost #{expected} — both arms below go blind"
    end

    for typed <- ~w(email slug name kind token platform) do
      refute MapSet.member?(internal, typed),
             "#{typed} is user-typed; classing it internal would red the tree for nothing"
    end
  end

  # Every literal multi-field `unique_constraint([...])`, as
  # {relative path, [field names]}.
  defp multi_field_constraints do
    for path <- lib_files(),
        line <- code(path),
        m = Regex.run(~r/unique_constraint\(\[([^\]]+)\]/, line),
        fields =
          m
          |> Enum.at(1)
          |> String.split(",")
          |> Enum.map(&(&1 |> String.trim() |> String.trim_leading(":"))),
        length(fields) > 1,
        do: {Path.relative_to(path, @lib_root), fields}
  end

  test "ARM A: no multi-field unique_constraint opens with an internal column" do
    internal = internal_columns()
    census = multi_field_constraints()

    assert length(census) == @multi_field_constraints,
           "the unique_constraint extractor found #{length(census)} multi-field constraints, " <>
             "expected #{@multi_field_constraints} — update the census deliberately"

    # PARSER non-vacuity, and it is not theoretical: the first cut of this
    # extractor trimmed with `String.trim(field, " :")`, whose second argument is
    # a whole BINARY and not a character set. The list's FIRST element has no
    # leading space, so it kept its colon, `":team_id"` matched nothing in the
    # internal set, and the arm went silently blind on exactly the position the
    # rule is about. A field that still carries punctuation reds here now.
    for {path, fields} <- census, field <- fields do
      assert field =~ ~r/^[a-z][a-z0-9_]*$/,
             "the unique_constraint extractor left #{inspect(field)} in #{path} — arm A is blind"
    end

    offenders =
      for {path, [first | rest]} <- census,
          MapSet.member?(internal, first),
          Enum.any?(rest, &(not MapSet.member?(internal, &1))),
          do:
            "#{path}: [#{Enum.map_join([first | rest], ", ", &(":" <> &1))}] -> keys on #{first}"

    assert offenders == [], """
    these constraints key their error on a column nobody typed, while a \
    user-typed field sits later in the same list: #{inspect(offenders)}

    Ecto hangs the error on the FIRST field, and the console renders \
    `field + " " + message`. Reorder so the typed field leads, and pin the \
    index `name:` so only the error field moves.
    """
  end

  # Every hand-built `details: %{...}` map in the router, one-line or block form,
  # as a flat list of its keys.
  defp router_details_maps do
    lines = code(@router)

    lines
    |> Enum.with_index()
    |> Enum.flat_map(fn {line, idx} ->
      cond do
        m = Regex.run(~r/details: %\{(\w+):/, line) ->
          [Enum.at(m, 1)]

        String.contains?(line, "details: %{") ->
          lines
          |> Enum.drop(idx + 1)
          |> Enum.take_while(&(not String.starts_with?(String.trim(&1), "}")))
          |> Enum.flat_map(fn l ->
            case Regex.run(~r/^\s*(\w+):/, l) do
              [_, key] -> [key]
              _ -> []
            end
          end)

        true ->
          []
      end
    end)
  end

  test "ARM B: no hand-built router details map names an internal column" do
    internal = internal_columns()
    keys = router_details_maps()

    assert length(keys) == @router_details_maps,
           "the details-map extractor found #{length(keys)} keys (#{inspect(keys)}), " <>
             "expected #{@router_details_maps} — update the census deliberately"

    offenders = Enum.filter(keys, &MapSet.member?(internal, &1))

    assert offenders == [], """
    these details maps name an internal column: #{inspect(offenders)}

    The console prints the key verbatim in front of the message, so a column \
    name here is a sentence about a field the person never typed.
    """
  end
end
