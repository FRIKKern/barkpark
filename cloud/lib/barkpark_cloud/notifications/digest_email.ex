defmodule BarkparkCloud.Notifications.DigestEmail do
  @moduledoc """
  isu-w5 — builds the daily FLEET-UPDATE digest email: one plain-text operator
  report of where every managed instance stands against the newest release the
  fleet has seen. This is the "from nag to product" push — the release curator's
  daily judgment (a draft GitHub Release + a run log) becomes something a human
  passively RECEIVES instead of having to go look for.

  It is NOT a gui-premium "email type" (that system renders PortableDoc blocks
  and never SENDS). It is a transactional-style plain-text send: this module only
  RENDERS a `%Swoosh.Email{}` from fleet rows — `Notifications.deliver_fleet_digest/1`
  resolves the operator recipients and delivers over the platform `Mailer`.

  Truth-only inputs: every value comes from columns the fleet already polls
  (`update_state` / `update_running_release` / `update_latest_release` /
  `update_checked_at` from isu-6, plus `autoupdate_enabled` / `autoupdate_paused` /
  `pinned_release` from isu-w4). It NEVER calls GitHub — "latest available" is
  simply the max `update_latest_release` across rows, the shared release fact the
  curator and the fleet both key off, surfaced through data already on hand.

  `base_email/3` in `Notifications.Transactional` is private, so this module
  builds the `%Swoosh.Email{}` with the same four-line Swoosh pattern
  `Notifications.EventEmail` uses (`new/0 |> to |> from(Mailer.from) |> subject |>
  text_body`) — one platform From, plain text, no HTML polish (YAGNI).
  """
  import Swoosh.Email

  alias BarkparkCloud.Mailer
  alias BarkparkCloud.Registry.Barkpark

  @typedoc "The pre-computed fleet roll-up the subject + body render from."
  @type summary :: %{
          total: non_neg_integer(),
          current: non_neg_integer(),
          behind: non_neg_integer(),
          paused: non_neg_integer(),
          latest: String.t() | nil,
          instances: [Barkpark.t()]
        }

  @doc """
  Roll the fleet rows up into the counts the digest reports. Pure — no DB, no
  clock — so the subject/body rendering is fully testable from fixture rows.

    * `current` / `behind` — instances at those `update_state`s;
    * `paused` — instances with `autoupdate_paused` set (the operator escape hatch);
    * `latest` — the newest `update_latest_release` seen across the fleet
      (semver-aware, `nil` when no row has reported one yet).
  """
  @spec summary([Barkpark.t()]) :: summary()
  def summary(barkparks) when is_list(barkparks) do
    %{
      total: length(barkparks),
      current: Enum.count(barkparks, &(&1.update_state == "current")),
      behind: Enum.count(barkparks, &(&1.update_state == "behind")),
      paused: Enum.count(barkparks, & &1.autoupdate_paused),
      latest: latest_release(barkparks),
      instances: barkparks
    }
  end

  @doc "The digest subject line — the fleet health at a glance."
  @spec subject(summary()) :: String.t()
  def subject(%{current: c, behind: b, paused: p}) do
    "Barkpark fleet digest — #{c} current / #{b} behind / #{p} paused"
  end

  @doc """
  The plain-text digest body: a fleet header (counts + latest available release)
  then one honest line per instance (name, running -> latest, state, pin/pause
  flags, last checked). An empty fleet renders a clear "no instances" line rather
  than a bare header.
  """
  @spec body(summary()) :: String.t()
  def body(%{instances: []} = s) do
    """
    #{header(s)}

    No instances are registered yet — nothing to report.

    #{footer()}
    """
  end

  def body(%{instances: instances} = s) do
    lines = Enum.map_join(instances, "\n", &instance_line/1)

    """
    #{header(s)}

    Instances:
    #{lines}

    #{footer()}
    """
  end

  @doc """
  Build (but do not send) the digest `%Swoosh.Email{}` for one operator
  `recipient` from a pre-computed `summary`. Separated from delivery so a test
  can inspect the struct and so every recipient shares one rendering.
  """
  @spec build(summary(), String.t()) :: Swoosh.Email.t()
  def build(summary, recipient) when is_binary(recipient) do
    new()
    |> to(recipient)
    |> from(Mailer.from())
    |> subject(subject(summary))
    |> text_body(body(summary))
  end

  ## ── Rendering helpers ────────────────────────────────────────────────────

  defp header(%{total: total, current: c, behind: b, paused: p, latest: latest}) do
    fleet =
      case total do
        0 ->
          "Fleet: 0 instances."

        _ ->
          "Fleet: #{total} #{pluralize(total, "instance")} — #{c} current, #{b} behind, #{p} paused."
      end

    """
    Barkpark fleet — daily update digest.

    #{fleet}
    Latest available release: #{latest || "unknown"}\
    """
  end

  defp footer do
    "This is an automated operator digest from Barkpark Cloud."
  end

  # One instance's honest status line:
  #   - Name (slug): <running> -> <latest> | state: <state>[ | <flags>] | checked <ts>
  defp instance_line(%Barkpark{} = bp) do
    running = present(bp.update_running_release) || present(bp.version) || "unknown"
    latest = present(bp.update_latest_release) || "unknown"
    state = present(bp.update_state) || "unknown"

    "- #{bp.name} (#{bp.slug}): #{running} -> #{latest} | state: #{state}" <>
      flags_suffix(bp) <>
      " | checked #{format_ts(bp.update_checked_at)}"
  end

  # The pin/pause/autoupdate-off flags an operator needs to read a row honestly.
  # Empty (no suffix) when the instance carries none.
  defp flags_suffix(%Barkpark{} = bp) do
    flags =
      [
        if(present(bp.pinned_release), do: "pinned=#{bp.pinned_release}"),
        if(bp.autoupdate_paused, do: "paused"),
        if(bp.autoupdate_enabled == false, do: "autoupdate off")
      ]
      |> Enum.reject(&is_nil/1)

    case flags do
      [] -> ""
      list -> " | " <> Enum.join(list, ", ")
    end
  end

  # The newest release across the fleet — semver-aware where the tags parse
  # (`v1.10.0` > `v1.9.0`, which a lexical max gets wrong), falling back to a
  # lexical compare for non-semver tags so a weird tag never crashes the digest.
  defp latest_release(barkparks) do
    barkparks
    |> Enum.map(& &1.update_latest_release)
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.reduce(nil, fn tag, acc ->
      cond do
        is_nil(acc) -> tag
        release_gte?(tag, acc) -> tag
        true -> acc
      end
    end)
  end

  defp release_gte?(a, b) do
    case {parse_version(a), parse_version(b)} do
      {{:ok, va}, {:ok, vb}} -> Version.compare(va, vb) != :lt
      _ -> a >= b
    end
  end

  defp parse_version(tag) when is_binary(tag) do
    tag |> String.trim_leading("v") |> Version.parse()
  end

  defp format_ts(nil), do: "never"
  defp format_ts(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")

  defp present(nil), do: nil
  defp present(""), do: nil
  defp present(v) when is_binary(v), do: v

  defp pluralize(1, word), do: word
  defp pluralize(_, word), do: word <> "s"
end
