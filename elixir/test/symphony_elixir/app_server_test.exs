defmodule SymphonyElixir.AppServerTest do
  use SymphonyElixir.TestSupport

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp end_turn_response do
    %{
      "id" => "msg_end",
      "type" => "message",
      "role" => "assistant",
      "model" => "claude-opus-4-6",
      "stop_reason" => "end_turn",
      "content" => [%{"type" => "text", "text" => "Done."}],
      "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
    }
  end

  defp tool_use_response(tool_name, tool_input) do
    %{
      "id" => "msg_tool",
      "type" => "message",
      "role" => "assistant",
      "model" => "claude-opus-4-6",
      "stop_reason" => "tool_use",
      "content" => [
        %{"type" => "text", "text" => "Using tool."},
        %{"type" => "tool_use", "id" => "tool_call_1", "name" => tool_name, "input" => tool_input}
      ],
      "usage" => %{"input_tokens" => 20, "output_tokens" => 10}
    }
  end

  defp stub_sequential(name, responses) do
    counter = :counters.new(1, [])

    Req.Test.stub(name, fn conn ->
      {:ok, _body, conn} = Plug.Conn.read_body(conn)
      n = :counters.get(counter, 1)
      :counters.put(counter, 1, n + 1)
      response = Enum.at(responses, n, List.last(responses))
      Req.Test.json(conn, response)
    end)
  end

  defp test_session(workspace, overrides \\ %{}) do
    Map.merge(
      %{
        workspace: workspace,
        model: "claude-opus-4-6",
        api_key: "test-key",
        max_tokens: 16_384,
        turn_timeout_ms: 5_000,
        stall_timeout_ms: 300_000,
        messages: [],
        plug: {Req.Test, SymphonyElixir.Claude.AppServer}
      },
      overrides
    )
  end

  defp test_issue(overrides \\ %{}) do
    Map.merge(
      %{
        id: "issue-test",
        identifier: "MT-1",
        title: "Test issue",
        description: "A test issue",
        state: "In Progress",
        url: "https://example.org/issues/MT-1",
        labels: []
      },
      overrides
    )
  end

  # ---------------------------------------------------------------------------
  # start_session tests
  # ---------------------------------------------------------------------------

  test "start_session returns a session map with config from workflow" do
    write_workflow_file!(Workflow.workflow_file_path(),
      claude_model: "claude-opus-4-6",
      claude_max_tokens: 8192
    )

    workspace = System.tmp_dir!()
    assert {:ok, session} = AppServer.start_session(workspace)
    assert session.workspace == workspace
    assert session.model == "claude-opus-4-6"
    assert session.max_tokens == 8192
    assert session.messages == []
    assert is_binary(session.api_key) and session.api_key != ""
  end

  test "start_session returns error when API key is missing" do
    write_workflow_file!(Workflow.workflow_file_path(), claude_api_key: nil)
    System.delete_env("ANTHROPIC_API_KEY")

    workspace = System.tmp_dir!()
    assert {:error, :missing_anthropic_api_key} = AppServer.start_session(workspace)
  end

  # ---------------------------------------------------------------------------
  # run_turn — basic API call shape
  # ---------------------------------------------------------------------------

  test "run_turn sends correct model, messages, and tool specs to Anthropic API" do
    write_workflow_file!(Workflow.workflow_file_path(), claude_model: "claude-opus-4-6")

    workspace = System.tmp_dir!()
    test_pid = self()

    Req.Test.stub(SymphonyElixir.Claude.AppServer, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request_body, Jason.decode!(body)})
      Req.Test.json(conn, end_turn_response())
    end)

    session = test_session(workspace)
    issue = test_issue()

    assert {:ok, result} = AppServer.run_turn(session, "Fix this bug", issue)
    assert result.result == :turn_completed
    assert is_binary(result.session_id)

    assert_receive {:request_body, body}
    assert body["model"] == "claude-opus-4-6"
    assert is_list(body["tools"])
    assert Enum.any?(body["tools"], &(&1["name"] == "shortcut_api"))
    assert [%{"role" => "user", "content" => "Fix this bug"}] = body["messages"]
  end

  test "run_turn accumulates messages in the returned session" do
    write_workflow_file!(Workflow.workflow_file_path())
    workspace = System.tmp_dir!()

    Req.Test.stub(SymphonyElixir.Claude.AppServer, fn conn ->
      {:ok, _body, conn} = Plug.Conn.read_body(conn)
      Req.Test.json(conn, end_turn_response())
    end)

    session = test_session(workspace)
    issue = test_issue()

    assert {:ok, result} = AppServer.run_turn(session, "Turn 1 prompt", issue)
    session2 = result.session

    # session2 should have user + assistant messages
    assert length(session2.messages) == 2
    assert Enum.at(session2.messages, 0)["role"] == "user"
    assert Enum.at(session2.messages, 1)["role"] == "assistant"

    # Running another turn adds two more
    Req.Test.stub(SymphonyElixir.Claude.AppServer, fn conn ->
      {:ok, _body, conn} = Plug.Conn.read_body(conn)
      Req.Test.json(conn, end_turn_response())
    end)

    assert {:ok, result2} = AppServer.run_turn(session2, "Turn 2 prompt", issue)
    session3 = result2.session
    assert length(session3.messages) == 4
  end

  # ---------------------------------------------------------------------------
  # Tool use loop
  # ---------------------------------------------------------------------------

  test "run_turn executes tool calls and sends results back in a follow-up message" do
    write_workflow_file!(Workflow.workflow_file_path())
    workspace = System.tmp_dir!()
    test_pid = self()

    stub_sequential(SymphonyElixir.Claude.AppServer, [
      tool_use_response("linear_graphql", %{"query" => "{ viewer { id } }"}),
      end_turn_response()
    ])

    session = test_session(workspace)
    issue = test_issue()

    on_message = fn msg -> send(test_pid, {:event, msg.event}) end

    custom_executor = fn tool, args ->
      send(test_pid, {:tool_called, tool, args})
      %{"success" => true, "output" => ~s({"data":{"viewer":{"id":"u1"}}})}
    end

    assert {:ok, _result} =
             AppServer.run_turn(session, "Query Linear", issue,
               on_message: on_message,
               tool_executor: custom_executor
             )

    assert_receive {:tool_called, "linear_graphql", %{"query" => "{ viewer { id } }"}}
    assert_receive {:event, :tool_call_completed}
    assert_receive {:event, :turn_completed}
  end

  test "run_turn emits tool_call_failed when tool executor returns success: false" do
    write_workflow_file!(Workflow.workflow_file_path())
    workspace = System.tmp_dir!()
    test_pid = self()

    stub_sequential(SymphonyElixir.Claude.AppServer, [
      tool_use_response("linear_graphql", %{"query" => "bad query"}),
      end_turn_response()
    ])

    session = test_session(workspace)
    issue = test_issue()

    on_message = fn msg -> send(test_pid, {:event, msg.event}) end

    failing_executor = fn _tool, _args ->
      %{"success" => false, "output" => ~s({"error":"query failed"})}
    end

    assert {:ok, _result} =
             AppServer.run_turn(session, "Fail a tool", issue,
               on_message: on_message,
               tool_executor: failing_executor
             )

    assert_receive {:event, :tool_call_failed}
    assert_receive {:event, :turn_completed}
  end

  test "run_turn sends tool result content in the next API request" do
    write_workflow_file!(Workflow.workflow_file_path())
    workspace = System.tmp_dir!()
    test_pid = self()
    call_count = :counters.new(1, [])

    Req.Test.stub(SymphonyElixir.Claude.AppServer, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      n = :counters.get(call_count, 1)
      :counters.put(call_count, 1, n + 1)
      send(test_pid, {:request, n, Jason.decode!(body)})

      response = if n == 0, do: tool_use_response("linear_graphql", %{"query" => "{ me }"}), else: end_turn_response()
      Req.Test.json(conn, response)
    end)

    session = test_session(workspace)
    issue = test_issue()

    executor = fn _tool, _args -> %{"success" => true, "output" => ~s({"data":{}})} end

    assert {:ok, _result} = AppServer.run_turn(session, "Run tool", issue, tool_executor: executor)

    assert_receive {:request, 0, _first_body}
    assert_receive {:request, 1, second_body}

    # Second request should have assistant message + tool_result user message
    messages = second_body["messages"]
    assert Enum.any?(messages, &(&1["role"] == "assistant"))

    tool_result_msg =
      Enum.find(messages, fn m ->
        m["role"] == "user" and is_list(m["content"]) and
          Enum.any?(m["content"], &(&1["type"] == "tool_result"))
      end)

    assert tool_result_msg != nil
  end

  # ---------------------------------------------------------------------------
  # Event emission
  # ---------------------------------------------------------------------------

  test "run_turn emits session_started, usage, and turn_completed events" do
    write_workflow_file!(Workflow.workflow_file_path())
    workspace = System.tmp_dir!()
    test_pid = self()

    Req.Test.stub(SymphonyElixir.Claude.AppServer, fn conn ->
      {:ok, _body, conn} = Plug.Conn.read_body(conn)
      Req.Test.json(conn, end_turn_response())
    end)

    session = test_session(workspace)
    issue = test_issue()
    on_message = fn msg -> send(test_pid, {:event, msg.event, msg}) end

    assert {:ok, _result} = AppServer.run_turn(session, "Do it", issue, on_message: on_message)

    assert_receive {:event, :session_started, %{session_id: sid}}
    assert is_binary(sid) and byte_size(sid) > 0
    assert_receive {:event, :usage, %{usage: %{"input_tokens" => 10}}}
    assert_receive {:event, :turn_completed, _}
  end

  test "run_turn emits turn_ended_with_error on API failure" do
    write_workflow_file!(Workflow.workflow_file_path())
    workspace = System.tmp_dir!()
    test_pid = self()

    Req.Test.stub(SymphonyElixir.Claude.AppServer, fn conn ->
      conn
      |> Plug.Conn.put_status(401)
      |> Req.Test.json(%{"error" => %{"type" => "authentication_error", "message" => "bad key"}})
    end)

    session = test_session(workspace)
    issue = test_issue()
    on_message = fn msg -> send(test_pid, {:event, msg.event}) end

    assert {:error, {:api_error, 401, _}} =
             AppServer.run_turn(session, "Will fail", issue, on_message: on_message)

    assert_receive {:event, :turn_ended_with_error}
  end

  # ---------------------------------------------------------------------------
  # stop_session
  # ---------------------------------------------------------------------------

  test "stop_session always returns :ok" do
    session = test_session(System.tmp_dir!())
    assert :ok = AppServer.stop_session(session)
    assert :ok = AppServer.stop_session(%{})
  end

  # ---------------------------------------------------------------------------
  # run/4 convenience wrapper
  # ---------------------------------------------------------------------------

  test "run/4 starts a session, runs a turn, and stops the session" do
    write_workflow_file!(Workflow.workflow_file_path())
    workspace = System.tmp_dir!()
    test_pid = self()

    Req.Test.stub(SymphonyElixir.Claude.AppServer, fn conn ->
      {:ok, _body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, :api_called)
      Req.Test.json(conn, end_turn_response())
    end)

    issue = %Issue{
      id: "issue-run",
      identifier: "MT-10",
      title: "Run test",
      description: "Test run/4",
      state: "In Progress",
      url: "https://example.org",
      labels: []
    }

    assert {:ok, result} =
             AppServer.run(workspace, "Go", issue,
               plug: {Req.Test, SymphonyElixir.Claude.AppServer}
             )

    assert result.result == :turn_completed
    assert_receive :api_called
  end
end
