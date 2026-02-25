defmodule LemonChannels.Adapters.Telegram.TransportConfigFlagsTest do
  @moduledoc """
  Tests for progress_reactions, typing_indicator, reply_to_user_message,
  and show_tool_status config flags.
  """
  use ExUnit.Case, async: false

  alias LemonChannels.Adapters.Telegram.Transport
  alias LemonCore.SessionKey

  # ---------------------------------------------------------------------------
  # Inline mock API that notifies the test process of API calls
  # ---------------------------------------------------------------------------

  defmodule ConfigFlagsMockAPI do
    @pid_key {__MODULE__, :pid}
    @updates_key {__MODULE__, :updates}

    def register_test(pid), do: :persistent_term.put(@pid_key, pid)
    def set_updates(updates), do: :persistent_term.put(@updates_key, updates)

    def get_updates(_token, _offset, _timeout_ms) do
      case :persistent_term.get(@updates_key, []) do
        [next | rest] ->
          :persistent_term.put(@updates_key, rest)
          {:ok, %{"ok" => true, "result" => [next]}}

        [] ->
          {:ok, %{"ok" => true, "result" => []}}
      end
    end

    def send_message(_token, chat_id, text, opts \\ nil, _parse_mode \\ nil) do
      notify({:send_message, chat_id, text, opts})
      {:ok, %{"ok" => true, "result" => %{"message_id" => System.unique_integer([:positive])}}}
    end

    def edit_message_text(_token, _chat_id, _message_id, _text, _opts \\ nil) do
      {:ok, %{"ok" => true}}
    end

    def delete_message(_token, _chat_id, _message_id) do
      {:ok, %{"ok" => true}}
    end

    def answer_callback_query(_token, _callback_id, _opts \\ %{}) do
      {:ok, %{"ok" => true}}
    end

    def set_message_reaction(_token, chat_id, message_id, emoji, _opts \\ %{}) do
      notify({:set_message_reaction, chat_id, message_id, emoji})
      {:ok, %{"ok" => true}}
    end

    def send_chat_action(_token, chat_id, action, _opts \\ %{}) do
      notify({:send_chat_action, chat_id, action})
      {:ok, %{"ok" => true}}
    end

    def forward_message(_token, _to_chat_id, _from_chat_id, _message_id, _opts \\ %{}) do
      {:ok, %{"ok" => true, "result" => %{"message_id" => System.unique_integer([:positive])}}}
    end

    def get_file(_token, _file_id) do
      {:ok, %{"ok" => true, "result" => %{"file_path" => "docs/test.txt"}}}
    end

    def get_me(_token) do
      {:ok, %{"ok" => true, "result" => %{"id" => 1, "username" => "testbot", "is_bot" => true}}}
    end

    defp notify(msg) do
      if pid = :persistent_term.get(@pid_key, nil) do
        send(pid, msg)
      end

      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Stub router bridge — just captures inbounds, never sends them anywhere real
  # ---------------------------------------------------------------------------

  defmodule StubRouter do
    def handle_inbound(_msg), do: :ok
    def abort(_session_key, _reason), do: :ok
    def abort_run(_run_id, _reason), do: :ok
  end

  # ---------------------------------------------------------------------------
  # Setup / teardown
  # ---------------------------------------------------------------------------

  setup do
    stop_transport()

    old_router_bridge = Application.get_env(:lemon_core, :router_bridge)
    old_channels_env = Application.get_env(:lemon_channels, :gateway)
    old_telegram_env = Application.get_env(:lemon_channels, :telegram)

    ConfigFlagsMockAPI.register_test(self())
    LemonCore.RouterBridge.configure(router: StubRouter)

    on_exit(fn ->
      stop_transport()
      :persistent_term.erase({ConfigFlagsMockAPI, :updates})
      :persistent_term.erase({ConfigFlagsMockAPI, :pid})
      restore_env(:lemon_core, :router_bridge, old_router_bridge)
      restore_env(:lemon_channels, :gateway, old_channels_env)
      restore_env(:lemon_channels, :telegram, old_telegram_env)
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # progress_reactions
  # ---------------------------------------------------------------------------

  test "progress_reactions: true sets 👀 reaction on user message" do
    chat_id = 701_001
    msg_id = 1001
    ConfigFlagsMockAPI.set_updates([message_update(chat_id, msg_id, "hello")])

    {:ok, _pid} =
      start_transport(%{
        allowed_chat_ids: [chat_id],
        deny_unbound_chats: false,
        # explicit so TOML config doesn't interfere
        progress_reactions: true,
        typing_indicator: false
      })

    assert_receive {:set_message_reaction, ^chat_id, ^msg_id, "👀"}, 500
  end

  test "progress_reactions: false suppresses the 👀 reaction" do
    chat_id = 701_002
    msg_id = 1002
    ConfigFlagsMockAPI.set_updates([message_update(chat_id, msg_id, "hello")])

    {:ok, _pid} =
      start_transport(%{
        allowed_chat_ids: [chat_id],
        deny_unbound_chats: false,
        progress_reactions: false,
        typing_indicator: false
      })

    refute_receive {:set_message_reaction, ^chat_id, ^msg_id, _}, 300
  end

  # ---------------------------------------------------------------------------
  # typing_indicator
  # ---------------------------------------------------------------------------

  test "typing_indicator: false does not send chat action" do
    chat_id = 702_001
    msg_id = 2001
    ConfigFlagsMockAPI.set_updates([message_update(chat_id, msg_id, "hello")])

    {:ok, _pid} =
      start_transport(%{
        allowed_chat_ids: [chat_id],
        deny_unbound_chats: false,
        # explicit so TOML config doesn't interfere
        progress_reactions: false,
        typing_indicator: false
      })

    refute_receive {:send_chat_action, ^chat_id, "typing"}, 300
  end

  test "typing_indicator: true sends a typing chat action on message receipt" do
    chat_id = 702_002
    msg_id = 2002
    ConfigFlagsMockAPI.set_updates([message_update(chat_id, msg_id, "hello")])

    {:ok, _pid} =
      start_transport(%{
        allowed_chat_ids: [chat_id],
        deny_unbound_chats: false,
        progress_reactions: false,
        typing_indicator: true
      })

    assert_receive {:send_chat_action, ^chat_id, "typing"}, 500
  end

  test "typing_indicator heartbeat is active in state and cancelled by run_completed" do
    chat_id = 702_003
    msg_id = 2003
    ConfigFlagsMockAPI.set_updates([message_update(chat_id, msg_id, "hello")])

    {:ok, pid} =
      start_transport(%{
        allowed_chat_ids: [chat_id],
        deny_unbound_chats: false,
        progress_reactions: false,
        typing_indicator: true
      })

    # Wait for the first typing action so we know the message was processed.
    assert_receive {:send_chat_action, ^chat_id, "typing"}, 500

    session_key =
      SessionKey.channel_peer(%{
        agent_id: "default",
        channel_id: "telegram",
        account_id: "default",
        peer_kind: :dm,
        peer_id: Integer.to_string(chat_id)
      })

    # State should have an active typing timer for this session.
    state = :sys.get_state(pid)
    assert Map.has_key?(state.typing_timers, session_key)

    # Simulate the run completing — send directly to bypass Bus subscription setup.
    send(pid, %LemonCore.Event{
      type: :run_completed,
      ts_ms: System.monotonic_time(:millisecond),
      meta: %{session_key: session_key},
      payload: %{ok: true}
    })

    # Give the GenServer a moment to process the event.
    :sys.get_state(pid)

    state = :sys.get_state(pid)
    refute Map.has_key?(state.typing_timers, session_key)
  end

  # ---------------------------------------------------------------------------
  # reply_to_user_message and show_tool_status (via GatewayConfig runtime override)
  # These tests verify that get_telegram/2 correctly handles boolean false values
  # (the || falsy bug) and that the runtime override path works end-to-end.
  # ---------------------------------------------------------------------------

  test "GatewayConfig.get_telegram/2 returns false when reply_to_user_message is explicitly false" do
    old = Application.get_env(:lemon_channels, :telegram)

    Application.put_env(:lemon_channels, :telegram, %{reply_to_user_message: false})

    try do
      assert LemonChannels.GatewayConfig.get_telegram(:reply_to_user_message, true) == false
    after
      restore_env(:lemon_channels, :telegram, old)
    end
  end

  test "GatewayConfig.get_telegram/2 returns true when reply_to_user_message is explicitly true" do
    old = Application.get_env(:lemon_channels, :telegram)

    Application.put_env(:lemon_channels, :telegram, %{reply_to_user_message: true})

    try do
      assert LemonChannels.GatewayConfig.get_telegram(:reply_to_user_message, false) == true
    after
      restore_env(:lemon_channels, :telegram, old)
    end
  end

  test "GatewayConfig.get_telegram/2 returns false when show_tool_status is explicitly false" do
    old = Application.get_env(:lemon_channels, :telegram)

    Application.put_env(:lemon_channels, :telegram, %{show_tool_status: false})

    try do
      assert LemonChannels.GatewayConfig.get_telegram(:show_tool_status, true) == false
    after
      restore_env(:lemon_channels, :telegram, old)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp start_transport(overrides) do
    token = "token-" <> Integer.to_string(System.unique_integer([:positive]))

    config =
      %{
        bot_token: token,
        api_mod: ConfigFlagsMockAPI,
        poll_interval_ms: 10,
        debounce_ms: 10
      }
      |> Map.merge(overrides)

    Transport.start_link(config: config)
  end

  defp message_update(chat_id, message_id, text) do
    %{
      "update_id" => System.unique_integer([:positive]),
      "message" => %{
        "message_id" => message_id,
        "date" => 1,
        "chat" => %{"id" => chat_id, "type" => "private"},
        "from" => %{"id" => 99, "username" => "tester", "first_name" => "Test"},
        "text" => text
      }
    }
  end

  defp stop_transport do
    if pid = Process.whereis(Transport) do
      if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    end
  catch
    :exit, _ -> :ok
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, val), do: Application.put_env(app, key, val)
end
