defmodule Ask do
  defstruct [
    :opts,
    :ai,
    :settings,
    :assistant_id,
    :thread_id,
    :run_id,
    :status_msgs,
    :assistant_searches,
    :files_found,
    :response
  ]

  @last_thread_id_setting "last_thread_id"

  def new(opts) do
    %Ask{
      opts: opts,
      ai: AI.new(),
      settings: Settings.new(),
      status_msgs: [],
      assistant_searches: [],
      files_found: []
    }
  end

  def run(opts) do
    with ask <- new(opts),
         {:ok, ask} <- with_assistant_id(ask),
         {:ok, ask} <- with_thread_id(ask),
         {:ok, ask} <- send_prompt(ask),
         {:ok, ask} <- with_run_id(ask),
         {:ok, ask} <- get_response(ask) do
      render(ask)
    end
  end

  defp info(ask, msg) do
    statuses =
      case ask.status_msgs do
        [^msg | _] ->
          ask.status_msgs

        _ ->
          if ask.opts[:verbose] do
            IO.puts(:stderr, "[fnord] " <> msg)
          end

          [msg | ask.status_msgs]
      end

    %Ask{ask | status_msgs: statuses}
  end

  defp render(ask) do
    searches =
      ask.assistant_searches
      |> Enum.reverse()
      |> Enum.map(fn query -> "- `#{query}`" end)
      |> Enum.join("\n")

    files =
      ask.files_found
      |> Enum.uniq()
      |> Enum.reverse()
      |> Enum.map(fn file -> "- `#{file}`" end)
      |> Enum.join("\n")

    IO.puts("""
    # Searched
    #{searches}

    # Matches
    #{files}

    # Response
    #{ask.response}
    """)
  end

  defp send_prompt(ask) do
    with {:ok, prompt} <- get_prompt(ask),
         {:ok, _} <- AI.add_user_message(ask.ai, ask.thread_id, prompt) do
      {:ok, ask}
    end
  end

  defp get_response(ask) do
    with {ask, {:ok, :done}} <- run_thread(ask),
         {:ok, msgs} <- AI.get_messages(ask.ai, ask.thread_id) do
      msgs
      |> Map.get("data", [])
      |> Enum.filter(fn %{"role" => role} -> role == "assistant" end)
      |> Enum.map(fn %{"content" => [%{"text" => %{"value" => msg}}]} -> msg end)
      |> Enum.join("\n\n")
      |> then(fn msg -> {:ok, %Ask{ask | response: msg}} end)
    end
  end

  defp get_prompt(%Ask{opts: %{question: question}}), do: {:ok, question}

  defp run_thread(ask) do
    case AI.get_run_status(ask.ai, ask.thread_id, ask.run_id) do
      {:ok, %{"status" => "queued"}} ->
        ask
        |> info("Assistant is working")
        |> run_thread()

      {:ok, %{"status" => "in_progress"}} ->
        ask
        |> info("Assistant is working")
        |> run_thread()

      # Requires action; most likely a tool call request
      {:ok, %{"status" => "requires_action"} = status} ->
        {ask, outputs} =
          ask
          |> info("Searching project")
          |> get_tool_outputs(status)

        case AI.submit_tool_outputs(ask.ai, ask.thread_id, ask.run_id, outputs) do
          {:ok, _} -> run_thread(ask)
          {:error, reason} -> {ask, {:error, reason}}
        end

      {:ok, %{"status" => "completed"}} ->
        {ask, {:ok, :done}}

      {:ok, status} ->
        ask
        |> info("error! API run status: #{inspect(status)}")
        |> then(fn _ -> {ask, {:error, :failed}} end)

      {:error, reason} ->
        ask
        |> info("error! API response: #{inspect(reason)}")
        |> then(fn _ -> {ask, {:error, reason}} end)
    end
  end

  defp get_tool_outputs(ask, run_status) do
    run_status
    |> Map.get("required_action", %{})
    |> Map.get("submit_tool_outputs", %{})
    |> Map.get("tool_calls", [])
    |> Enum.reduce({ask, []}, fn tool_call, {ask, acc} ->
      {ask, output} = get_tool_call_output(ask, tool_call)
      {ask, [output | acc]}
    end)
    |> then(fn {ask, outputs} ->
      outputs =
        outputs
        |> Enum.reverse()
        |> Enum.reject(&is_nil/1)

      {ask, outputs}
    end)
  end

  defp get_tool_call_output(
         ask,
         %{
           "id" => id,
           "function" => %{
             "name" => "search_tool",
             "arguments" => json_args_string
           }
         }
       ) do
    %{"query" => query} = Jason.decode!(json_args_string)

    ask =
      %Ask{ask | assistant_searches: [query | ask.assistant_searches]}
      |> info("  - #{query}")

    search_query =
      ask.opts
      |> Map.put(:detail, true)
      |> Map.put(:limit, 10)
      |> Map.put(:query, query)

    {ask, search_results} =
      search_query
      |> Search.new()
      |> Search.get_results()
      |> Enum.reduce({ask, []}, fn {file, score, data}, {ask, acc} ->
        ask = info(ask, "    - <#{Float.round(score, 5)}> #{file}")
        ask = %Ask{ask | files_found: [file | ask.files_found]}
        {ask, [{file, score, data} | acc]}
      end)

    {:ok, results} =
      search_results
      |> Enum.map(fn {file, score, data} ->
        """
        -----
        # File: #{file} | Score: #{score}
        #{data["summary"]}
        """
      end)
      |> Enum.join("\n")
      |> then(fn res -> {:ok, res} end)

    {ask, %{tool_call_id: id, output: results}}
  end

  defp get_tool_call_output(_ask, _status), do: nil

  defp with_run_id(ask) do
    case AI.run_thread(ask.ai, ask.assistant_id, ask.thread_id) do
      {:ok, %{"id" => run_id}} -> {:ok, %Ask{ask | run_id: run_id}}
      _ -> {:error, :run_thread_failed}
    end
  end

  defp with_assistant_id(ask) do
    with {:ok, assistant} <- Assistant.get(ask.ai, ask.settings) do
      {:ok, %Ask{ask | assistant_id: assistant["id"]}}
    end
  end

  defp with_thread_id(ask) do
    with true <- continue_last_thread?(ask),
         {:ok, ask} <- with_last_thread_id(ask) do
      {:ok, ask}
    else
      _ -> with_new_thread_id(ask)
    end
  end

  defp continue_last_thread?(%{opts: %{continue: true}}), do: true
  defp continue_last_thread?(_), do: false

  defp with_last_thread_id(ask) do
    case Settings.get(ask.settings, @last_thread_id_setting, nil) do
      nil -> {:error, :no_thread_id}
      thread_id -> {:ok, %Ask{ask | thread_id: thread_id}}
    end
  end

  defp with_new_thread_id(ask) do
    with {:ok, %{"id" => thread_id}} <- AI.start_thread(ask.ai) do
      Settings.set(ask.settings, @last_thread_id_setting, thread_id)
      {:ok, %Ask{ask | thread_id: thread_id}}
    end
  end
end
