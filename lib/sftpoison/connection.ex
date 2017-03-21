defmodule SFTPoison.Connection do
  @moduledoc """
  This module maintains a sftp connection that can be used to access remote
  files.

  `@stream_size` is how big each data chunk is when we read a file.
  """
  use GenServer
  @stream_size 32_768
  defstruct [ domain: nil, port: 22, user: nil, password: nil, pid: nil ]

  def start_link(init_args) do
    connection = %__MODULE__{
      domain: init_args.domain,
      port: init_args.port || 22,
      user: init_args.user,
      password: init_args.password,
    }
    GenServer.start_link(__MODULE__, connection, name: init_args.name)
  end

  @doc """
  List all of the files in a directory. Returns list of charlists

  ## Parameters
    - sftp: Atom that is the name the genserver is registered under
    - dir: charlist of the desired directory

  ## Example
    iex> list_dir(:hm_sftp, '/')
      ['test_file.txt', 'test2.txt']
  """
  def list_dir(sftp, dir), do: GenServer.call(sftp, {:list_dir, dir})

  @doc """
  Opens a file to be read or written to by providing a handle

  ## Parameters
    - sftp: Atom that is the name the genserver is registered under
    - file_path: charlist of the desired directory
    - mode: List of Atoms :read | :write | :creat | :trunc | :append | :binary
      defaults to :read

  ## Example
  iex> open_file(:hm_sftp, '/test_file.ex', [:read, :binary])
    {:ok, "0"}
  """
  def open_file(sftp, file, mode \\ [:read]) do
    GenServer.call(sftp, {:open_file, file, mode})
  end

  @doc """
  Returns a Map of info about a file

  ## Parameters
    - sftp: Atom that is the name the genserver is registered under
    - path: charlist of the desired file

  ## Example
    iex> read_file_info(:hm_sftp, '/test_file.ex')
      {:ok, %{access: :read_write, last_read: {{2017, 1, 25}, {14, 8, 0}},
            last_written: {{2017, 1, 25}, {14, 8, 0}}, size: 1640485}}
  """
  def read_file_info(sftp, path), do: GenServer.call(sftp, {:file_info, path})

  @doc """
  Returns the full file as a string

  ## Parameters
    - sftp: Atom that is the name the genserver is registered under
    - path: charlist of the desired file

  ## Example
    iex> get_full_file(:hm_sftp, '/test_file.ex')
      "Contests of the file."
  """
  def get_full_file(sftp, path) do
    {:ok, handle} = open_file(sftp, path, [:binary, :read])
    {:ok, data} = read_file(sftp, handle)
    get_full_file(sftp, path, handle, [], data)
  end
  def get_full_file(_sftp, _path, _handle, acc, :complete) do
    acc
    |> Enum.reverse
    |> Enum.join
  end
  def get_full_file(sftp, path, handle, acc, prev_data_element) do
    next_data = case read_file(sftp, handle) do
      {:ok, text} -> text
      :complete -> :complete
    end
    get_full_file(sftp, path, handle, [prev_data_element|acc], next_data)
  end

  @doc """
  Returns a `Stream` representation of a remote file

  ## Parameters
    - sftp: Atom that is the name the genserver is registered under
    - path: charlist of the desired file

  ## Example
    iex> stream_file(:hm_sftp, '/test_file.ex')
      #Function<51.36862645/2 in Stream.resource/3>
  """
  def stream_file(sftp, path) do
    Stream.resource(
      fn -> case open_file(sftp, path, [:binary, :read]) do
          {:ok, handle} -> handle
          {:error, msg} -> IO.puts(msg)
            {:halt, msg}
        end
      end,
      fn (handle) -> case read_file(sftp, handle) do
          {:ok, data} -> {[data], handle}
          :complete -> {:halt, handle}
          {:error, _msg} -> {:halt, handle}
        end
      end,
      fn (_handle) -> nil end
    )
  end

  defp read_file(sftp, handle), do: GenServer.call(sftp, {:read_file, handle})

  # Callbacks
  # TODO: Potentially move to a handle cast, as to no block
  def init(%__MODULE__{} = connection), do: connect(connection)

  def connect(config) do
    default_options = [{:sftp_vsn, 8}, {:silently_accept_hosts, :true}]

    result = :ssh_sftp.start_channel(config.domain, config.port,
      [{:user, config.user}, {:password, config.password}] ++ default_options)

    case result do
      {:ok, pid, _pid} -> {:ok, %{config | pid: pid}}
      {:error, msg} -> {:stop, "Could not establish connection: #{msg}"}
    end
  end
  def reconnect(old_conn) do
    {:ok, new_conn} = connect(old_conn)
    new_conn
  end

  def handle_call({:list_dir, directory} = args, from, conn) do
    case :ssh_sftp.list_dir(conn.pid, directory) do
      {:ok, file_names} -> {:reply, {:ok, file_names}, conn}
      {:error, :closed} -> handle_call(args, from, reconnect(conn))
      {:error, msg} -> {:reply, {:error, msg}, conn}
    end
  end

  def handle_call({:open_file, file_path, mode} = args, from, conn) do
    case :ssh_sftp.open(conn.pid, file_path, mode) do
      {:ok, handle} -> {:reply, {:ok, handle}, conn}
      {:error, :closed} -> handle_call(args, from, connect(conn))
      {:error, msg} -> {:reply, {:error, msg}, conn}
    end
  end

  def handle_call({:file_info, path}, _from, conn) do
    case :ssh_sftp.read_file_info(conn.pid, path) do
      {:ok, info} -> {:reply, {:ok, format_file_info(info)}, conn}
      {:error, msg} -> {:reply, {:error, msg}, conn}
    end
  end

  def handle_call({:read_file, handle}, _from, conn) do
    case :ssh_sftp.read(conn.pid, handle, @stream_size) do
      {:ok, data} -> {:reply, {:ok, data}, conn}
      :eof -> :ssh_sftp.close(conn.pid, handle)
        {:reply, :complete, conn}
      {:error, msg} -> {:reply, {:error, msg}, conn}
    end
  end

  def format_file_info({
    :file_info, size,_, access, last_read, last_written,_,_,_,_,_,_,_,_}) do
    %{size: size,
      access: access,
      last_read: last_read,
      last_written: last_written,
    }
  end

end
