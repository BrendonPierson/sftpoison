defmodule SFTPoison.Supervisor do
  use Supervisor

  def start_link() do
    Supervisor.start_link(__MODULE__, [])
  end

  def init(_opts) do
    Application.get_env(:sftpoison, :sftp_connections, [])
    |> Enum.map(&worker(SFTPoison.Connection, [&1]))
    |> supervise(strategy: :one_for_one)
  end

end
