defmodule GN.Orchestration do
  import GN.CNTKWrapper
  import GN.Gluon
  import GN.Evolution, only: [spawn_offspring: 1, build_layer: 2]
  alias GN.Network, as: Network
  import GN.Python
  import GN.Selection, only: [select: 1]
  use Export.Python

  def start_and_spawn({_level, net}) do
    {:ok, file_path} = write_net(net)
    {:ok, py} = start()
    test_acc = py |> call(evaluate(file_path))

    %Network{
      id: UUID.uuid4(),
      test_acc: test_acc,
      onnx: net.onnx
    }
  end

  def write_net(net) do
    encoded_net_data = Onnx.ModelProto.encode(net.onnx)
    file_path = "/tmp/model-#{UUID.uuid4()}.onnx"
    {:ok, file} = File.open(file_path, [:write])
    IO.binwrite(file, encoded_net_data)
    File.close(file)
    {:ok, file_path}
  end

  def strip_empties(nets) do
    Enum.filter(nets, fn {_k, v} -> Map.size(v) != 0 end)
  end

  def learn_generation(%Network{} = initial_net) do
    generation_size = GN.Parameters.get(__MODULE__, :generation_size)
    # clone the initial net to create a generation
    nets =
      Enum.reduce(1..generation_size, %{}, fn n, acc ->
        Map.put(acc, -1 * n, initial_net)
      end)

    learn_generation(nets)
  end

  def learn_generation(nets) when map_size(nets) == 1 do
    # too little diversity in complexity, so clones must be spawned
    [net] = Map.values(nets)
    learn_generation(net)
  end

  def learn_generation(nets) do
    clean_nets = strip_empties(nets)

    tasks =
      Task.Supervisor.async_stream_nolink(
        GN.TaskSupervisor,
        clean_nets,
        &start_and_spawn(&1),
        timeout: GN.Parameters.get(__MODULE__, :timeout)
      )

    generation = for {status, net} <- tasks, status == :ok, do: net
    IO.puts(inspect(generation))
    generation
  end

  def decrement(generations) do
    generations - 1
  end

  def evolve_continual(nets) do
    evolve(nets, :infinity, & &1)
  end

  def evolve(nets, generations) do
    evolve(nets, generations, &decrement/1)
  end

  def evolve(nets, generations, count_function) when generations > 0 do
    Task.Supervisor.async(GN.TaskSupervisor, fn ->
      IO.puts("Generations remaining: #{generations}")

      learn_generation(nets)
      |> select()
      |> evolve(count_function.(generations), count_function)
    end)
  end

  def evolve(nets, _generations, _count_function) do
    nets
  end
end
