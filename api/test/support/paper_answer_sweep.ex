defmodule BarkparkWeb.PaperAnswerSweep do
  @moduledoc """
  The instrument behind `PaperAnswerSweepTest`: a seeded pair of Papers whose
  schema hides block and label fields, the callers, and one way to drive any
  route, live route, stream or channel and get back every byte it answered.

  Paper A's title comes from a heading whose text is hidden, one hidden
  heading sits two sections deep, and its description is hidden. Paper B
  links to A, so A's backlinks carry B's title, which also comes from a
  hidden heading.

  Driving never skips: a route that raises answers its exception text, a
  route that does not return is a stream, read through a trace of the bytes
  it writes while the Paper changes. Each non-GET call runs inside a
  savepoint, so a write cannot change what the next route sees.
  """

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest, only: [live: 2, render: 1]
  import Plug.Conn

  alias Barkpark.{Auth, Content, LabelFixtures, Repo, Tenancy}

  @endpoint BarkparkWeb.Endpoint
  @ds "production"
  @block_word "SWEEPHEADINGWORD"
  @nested_word "SWEEPNESTEDWORD"
  @label_word "SWEEPLABELWORD"
  @visible "Sweepvisible"
  @groq ~s(*[_type == "paper"])
  @stream_wait 2_000

  def dataset, do: @ds
  def hidden, do: [@block_word, @nested_word, @label_word]
  def words, do: [@visible | hidden()]

  @doc "Every hidden word found in `bytes`."
  def leaks(bytes) when is_binary(bytes), do: Enum.filter(hidden(), &String.contains?(bytes, &1))

  # ── Seed ────────────────────────────────────────────────────────────────

  def seed! do
    LabelFixtures.register_tags!(@ds)
    put_schema!()
    ws = Tenancy.get_default_workspace()
    project = Tenancy.get_default_project()
    a = "sweep-a-#{System.unique_integer([:positive])}"
    b = "sweep-b-#{System.unique_integer([:positive])}"
    paper_a = paper!(a, [])
    _paper_b = paper!(b, [%{"type" => "wikilink", "docId" => a, "target" => a}])

    tag =
      paper_a.content["tags"]
      |> List.first()
      |> then(&((is_map(&1) && &1["tag"]) || &1))

    tokens =
      Map.new([reader: ["read"], writer: ["read", "write"], admin: ["admin"]], fn {role, perms} ->
        raw = "sweep-#{role}-#{System.unique_integer([:positive])}"
        {:ok, _} = Auth.create_token(raw, "answer sweep #{role}", @ds, perms)
        {role, raw}
      end)

    %{slug: a, other: b, tag: tag, ws: ws, project: project, tokens: tokens}
  end

  defp put_schema! do
    fields = [
      %{"name" => "title", "type" => "string"},
      %{"name" => "description", "type" => "string", "private" => true},
      %{
        "name" => "blocks",
        "type" => "array",
        "of" => [
          %{
            "type" => "object",
            "fields" => [%{"name" => "text", "type" => "string", "private" => true}]
          }
        ]
      }
    ]

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "paper", "title" => "Papers", "visibility" => "public", "fields" => fields},
        @ds,
        workspace_id: Tenancy.get_default_workspace().id,
        project_id: Tenancy.get_default_project().id
      )
  end

  defp text(v), do: %{"type" => "text", "value" => v}

  defp paper!(slug, link) do
    blocks = [
      %{"id" => "h", "type" => "heading", "level" => 1, "text" => "#{@block_word} #{slug}"},
      %{
        "id" => "p",
        "type" => "paragraph",
        "content" => [text("#{@visible} paragraph. ") | link]
      },
      %{
        "id" => "s",
        "type" => "section",
        "title" => "Section",
        "children" => [
          %{
            "id" => "s2",
            "type" => "section",
            "title" => "Inner",
            "children" => [
              %{
                "id" => "nh",
                "type" => "heading",
                "level" => 3,
                "text" => "#{@nested_word} deep"
              },
              %{"id" => "np", "type" => "paragraph", "content" => [text("#{@visible} deep.")]}
            ]
          }
        ]
      }
    ]

    description = "A description long enough for the label spine, carrying #{@label_word}."

    {:ok, paper} =
      Content.upsert_paper(
        LabelFixtures.paper_attrs(%{slug: slug, blocks: blocks, description: description})
      )

    paper
  end

  @doc "A write to Paper A, so a stream has something to send."
  def touch!(seed), do: paper!(seed.slug, [text(" touched")])

  # ── Callers ─────────────────────────────────────────────────────────────

  @doc "The callers without the right: anonymous, a read token, a write token."
  def without_right(seed),
    do: [{"anonymous", nil}] ++ for(r <- [:reader, :writer], do: {"#{r}", seed.tokens[r]})

  def conn_for(nil), do: base_conn()

  def conn_for(token) do
    base_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> Plug.Test.init_test_session(%{"api_token" => token})
  end

  defp base_conn, do: BarkparkWeb.ConnCase.scoped_conn()

  # ── Paths and params ────────────────────────────────────────────────────

  @doc "`path` with every parameter filled from the seed."
  def fill(path, seed) do
    fill = %{
      "dataset" => @ds,
      "type" => "paper",
      "tag" => seed.tag,
      "workspace_slug" => seed.ws.slug,
      "project_slug" => seed.project.slug,
      "plugin" => "bulldocs"
    }

    path
    |> String.split("/")
    |> Enum.map(fn
      ":" <> name -> Map.get(fill, name, seed.slug)
      "*" <> _ -> seed.slug
      segment -> segment
    end)
    |> Enum.join("/")
  end

  @doc "The param sets tried, in order, until the caller with the right is answered."
  def param_sets(seed, word) do
    [
      %{},
      %{"q" => word},
      %{"query" => @groq},
      %{"q" => word, "query" => @groq, "type" => "paper"},
      %{"ids" => [seed.slug], "id" => seed.slug, "slug" => seed.slug}
    ]
  end

  @doc "`params` with its search word replaced by `word`."
  def with_word(params, word),
    do: if(Map.has_key?(params, "q"), do: Map.put(params, "q", word), else: params)

  # ── Driving ─────────────────────────────────────────────────────────────

  @doc """
  Every byte one call answered: `%{status: status, bytes: headers <> body,
  location: location}`, with `status: :stream` and the bytes written for a
  call that did not return.
  """
  def call(seed, token, verb, path, params) do
    conn = conn_for(token)
    method = verb |> String.downcase() |> String.to_atom()
    savepoint? = verb != "GET"
    if savepoint?, do: Repo.query!("SAVEPOINT answer_sweep", [])

    try do
      run(seed, fn -> dispatch(conn, @endpoint, method, path, params) end)
    after
      if savepoint?, do: Repo.query!("ROLLBACK TO SAVEPOINT answer_sweep", [])
    end
  end

  @doc "A live route's connected render, following one redirect."
  def live_call(token, path, redirects \\ 1) do
    conn = conn_for(token)

    case safely(fn -> live(conn, path) end) do
      {:ok, {:ok, view, html}} ->
        %{status: 200, bytes: html <> render(view), location: nil}

      {:ok, {:error, {kind, %{to: to}}}} when kind in [:redirect, :live_redirect] ->
        if path == to or redirects == 0,
          do: %{status: 302, bytes: to, location: to},
          else: live_call(token, to, redirects - 1)

      {:ok, other} ->
        %{status: 500, bytes: inspect(other), location: nil}

      {:raised, text} ->
        %{status: 500, bytes: text, location: nil}
    end
  end

  defp run(seed, fun) do
    :erlang.trace_pattern({Plug.Adapters.Test.Conn, :chunk, 2}, true, [:local])
    task = Task.async(fn -> receive(do: (:go -> safely(fun))) end)
    :erlang.trace(task.pid, true, [:call])
    send(task.pid, :go)

    result =
      case Task.yield(task, @stream_wait) do
        {:ok, {:ok, %Plug.Conn{} = c}} ->
          %{
            status: c.status,
            bytes: inspect(c.resp_headers) <> (c.resp_body || ""),
            location: c |> get_resp_header("location") |> List.first()
          }

        {:ok, {:raised, text}} ->
          %{status: 500, bytes: text, location: nil}

        nil ->
          touch!(seed)
          Process.sleep(500)
          Task.shutdown(task, :brutal_kill)
          %{status: :stream, bytes: "", location: nil}
      end

    %{result | bytes: result.bytes <> drain_chunks(task.pid, [])}
  end

  defp drain_chunks(pid, acc) do
    receive do
      {:trace, ^pid, :call, {_, :chunk, [_state, body]}} ->
        drain_chunks(pid, [IO.iodata_to_binary(body) | acc])
    after
      0 -> acc |> Enum.reverse() |> Enum.join()
    end
  end

  defp safely(fun) do
    {:ok, fun.()}
  rescue
    e -> {:raised, Exception.format(:error, e, __STACKTRACE__)}
  catch
    kind, value -> {:raised, inspect({kind, value})}
  end

  @doc """
  Every byte a channel answered a caller: the join reply, then each event's
  reply and pushes, for each search word. `{:joined, bytes}`, or
  `{:refused, bytes}` when the connect or the join was refused.
  """
  def channel_call(seed, token, {_path, socket, prefix, _channel, events}) do
    import Phoenix.ChannelTest

    topic = prefix <> "#{seed.ws.slug}:#{seed.project.slug}:#{@ds}"
    info = %{peer_data: %{address: {127, 0, 0, 1}, port: 4000, ssl_cert: nil}}

    case safely(fn -> connect(socket, %{"token" => token}, connect_info: info) end) do
      {:ok, {:ok, sock}} ->
        case safely(fn -> subscribe_and_join(sock, topic, %{}) end) do
          {:ok, {:ok, reply, chan}} ->
            pushed =
              for event <- events, word <- words() do
                ref = push(chan, event, %{"q" => word, "query" => word})
                inspect(safely(fn -> assert_reply(ref, _, _, 2_000) end))
              end

            Process.sleep(100)
            {:joined, inspect(reply) <> Enum.join(pushed) <> mailbox()}

          other ->
            {:refused, inspect(other)}
        end

      other ->
        {:refused, inspect(other)}
    end
  end

  defp mailbox do
    receive do
      message -> inspect(message) <> mailbox()
    after
      0 -> ""
    end
  end
end
