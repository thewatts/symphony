defmodule SymphonyElixir.Claude.DynamicToolTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Claude.DynamicTool

  # ---------------------------------------------------------------------------
  # tool_specs
  # ---------------------------------------------------------------------------

  test "tool_specs advertises the shortcut_api input contract" do
    assert [
             %{
               "name" => "shortcut_api",
               "description" => description,
               "input_schema" => %{
                 "type" => "object",
                 "required" => ["method", "path"],
                 "properties" => %{
                   "method" => %{"type" => "string", "enum" => methods},
                   "path" => %{"type" => "string"},
                   "body" => %{"type" => "object"}
                 }
               }
             }
           ] = DynamicTool.tool_specs()

    assert description =~ "Shortcut"
    assert "GET" in methods
    assert "POST" in methods
    assert "PUT" in methods
    assert "DELETE" in methods
  end

  # ---------------------------------------------------------------------------
  # Unsupported tool
  # ---------------------------------------------------------------------------

  test "unsupported tools return a failure payload with the supported tool list" do
    result = DynamicTool.execute("not_a_real_tool", %{})

    assert result["success"] == false
    body = Jason.decode!(result["output"])
    assert body["error"]["message"] =~ "not_a_real_tool"
    assert body["error"]["supportedTools"] == ["shortcut_api"]
  end

  # ---------------------------------------------------------------------------
  # Argument validation
  # ---------------------------------------------------------------------------

  test "shortcut_api requires method and path" do
    no_method = DynamicTool.execute("shortcut_api", %{"path" => "/stories/1"})
    assert no_method["success"] == false
    assert Jason.decode!(no_method["output"])["error"]["message"] =~ "method"

    no_path = DynamicTool.execute("shortcut_api", %{"method" => "GET"})
    assert no_path["success"] == false
    assert Jason.decode!(no_path["output"])["error"]["message"] =~ "path"
  end

  test "shortcut_api rejects invalid methods" do
    result = DynamicTool.execute("shortcut_api", %{"method" => "PATCH", "path" => "/stories/1"})
    assert result["success"] == false
    assert Jason.decode!(result["output"])["error"]["message"] =~ "PATCH"
  end

  test "shortcut_api rejects blank path" do
    result = DynamicTool.execute("shortcut_api", %{"method" => "GET", "path" => "  "})
    assert result["success"] == false
    assert Jason.decode!(result["output"])["error"]["message"] =~ "path"
  end

  test "shortcut_api rejects invalid body type" do
    result =
      DynamicTool.execute("shortcut_api", %{
        "method" => "POST",
        "path" => "/stories",
        "body" => ["not", "a", "map"]
      })

    assert result["success"] == false
    assert Jason.decode!(result["output"])["error"]["message"] =~ "body"
  end

  test "shortcut_api rejects invalid argument types" do
    result = DynamicTool.execute("shortcut_api", "not a map")
    assert result["success"] == false
    assert Jason.decode!(result["output"])["error"]["message"] =~ "object"
  end

  # ---------------------------------------------------------------------------
  # Successful requests
  # ---------------------------------------------------------------------------

  test "shortcut_api passes method, path, and body to the client" do
    test_pid = self()

    result =
      DynamicTool.execute(
        "shortcut_api",
        %{"method" => "GET", "path" => "/stories/12345"},
        shortcut_client: fn method, path, body ->
          send(test_pid, {:called, method, path, body})
          {:ok, %{status: 200, body: %{"id" => 12345, "name" => "Fix bug"}}}
        end
      )

    assert result["success"] == true
    assert_received {:called, "GET", "/stories/12345", %{}}
    body = Jason.decode!(result["output"])
    assert body["id"] == 12345
  end

  test "shortcut_api forwards request body for POST" do
    test_pid = self()

    DynamicTool.execute(
      "shortcut_api",
      %{
        "method" => "POST",
        "path" => "/stories/1/comments",
        "body" => %{"text" => "looks good"}
      },
      shortcut_client: fn method, path, body ->
        send(test_pid, {:called, method, path, body})
        {:ok, %{status: 201, body: %{"id" => 99}}}
      end
    )

    assert_received {:called, "POST", "/stories/1/comments", %{"text" => "looks good"}}
  end

  test "shortcut_api defaults body to empty map when omitted" do
    test_pid = self()

    DynamicTool.execute(
      "shortcut_api",
      %{"method" => "GET", "path" => "/member"},
      shortcut_client: fn _method, _path, body ->
        send(test_pid, {:body, body})
        {:ok, %{status: 200, body: %{}}}
      end
    )

    assert_received {:body, %{}}
  end

  test "shortcut_api marks non-2xx HTTP responses as failures" do
    result =
      DynamicTool.execute(
        "shortcut_api",
        %{"method" => "GET", "path" => "/stories/999"},
        shortcut_client: fn _method, _path, _body ->
          {:ok, %{status: 404, body: %{"message" => "Story not found"}}}
        end
      )

    assert result["success"] == false
    body = Jason.decode!(result["output"])
    assert body["error"] =~ "404"
  end

  # ---------------------------------------------------------------------------
  # Error handling
  # ---------------------------------------------------------------------------

  test "shortcut_api formats missing token error" do
    result =
      DynamicTool.execute(
        "shortcut_api",
        %{"method" => "GET", "path" => "/member"},
        shortcut_client: fn _method, _path, _body ->
          {:error, :missing_shortcut_api_token}
        end
      )

    assert result["success"] == false
    assert Jason.decode!(result["output"])["error"]["message"] =~ "SHORTCUT_API_TOKEN"
  end

  test "shortcut_api formats HTTP status errors" do
    result =
      DynamicTool.execute(
        "shortcut_api",
        %{"method" => "GET", "path" => "/member"},
        shortcut_client: fn _method, _path, _body ->
          {:error, {:shortcut_api_status, 503}}
        end
      )

    assert result["success"] == false
    body = Jason.decode!(result["output"])
    assert body["error"]["message"] =~ "503"
    assert body["error"]["status"] == 503
  end

  test "shortcut_api formats transport errors" do
    result =
      DynamicTool.execute(
        "shortcut_api",
        %{"method" => "GET", "path" => "/member"},
        shortcut_client: fn _method, _path, _body ->
          {:error, {:shortcut_api_request, :timeout}}
        end
      )

    assert result["success"] == false
    body = Jason.decode!(result["output"])
    assert body["error"]["message"] =~ "failed"
    assert body["error"]["reason"] =~ "timeout"
  end

  test "shortcut_api formats unexpected errors" do
    result =
      DynamicTool.execute(
        "shortcut_api",
        %{"method" => "GET", "path" => "/member"},
        shortcut_client: fn _method, _path, _body -> {:error, :boom} end
      )

    assert result["success"] == false
    body = Jason.decode!(result["output"])
    assert body["error"]["message"] =~ "failed"
    assert body["error"]["reason"] =~ "boom"
  end
end
