defmodule Index do
  defstruct [
    :store,
    :ai
  ]

  def run(root, project, force_reindex) do
    idx = %Index{
      store: Store.new(project),
      ai: AI.new()
    }

    if force_reindex do
      # When --force-reindex is passed, delete the project completely and start
      # from scratch.
      IO.puts("Deleting all embeddings to force full reindexing of #{project}")
      Store.delete_project(idx.store)
    else
      # Otherwise, just delete any files that no longer exist.
      IO.puts("Deleting missing files from #{project}")
      Store.delete_missing_files(idx.store, root)
    end

    Queue.start_link(4, fn file ->
      IO.write(".")
      process_file(idx, file)
      IO.write(".")
    end)

    scanner = Scanner.new(root, fn file -> Queue.queue(file) end)

    IO.puts("Indexing files in #{root}")

    Scanner.scan(scanner)
    |> case do
      {:error, reason} -> IO.puts("Error: #{reason}")
      _ -> :ok
    end

    Queue.shutdown()
    Queue.join()

    IO.puts("done!")
  end

  def delete_project(project) do
    store = Store.new(project)
    Store.delete_project(store)
  end

  defp process_file(idx, file) do
    existing_hash = Store.get_hash(idx.store, file)
    file_hash = sha256(file)

    if is_nil(existing_hash) or existing_hash != file_hash do
      file_contents = File.read!(file)

      with {:ok, summary} <- get_summary(idx, file, file_contents),
           {:ok, embeddings} <- get_embeddings(idx, file, summary, file_contents) do
        Store.put(idx.store, file, file_hash, summary, embeddings)
      else
        {:error, reason} -> IO.puts("Error processing file: #{file} - #{reason}")
      end
    end
  end

  defp get_summary(idx, file, file_contents, attempt \\ 0) do
    AI.get_summary(idx.ai, file, file_contents)
    |> case do
      {:ok, summary} ->
        {:ok, summary}

      {:error, %OpenaiEx.Error{message: "Request timed out."}} ->
        if attempt < 3 do
          IO.puts("request to summarize file timed out, retrying (attempt #{attempt + 1}/3)")
          get_summary(idx, file, file_contents, attempt + 1)
        else
          {:error, "request to summarize file timed out after 3 attempts"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_embeddings(idx, file, summary, file_contents, attempt \\ 0) do
    to_embed = """
      # File
      `#{file}`

      ## Summary
      #{summary}

      ## Contents
      ```
      #{file_contents}
      ```
    """

    AI.get_embeddings(idx.ai, to_embed)
    |> case do
      {:ok, embeddings} ->
        {:ok, embeddings}

      {:error, %OpenaiEx.Error{message: "Request timed out."}} ->
        if attempt < 3 do
          IO.puts("request to index file timed out, retrying (attempt #{attempt + 1}/3)")
          get_embeddings(idx, file, summary, file_contents, attempt + 1)
        else
          {:error, "request to index file timed out after 3 attempts"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp sha256(file_path) do
    case File.read(file_path) do
      {:ok, content} -> :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
      {:error, reason} -> {:error, reason}
    end
  end
end
