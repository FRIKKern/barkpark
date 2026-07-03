defmodule Barkpark.Plugins.Tickets.HandoffTest do
  use ExUnit.Case, async: true

  alias Barkpark.Plugins.Tickets.Handoff

  @host "https://guerrilla.barkpark.cloud"
  @raw "bptk_abc123"

  test "card/2 is the exact forwardable handoff artifact (golden)" do
    expected = """
    Barkpark ticket key — this key is your identity. Keep it secret.

      bptk_abc123

    1) File a ticket:
       curl -X POST https://guerrilla.barkpark.cloud/v1/tickets \\
         -H 'Authorization: Bearer bptk_abc123' \\
         -H 'Content-Type: application/json' \\
         -d '{"subject":"Short summary","body":"What you need"}'

    2) List your tickets:
       curl https://guerrilla.barkpark.cloud/v1/tickets \\
         -H 'Authorization: Bearer bptk_abc123'

    3) Read a ticket thread:
       curl https://guerrilla.barkpark.cloud/v1/tickets/TICKET_ID \\
         -H 'Authorization: Bearer bptk_abc123'

    Replying to an answered ticket reopens it.
    """

    assert Handoff.card(@host, @raw) == expected
  end

  test "shows the key exactly once" do
    card = Handoff.card(@host, @raw)
    # The raw appears in the key line + three curl Bearer headers = 4 times.
    occurrences = card |> String.split(@raw) |> length() |> Kernel.-(1)
    assert occurrences == 4
  end

  test "promises the three charter routes verbatim" do
    card = Handoff.card(@host, @raw)
    assert card =~ "1) File a ticket:"
    assert card =~ "curl -X POST https://guerrilla.barkpark.cloud/v1/tickets"
    assert card =~ "2) List your tickets:"
    assert card =~ "3) Read a ticket thread:"
    assert card =~ "https://guerrilla.barkpark.cloud/v1/tickets/TICKET_ID"
    assert card =~ "Replying to an answered ticket reopens it."
  end

  test "normalizes a trailing slash on the host" do
    assert Handoff.card("https://x.test/", @raw) == Handoff.card("https://x.test", @raw)
  end
end
