defmodule Search do
  defstruct [
    :project,
    :query,
    :limit,
    :detail,
    :store
  ]

  def run(opts) do
    %{
      project: project,
      query: query,
      limit: limit,
      detail: detail
    } = opts

    search = %Search{
      project: project,
      query: query,
      limit: limit,
      detail: detail,
      store: Store.new(project)
    }

    needle = get_query_embeddings(query)

    search
    |> list_files()
    |> Enum.map(fn file ->
      with {:ok, data} <- get_file_data(search, file) do
        get_score(needle, data)
        |> case do
          {:ok, score} -> {file, score, data}
          {:error, :no_embeddings} -> nil
        end
      else
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort(fn {_, score1, _}, {_, score2, _} -> score1 >= score2 end)
    |> Enum.take(limit)
    |> Enum.each(fn {file, score, data} -> output_file(search, file, score, data) end)
  end

  defp output_file(search, file, score, data) do
    if search.detail do
      summary = Map.get(data, "summary")

      IO.puts("""
      -----
      # File: #{file} | Score: #{score}
      #{summary}
      """)
    else
      IO.puts(file)
    end
  end

  defp get_score(needle, data) do
    data
    |> Map.get("embeddings", [])
    |> Enum.map(fn emb -> Store.cosine_similarity(needle, emb) end)
    |> case do
      [] -> {:error, :no_embeddings}
      scores -> {:ok, Enum.max(scores)}
    end
  end

  defp get_query_embeddings(query) do
    {:ok, [needle]} = AI.get_embeddings(AI.new(), query)
    needle
  end

  defp list_files(search) do
    Store.list_files(search.store)
  end

  defp get_file_data(search, file) do
    if search.detail do
      Store.get(search.store, file)
    else
      with {:ok, embeddings} <- Store.get_embeddings(search.store, file) do
        {:ok, %{embeddings: embeddings}}
      else
        {:error, _} -> {:error, :file}
      end
    end
  end
end
