defmodule AI.Agent.FileInfo do
  @model "gpt-4o-mini"

  # It's actually 128k for this model, but "context window" != "attention span"
  @max_tokens 50_000

  @prompt """
  You are an AI agent who is responsible for answering questions about a file's
  contents. The AI search agent will request specific details about a file. Use
  your tools as appropriate to provide the most accurate and relevant answers
  to the search agent's questions.
  """

  @tools [
    AI.Tools.GitShow.spec(),
    AI.Tools.GitPickaxe.spec()
  ]

  # -----------------------------------------------------------------------------
  # Behaviour implementation
  # -----------------------------------------------------------------------------
  @behaviour AI.Agent

  @impl AI.Agent
  def get_response(ai, opts) do
    with {:ok, file} <- Map.fetch(opts, :file),
         {:ok, question} <- Map.fetch(opts, :question),
         {:ok, content} <- Map.fetch(opts, :content) do
      question = """
      File: #{file}
      Question: #{question}
      """

      AI.Accumulator.get_response(ai,
        max_tokens: @max_tokens,
        model: @model,
        tools: @tools,
        prompt: @prompt,
        input: content,
        question: question,
        on_event: &on_event/2
      )
    end
  end

  defp on_event(:tool_call, {"git_show_tool", %{"sha" => sha}}) do
    UI.report_step("[file_info] Inspecting commit", sha)
  end

  defp on_event(:tool_call, {"git_pickaxe_tool", %{"regex" => regex}}) do
    UI.report_step("[file_info] Archaeologizing", regex)
  end

  defp on_event(_, _), do: :ok
end
