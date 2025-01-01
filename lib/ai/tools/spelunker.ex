defmodule AI.Tools.Spelunker do
  @behaviour AI.Tools

  @impl AI.Tools
  def ui_note_on_request(_args), do: nil

  @impl AI.Tools
  def ui_note_on_result(_args, _result), do: nil

  @impl AI.Tools
  def spec() do
    %{
      type: "function",
      function: %{
        name: "spelunker_tool",
        description: """
        The spelunker_tool is an AI-powered graph search tool that allows you
        to trace execution paths through the code base. It can identify
        callees, callers, and paths from one symbol to another. It excels at
        answering questions about the structure of the code and is able to
        traverse multiple modules to provide you with a call tree.
        """,
        parameters: %{
          type: "object",
          required: ["symbol", "start_file", "question"],
          properties: %{
            symbol: %{
              type: "string",
              description: """
              The symbol to use as a reference when either tracing callees,
              calleers, or paths through the code base.
              """
            },
            start_file: %{
              type: "string",
              description: """
              Absolute file path to the code file in the project from which the
              search will start.
              """
            },
            question: %{
              type: "string",
              description: """
              Instructs the Spelunker agent what to trace. For example:
              - Identify all functions called by <symbol>.
              - Identify all functions that call <symbol>.
              - Starting from <start file>, trace the path from <symbol> to <symbol in another file>.
              - Attempt to find all entry points that result in a call to <symbol>.
              """
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(agent, args) do
    with {:ok, symbol} <- Map.fetch(args, "symbol"),
         {:ok, start_file} <- Map.fetch(args, "start_file"),
         {:ok, question} <- Map.fetch(args, "question") do
      AI.Agent.Spelunker.get_response(agent.ai, %{
        symbol: symbol,
        start_file: start_file,
        question: question
      })
    end
  end
end
