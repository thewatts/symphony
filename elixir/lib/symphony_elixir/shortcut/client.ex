defmodule SymphonyElixir.Shortcut.Client do
  @moduledoc """
  Shortcut REST API v3 client for polling and managing stories.
  """

  require Logger
  alias SymphonyElixir.{Config, Issue}

  @base_url "https://api.app.shortcut.com/api/v3"
  @page_size 25
  @max_error_body_log_bytes 1_000

  # ---------------------------------------------------------------------------
  # Public interface (mirrors Linear.Client)
  # ---------------------------------------------------------------------------

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    tracker = Config.settings!().tracker

    cond do
      is_nil(tracker.api_key) ->
        {:error, :missing_shortcut_api_token}

      is_nil(tracker.project_slug) ->
        {:error, :missing_shortcut_workflow_id}

      true ->
        with {:ok, assignee_filter} <- routing_assignee_filter() do
          fetch_stories_by_states(tracker.active_states, tracker.project_slug, assignee_filter)
        end
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    normalized = state_names |> Enum.map(&to_string/1) |> Enum.uniq()

    if normalized == [] do
      {:ok, []}
    else
      tracker = Config.settings!().tracker

      cond do
        is_nil(tracker.api_key) ->
          {:error, :missing_shortcut_api_token}

        is_nil(tracker.project_slug) ->
          {:error, :missing_shortcut_workflow_id}

        true ->
          fetch_stories_by_states(normalized, tracker.project_slug, nil)
      end
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    ids = Enum.uniq(issue_ids)

    case ids do
      [] ->
        {:ok, []}

      ids ->
        with {:ok, assignee_filter} <- routing_assignee_filter() do
          fetch_stories_by_ids(ids, assignee_filter)
        end
    end
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(story_id, text) when is_binary(story_id) and is_binary(text) do
    with {:ok, headers} <- api_headers() do
      url = "#{@base_url}/stories/#{story_id}/comments"

      case Req.post(url, headers: headers, json: %{"text" => text}, connect_options: [timeout: 30_000]) do
        {:ok, %{status: status}} when status in 200..299 ->
          :ok

        {:ok, %{status: status, body: body}} ->
          Logger.error("Shortcut create_comment failed status=#{status} body=#{inspect_body(body)}")
          {:error, {:shortcut_api_status, status}}

        {:error, reason} ->
          Logger.error("Shortcut create_comment request failed: #{inspect(reason)}")
          {:error, {:shortcut_api_request, reason}}
      end
    end
  end

  @spec update_story_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_story_state(story_id, state_name) when is_binary(story_id) and is_binary(state_name) do
    with {:ok, headers} <- api_headers(),
         {:ok, workflow_state_id} <- resolve_workflow_state_id(story_id, state_name, headers) do
      url = "#{@base_url}/stories/#{story_id}"

      case Req.put(url,
             headers: headers,
             json: %{"workflow_state_id" => workflow_state_id},
             connect_options: [timeout: 30_000]
           ) do
        {:ok, %{status: status}} when status in 200..299 ->
          :ok

        {:ok, %{status: status, body: body}} ->
          Logger.error("Shortcut update_story_state failed status=#{status} body=#{inspect_body(body)}")
          {:error, {:shortcut_api_status, status}}

        {:error, reason} ->
          Logger.error("Shortcut update_story_state request failed: #{inspect(reason)}")
          {:error, {:shortcut_api_request, reason}}
      end
    end
  end

  @spec request(String.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def request(method, path, body \\ %{}, opts \\ []) do
    with {:ok, headers} <- api_headers() do
      url = if String.starts_with?(path, "http"), do: path, else: "#{@base_url}/#{String.trim_leading(path, "/")}"
      request_fun = Keyword.get(opts, :request_fun, &do_request/4)
      request_fun.(method, url, headers, body)
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp fetch_stories_by_states(state_names, workflow_id, assignee_filter) do
    workflow_id_int = parse_int(workflow_id)

    if is_nil(workflow_id_int) do
      {:error, {:invalid_shortcut_workflow_id, workflow_id}}
    else
      with {:ok, state_id_map} <- fetch_workflow_state_map(workflow_id_int),
           {:ok, state_ids} <- resolve_state_ids(state_names, state_id_map) do
        do_search_stories(state_ids, workflow_id_int, assignee_filter, nil, [])
      end
    end
  end

  # Fetches all workflow states and returns a downcased-name → id map.
  defp fetch_workflow_state_map(workflow_id) do
    with {:ok, headers} <- api_headers() do
      case Req.get("#{@base_url}/workflows/#{workflow_id}",
             headers: headers,
             connect_options: [timeout: 30_000]
           ) do
        {:ok, %{status: 200, body: workflow}} ->
          state_map =
            workflow
            |> Map.get("states", [])
            |> Map.new(fn s -> {String.downcase(to_string(s["name"])), s["id"]} end)

          {:ok, state_map}

        {:ok, %{status: status}} ->
          {:error, {:shortcut_api_status, status}}

        {:error, reason} ->
          {:error, {:shortcut_api_request, reason}}
      end
    end
  end

  # Resolves a list of state name strings to their integer IDs.
  # Logs a warning for any name not found in the workflow.
  defp resolve_state_ids(state_names, state_id_map) do
    {ids, missing} =
      Enum.reduce(state_names, {[], []}, fn name, {ids_acc, missing_acc} ->
        key = String.downcase(String.trim(name))

        case Map.get(state_id_map, key) do
          nil -> {ids_acc, [name | missing_acc]}
          id -> {[id | ids_acc], missing_acc}
        end
      end)

    if missing != [] do
      Logger.warning(
        "Shortcut: state names not found in workflow: #{inspect(Enum.reverse(missing))}. " <>
          "Available states: #{inspect(Map.keys(state_id_map))}"
      )
    end

    {:ok, Enum.reverse(ids)}
  end

  defp do_search_stories(state_ids, workflow_id, assignee_filter, next_page_token, acc) do
    with {:ok, headers} <- api_headers() do
      body =
        %{
          "workflow_id" => workflow_id,
          "workflow_state_ids" => state_ids,
          "page_size" => @page_size
        }
        |> maybe_put("next", next_page_token)

      case Req.post("#{@base_url}/stories/search",
             headers: headers,
             json: body,
             connect_options: [timeout: 30_000]
           ) do
        {:ok, %{status: 200, body: response}} ->
          stories = Map.get(response, "data", [])
          issues = stories |> Enum.map(&normalize_story(&1, assignee_filter)) |> Enum.reject(&is_nil/1)
          updated_acc = issues ++ acc

          case Map.get(response, "next") do
            token when is_binary(token) and token != "" ->
              do_search_stories(state_ids, workflow_id, assignee_filter, token, updated_acc)

            _ ->
              {:ok, Enum.reverse(updated_acc)}
          end

        {:ok, %{status: status, body: body}} ->
          Logger.error("Shortcut search failed status=#{status} body=#{inspect_body(body)}")
          {:error, {:shortcut_api_status, status}}

        {:error, reason} ->
          Logger.error("Shortcut search request failed: #{inspect(reason)}")
          {:error, {:shortcut_api_request, reason}}
      end
    end
  end

  defp fetch_stories_by_ids(ids, assignee_filter) do
    with {:ok, headers} <- api_headers() do
      ids
      |> Enum.chunk_every(@page_size)
      |> Enum.reduce_while({:ok, []}, fn batch, {:ok, acc} ->
        case fetch_stories_batch(batch, headers, assignee_filter) do
          {:ok, issues} -> {:cont, {:ok, acc ++ issues}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp fetch_stories_batch(ids, headers, assignee_filter) do
    case Req.get("#{@base_url}/stories/bulk",
           headers: headers,
           params: [story_ids: Enum.join(ids, ",")],
           connect_options: [timeout: 30_000]
         ) do
      {:ok, %{status: 200, body: stories}} when is_list(stories) ->
        issues = stories |> Enum.map(&normalize_story(&1, assignee_filter)) |> Enum.reject(&is_nil/1)
        {:ok, issues}

      {:ok, %{status: status, body: body}} ->
        Logger.error("Shortcut bulk fetch failed status=#{status} body=#{inspect_body(body)}")
        {:error, {:shortcut_api_status, status}}

      {:error, reason} ->
        Logger.error("Shortcut bulk fetch request failed: #{inspect(reason)}")
        {:error, {:shortcut_api_request, reason}}
    end
  end

  defp resolve_workflow_state_id(story_id, state_name, headers) do
    case Req.get("#{@base_url}/stories/#{story_id}", headers: headers, connect_options: [timeout: 30_000]) do
      {:ok, %{status: 200, body: story}} ->
        workflow_id = story["workflow_id"]

        with {:ok, state_map} <- fetch_workflow_state_map(workflow_id) do
          key = String.downcase(String.trim(state_name))

          case Map.get(state_map, key) do
            nil -> {:error, {:shortcut_state_not_found, state_name}}
            state_id -> {:ok, state_id}
          end
        end

      {:ok, %{status: status}} ->
        {:error, {:shortcut_api_status, status}}

      {:error, reason} ->
        {:error, {:shortcut_api_request, reason}}
    end
  end

  defp routing_assignee_filter do
    case Config.settings!().tracker.assignee do
      nil -> {:ok, nil}
      "me" -> resolve_self_assignee_filter()
      assignee -> {:ok, %{match_values: MapSet.new([assignee])}}
    end
  end

  defp resolve_self_assignee_filter do
    with {:ok, headers} <- api_headers() do
      case Req.get("#{@base_url}/member", headers: headers, connect_options: [timeout: 30_000]) do
        {:ok, %{status: 200, body: %{"id" => member_id}}} ->
          {:ok, %{match_values: MapSet.new([to_string(member_id)])}}

        {:ok, _} ->
          {:error, :missing_shortcut_member_identity}

        {:error, reason} ->
          {:error, {:shortcut_api_request, reason}}
      end
    end
  end

  defp normalize_story(story, assignee_filter) when is_map(story) do
    assignee_ids =
      story
      |> Map.get("owner_ids", [])
      |> Enum.map(&to_string/1)

    primary_assignee_id = List.first(assignee_ids)

    %Issue{
      id: to_string(story["id"]),
      identifier: "sc-#{story["id"]}",
      title: story["name"],
      description: story["description"],
      priority: parse_priority(story["priority"]),
      state: get_in(story, ["workflow_state", "name"]) || resolve_state_name(story),
      branch_name: Map.get(story, "branch_ids", []) |> List.first() |> then(&if(&1, do: "sc-#{story["id"]}", else: nil)),
      url: story["app_url"],
      assignee_id: primary_assignee_id,
      labels: extract_labels(story),
      blocked_by: extract_blockers(story),
      assigned_to_worker: assigned_to_worker?(assignee_ids, assignee_filter),
      created_at: parse_datetime(story["created_at"]),
      updated_at: parse_datetime(story["updated_at"])
    }
  end

  defp normalize_story(_story, _assignee_filter), do: nil

  defp resolve_state_name(story) do
    # workflow_state may be embedded or just an ID — fall back to nil
    case story["workflow_state"] do
      %{"name" => name} when is_binary(name) -> name
      _ -> nil
    end
  end

  defp assigned_to_worker?(_assignee_ids, nil), do: true

  defp assigned_to_worker?(assignee_ids, %{match_values: match_values}) when is_list(assignee_ids) do
    Enum.any?(assignee_ids, &MapSet.member?(match_values, &1))
  end

  defp assigned_to_worker?(_assignee_ids, _filter), do: false

  defp extract_labels(story) do
    story
    |> Map.get("labels", [])
    |> Enum.map(&Map.get(&1, "name"))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&String.downcase/1)
  end

  defp extract_blockers(story) do
    story
    |> Map.get("blocker_ids", [])
    |> Enum.map(fn blocker_id ->
      %{id: to_string(blocker_id), identifier: "sc-#{blocker_id}", state: nil}
    end)
  end

  defp api_headers do
    case Config.settings!().tracker.api_key do
      nil ->
        {:error, :missing_shortcut_api_token}

      token ->
        {:ok,
         [
           {"Shortcut-Token", token},
           {"Content-Type", "application/json"}
         ]}
    end
  end

  defp do_request("GET", url, headers, _body) do
    Req.get(url, headers: headers, connect_options: [timeout: 30_000])
  end

  defp do_request("POST", url, headers, body) do
    Req.post(url, headers: headers, json: body, connect_options: [timeout: 30_000])
  end

  defp do_request("PUT", url, headers, body) do
    Req.put(url, headers: headers, json: body, connect_options: [timeout: 30_000])
  end

  defp do_request("DELETE", url, headers, _body) do
    Req.delete(url, headers: headers, connect_options: [timeout: 30_000])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp parse_int(value) when is_integer(value), do: value

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_int(_), do: nil

  defp parse_priority(0), do: nil
  defp parse_priority(p) when is_integer(p), do: p
  defp parse_priority(_), do: nil

  defp parse_datetime(nil), do: nil

  defp parse_datetime(raw) when is_binary(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil

  defp inspect_body(body) when is_binary(body) do
    body
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> then(fn b ->
      if byte_size(b) > @max_error_body_log_bytes,
        do: binary_part(b, 0, @max_error_body_log_bytes) <> "...<truncated>",
        else: b
    end)
    |> inspect()
  end

  defp inspect_body(body), do: inspect(body, limit: 20, printable_limit: @max_error_body_log_bytes)

  # ---------------------------------------------------------------------------
  # Test helpers (public for use in tests only)
  # ---------------------------------------------------------------------------

  @doc false
  @spec normalize_story_for_test(map(), term()) :: Issue.t() | nil
  def normalize_story_for_test(story, assignee_filter), do: normalize_story(story, assignee_filter)

  @doc false
  @spec resolve_state_ids_for_test([String.t()], map()) :: {:ok, [integer()]}
  def resolve_state_ids_for_test(state_names, state_map), do: resolve_state_ids(state_names, state_map)

  @doc false
  @spec build_state_map_for_test([map()]) :: map()
  def build_state_map_for_test(states) do
    Map.new(states, fn s -> {String.downcase(to_string(s["name"])), s["id"]} end)
  end
end
