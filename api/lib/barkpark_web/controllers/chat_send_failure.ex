defmodule BarkparkWeb.ChatSendFailure do
  @moduledoc """
  The D26 send-failure reason split for `POST /v1/chat/sessions/:id/messages`.

  `classify/1` sorts a Recorder/Runtime failure term over an explicit
  ALLOWLIST into a class; `public_error/1` gives each class its fixed status,
  public code and message, which `ChatController.send_failure_response/2`
  answers with. `loggable/1` is the term the server log may carry.
  `studio_text/1` is the Studio chat's wording for the same failures.
  """

  @type class :: :capacity | :unavailable | :unsupported | :host_cannot_receive_attachments

  @spec classify(term()) :: class()
  # Capacity: admission refused the spawn — the runtime pool is full or two
  # spawns raced the registration; both clear on their own.
  def classify({:managed_runtime_capacity, _}), do: :capacity
  def classify(:admission_registration_conflict), do: :capacity

  # Unavailable: the runtime is not there right now (dead GenServer, closed or
  # absent port, dead app-server, ensure_and_send's {:ok, nil} guard) — retryable.
  def classify({:not_running, _}), do: :unavailable
  def classify(:port_closed), do: :unavailable
  def classify(:no_port), do: :unavailable
  def classify({:app_server_exit, _}), do: :unavailable
  def classify(:runtime_session_missing), do: :unavailable
  # The registered host is enrolled but has not heartbeated within the window.
  def classify(:host_offline), do: :unavailable

  # Unsupported: the provider/operation combination can never succeed as asked.
  # `:host_not_found`: the session's registered host is revoked, never finished
  # enrolling, or belongs to another workspace — retrying cannot bring it back.
  def classify(:host_not_found), do: :unsupported
  def classify({:provider_not_ready, _}), do: :unsupported
  def classify({:provider_protocol_incompatible, _}), do: :unsupported
  def classify({:unsupported_runtime_operation, _}), do: :unsupported
  def classify({:missing_runtime_contract, _}), do: :unsupported

  # The turn names attachments and the session's registered host does not list
  # their type (Paper chat-host-attachments-plan). Permanent for this host until
  # its binary is updated; its own code so a client can say why, and offer to
  # send the words alone.
  def classify({:host_cannot_receive_attachments, _}), do: :host_cannot_receive_attachments

  # Opaque fallback: any term outside the allowlist stays a generic transient
  # 503 — unknown ≠ permanent, and the term itself never reaches the wire.
  def classify(_), do: :unavailable

  @doc """
  The fixed `{status, code, message}` for a class. A permanent class is a 4xx:
  a 503 would make a well-behaved client retry forever (charter D26). The
  `:capacity` answer also carries a Retry-After header, which the controller
  adds.
  """
  @spec public_error(class()) :: {pos_integer(), String.t(), String.t()}
  def public_error(:capacity),
    do: {503, "runtime_capacity", "chat runtime capacity is exhausted — retry shortly"}

  def public_error(:unavailable), do: {503, "runtime_unavailable", "chat runtime is unavailable"}

  def public_error(:unsupported),
    do:
      {422, "chat_unsupported", "chat is not supported for this session's provider or operation"}

  def public_error(:host_cannot_receive_attachments),
    do:
      {422, "host_cannot_receive_attachments",
       "this session's chat host cannot receive attachments of this type — update barkpark-chat-host, or send the text alone"}

  @doc """
  The Studio chat's system line for a user turn that never reached the model.

  Honest line (charter D24): the port write failed or the session had already
  gone. The words are restored to the composer, so this is a "try again", not a
  "your message is lost". A registered host that does not advertise the
  attachments capability did not drop: retrying with the same images fails the
  same way, so say what will work.
  """
  @spec studio_text(term()) :: String.t()
  def studio_text({:host_cannot_receive_attachments, _provider}),
    do:
      "This session's chat host can't receive images yet. Update barkpark-chat-host, or send the words alone."

  def studio_text(_reason),
    do:
      "That message didn't reach Claude — the session dropped. Your words were kept; send again."

  @doc """
  The failure term with every stack frame's arguments replaced by their arity.

  A Recorder that raised in `init/1` comes back as `{reason, stacktrace}`, and
  the top frame of a FunctionClauseError carries the call's ARGUMENTS — on the
  registered-host path a RemoteRef holding the minted task token's row
  (task-ff4074ff3f85fcfb). Log the reason and every frame by arity; never the
  arguments.
  """
  @spec loggable(term()) :: term()
  def loggable({reason, [{_m, _f, _a, _l} | _] = stack}),
    do: {reason, Enum.map(stack, &frame_without_args/1)}

  def loggable(reason), do: reason

  defp frame_without_args({m, f, args, loc}) when is_list(args), do: {m, f, length(args), loc}
  defp frame_without_args(frame), do: frame
end
