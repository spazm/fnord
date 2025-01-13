defmodule AI.Completion do
  @moduledoc """
  This module sends a request to the model and handles the response. It is able
  to handle tool calls and responses.
  """
  defstruct [
    :ai,
    :opts,
    :max_tokens,
    :model,
    :use_planner,
    :tools,
    :log_msgs,
    :log_tool_calls,
    :log_tool_call_results,
    :messages,
    :tool_call_requests,
    :response
  ]

  @type t :: %__MODULE__{
          ai: AI.t(),
          opts: Keyword.t(),
          max_tokens: non_neg_integer(),
          model: String.t(),
          use_planner: boolean(),
          tools: list(),
          log_msgs: boolean(),
          log_tool_calls: boolean(),
          log_tool_call_results: boolean(),
          messages: list(),
          tool_call_requests: list(),
          response: String.t() | nil
        }

  @type success :: {:ok, t}
  @type error :: {:error, String.t()}
  @type response :: success | error

  @spec get(AI.t(), Keyword.t()) :: response
  def get(ai, opts) do
    with {:ok, max_tokens} <- Keyword.fetch(opts, :max_tokens),
         {:ok, model} <- Keyword.fetch(opts, :model),
         {:ok, messages} <- Keyword.fetch(opts, :messages) do
      tools = Keyword.get(opts, :tools, nil)
      use_planner = Keyword.get(opts, :use_planner, false)
      log_msgs = Keyword.get(opts, :log_msgs, false)

      quiet? = Application.get_env(:fnord, :quiet)
      log_tool_calls = Keyword.get(opts, :log_tool_calls, !quiet?)
      log_tool_call_results = Keyword.get(opts, :log_tool_call_results, !quiet?)

      state = %__MODULE__{
        ai: ai,
        opts: Enum.into(opts, %{}),
        max_tokens: max_tokens,
        model: model,
        use_planner: use_planner,
        tools: tools,
        log_msgs: log_msgs,
        log_tool_calls: log_tool_calls,
        log_tool_call_results: log_tool_call_results,
        messages: messages,
        tool_call_requests: [],
        response: nil
      }

      state
      |> replay_conversation()
      |> maybe_start_planner()
      |> send_request()
      |> maybe_finish_planner()
      |> then(&{:ok, &1})
    end
  end

  def context_window_usage(%{model: model, messages: msgs, max_tokens: max_tokens}) do
    tokens = msgs |> inspect() |> AI.Tokenizer.encode(model) |> length()
    pct = tokens / max_tokens * 100.0
    pct_str = Number.Percentage.number_to_percentage(pct, precision: 2)
    tokens_str = Number.Delimit.number_to_delimited(tokens, precision: 0)
    max_tokens_str = Number.Delimit.number_to_delimited(max_tokens, precision: 0)
    {"Context window usage", "#{pct_str} | #{tokens_str} / #{max_tokens_str}"}
  end

  def tools_used(%{messages: messages}) do
    messages
    |> Enum.reduce(%{}, fn
      %{tool_calls: tool_calls}, acc ->
        tool_calls
        |> Enum.reduce(acc, fn
          %{function: %{name: func}}, acc ->
            Map.update(acc, func, 1, &(&1 + 1))
        end)

      _, acc ->
        acc
    end)
  end

  # -----------------------------------------------------------------------------
  # Completion handling
  # -----------------------------------------------------------------------------
  defp send_request(state) do
    state
    |> maybe_use_planner()
    |> get_completion()
    |> handle_response()
  end

  def get_completion(state) do
    response = AI.get_completion(state.ai, state.model, state.messages, state.tools)
    {response, state}
  end

  defp handle_response({{:ok, :msg, response}, state}) do
    %{
      state
      | messages: state.messages ++ [AI.Util.assistant_msg(response)],
        response: response
    }
  end

  defp handle_response({{:ok, :tool, tool_calls}, state}) do
    %{state | tool_call_requests: tool_calls}
    |> handle_tool_calls()
    |> send_request()
  end

  defp handle_response({{:error, %{http_status: http_status, code: code, message: msg}}, state}) do
    error_msg = """
    I encountered an error while processing your request.

    - HTTP Status: #{http_status}
    - Error code: #{code}
    - Message: #{msg}
    """

    %{state | response: error_msg}
  end

  defp handle_response({{:error, %{http_status: http_status, message: msg}}, state}) do
    error_msg = """
    I encountered an error while processing your request.

    - HTTP Status: #{http_status}
    - Message: #{msg}
    """

    %{state | response: error_msg}
  end

  defp handle_response({{:error, reason}, state}) do
    reason =
      if is_binary(reason) do
        reason
      else
        inspect(reason, pretty: true)
      end

    error_msg = """
    I encountered an error while processing your request.

    The error message was:

    #{reason}
    """

    %{state | response: error_msg}
  end

  # -----------------------------------------------------------------------------
  # Planner
  # -----------------------------------------------------------------------------
  defp maybe_start_planner(%{use_planner: false} = state), do: state

  defp maybe_start_planner(%{ai: ai, use_planner: true, messages: msgs, tools: tools} = state) do
    log_tool_call(state, "Building a research plan")

    case AI.Agent.Planner.get_response(ai, %{msgs: msgs, tools: tools, stage: :initial}) do
      {:ok, response} ->
        log_tool_call_result(state, "Research plan", response)
        planner_msg = AI.Util.user_msg("From the Planner Agent: #{response}")
        %__MODULE__{state | messages: state.messages ++ [planner_msg]}

      {:error, reason} ->
        log_tool_call_error(state, "planner", reason)
        state
    end
  end

  defp maybe_use_planner(%{use_planner: false} = state), do: state

  defp maybe_use_planner(%{ai: ai, use_planner: true, messages: msgs, tools: tools} = state) do
    log_tool_call(state, "Evaluating research and planning next steps")

    case AI.Agent.Planner.get_response(ai, %{msgs: msgs, tools: tools, stage: :checkin}) do
      {:ok, response} ->
        log_tool_call_result(state, "Refining research plan", response)
        planner_msg = AI.Util.user_msg("From the Planner Agent: #{response}")
        %__MODULE__{state | messages: state.messages ++ [planner_msg]}

      {:error, reason} ->
        log_tool_call_error(state, "planner", reason)
        state
    end
  end

  defp maybe_finish_planner(%{use_planner: false} = state), do: state

  defp maybe_finish_planner(%{ai: ai, use_planner: true, messages: msgs, tools: tools} = state) do
    log_tool_call(state, "Consolidating lessons learned from the research")

    case AI.Agent.Planner.get_response(ai, %{msgs: msgs, tools: tools, stage: :finish}) do
      {:ok, response} ->
        planner_msg = AI.Util.system_msg(response)
        %__MODULE__{state | messages: state.messages ++ [planner_msg]}

      {:error, reason} ->
        log_tool_call_error(state, "planner", reason)
        state
    end
  end

  # -----------------------------------------------------------------------------
  # Tool calls
  # -----------------------------------------------------------------------------
  defp handle_tool_calls(%{tool_call_requests: tool_calls} = state) do
    {:ok, queue} = Queue.start_link(&handle_tool_call(state, &1))

    outputs =
      tool_calls
      |> Queue.map(queue)
      |> Enum.flat_map(fn {:ok, msgs} -> msgs end)

    Queue.shutdown(queue)
    Queue.join(queue)

    %__MODULE__{
      state
      | tool_call_requests: [],
        messages: state.messages ++ outputs
    }
  end

  def handle_tool_call(state, %{id: id, function: %{name: func, arguments: args_json}}) do
    request = AI.Util.assistant_tool_msg(id, func, args_json)

    if state.log_tool_calls do
      UI.debug("TOOL CALL", "#{func} -> #{args_json}")
    end

    with {:ok, output} <- perform_tool_call(state, func, args_json) do
      response = AI.Util.tool_msg(id, func, output)
      {:ok, [request, response]}
    else
      :error ->
        on_event(state, :tool_call_error, {func, args_json, :error})
        msg = "An error occurred (most likely incorrect arguments)"
        response = AI.Util.tool_msg(id, func, msg)
        {:ok, [request, response]}

      {:error, reason} ->
        on_event(state, :tool_call_error, {func, args_json, {:error, reason}})
        response = AI.Util.tool_msg(id, func, reason)
        {:ok, [request, response]}

      {:error, :unknown_tool, tool} ->
        on_event(state, :tool_call_error, {func, args_json, {:error, "Unknown tool: #{tool}"}})

        error = """
        Your attempt to call #{func} failed because the tool '#{tool}' is unknown.
        Your tool call request supplied the following arguments: #{args_json}.
        Please consult the specifications for your available tools and use only the tools that are listed.
        """

        response = AI.Util.tool_msg(id, func, error)
        {:ok, [request, response]}

      {:error, :missing_argument, key} ->
        on_event(
          state,
          :tool_call_error,
          {func, args_json, {:error, "Missing required argument: #{key}"}}
        )

        spec =
          with {:ok, spec} <- AI.Tools.tool_spec(func),
               {:ok, json} <- Jason.encode(spec) do
            json
          else
            error -> "Error retrieving specification: #{inspect(error)}"
          end

        error = """
        Your attempt to call #{func} failed because it was missing a required argument, '#{key}'.
        Your tool call request supplied the following arguments: #{args_json}.
        The parameter `#{key}` must be included and cannot be `null` or an empty string.
        The correct specification for the tool call is: #{spec}
        """

        response = AI.Util.tool_msg(id, func, error)
        {:ok, [request, response]}
    end
  end

  defp perform_tool_call(state, func, args_json) when is_binary(args_json) do
    with {:ok, args} <- Jason.decode(args_json) do
      AI.Tools.with_args(func, args, fn args ->
        on_event(state, :tool_call, {func, args})

        result =
          AI.Tools.perform_tool_call(state, func, args)
          |> case do
            {:ok, response} when is_binary(response) -> {:ok, response}
            {:ok, response} -> Jason.encode(response)
            :ok -> {:ok, "#{func} completed successfully"}
            other -> other
          end

        on_event(state, :tool_call_result, {func, args, result})
        result
      end)
    end
  end

  # -----------------------------------------------------------------------------
  # Tool call UI integration
  # -----------------------------------------------------------------------------
  defp log_user_msg(state, msg) do
    if state.log_msgs do
      UI.info("You", msg)
    end
  end

  defp log_assistant_msg(state, msg) do
    if state.log_msgs do
      UI.info("Assistant", msg)
    end
  end

  defp log_tool_call(state, step) do
    if state.log_tool_calls do
      UI.info(step)
    end
  end

  defp log_tool_call(state, step, msg) do
    if state.log_tool_calls do
      UI.info(step, msg)
    end
  end

  defp log_tool_call_result(state, step) do
    if state.log_tool_call_results do
      UI.debug(step)
    end
  end

  defp log_tool_call_result(state, step, msg) do
    if state.log_tool_call_results do
      UI.debug(step, msg)
    end
  end

  defp log_tool_call_error(_state, tool, reason) do
    UI.error("Error calling #{tool}", reason)
  end

  # -----------------------------------------------------------------------------
  # Tool call logging
  # -----------------------------------------------------------------------------
  defp on_event(state, :tool_call, {tool, args}) do
    AI.Tools.with_args(tool, args, fn args ->
      AI.Tools.on_tool_request(tool, args)
      |> case do
        nil -> state
        {step, msg} -> log_tool_call(state, step, msg)
        step -> log_tool_call(state, step)
      end
    end)
  end

  defp on_event(state, :tool_call_result, {tool, args, {:ok, result}}) do
    AI.Tools.with_args(tool, args, fn args ->
      AI.Tools.on_tool_result(tool, args, result)
      |> case do
        nil -> state
        {step, msg} -> log_tool_call_result(state, step, msg)
        step -> log_tool_call_result(state, step)
      end
    end)
  end

  defp on_event(state, :tool_call_error, {tool, _args_json, {:error, reason}}) do
    log_tool_call_error(state, tool, reason)
  end

  defp on_event(_state, _, _), do: :ok

  # ----------------------------------------------------------------------------
  # Continuing a conversation
  # ----------------------------------------------------------------------------
  defp replay_conversation(state) do
    messages = Util.string_keys_to_atoms(state.messages)

    # Make a lookup for tool call args by id
    tool_call_args =
      messages
      |> Enum.reduce(%{}, fn msg, acc ->
        case msg do
          %{role: "assistant", content: nil, tool_calls: tool_calls} ->
            tool_calls
            |> Enum.map(fn %{id: id, function: %{arguments: args}} -> {id, args} end)
            |> Enum.into(acc)

          _ ->
            acc
        end
      end)

    messages
    # Skip the first message, which is the system prompt for the agent
    |> Enum.drop(1)
    |> Enum.each(fn
      %{role: "assistant", content: nil, tool_calls: tool_calls} ->
        tool_calls
        |> Enum.each(fn %{function: %{name: func, arguments: args_json}} ->
          with {:ok, args} <- Jason.decode(args_json) do
            on_event(state, :tool_call, {func, args})
          end
        end)

      %{role: "tool", name: func, tool_call_id: id, content: content} ->
        on_event(state, :tool_call_result, {func, tool_call_args[id], content})

      %{role: "system", content: content} ->
        on_event(state, :tool_call_result, {"planner", %{}, content})

      %{role: "assistant", content: content} ->
        log_assistant_msg(state, content)

      %{role: "user", content: content} ->
        log_user_msg(state, content)
    end)

    state
  end
end
