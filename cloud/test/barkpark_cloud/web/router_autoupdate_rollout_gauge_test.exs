defmodule BarkparkCloud.Web.RolloutGauge.Go do
  @moduledoc """
  The Side-B extractor for this suite: the `json:"…"` tags of ONE Go struct,
  read off `internal/cloudclient/client.go` ON DISK.

  Deliberately self-contained rather than calling
  `BarkparkCloud.PayloadKeySetCensus.Go.struct_tags/2`: that module is defined
  inside another `_test.exs`, so it exists only when the whole suite is compiled.
  A cross-surface lock that evaporates when someone runs `mix test <this file>`
  is a lock that is absent exactly when a person is iterating on the thing it
  guards. Same regex shape as that module's — a body is the run of lines that are
  NOT a column-0 closing brace (gofmt indents a nested struct's brace), and
  `json:"-"` is an explicit DO-NOT-DECODE, not a wire key.
  """

  @doc "The json tag names of one Go struct, or nil when the struct does not exist."
  @spec struct_tags(binary, binary) :: MapSet.t() | nil
  def struct_tags(src, name) do
    case Regex.run(~r/^type #{name} struct \{\n((?:(?!^\}$).)*)^\}$/ms, src,
           capture: :all_but_first
         ) do
      nil ->
        nil

      [body] ->
        ~r/json:"([^"]*)"/
        |> Regex.scan(body, capture: :all_but_first)
        |> Enum.map(fn [t] -> t |> String.split(",") |> List.first() end)
        |> Enum.reject(&(&1 in ["", "-"]))
        |> MapSet.new()
    end
  end
end

