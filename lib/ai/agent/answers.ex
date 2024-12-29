defmodule AI.Agent.Answers do
  @model "gpt-4o"

  @max_tokens 128_000

  @prompt """
  You are the "Answers Agent," an orchestrator of specialized research and problem-solving agents.
  Your primary role is to research topics, write code, or write documentation for the user within the selected project.
  You achieve this by using a suite of tools designed to interact with a vector database of embeddings generated from a git repository, folder of documentation, or other structured knowledge sources on the user's machine.
  Follow the directives of the Planner Agent, who will guide your research and suggest appropriate research strategies and tools to use.
  Once your research is complete, you provide the user with a detailed and actionable response to their query.
  Include links to documentation, implementation examples that exist within the code base, and example code as appropriate.
  ALWAYS include code examples when asked to generate code or how to implement an artifact.

  # Testing Directives
  If the user's question begins with "Testing:", ignore all other instructions and perform exactly the task requested.
  Report any anomalies or errors encountered during the process and provide a summary of the outcomes.

  # Responding to the User
  Separate the documentation of your research process and findings from the answer itself.
  Ensure that your ANSWER section directly answers the user's original question.
  Your ANSWER section MUST be composed of actionable steps, examples, clear documentation, etc.

  ----------
  Respond using the following template:

  # [Restate the user's *original* query as the document title, correcting grammar and spelling]

  ## SYNOPSIS
  [List the components of the user's query, as restated by the Planner Agent]

  ## RESEARCH
  [Document each fact discovered about the project and topic, organized chronologically. Cite the tools used and explain their outputs briefly. Clarify ambiguities in terminology, concepts, or code; if resolved, explain how to differentiate them.]

  ### UNKNOWNS
  [List any unresolved questions or dangling threads that may require further investigation on the part of the user; suggest files or other entry points for research.]

  ### CONCLUSIONS
  [Provide a detailed and actionable response to the user's question, organized logically and supported by evidence.]

  ## ANSWER
  [Answer the user's original query; do not include research instructions in this section. Provide code examples, documentation, numbered steps, or other artifacts as necessary.]

  ## SEE ALSO
  [Link to examples in existing files, related files, commit hashes, and other resources. Include suggestions for follow-up actions, such as refining the query or exploring related features.]

  ## MOTD
  [Invent a custom MOTD that is **FUNNY** and relevant to the query or findings, such as a sarcastic fact or obviously made-up quote misattributed to a historical, mythological, or pop culture figure (e.g., "-Rick Sanchez, speaking at ElixirConf" | "-AI model of Ada Lovelace" | "-Abraham Lincoln, live on Tic Tok at Gettysburg").]
  """

  @non_git_tools [
    AI.Tools.Search.spec(),
    AI.Tools.ListFiles.spec(),
    AI.Tools.FileInfo.spec(),
    AI.Tools.Spelunker.spec(),
    AI.Tools.FileContents.spec()
  ]

  @git_tools [
    AI.Tools.GitLog.spec(),
    AI.Tools.GitShow.spec(),
    AI.Tools.GitPickaxe.spec(),
    AI.Tools.GitDiffBranch.spec()
  ]

  @tools @non_git_tools ++ @git_tools

  # -----------------------------------------------------------------------------
  # Behaviour implementation
  # -----------------------------------------------------------------------------
  @behaviour AI.Agent

  @impl AI.Agent
  def get_response(ai, opts) do
    with includes = opts |> Map.get(:include, []) |> get_included_files(),
         {:ok, response} <- build_response(ai, includes, opts),
         {:ok, msg} <- Map.fetch(response, :response),
         {label, usage} <- AI.Completion.context_window_usage(response) do
      UI.report_step(label, usage)
      UI.flush()

      IO.puts(msg)

      save_conversation(response, opts)
      UI.flush()

      {:ok, msg}
    else
      error ->
        UI.error("An error occurred", "#{inspect(error)}")
    end
  end

  # -----------------------------------------------------------------------------
  # Private functions
  # -----------------------------------------------------------------------------
  defp save_conversation(%AI.Completion{messages: messages}, %{conversation: conversation}) do
    Store.Conversation.write(conversation, __MODULE__, messages)
    UI.debug("Conversation saved to file", conversation.store_path)
    UI.report_step("Conversation saved", conversation.id)
  end

  defp get_included_files(files) do
    preamble = "The user has included the following file for context"

    files
    |> Enum.reduce_while([], fn file, acc ->
      file
      |> Path.expand()
      |> File.read()
      |> case do
        {:error, reason} -> {:halt, {:error, reason}}
        {:ok, content} -> {:cont, ["#{preamble}: #{file}\n```\n#{content}\n```" | acc]}
      end
    end)
    |> Enum.join("\n\n")
  end

  defp build_response(ai, includes, opts) do
    tools =
      if Git.is_git_repo?() do
        @tools
      else
        @non_git_tools
      end

    use_planner =
      opts.question
      |> String.downcase()
      |> String.starts_with?("testing:")
      |> then(fn x -> !x end)

    AI.Completion.get(ai,
      max_tokens: @max_tokens,
      model: @model,
      tools: tools,
      messages: build_messages(opts, includes),
      use_planner: use_planner,
      log_msgs: true
    )
  end

  defp build_messages(%{conversation: conversation} = opts, includes) do
    user_msg = user_prompt(opts.question, includes)

    if Store.Conversation.exists?(conversation) do
      with {:ok, _timestamp, %{"messages" => messages}} <- Store.Conversation.read(conversation) do
        # Conversations are stored as JSON and parsed into a map with string
        # keys, so we need to convert the keys to atoms.
        messages =
          messages
          |> Enum.map(fn msg ->
            Map.new(msg, fn {k, v} ->
              {String.to_atom(k), v}
            end)
          end)

        messages ++ [user_msg]
      else
        error ->
          raise error
      end
    else
      [AI.Util.system_msg(@prompt), user_msg]
    end
  end

  defp user_prompt(question, includes) do
    if includes == "" do
      question
    else
      "#{question}\n#{includes}"
    end
    |> AI.Util.user_msg()
  end
end
