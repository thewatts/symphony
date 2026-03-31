defmodule SymphonyElixir.Claude.AppServer do
  @moduledoc """
  Drives Claude Code CLI as a subprocess for autonomous coding turns.

  Spawns `claude --print --dangerously-skip-permissions --output-format stream-json`
  in the workspace directory, pipes the prompt via stdin, and waits for the
  process to exit. Claude Code handles all tool use (bash, file edits, git, etc.)
  internally.

  Public API mirrors Codex.AppServer:
    run/4, start_session/2, run_turn/4, stop_session/1
  """

  require Logger
  alias SymphonyElixir.Config

  @port_line_bytes 1_048_576
  @max_stream_log_bytes 1_000

  @type session :: %{
          workspace: Path.t(),
          model: String.t(),
          api_key: String.t(),
          turn_timeout_ms: pos_integer(),
          stall_timeout_ms: pos_integer()
        }

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec run(Path.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(workspace, prompt, issue, opts \\ []) do
    with {:ok, session} <- start_session(workspace, opts) do
      try do
        run_turn(session, prompt, issue, opts)
      after
        stop_session(session)
      end
    end
  end

  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, _opts \\ []) do
    settings = Config.settings!()
    claude = settings.claude

    case claude.api_key do
      key when is_binary(key) and key != "" ->
        {:ok,
         %{
           workspace: workspace,
           model: claude.model,
           api_key: key,
           turn_timeout_ms: claude.turn_timeout_ms,
           stall_timeout_ms: claude.stall_timeout_ms
         }}

      _ ->
        {:error, :missing_anthropic_api_key}
    end
  end

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(session, prompt, issue, opts \\ []) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    session_id = generate_session_id()

    Logger.info("Claude session started for #{issue_context(issue)} session_id=#{session_id}")
    emit_message(on_message, :session_started, %{session_id: session_id}, %{})

    case run_claude_subprocess(session, prompt, on_message, session_id) do
      {:ok, output} ->
        Logger.info("Claude session completed for #{issue_context(issue)} session_id=#{session_id}")
        emit_message(on_message, :turn_completed, %{session_id: session_id}, %{})
        {:ok, %{result: :turn_completed, session_id: session_id, output: output}}

      {:error, :permission_blocked} = err ->
        Logger.warning("Claude session permission blocked for #{issue_context(issue)} session_id=#{session_id}")
        emit_message(on_message, :turn_ended_with_error, %{session_id: session_id, reason: :permission_blocked}, %{})
        err

      {:error, reason} ->
        Logger.warning("Claude session ended with error for #{issue_context(issue)} session_id=#{session_id}: #{inspect(reason)}")
        emit_message(on_message, :turn_ended_with_error, %{session_id: session_id, reason: reason}, %{})
        {:error, reason}
    end
  end

  @spec stop_session(session()) :: :ok
  def stop_session(_session), do: :ok

  # ---------------------------------------------------------------------------
  # Subprocess execution
  # ---------------------------------------------------------------------------

  defp run_claude_subprocess(session, prompt, on_message, session_id) do
    executable = Map.get(session, :claude_executable) || System.find_executable("claude")

    if is_nil(executable) do
      {:error, :claude_not_found}
    else
      command = build_command(session)
      env = subprocess_env(session)

      port =
        Port.open(
          {:spawn_executable, String.to_charlist(executable)},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: command,
            cd: String.to_charlist(session.workspace),
            env: env,
            line: @port_line_bytes
          ]
        )

      # Send prompt via stdin then close stdin
      Port.command(port, prompt <> "\n")

      receive_loop(port, on_message, session_id, session.turn_timeout_ms, "", [])
    end
  end

  defp build_command(session) do
    [
      ~c"--print",
      ~c"--dangerously-skip-permissions",
      ~c"--output-format", ~c"stream-json",
      ~c"--model", String.to_charlist(session.model),
      ~c"--bare",
      ~c"--no-session-persistence"
    ]
  end

  defp subprocess_env(session) do
    # --bare mode uses ANTHROPIC_API_KEY strictly (no OAuth/keychain)
    [
      {~c"ANTHROPIC_API_KEY", String.to_charlist(session.api_key)}
    ]
  end

  defp receive_loop(port, on_message, session_id, timeout_ms, pending_line, output_acc) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        line = pending_line <> to_string(chunk)
        handle_line(port, on_message, session_id, timeout_ms, line, output_acc)

      {^port, {:data, {:noeol, chunk}}} ->
        receive_loop(port, on_message, session_id, timeout_ms, pending_line <> to_string(chunk), output_acc)

      {^port, {:exit_status, 0}} ->
        {:ok, Enum.reverse(output_acc)}

      {^port, {:exit_status, status}} ->
        Logger.warning("Claude subprocess exited with status=#{status}")
        check_permission_block(output_acc, status)
    after
      timeout_ms ->
        Port.close(port)
        {:error, :turn_timeout}
    end
  end

  defp handle_line(port, on_message, session_id, timeout_ms, line, output_acc) do
    trimmed = String.trim(line)

    updated_acc =
      case Jason.decode(trimmed) do
        {:ok, event} ->
          handle_stream_event(event, on_message, session_id)
          [event | output_acc]

        {:error, _} ->
          log_non_json_line(trimmed)
          output_acc
      end

    receive_loop(port, on_message, session_id, timeout_ms, "", updated_acc)
  end

  defp handle_stream_event(%{"type" => "assistant"} = event, on_message, session_id) do
    text = extract_text(event)

    if text != "" do
      Logger.debug("Claude: #{String.slice(text, 0, @max_stream_log_bytes)}")
    end

    emit_message(on_message, :notification, %{session_id: session_id, payload: event}, %{})
  end

  defp handle_stream_event(%{"type" => "result"} = event, on_message, session_id) do
    usage = Map.get(event, "usage")
    metadata = if is_map(usage), do: %{usage: usage}, else: %{}
    emit_message(on_message, :usage, %{session_id: session_id, payload: event}, metadata)
  end

  defp handle_stream_event(%{"type" => type} = event, on_message, session_id) do
    Logger.debug("Claude event type=#{type}")
    emit_message(on_message, :notification, %{session_id: session_id, payload: event}, %{})
  end

  defp handle_stream_event(_event, _on_message, _session_id), do: :ok

  defp check_permission_block(output_acc, exit_status) do
    blocked =
      Enum.any?(output_acc, fn event ->
        case event do
          %{"type" => "error", "error" => %{"type" => type}} ->
            String.contains?(to_string(type), "permission")

          %{"type" => "system", "subtype" => subtype} ->
            String.contains?(to_string(subtype), "permission")

          _ ->
            false
        end
      end)

    if blocked do
      {:error, :permission_blocked}
    else
      {:error, {:process_exit, exit_status}}
    end
  end

  defp extract_text(%{"message" => %{"content" => content}}) when is_list(content) do
    content
    |> Enum.filter(&(&1["type"] == "text"))
    |> Enum.map_join("", & &1["text"])
    |> String.trim()
  end

  defp extract_text(_), do: ""

  defp log_non_json_line(""), do: :ok

  defp log_non_json_line(line) do
    text = String.slice(line, 0, @max_stream_log_bytes)

    if String.match?(text, ~r/\b(error|warn|warning|failed|fatal|panic|exception)\b/i) do
      Logger.warning("Claude subprocess output: #{text}")
    else
      Logger.debug("Claude subprocess output: #{text}")
    end
  end

  defp emit_message(on_message, event, details, metadata) when is_function(on_message, 1) do
    message =
      metadata
      |> Map.merge(details)
      |> Map.put(:event, event)
      |> Map.put(:timestamp, DateTime.utc_now())

    on_message.(message)
  end

  defp default_on_message(_message), do: :ok

  defp generate_session_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
