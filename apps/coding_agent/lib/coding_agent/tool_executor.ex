defmodule CodingAgent.ToolExecutor do
  @moduledoc """
  Tool execution wrapper that integrates approval gating.

  This module provides a way to wrap tool execution with approval checks
  based on the ToolPolicy. When a tool requires approval, execution is
  paused until approval is granted or denied.

  ## Usage

      # Wrap a tool with approval enforcement
      wrapped_tool = ToolExecutor.wrap_with_approval(tool, policy, context)

      # Or wrap all tools in a list
      wrapped_tools = ToolExecutor.wrap_all_with_approval(tools, policy, context)

  ## Context

  The context map should include:
  - `:run_id` - The current run ID
  - `:session_key` - The session key for routing
  - `:timeout_ms` - Approval timeout in milliseconds (optional; default: no timeout)
  """

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias Ai.Types.TextContent
  alias CodingAgent.ToolPolicy

  require Logger

  # Tool calls should not enforce approval timeouts by default.
  @default_timeout_ms :infinity

  @doc """
  Wrap a single tool with approval checks.

  If the tool doesn't require approval according to the policy, it is
  returned unchanged.
  """
  @spec wrap_with_approval(AgentTool.t(), ToolPolicy.policy(), map()) :: AgentTool.t()
  def wrap_with_approval(%AgentTool{} = tool, policy, context) do
    if ToolPolicy.requires_approval?(policy, tool.name) do
      # Embed the policy in context so path-bypass checks can run at execution time.
      wrap_tool(tool, Map.put(context, :tool_policy, policy))
    else
      tool
    end
  end

  @doc """
  Wrap all tools in a list with approval checks based on the policy.
  """
  @spec wrap_all_with_approval([AgentTool.t()], ToolPolicy.policy(), map()) :: [AgentTool.t()]
  def wrap_all_with_approval(tools, policy, context) do
    Enum.map(tools, fn tool ->
      wrap_with_approval(tool, policy, context)
    end)
  end

  @doc """
  Execute a tool with approval check.

  This function checks if approval is required and blocks until
  approval is granted, denied, or times out.

  Path-based bypasses are evaluated here, at execution time, when the
  actual args (and thus the target path) are known:
  - If `context[:tool_policy]` has `workspace_write: true` and the path
    argument falls within the workspace directory, approval is skipped.
  - If `context[:tool_policy]` has `per_tool_paths` entries for this tool
    and the path argument matches one of them, approval is skipped.

  Returns:
  - The tool result on success
  - An error result if approval is denied or times out
  """
  @spec execute_with_approval(
          tool_name :: String.t(),
          args :: map(),
          execute_fn :: function(),
          context :: map()
        ) :: AgentToolResult.t() | {:error, term()}
  def execute_with_approval(tool_name, args, execute_fn, context) do
    run_id = context[:run_id]
    session_key = context[:session_key]
    timeout_ms = context[:timeout_ms] || @default_timeout_ms
    approval_request_fun = context[:approval_request_fun] || (&LemonCore.ExecApprovals.request/1)
    tool_policy = context[:tool_policy]

    if path_bypass?(tool_name, args, tool_policy) do
      Logger.debug("Tool #{tool_name} approved via path policy bypass")
      execute_fn.()
    else
      case request_approval(
             run_id,
             session_key,
             tool_name,
             args,
             timeout_ms,
             approval_request_fun
           ) do
        {:ok, :approved, scope} ->
          Logger.debug("Tool #{tool_name} approved at scope: #{scope}")
          execute_fn.()

        {:ok, :denied} ->
          Logger.info("Tool #{tool_name} denied by approval")
          denied_result(tool_name)

        {:error, :timeout} ->
          Logger.warning("Tool #{tool_name} approval timed out")
          timeout_result(tool_name, timeout_ms)

        {:error, reason} ->
          Logger.warning("Tool #{tool_name} approval failed: #{inspect(reason)}")
          approval_error_result(tool_name, reason)

        other ->
          Logger.warning("Tool #{tool_name} approval returned unexpected value: #{inspect(other)}")
          approval_error_result(tool_name, {:unexpected_result, other})
      end
    end
  end

  # Private helpers

  # Returns true if the tool's path argument satisfies a workspace_write or
  # per_tool_paths bypass, meaning approval can be skipped entirely.
  defp path_bypass?(_tool_name, _args, nil), do: false

  defp path_bypass?(tool_name, args, tool_policy) do
    path = extract_path(args)

    workspace_bypass?(path, tool_policy) or
      per_tool_paths_bypass?(tool_name, path, tool_policy)
  end

  # Extracts a file path from the tool args map. Claude tool conventions use
  # "path", "file_path", or "command" (for bash). We only check the first two
  # since bash command strings are not file paths.
  defp extract_path(args) when is_map(args) do
    Map.get(args, "path") || Map.get(args, :path) ||
      Map.get(args, "file_path") || Map.get(args, :file_path)
  end

  defp extract_path(_), do: nil

  defp workspace_bypass?(nil, _tool_policy), do: false

  defp workspace_bypass?(path, tool_policy) do
    case Map.get(tool_policy, :workspace_write) do
      true ->
        workspace_dir = resolve_workspace_dir()
        path_within?(path, workspace_dir)

      _ ->
        false
    end
  end

  defp per_tool_paths_bypass?(_tool_name, nil, _tool_policy), do: false

  defp per_tool_paths_bypass?(tool_name, path, tool_policy) do
    per_tool_paths = Map.get(tool_policy, :per_tool_paths, %{})
    allowed = Map.get(per_tool_paths, tool_name, [])

    Enum.any?(allowed, fn pattern -> path_within?(path, pattern) end)
  end

  defp path_within?(path, prefix) when is_binary(path) and is_binary(prefix) do
    expanded_path = Path.expand(path)
    expanded_prefix = Path.expand(prefix)
    # Ensure prefix ends with separator so "/foo/bar" doesn't match "/foo/baz"
    normalized_prefix =
      if String.ends_with?(expanded_prefix, "/"),
        do: expanded_prefix,
        else: expanded_prefix <> "/"

    String.starts_with?(expanded_path <> "/", normalized_prefix)
  end

  defp path_within?(_, _), do: false

  defp resolve_workspace_dir do
    base =
      System.get_env("LEMON_DOTENV_DIR") ||
        Path.join(System.get_env("HOME") || Path.expand("~"), ".lemon")

    Path.join(base, "agent/workspace")
  end

  defp wrap_tool(%AgentTool{} = tool, context) do
    original_execute = tool.execute

    wrapped_execute = fn tool_call_id, params, signal, on_update ->
      execute_with_approval(
        tool.name,
        params,
        fn -> original_execute.(tool_call_id, params, signal, on_update) end,
        context
      )
    end

    %{tool | execute: wrapped_execute}
  end

  defp request_approval(run_id, session_key, tool_name, args, timeout_ms, request_fun) do
    request_fun.(%{
      run_id: run_id,
      session_key: session_key,
      tool: tool_name,
      action: args,
      rationale: "Tool execution: #{tool_name}",
      expires_in_ms: timeout_ms
    })
  rescue
    _ ->
      # If approvals are unavailable, auto-approve (matches previous behavior).
      Logger.debug("ExecApprovals unavailable, auto-approving #{tool_name}")
      {:ok, :approved, :auto}
  end

  defp denied_result(tool_name) do
    %AgentToolResult{
      content: [
        %TextContent{
          type: :text,
          text:
            "Tool '#{tool_name}' execution was denied. The operation requires approval that was not granted."
        }
      ],
      details: %{
        denied: true,
        reason: :approval_denied
      }
    }
  end

  defp timeout_result(tool_name, timeout_ms) do
    timeout_seconds = div(timeout_ms, 1000)

    %AgentToolResult{
      content: [
        %TextContent{
          type: :text,
          text:
            "Tool '#{tool_name}' execution timed out waiting for approval (#{timeout_seconds}s). " <>
              "Please request approval and try again."
        }
      ],
      details: %{
        timeout: true,
        timeout_ms: timeout_ms,
        reason: :approval_timeout
      }
    }
  end

  defp approval_error_result(tool_name, reason) do
    %AgentToolResult{
      content: [
        %TextContent{
          type: :text,
          text:
            "Tool '#{tool_name}' could not run because approval failed: #{inspect(reason)}. " <>
              "Please retry or approve manually."
        }
      ],
      details: %{
        approval_error: reason,
        reason: :approval_error
      }
    }
  end
end