defmodule BarkparkCloud.Web.RouterAutoupdateRolloutGaugeTest do
  @moduledoc """
  task-0f05a5f719493b5f — THE ROLLOUT GAUGE WAS BLANK ON EVERY CONTROL PLANE
  THAT HAS EVER RUN, and nothing anywhere said so.

  `cloudclient.RolloutState` has modelled four fields since it was written —
  `halted`, `in_flight`, `behind`, `eligible` — and `renderRolloutState` prints
  the last three each behind a `!= nil` guard. The six `/v1/*/autoupdate` routes
  emitted `halted` and nothing else. Go decodes an absent key to the zero value,
  so the three pointers stayed nil, the three guards stayed false, and
  `bp cloud autoupdate status` printed the halted line and stopped — which reads
  as an older, leaner control plane rather than as a missing measurement. The one
  number an operator DID get, `halted`, is a lever they set themselves.

  This suite is the LOCK that keeps the two surfaces named the same thing, plus
  the proof that the counters are measurements and not constants:

    * §1 — the key set every autoupdate route emits EQUALS the json-tag set of
      the Go struct that decodes it, read from `internal/cloudclient/client.go`
      on disk. A rename on either side reds here.
    * §2 — the lock is proven able to LOSE in BOTH directions: a mutated Go
      source and a mutated route payload each break the equality.
    * §3 — the counters move with the fleet, and `eligible` and `behind` are
      NOT the same number (the gap between policy and drift is the thing the
      operator is actually asking about).
  """
  use BarkparkCloud.DataCase, async: false
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Registry, Repo}
  alias BarkparkCloud.Web.RolloutGauge.Go
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"
  @worker_token "worker-token-test-fixed"

  # The Go decoder, by PATH not by line: this struct is appended to, and a line
  # number here would rot within the week.
  @client_go Path.expand("../../../../internal/cloudclient/client.go", __DIR__)

  # Every route that answers with the rollout envelope — the worker-gated admin
  # trio and the platform-operator proxies. The proxies RE-RENDER rather than
  # forward, which is precisely how a key survives on one principal's door and
  # dies on the other's, so both doors are pinned.
  @admin_routes [
    {:get, "/v1/admin/autoupdate"},
    {:post, "/v1/admin/autoupdate/halt"},
    {:post, "/v1/admin/autoupdate/resume"}
  ]

  @operator_routes [
    {:get, "/v1/operator/autoupdate"},
    {:post, "/v1/operator/autoupdate/halt"},
    {:post, "/v1/operator/autoupdate/resume"}
  ]

  setup do
    prior = Application.get_env(:barkpark_cloud, :platform_admin_emails, [])
    on_exit(fn -> Application.put_env(:barkpark_cloud, :platform_admin_emails, prior) end)
    :ok
  end

  ## Fixtures

  defp user_fixture do
    {:ok, user} =
      Accounts.register_user(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    user
  end

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  defp operator_session do
    user = user_fixture()
    Application.put_env(:barkpark_cloud, :platform_admin_emails, [user.email])
    {:ok, token} = Accounts.create_user_session_token(user)
    token
  end

  # A live, `behind`, autoupdate-eligible instance unless `overrides` say
  # otherwise — the same fixture shape RegistryAutoupdateTest uses.
  defp behind_barkpark(overrides \\ %{}) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team_fixture(), %{name: "BP #{n}", slug: "bp-#{n}"})

    bp
    |> Ecto.Changeset.change(
      Map.merge(
        %{
          host: "203.0.113.#{rem(n, 250) + 1}",
          url: "https://bp-#{n}.barkpark.cloud",
          suspended: false,
          update_state: "behind",
          update_checked_at: DateTime.utc_now(),
          autoupdate_enabled: true,
          autoupdate_paused: false,
          pinned_release: nil,
          autoupdate_triggered_at: nil
        },
        overrides
      )
    )
    |> Repo.update!()
  end

  defp call(method, path, token) do
    conn = conn(method, path)
    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn
    Router.call(conn, @opts)
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  defp emitted_keys(method, path, token) do
    conn = call(method, path, token)
    assert conn.status == 200, "#{method} #{path} → #{conn.status}, expected 200"
    conn |> json_body() |> Map.keys() |> MapSet.new()
  end

  ## ─────────────────────────────────────────────────────────────────────────
  ## §1 — the cross-surface lock

  describe "§1 the emitted key set is pinned to the Go RolloutState json tags" do
    test "the Go side is READ, non-empty, and exactly the four rollout fields" do
      # THE ANTI-VACUITY FLOOR. Every arm below compares against this set; a
      # regex that silently matched nothing would make all of them pass on an
      # empty MapSet, which is the shape a broken extractor takes.
      src = File.read!(@client_go)
      tags = Go.struct_tags(src, "RolloutState")

      assert tags == MapSet.new(["halted", "in_flight", "behind", "eligible"]),
             "internal/cloudclient/client.go RolloutState tags drifted: #{inspect(tags)}"

      # The control that the extractor can answer NO: a struct that does not
      # exist must not resolve to some neighbour's body.
      assert Go.struct_tags(src, "RolloutStateThatDoesNotExist") == nil
    end

    test "every /v1/admin/autoupdate route emits exactly the decoded key set" do
      tags = Go.struct_tags(File.read!(@client_go), "RolloutState")

      for {method, path} <- @admin_routes do
        assert emitted_keys(method, path, @worker_token) == tags,
               "#{method} #{path} key set diverged from cloudclient.RolloutState"
      end
    end

    test "every /v1/operator/autoupdate proxy emits exactly the decoded key set" do
      tags = Go.struct_tags(File.read!(@client_go), "RolloutState")
      token = operator_session()

      for {method, path} <- @operator_routes do
        assert emitted_keys(method, path, token) == tags,
               "#{method} #{path} key set diverged from cloudclient.RolloutState"
      end
    end

    test "the counters are integers on the wire, not nulls the Go nil-guards would swallow" do
      body = json_body(call(:get, "/v1/admin/autoupdate", @worker_token))

      for key <- ["eligible", "behind", "in_flight"] do
        assert is_integer(body[key]), "#{key} must be an integer, got #{inspect(body[key])}"
      end

      assert is_boolean(body["halted"])
    end
  end

  ## ─────────────────────────────────────────────────────────────────────────
  ## §2 — the lock is able to LOSE, in both directions

  describe "§2 mutation proof" do
    test "a RENAME on the Go side breaks the equality" do
      live = emitted_keys(:get, "/v1/admin/autoupdate", @worker_token)

      mutated =
        @client_go
        |> File.read!()
        |> String.replace(~s(json:"behind"), ~s(json:"behind_count"))
        |> Go.struct_tags("RolloutState")

      assert MapSet.member?(mutated, "behind_count"),
             "the mutation did not take — the tag text to replace was not found"

      refute mutated == live,
             "a renamed Go tag must red this lock; it did not, so the lock is vacuous"

      assert MapSet.symmetric_difference(mutated, live) |> MapSet.to_list() |> Enum.sort() ==
               ["behind", "behind_count"]
    end

    test "a DROPPED key on the route side breaks the equality" do
      tags = Go.struct_tags(File.read!(@client_go), "RolloutState")
      live = emitted_keys(:get, "/v1/admin/autoupdate", @worker_token)

      # The control first: unmutated, the two sides agree.
      assert live == tags

      for dropped <- ["eligible", "behind", "in_flight", "halted"] do
        refute MapSet.delete(live, dropped) == tags,
               "dropping #{dropped} from the payload must red this lock; it did not"
      end
    end
  end

  ## ─────────────────────────────────────────────────────────────────────────
  ## §3 — the counters are measurements, not constants

  describe "§3 the counters measure the fleet" do
    test "an empty fleet reports three honest zeroes" do
      body = json_body(call(:get, "/v1/admin/autoupdate", @worker_token))
      assert body["eligible"] == 0
      assert body["behind"] == 0
      assert body["in_flight"] == 0
    end

    test "eligible counts the whole candidate set, not just the head the worker takes" do
      behind_barkpark()
      behind_barkpark()
      behind_barkpark()

      body = json_body(call(:get, "/v1/admin/autoupdate", @worker_token))

      # `next_autoupdate_candidate/1` returns ONE row; the gauge must not report
      # 1 just because the rollout advances one at a time.
      assert body["eligible"] == 3
      assert body["behind"] == 3
      assert body["in_flight"] == 0
    end

    test "in_flight counts triggered boxes and eligible EXCLUDES them" do
      behind_barkpark()
      behind_barkpark(%{autoupdate_triggered_at: DateTime.utc_now()})

      body = json_body(call(:get, "/v1/admin/autoupdate", @worker_token))

      assert body["in_flight"] == 1
      assert body["eligible"] == 1, "an in-flight box is work in progress, not queue"
      assert body["behind"] == 2, "drift counts it — it is still not on the release"
    end

    test "behind is DRIFT and eligible is POLICY — the gap is the operator's question" do
      behind_barkpark()
      behind_barkpark(%{autoupdate_enabled: false})
      behind_barkpark(%{autoupdate_paused: true})
      behind_barkpark(%{pinned_release: "v0.2.24"})
      behind_barkpark(%{apply_arming: "unarmed"})

      body = json_body(call(:get, "/v1/admin/autoupdate", @worker_token))

      assert body["behind"] == 5
      assert body["eligible"] == 1

      # The sentence a blank gauge could never say. If these two were ever
      # computed off one predicate this assertion would be a tautology; they are
      # not, and this is the arm that proves it.
      assert body["eligible"] < body["behind"]
    end

    test "an UNMEASURED box is in neither counter — unreachable is not drift" do
      behind_barkpark(%{update_state: "unknown"})
      behind_barkpark(%{update_state: "current"})

      body = json_body(call(:get, "/v1/admin/autoupdate", @worker_token))

      assert body["behind"] == 0
      assert body["eligible"] == 0
    end

    test "a hostless or suspended box is outside the managed frame for BOTH counters" do
      behind_barkpark(%{host: ""})
      behind_barkpark(%{suspended: true})

      body = json_body(call(:get, "/v1/admin/autoupdate", @worker_token))

      assert body["behind"] == 0
      assert body["eligible"] == 0
    end

    test "halt/resume report the counters too, so the gauge survives the lever" do
      behind_barkpark()
      behind_barkpark()

      halt = json_body(call(:post, "/v1/admin/autoupdate/halt", @worker_token))
      assert halt["halted"] == true
      assert halt["behind"] == 2
      assert halt["eligible"] == 2

      resume = json_body(call(:post, "/v1/admin/autoupdate/resume", @worker_token))
      assert resume["halted"] == false
      assert resume["behind"] == 2
    end

    test "the operator proxy reports the SAME numbers as the worker door" do
      behind_barkpark()
      behind_barkpark(%{autoupdate_triggered_at: DateTime.utc_now()})
      token = operator_session()

      admin = json_body(call(:get, "/v1/admin/autoupdate", @worker_token))
      operator = json_body(call(:get, "/v1/operator/autoupdate", token))

      assert admin == operator
      assert operator["behind"] == 2
      assert operator["in_flight"] == 1
    end
  end
end
