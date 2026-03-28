defmodule SymphonyElixir.Claude.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Claude during agentic turns.
  """

  alias SymphonyElixir.Shortcut.Client

  @shortcut_api_tool "shortcut_api"
  @shortcut_api_description """
  Make an authenticated request to the Shortcut REST API v3 using Symphony's configured auth.
  Use this to read or update stories, comments, workflows, and other Shortcut resources.
  """

  @shortcut_api_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["method", "path"],
    "properties" => %{
      "method" => %{
        "type" => "string",
        "enum" => ["GET", "POST", "PUT", "DELETE"],
        "description" => "HTTP method."
      },
      "path" => %{
        "type" => "string",
        "description" => "API path, e.g. `/stories/123` or `/stories/123/comments`. Relative to /api/v3."
      },
      "body" => %{
        "type" => "object",
        "description" => "Optional request body for POST/PUT requests.",
        "additionalProperties" => true
      }
    }
  }

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    case tool do
      @shortcut_api_tool ->
        execute_shortcut_api(arguments, opts)

      other ->
        failure_response(%{
          "error" => %{
            "message" => "Unsupported dynamic tool: #{inspect(other)}.",
            "supportedTools" => supported_tool_names()
          }
        })
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    [
      %{
        "name" => @shortcut_api_tool,
        "description" => @shortcut_api_description,
        "input_schema" => @shortcut_api_input_schema
      }
    ]
  end

  defp execute_shortcut_api(arguments, opts) do
    shortcut_client = Keyword.get(opts, :shortcut_client, &Client.request/3)

    with {:ok, method, path, body} <- normalize_shortcut_api_arguments(arguments),
         {:ok, response} <- shortcut_client.(method, path, body) do
      api_response(response)
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp normalize_shortcut_api_arguments(arguments) when is_map(arguments) do
    method = Map.get(arguments, "method") || Map.get(arguments, :method)
    path = Map.get(arguments, "path") || Map.get(arguments, :path)
    body = Map.get(arguments, "body") || Map.get(arguments, :body) || %{}

    cond do
      not is_binary(method) or String.trim(method) == "" ->
        {:error, :missing_method}

      not (method in ["GET", "POST", "PUT", "DELETE"]) ->
        {:error, {:invalid_method, method}}

      not is_binary(path) or String.trim(path) == "" ->
        {:error, :missing_path}

      not is_map(body) ->
        {:error, :invalid_body}

      true ->
        {:ok, method, String.trim(path), body}
    end
  end

  defp normalize_shortcut_api_arguments(_), do: {:error, :invalid_arguments}

  defp api_response(%{status: status, body: body}) when status in 200..299 do
    tool_result(true, encode_payload(body))
  end

  defp api_response(%{status: status, body: body}) do
    tool_result(false, encode_payload(%{"error" => "HTTP #{status}", "body" => body}))
  end

  defp api_response(response) do
    tool_result(true, encode_payload(response))
  end

  defp failure_response(payload) do
    tool_result(false, encode_payload(payload))
  end

  defp tool_result(success, output) when is_boolean(success) and is_binary(output) do
    %{"success" => success, "output" => output}
  end

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)

  defp tool_error_payload(:missing_method) do
    %{"error" => %{"message" => "`shortcut_api` requires a `method` string (GET, POST, PUT, DELETE)."}}
  end

  defp tool_error_payload({:invalid_method, method}) do
    %{"error" => %{"message" => "Invalid method `#{method}`. Must be GET, POST, PUT, or DELETE."}}
  end

  defp tool_error_payload(:missing_path) do
    %{"error" => %{"message" => "`shortcut_api` requires a non-empty `path` string."}}
  end

  defp tool_error_payload(:invalid_body) do
    %{"error" => %{"message" => "`shortcut_api.body` must be a JSON object when provided."}}
  end

  defp tool_error_payload(:invalid_arguments) do
    %{"error" => %{"message" => "`shortcut_api` expects an object with `method` and `path` fields."}}
  end

  defp tool_error_payload(:missing_shortcut_api_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing Shortcut auth. Set `tracker.api_key` in `WORKFLOW.md` or export `SHORTCUT_API_TOKEN`."
      }
    }
  end

  defp tool_error_payload({:shortcut_api_status, status}) do
    %{"error" => %{"message" => "Shortcut API request failed with HTTP #{status}.", "status" => status}}
  end

  defp tool_error_payload({:shortcut_api_request, reason}) do
    %{"error" => %{"message" => "Shortcut API request failed.", "reason" => inspect(reason)}}
  end

  defp tool_error_payload(reason) do
    %{"error" => %{"message" => "Shortcut API tool execution failed.", "reason" => inspect(reason)}}
  end

  defp supported_tool_names do
    Enum.map(tool_specs(), & &1["name"])
  end
end
