defmodule SymphonyElixir.Claude.AppServer do
  @moduledoc """
  Drives Claude via the Anthropic Messages API (tool-use agentic loop).

  Public API mirrors Codex.AppServer so AgentRunner needs minimal changes:
    run/4, start_session/2, run_turn/4, stop_session/1
  """

  require Logger
  alias SymphonyElixir.{Claude.DynamicTool, Config}

  @anthropic_api_url "https://api.anthropic.com/v1/messages"
  @anthropic_version "2023-06-01"

  @type session :: %{
          workspace: Path.t(),
          model: String.t(),
          api_key: String.t(),
          max_tokens: pos_integer(),
          turn_timeout_ms: pos_integer(),
          stall_timeout_ms: pos_integer(),
          # accumulated conversation messages across turns in this session
          messages: [map()]
        }

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec run(Path.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(workspace, prompt, issue, opts \\ []) do
    with {:ok, session} <- start_session(workspace, opts) do
      try do
        session_with_plug =
          case Keyword.get(opts, :plug) do
            nil -> session
            plug -> Map.put(session, :plug, plug)
          end

        run_turn(session_with_plug, prompt, issue, opts)
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
           max_tokens: claude.max_tokens,
           turn_timeout_ms: claude.turn_timeout_ms,
           stall_timeout_ms: claude.stall_timeout_ms,
           messages: []
         }}

      _ ->
        {:error, :missing_anthropic_api_key}
    end
  end

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(session, prompt, issue, opts \\ []) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    tool_executor = Keyword.get(opts, :tool_executor, &DynamicTool.execute/2)

    session_id = generate_session_id()
    Logger.info("Claude session started for #{issue_context(issue)} session_id=#{session_id}")

    emit_message(on_message, :session_started, %{session_id: session_id}, %{})

    # Append the new user turn to the running conversation
    updated_session = append_message(session, "user", prompt)

    case run_agentic_loop(updated_session, on_message, tool_executor, session_id) do
      {:ok, final_session} ->
        Logger.info("Claude session completed for #{issue_context(issue)} session_id=#{session_id}")
        emit_message(on_message, :turn_completed, %{session_id: session_id}, %{})
        {:ok, %{result: :turn_completed, session_id: session_id, session: final_session}}

      {:error, reason} ->
        Logger.warning(
          "Claude session ended with error for #{issue_context(issue)} session_id=#{session_id}: #{inspect(reason)}"
        )

        emit_message(on_message, :turn_ended_with_error, %{session_id: session_id, reason: reason}, %{})
        {:error, reason}
    end
  end

  @spec stop_session(session()) :: :ok
  def stop_session(_session), do: :ok

  # ---------------------------------------------------------------------------
  # Agentic loop
  # ---------------------------------------------------------------------------

  defp run_agentic_loop(session, on_message, tool_executor, session_id) do
    case call_api(session) do
      {:ok, %{"stop_reason" => "end_turn"} = response} ->
        emit_usage(on_message, response)
        log_assistant_text(response)
        {:ok, append_assistant_response(session, response)}

      {:ok, %{"stop_reason" => "tool_use"} = response} ->
        emit_usage(on_message, response)
        log_assistant_text(response)

        {:ok, tool_result_content} = handle_tool_calls(response, tool_executor, on_message, session_id)
        session_with_assistant = append_assistant_response(session, response)
        session_with_results = append_message(session_with_assistant, "user", tool_result_content)
        run_agentic_loop(session_with_results, on_message, tool_executor, session_id)

      {:ok, %{"stop_reason" => reason} = response} ->
        emit_usage(on_message, response)
        {:error, {:unexpected_stop_reason, reason}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # API call
  # ---------------------------------------------------------------------------

  defp call_api(%{api_key: api_key, model: model, max_tokens: max_tokens, messages: messages} = session) do
    body = %{
      "model" => model,
      "max_tokens" => max_tokens,
      "tools" => DynamicTool.tool_specs(),
      "messages" => messages
    }

    headers = [
      {"x-api-key", api_key},
      {"anthropic-version", @anthropic_version},
      {"content-type", "application/json"}
    ]

    timeout = session.turn_timeout_ms

    base_opts = [
      json: body,
      headers: headers,
      receive_timeout: timeout,
      connect_options: [timeout: 10_000]
    ]

    opts =
      case Map.get(session, :plug) do
        nil -> base_opts
        plug -> Keyword.put(base_opts, :plug, plug)
      end

    case Req.post(@anthropic_api_url, opts) do
      {:ok, %{status: 200, body: response_body}} ->
        {:ok, response_body}

      {:ok, %{status: status, body: body}} ->
        Logger.error("Anthropic API error status=#{status} body=#{inspect(body)}")
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        Logger.error("Anthropic API request failed: #{inspect(reason)}")
        {:error, {:api_request_failed, reason}}
    end
  end

  # ---------------------------------------------------------------------------
  # Tool call handling
  # ---------------------------------------------------------------------------

  defp handle_tool_calls(response, tool_executor, on_message, session_id) do
    tool_use_blocks =
      response
      |> Map.get("content", [])
      |> Enum.filter(&(&1["type"] == "tool_use"))

    results =
      Enum.map(tool_use_blocks, fn %{"id" => tool_id, "name" => name, "input" => input} ->
        result = tool_executor.(name, input)

        event =
          case result do
            %{"success" => true} -> :tool_call_completed
            _ -> :tool_call_failed
          end

        emit_message(on_message, event, %{session_id: session_id, tool: name, tool_id: tool_id}, %{})

        %{
          "type" => "tool_result",
          "tool_use_id" => tool_id,
          "content" => result["output"] || Jason.encode!(result)
        }
      end)

    {:ok, results}
  end

  # ---------------------------------------------------------------------------
  # Message helpers
  # ---------------------------------------------------------------------------

  defp append_message(session, role, content) when is_binary(content) do
    message = %{"role" => role, "content" => content}
    %{session | messages: session.messages ++ [message]}
  end

  defp append_message(session, role, content) when is_list(content) do
    message = %{"role" => role, "content" => content}
    %{session | messages: session.messages ++ [message]}
  end

  defp append_assistant_response(session, response) do
    content = Map.get(response, "content", [])
    append_message(session, "assistant", content)
  end

  # ---------------------------------------------------------------------------
  # Emit / logging helpers
  # ---------------------------------------------------------------------------

  defp emit_usage(on_message, response) do
    case Map.get(response, "usage") do
      usage when is_map(usage) ->
        emit_message(on_message, :usage, %{usage: usage}, %{usage: usage})

      _ ->
        :ok
    end
  end

  defp log_assistant_text(response) do
    text =
      response
      |> Map.get("content", [])
      |> Enum.filter(&(&1["type"] == "text"))
      |> Enum.map(& &1["text"])
      |> Enum.join("")
      |> String.trim()

    if text != "" do
      Logger.debug("Claude: #{String.slice(text, 0, 500)}")
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
