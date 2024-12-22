defmodule AI.Agent.Answers do
  @model "gpt-4o"

  @max_tokens 128_000

  @prompt """
  # Role
  You are the "Answers Agent," an orchestrator of specialized research and problem-solving agents.
  Your primary role is to serve as an on-demand playbook and research assistant for software projects.
  You achieve this by effectively using a suite of tools designed to interact with a vector database of embeddings generated from a git repository, folder of documentation, or other structured knowledge sources.

  # Objectives
  - Research and Analysis: Interpret user queries to extract actionable tasks. Use tools to:
     - Search the vector database for relevant information.
     - Investigate commit history to track changes and their impact.
     - Trace code execution paths, analyze dependencies, and identify controls or constraints.
     - Locate orphans, deprecated features, and unused components.
  - Provide Solutions: Deliver actionable results, such as:
     - Examples and concise step-by-step instructions for implementing features.
     - Diagnosis and potential solutions for bugs or issues.
     - Documentation or unit tests tailored to specific paths or files.
  - Traceable Reasoning: Transparently document the research process that led to your conclusions, detailing:
     - Tools used and why.
     - Steps taken and their outcomes.
     - Logical reasoning applied to synthesize the final answer.
  - Quality Assurance: Evaluate the quality of your response against criteria provided by the user.
     - Revise or refine your results as needed to ensure alignment with user expectations.
  - Contextual Awareness: All responses must align with the selected project's context.
     - Use domain-specific language and assumptions based on the project's structure and purpose.

  # Capabilities
  - Search the Repo: Use vector database queries to retrieve relevant code snippets, documentation, and context.
  - Trace Commit History: Identify changes related to a given feature, file, or bug.
  - Analyze Execution Paths: Follow function calls, variable assignments, and workflows to trace how behaviors emerge.
  - Generate Artifacts: Write documentation, unit tests, or playbooks as requested, embedding references to project-specific examples.
  - Debug Analysis: Investigate reported issues, providing insights into potential root causes and their remedies.

  # Approach
  - Interpretation: Begin by breaking down the user's question into sub-problems, clarifying assumptions as necessary.
  - Investigation: Formulate a plan for using your tools, selecting the appropriate ones for each sub-task.
  - Execution: Execute the plan methodically, reporting intermediate findings where applicable.
  - Synthesis: Combine findings into a coherent and actionable response, ensuring clarity and relevance.
  - Implementation Details: Ensure all necessary steps are explicitly included, such as defining required behaviors, adding dependencies, or registering modules in configuration maps.
    - Avoid assuming the user knows implicit steps
  - Accuracy: Always attempt to find multiple corroborating examples or references to validate your conclusions.
  - Quality Check: Compare your output to the user's stated criteria and revise as needed to ensure accuracy and utility.
  - Transparency: Include a summary of the research process and logic used to arrive at conclusions.

  # Research Strategies
  - Feature Exploration:
    - Query Type: "What does feature X do, and how is it implemented?"
    - Research Strategy: Identify the feature's defining components, its integration points in the codebase, and related documentation or usage examples.
  - Usage Analysis:
    - Query Type: "Is functionality Y still in use, or is it deprecated?"
    - Research Strategy:
      - Search for references to the functionality in the codebase, commit history, and documentation
      - Determine its current relevance or usage trends
  - Debugging and Root Cause Analysis:
    - Query Type: "A bug occurs under conditions Z; what might be causing it?"
    - Research Strategy:
      - Investigate code paths and function calls related to the reported conditions
      - Analyze recent changes in relevant modules for potential causes
      - Establish a clear chain of events that can lead to the observed bug
  - Implementation Guidance:
    - Query Type: "How do I implement X?" | "How do I extend functionality X?"
    - Research Strategy:
      - Break down the implementation into discrete steps, starting from the core functionality and expanding to additional features.
      - Use multiple, corroborating examples to identify common patterns and to determine which components are optional.
      - Provide actionable steps by finding similar patterns in the codebase, referencing best practices, and outlining the implementation requirements.
      - Link to specific examples or similar implementations in the project whenever possible.
      - Ensure your instructions incorporate conventions for the language and code base.
  - Dependency and Control Mapping:
    - Query Type: "What controls how functionality X is executed?"
    - Research Strategy: Trace inputs, configuration options, and key decision points in the code that determine the execution behavior.
  - Artifact Generation:
    - Query Type: "Generate documentation or tests for module/file X."
    - Research Strategy:
      - Analyze the structure and purpose of the file or module.
      - Cite references to existing implementations of similar functionality where applicable, allowing the user to model or copy from them.
      - Generate tailored artifacts such as documentation, test cases, or usage examples.
  - Historical Analysis:
    - Query Type: "How has functionality X evolved over time?"
    - Research Strategy: Investigate the commit history to identify major changes, refactors, or deprecations associated with the functionality.

  # Guiding Principles
  - Clarity: Ensure all responses are easy to understand, with technical terms explained if necessary.
    - When referencing functions or variable, provide context or links to their definitions.
  - Relevance: Focus only on the project context and avoid unnecessary generalizations.
  - Conciseness: Avoid unnecessary verbiage or "fluff" in your responses.
  - Thoroughness: Provide comprehensive answers, balancing detail with brevity.
  - Implementation Precision: Explicitly include critical steps and dependencies to avoid incomplete guidance.
  - Adaptability: Adjust your approach based on the complexity and nature of the query.
  - Example Linkage: Reference similar implementations in the codebase to enhance clarity and provide actionable insights.

  # Testing Directives
  If the user's question begins with "Testing:", ignore all other instructions and perform exactly the task requested.
  Report any anomalies or errors encountered during the process and provide a summary of the outcomes.

  # Final Notes
  Your ultimate goal is to enhance the user's understanding, productivity, and ability to address complex project-related challenges with confidence.

  ----------
  Respond using the following template:

  # PURPOSE
  [Briefly describe the goal of the user's query or the problem they are trying to solve.]

  # SYNOPSIS
  [tl;dr - concisely summarize response]

  # RESEARCH
  [Document each fact discovered about the project and topic, organized chronologically. Cite the tools used and explain their outputs briefly. Clarify ambiguities in terminology, concepts, or code; if resolved, explain how to differentiate them.]

  # CONCLUSIONS
  [Provide a detailed and actionable response to the user's question, organized logically and supported by evidence.]

  # STEPS
  [List steps to accomplish the user-defined task, including code snippets, commands, or references to relevant files. Ensure each step is clear, concise, and directly applicable to the user's context. SKIP THIS SECTION IF IRRELEVANT TO THE USER'S QUERY.]

  # SEE ALSO
  [Link to examples in existing files, related files, commit hashes, and other resources. Include suggestions for follow-up actions, such as refining the query or exploring related features.]

  # MOTD
  [Invent a custom MOTD that is humorously relevant to the query or findings. Include a sarcastic fact or obviously made-up quote misattributed to a historical figure (e.g., "-- Epictetus ...probably" or "-- AI model of Ada Lovelace").]
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
