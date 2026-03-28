defmodule SymphonyElixir.Test.StubAppServer do
  @moduledoc """
  A test stub for Claude.AppServer that records calls and returns configurable responses.

  Configure via process dictionary:
    Process.put(:stub_app_server_turns, [{:ok, %{result: :turn_completed, session_id: "stub-1", session: %{}}}])

  Each call to run_turn/4 pops one response from the list. If the list is empty, returns end_turn.
  """

  def start_session(_workspace, _opts \\ []) do
    {:ok, %{messages: [], stub: true}}
  end

  def run_turn(session, prompt, _issue, opts) do
    on_message = Keyword.get(opts, :on_message, fn _ -> :ok end)

    session_id = "stub-#{System.unique_integer([:positive])}"

    on_message.(%{event: :session_started, session_id: session_id, timestamp: DateTime.utc_now()})

    result =
      case Process.get(:stub_app_server_turns, []) do
        [] ->
          {:ok, %{result: :turn_completed, session_id: session_id, session: append_message(session, "user", prompt)}}

        [head | rest] ->
          Process.put(:stub_app_server_turns, rest)
          head
      end

    case result do
      {:ok, turn_result} ->
        on_message.(%{event: :turn_completed, session_id: session_id, timestamp: DateTime.utc_now()})
        {:ok, turn_result}

      {:error, _} = err ->
        err
    end
  end

  def stop_session(_session), do: :ok

  defp append_message(session, role, content) do
    msg = %{"role" => role, "content" => content}
    %{session | messages: session.messages ++ [msg]}
  end
end
