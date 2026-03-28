defmodule SymphonyElixir.Shortcut.ClientTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Shortcut.Client

  # ---------------------------------------------------------------------------
  # Story normalization
  # ---------------------------------------------------------------------------

  defp raw_story(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => 12345,
        "name" => "Fix the bug",
        "description" => "It is broken",
        "priority" => 2,
        "workflow_state" => %{"name" => "In Development"},
        "app_url" => "https://app.shortcut.com/org/story/12345",
        "owner_ids" => ["user-1"],
        "labels" => [%{"name" => "Backend"}, %{"name" => "Urgent"}],
        "blocker_ids" => [],
        "branch_ids" => [],
        "created_at" => "2026-01-01T00:00:00Z",
        "updated_at" => "2026-01-02T00:00:00Z"
      },
      overrides
    )
  end

  test "normalize_story_for_test builds a correct Issue struct" do
    story = raw_story()
    issue = Client.normalize_story_for_test(story, nil)

    assert issue.id == "12345"
    assert issue.identifier == "sc-12345"
    assert issue.title == "Fix the bug"
    assert issue.description == "It is broken"
    assert issue.priority == 2
    assert issue.state == "In Development"
    assert issue.url == "https://app.shortcut.com/org/story/12345"
    assert issue.assignee_id == "user-1"
    assert issue.labels == ["backend", "urgent"]
    assert issue.assigned_to_worker == true
    assert %DateTime{} = issue.created_at
    assert %DateTime{} = issue.updated_at
  end

  test "normalize_story_for_test lowercases labels" do
    story = raw_story(%{"labels" => [%{"name" => "FRONTEND"}, %{"name" => "Design"}]})
    issue = Client.normalize_story_for_test(story, nil)
    assert issue.labels == ["frontend", "design"]
  end

  test "normalize_story_for_test uses first owner as assignee_id" do
    story = raw_story(%{"owner_ids" => ["user-a", "user-b"]})
    issue = Client.normalize_story_for_test(story, nil)
    assert issue.assignee_id == "user-a"
  end

  test "normalize_story_for_test sets assignee_id to nil when no owners" do
    story = raw_story(%{"owner_ids" => []})
    issue = Client.normalize_story_for_test(story, nil)
    assert issue.assignee_id == nil
  end

  test "normalize_story_for_test extracts blocker_ids" do
    story = raw_story(%{"blocker_ids" => [99, 100]})
    issue = Client.normalize_story_for_test(story, nil)

    assert issue.blocked_by == [
             %{id: "99", identifier: "sc-99", state: nil},
             %{id: "100", identifier: "sc-100", state: nil}
           ]
  end

  test "normalize_story_for_test marks story as not assigned to worker when assignee filter set and no match" do
    story = raw_story(%{"owner_ids" => ["user-2"]})
    assignee_filter = %{match_values: MapSet.new(["user-1"])}
    issue = Client.normalize_story_for_test(story, assignee_filter)
    refute issue.assigned_to_worker
  end

  test "normalize_story_for_test marks story as assigned to worker when owner matches filter" do
    story = raw_story(%{"owner_ids" => ["user-1", "user-2"]})
    assignee_filter = %{match_values: MapSet.new(["user-1"])}
    issue = Client.normalize_story_for_test(story, assignee_filter)
    assert issue.assigned_to_worker
  end

  test "normalize_story_for_test marks all stories as assigned when no filter" do
    story = raw_story(%{"owner_ids" => []})
    issue = Client.normalize_story_for_test(story, nil)
    assert issue.assigned_to_worker
  end

  test "normalize_story_for_test handles missing optional fields gracefully" do
    story = %{"id" => 1, "name" => "Minimal"}
    issue = Client.normalize_story_for_test(story, nil)
    assert issue.id == "1"
    assert issue.title == "Minimal"
    assert issue.labels == []
    assert issue.blocked_by == []
    assert issue.assignee_id == nil
    assert issue.created_at == nil
    assert issue.updated_at == nil
  end

  test "normalize_story_for_test priority 0 is treated as nil" do
    story = raw_story(%{"priority" => 0})
    issue = Client.normalize_story_for_test(story, nil)
    assert issue.priority == nil
  end

  # ---------------------------------------------------------------------------
  # State ID resolution
  # ---------------------------------------------------------------------------

  test "resolve_state_ids_for_test maps names to IDs case-insensitively" do
    state_map = %{
      "ready for development" => 100,
      "in development" => 200,
      "completed" => 300
    }

    assert {:ok, [100, 200]} =
             Client.resolve_state_ids_for_test(["Ready for Development", "In Development"], state_map)
  end

  test "resolve_state_ids_for_test returns empty list for empty names" do
    assert {:ok, []} = Client.resolve_state_ids_for_test([], %{})
  end

  test "resolve_state_ids_for_test warns and skips unknown state names" do
    state_map = %{"in development" => 200}

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, [200]} =
                 Client.resolve_state_ids_for_test(["In Development", "Unknown State"], state_map)
      end)

    assert log =~ "Unknown State"
    assert log =~ "not found in workflow"
  end

  test "resolve_state_ids_for_test returns ok with empty list when all names unknown" do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, []} = Client.resolve_state_ids_for_test(["Nonexistent"], %{"other" => 1})
      end)

    assert log =~ "Nonexistent"
  end

  # ---------------------------------------------------------------------------
  # Workflow state map building
  # ---------------------------------------------------------------------------

  test "build_state_map_for_test builds downcased name to id map" do
    states = [
      %{"name" => "Ready for Development", "id" => 100},
      %{"name" => "In Development", "id" => 200},
      %{"name" => "Completed", "id" => 300}
    ]

    map = Client.build_state_map_for_test(states)

    assert map == %{
             "ready for development" => 100,
             "in development" => 200,
             "completed" => 300
           }
  end

  test "build_state_map_for_test handles empty states" do
    assert Client.build_state_map_for_test([]) == %{}
  end
end
