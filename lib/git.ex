defmodule Git do
  @moduledoc """
  Module for interacting with git.
  """

  @common_args [
    stderr_to_stdout: true,
    parallelism: true,
    env: [
      {"GIT_TRACE", "0"},
      {"GIT_CURL_VERBOSE", "0"},
      {"GIT_DEBUG", "0"}
    ]
  ]

  def git_root() do
    Settings.new()
    |> Settings.get_root()
    |> case do
      {:ok, root} ->
        case git_cmd(["-C", root, "rev-parse", "--show-toplevel"]) do
          {:ok, root} -> {:ok, root}
          _ -> {:error, :not_a_git_repo}
        end

      {:error, :not_found} ->
        {:error, :not_a_git_repo}
    end
  end

  def is_git_repo?() do
    case git_root() do
      {:ok, _} -> true
      _ -> false
    end
  end

  def is_ignored?(file) do
    case git(["check-ignore", file]) do
      {:ok, _} -> true
      _ -> false
    end
  end

  def is_ignored?(file, git_root) do
    case git(git_root, ["check-ignore", file]) do
      {:ok, _} -> true
      _ -> false
    end
  end

  def pickaxe_regex(regex) do
    git(["log", "-G", regex])
  end

  def show(sha) do
    git(["show", sha])
  end

  def show(sha, file) do
    with {:ok, root} <- git_root() do
      # Make file relative to git root
      file = Path.relative_to(file, root)
      git(root, ["show", "#{sha}:#{file}"])
    end
  end

  def git_log(args) do
    git(["log"] ++ args)
  end

  def git_diff(args) do
    git(["diff"] ++ args)
  end

  def base_commit(topic, main) do
    git(["merge-base", main, topic])
  end

  def diff_branch(topic, main) do
    topic =
      if String.starts_with?(topic, "origin/") do
        topic
      else
        "origin/#{topic}"
      end

    main =
      if String.starts_with?(main, "origin/") do
        main
      else
        "origin/#{main}"
      end

    with {:ok, base} <- base_commit(topic, main),
         {:ok, commits} <- git_log(["--no-merges", "#{base}..#{topic}"]),
         {:ok, changes} <- git_diff(["#{base}..#{topic}"]) do
      {:ok, {commits, changes}}
    end
  end

  def list_branches() do
    git(["branch", "-a", "-r", "--list"])
  end

  # -----------------------------------------------------------------------------
  # Private functions
  # -----------------------------------------------------------------------------
  defp git(root, args) do
    git(["-C", root] ++ args)
  end

  defp git(args) do
    args
    |> git_args()
    |> git_cmd()
  end

  defp git_args(args) do
    if "-C" in args do
      args
    else
      with {:ok, root} <- git_root() do
        ["-C", root] ++ args
      else
        _ -> args
      end
    end
  end

  defp git_cmd(args) do
    case System.cmd("git", args, @common_args) do
      {output, 0} -> {:ok, String.trim_trailing(output)}
      {output, _} -> {:error, String.trim_trailing(output)}
    end
  end
end
