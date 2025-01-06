defmodule Settings do
  defstruct [:path, :data]

  def new() do
    %Settings{path: settings_file()}
    |> slurp()
  end

  @doc """
  Get the path to the store root directory.
  """
  def home() do
    path = "#{System.get_env("HOME")}/.fnord"
    File.mkdir_p!(path)
    path
  end

  @doc """
  Get the path to the settings file.
  """
  def settings_file() do
    path = "#{home()}/settings.json"

    if !File.exists?(path) do
      File.write!(path, "{}")
    end

    path
  end

  @doc """
  Get a value from the settings store.
  """
  def get(settings, key, default \\ nil) do
    key = make_key(key)
    Map.get(settings.data, key, default)
  end

  @doc """
  Set a value in the settings store.
  """
  def set(settings, key, value) do
    key = make_key(key)

    %Settings{settings | data: Map.put(settings.data, key, value)}
    |> spew()
  end

  @doc """
  Delete a value from the settings store.
  """
  def delete(settings, key) do
    key = make_key(key)

    %Settings{settings | data: Map.delete(settings.data, key)}
    |> spew()
  end

  @doc """
  Get the project specified with --project. If the project name is not set, an
  error will be raised.
  """
  def get_selected_project!() do
    Application.get_env(:fnord, :project)
    |> case do
      nil -> raise "--project not set"
      project -> project
    end
  end

  def get_project(settings) do
    project = get_selected_project!()

    case get(settings, project, nil) do
      nil -> {:error, :not_found}
      data -> {:ok, data}
    end
  end

  def set_project(settings, data) do
    project = get_selected_project!()
    set(settings, project, data)
    data
  end

  def get_root(settings) do
    settings
    |> get_project()
    |> case do
      {:ok, %{"root" => root}} -> {:ok, Path.absname(root)}
      {:error, _} -> {:error, :not_found}
    end
  end

  defp slurp(settings) do
    %Settings{
      settings
      | data: File.read!(settings.path) |> Jason.decode!()
    }
  end

  defp spew(settings) do
    File.write!(settings.path, Jason.encode!(settings.data, pretty: true))
    settings
  end

  defp make_key(key) when is_atom(key), do: Atom.to_string(key)
  defp make_key(key), do: key
end
