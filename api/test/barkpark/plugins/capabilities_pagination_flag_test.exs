defmodule Barkpark.Plugins.CapabilitiesPaginationFlagTest do
  @moduledoc """
  The manifest's `paginated` bit is not documentation — it is the ONLY switch
  the Go CLI reads before it will page, warn, or refuse:

    * `internal/cli/run.go:236` — `--all` walks offset pages only when
      `cmd.Paginated`; on a `false` command `--all` is silently a no-op and the
      caller gets page one believing it got everything;
    * `internal/cli/run.go:527` — the "page reached the default limit, more may
      be available" notice is suppressed for non-paginated commands, so a
      truncated read looks complete;
    * `internal/cli/run.go:373` — the `unreadable_list_page` refusal (the PDS
      reader law) does not even arm, so a proxy 502 on a list read renders as an
      empty success.

  A read command that OFFERS `--limit` and `--offset` is by construction a
  paged read: those flags exist because the server truncates. Flagging it
  `paginated: false` is therefore not a lesser setting, it is a false one, and
  every consequence above is silent. `media.search` shipped exactly that shape —
  limit + offset + cursor flags, a server emitting `total`/`hasMore`/`nextCursor`,
  and `paginated: false`.

  This guard runs over the WHOLE manifest, not the media noun: an inverted flag
  in one command is never an inverted flag in only one.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Plugins.Capabilities

  defp commands do
    Capabilities.manifest("admin", project: false)["commands"]
  end

  defp flag_names(command), do: Enum.map(command["flags"] || [], & &1["name"])

  test "the manifest is non-empty and carries the flag this guard measures" do
    cmds = commands()

    assert length(cmds) > 50,
           "manifest scanned #{length(cmds)} commands — too few to be the real one"

    assert Enum.all?(cmds, &is_map_key(&1, "paginated")),
           "every command must carry a `paginated` bit for this guard to mean anything"

    assert Enum.any?(cmds, & &1["paginated"]),
           "no command is `paginated: true` — the guard would pass vacuously"
  end

  test "every read offering both --limit and --offset is paginated: true" do
    offenders =
      commands()
      |> Enum.filter(fn cmd ->
        names = flag_names(cmd)
        not cmd["writes"] and "limit" in names and "offset" in names and not cmd["paginated"]
      end)
      |> Enum.map(& &1["id"])
      |> Enum.sort()

    assert offenders == [],
           """
           These read commands declare --limit AND --offset but are flagged `paginated: false`:

             #{Enum.join(offenders, "\n  ")}

           `bp <cmd> --all` silently returns page one for each of them, the
           default-page truncation notice never fires, and the
           unreadable_list_page refusal never arms. Set `paginated: true` on the
           command in api/lib/barkpark/plugins/capabilities.ex and record its
           response envelope key in internal/cli/paginate_all_test.go's
           `paginatedEnvelopeKeys` (that Go guard fails until you do).
           """
  end

  test "every paginated read declares a --limit flag with the server's default" do
    # `defaultPageLimit` (internal/cli/run.go:540) reads the limit flag's
    # DEFAULT off the manifest to decide whether page one was full. No default
    # means it returns 0 and the truncation notice is skipped — a paginated
    # command with no declared limit default cannot warn about truncation.
    offenders =
      commands()
      |> Enum.filter(& &1["paginated"])
      |> Enum.filter(fn cmd ->
        limit = Enum.find(cmd["flags"] || [], &(&1["name"] == "limit"))
        is_nil(limit) or is_nil(limit["default"])
      end)
      |> Enum.map(& &1["id"])
      |> Enum.sort()

    assert offenders == [],
           """
           These `paginated: true` commands declare no --limit default, so
           `defaultPageLimit` returns 0 and the "more may be available" notice
           can never fire for them:

             #{Enum.join(offenders, "\n  ")}
           """
  end

  test "the four media list reads are paginated with server-matching defaults" do
    by_id = Map.new(commands(), &{&1["id"], &1})

    for {id, limit_default} <- [
          {"media.ls", 50},
          {"media.search", 50},
          {"media.collections", 200},
          {"media.collection-assets", 50}
        ] do
      cmd = Map.fetch!(by_id, id)
      assert cmd["paginated"], "#{id} must be paginated: true"

      names = flag_names(cmd)
      assert "limit" in names, "#{id} must offer --limit"
      assert "offset" in names, "#{id} must offer --offset"

      limit = Enum.find(cmd["flags"], &(&1["name"] == "limit"))

      assert limit["default"] == limit_default,
             "#{id} --limit default #{inspect(limit["default"])} does not match the server's #{limit_default}"
    end
  end
end
