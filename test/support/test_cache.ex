defmodule Nebulex.Version.Timestamp do
  @moduledoc false
  @behaviour Nebulex.Object.Version

  alias Nebulex.Object

  @impl true
  def generate(nil), do: now()
  def generate(%Object{}), do: now()

  defp now, do: DateTime.to_unix(DateTime.utc_now(), :nanosecond)
end

defmodule Nebulex.TestCache do
  @moduledoc false
  defmodule Hooks do
    @moduledoc false
    defmacro __using__(opts) do
      quote bind_quoted: [opts: opts] do
        @opts opts

        def pre_hooks do
          pre_hook = fn
            result, {_, :get, _} = call ->
              send(:hooked_cache, call)

            _, _ ->
              :noop
          end

          {@opts[:pre_hooks_mode] || :async, [pre_hook]}
        end

        def post_hooks do
          wrong_hook = fn var -> var end
          {@opts[:post_hooks_mode] || :async, [wrong_hook, &post_hook/2]}
        end

        def post_hook(result, {_, :set, _} = call) do
          _ = send(:hooked_cache, call)
          result
        end

        def post_hook(nil, {_, :get, _}) do
          "hello"
        end

        def post_hook(result, _) do
          result
        end
      end
    end
  end

  defmodule Local do
    @moduledoc false
    use Nebulex.Cache,
      otp_app: :nebulex,
      adapter: Nebulex.Adapters.Local,
      version_generator: Nebulex.Version.Timestamp
  end

  :ok = Application.put_env(:nebulex, Nebulex.TestCache.Versionless, compressed: true)

  defmodule Versionless do
    @moduledoc false
    use Nebulex.Cache,
      otp_app: :nebulex,
      adapter: Nebulex.Adapters.Local
  end

  defmodule HookableCache do
    @moduledoc false
    defmodule C1 do
      @moduledoc false
      use Nebulex.Cache,
        otp_app: :nebulex,
        adapter: Nebulex.Adapters.Local

      use Hooks
    end

    defmodule C2 do
      @moduledoc false
      use Nebulex.Cache,
        otp_app: :nebulex,
        adapter: Nebulex.Adapters.Local

      use Hooks, post_hooks_mode: :pipe
    end

    defmodule C3 do
      @moduledoc false
      use Nebulex.Cache,
        otp_app: :nebulex,
        adapter: Nebulex.Adapters.Local

      use Hooks, post_hooks_mode: :sync
    end
  end

  defmodule CacheStats do
    @moduledoc false
    use Nebulex.Cache,
      otp_app: :nebulex,
      adapter: Nebulex.Adapters.Local,
      stats: true

    def post_hooks do
      {:pipe, []}
    end
  end

  defmodule LocalWithGC do
    @moduledoc false
    use Nebulex.Cache,
      otp_app: :nebulex,
      adapter: Nebulex.Adapters.Local,
      version_generator: Nebulex.Version.Timestamp
  end

  :ok =
    Application.put_env(
      :nebulex,
      Nebulex.TestCache.LocalWithSizeLimit,
      allocated_memory: 100_000,
      gc_cleanup_interval: 2
    )

  defmodule LocalWithSizeLimit do
    @moduledoc false
    use Nebulex.Cache,
      otp_app: :nebulex,
      adapter: Nebulex.Adapters.Local,
      version_generator: Nebulex.Version.Timestamp,
      n_shards: 2,
      gc_interval: 3600,
      n_generations: 3
  end

  defmodule Partitioned do
    @moduledoc false
    use Nebulex.Cache,
      otp_app: :nebulex,
      adapter: Nebulex.Adapters.Partitioned,
      primary: Nebulex.TestCache.Partitioned.Primary,
      version_generator: Nebulex.Version.Timestamp

    defmodule Primary do
      @moduledoc false
      use Nebulex.Cache,
        otp_app: :nebulex,
        adapter: Nebulex.Adapters.Local,
        gc_interval: 3600
    end

    def get_and_update_fun(nil), do: {nil, 1}
    def get_and_update_fun(current) when is_integer(current), do: {current, current * 2}

    def get_and_update_bad_fun(_), do: :other
  end

  defmodule PartitionedWithCustomHashSlot do
    @moduledoc false
    use Nebulex.Cache,
      otp_app: :nebulex,
      adapter: Nebulex.Adapters.Partitioned,
      primary: Nebulex.TestCache.PartitionedWithCustomHashSlot.Primary,
      hash_slot: Nebulex.TestCache.PartitionedWithCustomHashSlot.HashSlot

    defmodule Primary do
      @moduledoc false
      use Nebulex.Cache,
        otp_app: :nebulex,
        adapter: Nebulex.Adapters.Local
    end

    defmodule HashSlot do
      @moduledoc false
      @behaviour Nebulex.Adapter.HashSlot

      @impl true
      def keyslot(key, range) do
        key
        |> :erlang.phash2()
        |> rem(range)
      end
    end
  end

  for mod <- [Nebulex.TestCache.Multilevel, Nebulex.TestCache.MultilevelExclusive] do
    levels =
      for l <- 1..3 do
        level = String.to_atom("#{mod}.L#{l}")
        :ok = Application.put_env(:nebulex, level, gc_interval: 3600)
        level
      end

    config =
      case mod do
        Nebulex.TestCache.Multilevel ->
          [levels: levels, fallback: &mod.fallback/1]

        _ ->
          [cache_model: :exclusive, levels: levels, fallback: &mod.fallback/1]
      end

    :ok = Application.put_env(:nebulex, mod, config)

    defmodule mod do
      @moduledoc false
      use Nebulex.Cache,
        otp_app: :nebulex,
        adapter: Nebulex.Adapters.Multilevel

      defmodule L1 do
        @moduledoc false
        use Nebulex.Cache,
          otp_app: :nebulex,
          adapter: Nebulex.Adapters.Local
      end

      defmodule L2 do
        @moduledoc false
        use Nebulex.Cache,
          otp_app: :nebulex,
          adapter: Nebulex.Adapters.Local
      end

      defmodule L3 do
        @moduledoc false
        use Nebulex.Cache,
          otp_app: :nebulex,
          adapter: Nebulex.Adapters.Local,
          n_shards: 2
      end

      def fallback(_key) do
        # maybe fetch the data from Database
        nil
      end
    end
  end

  defmodule Replicated do
    @moduledoc false
    use Nebulex.Cache,
      otp_app: :nebulex,
      adapter: Nebulex.Adapters.Replicated,
      version_generator: Nebulex.Version.Timestamp,
      primary: Nebulex.TestCache.Replicated.Primary

    defmodule Primary do
      @moduledoc false
      use Nebulex.Cache,
        otp_app: :nebulex,
        adapter: Nebulex.Adapters.Local
    end
  end

  ## Mocks

  defmodule AdapterMock do
    @moduledoc false
    @behaviour Nebulex.Adapter

    @impl true
    defmacro __before_compile__(_), do: :ok

    @impl true
    def init(_), do: {:ok, []}

    @impl true
    def get(_, _, _), do: raise(ArgumentError, "Error")

    @impl true
    def set(_, _, _), do: Process.sleep(1000)

    @impl true
    def delete(_, _, _), do: :ok

    @impl true
    def take(_, _, _), do: nil

    @impl true
    def has_key?(_, _), do: nil

    @impl true
    def object_info(_, _, _), do: nil

    @impl true
    def expire(_, _, _), do: nil

    @impl true
    def update_counter(_, _, _, _), do: 1

    @impl true
    def size(_), do: Process.exit(self(), :normal)

    @impl true
    def flush(_), do: Process.sleep(2000)

    @impl true
    def get_many(_, _, _), do: Process.sleep(1000)

    @impl true
    def set_many(_, _, _), do: Process.exit(self(), :normal)
  end

  :ok =
    Application.put_env(
      :nebulex,
      Nebulex.TestCache.PartitionedMock,
      primary: Nebulex.TestCache.PartitionedMock.Primary
    )

  defmodule PartitionedMock do
    @moduledoc false
    use Nebulex.Cache,
      otp_app: :nebulex,
      adapter: Nebulex.Adapters.Partitioned

    defmodule Primary do
      @moduledoc false
      use Nebulex.Cache,
        otp_app: :nebulex,
        adapter: Nebulex.TestCache.AdapterMock
    end
  end

  :ok =
    Application.put_env(
      :nebulex,
      Nebulex.TestCache.ReplicatedMock,
      primary: Nebulex.TestCache.ReplicatedMock.Primary
    )

  defmodule ReplicatedMock do
    @moduledoc false
    use Nebulex.Cache,
      otp_app: :nebulex,
      adapter: Nebulex.Adapters.Replicated

    defmodule Primary do
      @moduledoc false
      use Nebulex.Cache,
        otp_app: :nebulex,
        adapter: Nebulex.TestCache.AdapterMock
    end
  end
end
