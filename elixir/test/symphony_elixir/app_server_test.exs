defmodule SymphonyElixir.AppServerTest do
  use SymphonyElixir.TestSupport

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Writes a fake claude script that emits stream-json events and exits 0.
  defp write_fake_claude(path, events, exit_code \\ 0) do
    lines =
      Enum.map(events, fn event ->
        "printf '%s\\n' '#{Jason.encode!(event) |> String.replace("'", "'\\''")}'"
      end)

    body = Enum.join(lines, "\n") <> "\nexit #{exit_code}\n"

    File.write!(path, "#!/bin/sh\n" <> body)
    File.chmod!(path, 0o755)
  end

  defp assistant_event(text) do
    %{
      "type" => "assistant",
      "message" => %{
        "content" => [%{"type" => "text", "text" => text}]
      }
    }
  end

  defp result_event(usage \\ %{"input_tokens" => 10, "output_tokens" => 5}) do
    %{"type" => "result", "subtype" => "success", "usage" => usage}
  end

  defp test_session(workspace, model \\ "claude-opus-4-6") do
    %{
      workspace: workspace,
      model: model,
      api_key: "test-key",
      turn_timeout_ms: 5_000,
      stall_timeout_ms: 300_000
    }
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
  # start_session
  # ---------------------------------------------------------------------------

  test "start_session returns a session map with config from workflow" do
    write_workflow_file!(Workflow.workflow_file_path(), claude_model: "claude-opus-4-6")

    workspace = System.tmp_dir!()
    assert {:ok, session} = AppServer.start_session(workspace)
    assert session.workspace == workspace
    assert session.model == "claude-opus-4-6"
    assert is_binary(session.api_key) and session.api_key != ""
    refute Map.has_key?(session, :messages)
  end

  test "start_session returns error when API key is missing" do
    write_workflow_file!(Workflow.workflow_file_path(), claude_api_key: nil)
    previous = System.get_env("SYMPHONY_ANTHROPIC_API_KEY")
    System.delete_env("SYMPHONY_ANTHROPIC_API_KEY")
    System.delete_env("ANTHROPIC_API_KEY")
    on_exit(fn ->
      if previous, do: System.put_env("SYMPHONY_ANTHROPIC_API_KEY", previous)
    end)

    workspace = System.tmp_dir!()
    assert {:error, :missing_anthropic_api_key} = AppServer.start_session(workspace)
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
  # run_turn — subprocess driving
  # ---------------------------------------------------------------------------

  test "run_turn spawns claude and returns turn_completed on exit 0" do
    test_root = Path.join(System.tmp_dir!(), "sym-appserver-#{System.unique_integer([:positive])}")
    File.mkdir_p!(test_root)

    try do
      fake_claude = Path.join(test_root, "claude")
      write_fake_claude(fake_claude, [assistant_event("Done!"), result_event()])

      workspace = Path.join(test_root, "workspace")
      File.mkdir_p!(workspace)

      session = test_session(workspace) |> Map.put(:claude_executable, fake_claude)
      issue = test_issue()

      assert {:ok, result} = AppServer.run_turn(session, "Fix the bug", issue)
      assert result.result == :turn_completed
      assert is_binary(result.session_id)
    after
      File.rm_rf(test_root)
    end
  end

  test "run_turn emits session_started and turn_completed events" do
    test_root = Path.join(System.tmp_dir!(), "sym-appserver-events-#{System.unique_integer([:positive])}")
    File.mkdir_p!(test_root)

    try do
      fake_claude = Path.join(test_root, "claude")
      write_fake_claude(fake_claude, [assistant_event("Done!"), result_event()])

      workspace = Path.join(test_root, "workspace")
      File.mkdir_p!(workspace)

      test_pid = self()
      on_message = fn msg -> send(test_pid, {:event, msg.event}) end

      session = test_session(workspace) |> Map.put(:claude_executable, fake_claude)
      issue = test_issue()

      assert {:ok, _} = AppServer.run_turn(session, "Do it", issue, on_message: on_message)

      assert_receive {:event, :session_started}
      assert_receive {:event, :turn_completed}
    after
      File.rm_rf(test_root)
    end
  end

  test "run_turn returns error on non-zero exit" do
    test_root = Path.join(System.tmp_dir!(), "sym-appserver-fail-#{System.unique_integer([:positive])}")
    File.mkdir_p!(test_root)

    try do
      fake_claude = Path.join(test_root, "claude")
      write_fake_claude(fake_claude, [], 1)

      workspace = Path.join(test_root, "workspace")
      File.mkdir_p!(workspace)

      test_pid = self()
      on_message = fn msg -> send(test_pid, {:event, msg.event}) end

      session = test_session(workspace) |> Map.put(:claude_executable, fake_claude)
      issue = test_issue()

      assert {:error, _} = AppServer.run_turn(session, "Will fail", issue, on_message: on_message)
      assert_receive {:event, :turn_ended_with_error}
    after
      File.rm_rf(test_root)
    end
  end

  test "run_turn passes ANTHROPIC_API_KEY from session to subprocess" do
    test_root = Path.join(System.tmp_dir!(), "sym-appserver-env-#{System.unique_integer([:positive])}")
    File.mkdir_p!(test_root)

    try do
      env_file = Path.join(test_root, "env.txt")
      fake_claude = Path.join(test_root, "claude")

      File.write!(fake_claude, """
      #!/bin/sh
      printf '%s\\n' "KEY=$ANTHROPIC_API_KEY" >> #{env_file}
      printf '%s\\n' '{"type":"result","subtype":"success"}'
      exit 0
      """)
      File.chmod!(fake_claude, 0o755)

      workspace = Path.join(test_root, "workspace")
      File.mkdir_p!(workspace)

      session = test_session(workspace) |> Map.put(:api_key, "test-key-xyz") |> Map.put(:claude_executable, fake_claude)
      issue = test_issue()

      AppServer.run_turn(session, "test", issue)

      assert File.read!(env_file) =~ "KEY=test-key-xyz"
    after
      File.rm_rf(test_root)
    end
  end
end
