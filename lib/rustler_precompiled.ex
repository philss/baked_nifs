defmodule RustlerPrecompiled do
  @moduledoc """
  Download and use precompiled NIFs safely with checksums.

  Rustler Precompiled is a tool for library maintainers that rely on Rustler.
  It helps by removing the need to have the Rust compiler installed in the
  user's machine.

  Check the [Precompilation Guide](PRECOMPILATION_GUIDE.md) for details.

  ## Example

      defmodule MyNative do
        use RustlerPrecompiled,
          otp_app: :my_app,
          crate: "my_app_nif",
          base_url: "https://github.com/me/my_project/releases/download/v0.1.0",
          version: "0.1.0"
      end

  ## Options

    * `:otp_app` - The OTP app name that the dynamic library will be loaded from.

    * `:crate` - The name of Rust crate if different from the `:otp_app`. This is optional.

    * `:base_url` - A valid URL that is used as base path for the NIF file.

    * `:version` - The version of precompiled assets (it is part of the NIF filename).

    * `:force_build` - Force the build with `Rustler`. This is `false` by default, but
      if your `:version` is a pre-release (like "2.1.0-dev"), this option will always
      be set `true`.
      You can also configure this option by setting an application env like this:

          config :rustler_precompiled, :force_build, your_otp_app: true

      It is important to add the ":rustler" package to your dependencies in order to force
      the build. To do that, just add it to your `mix.exs` file:

          {:rustler, ">= 0.0.0", optional: true}

    * `:targets` - A list of targets [supported by
      Rust](https://doc.rust-lang.org/rustc/platform-support.html) for which
      precompiled assets are available. By default the following targets are
      configured:

    #{Enum.map_join(RustlerPrecompiled.Config.default_targets(), "\n", &"    - `#{&1}`")}

  In case "force build" is used, all options except `:base_url`, `:version`,
  `:force_build` and `:targets` are going to be passed down to `Rustler`.
  So if you need to configure the build, check the `Rustler` options.
  """
  defmacro __using__(opts) do
    force =
      if Code.ensure_loaded?(Rustler) do
        quote do
          use Rustler, only_rustler_opts
        end
      else
        quote do
          raise "Rustler dependency is needed to force the build. " <>
                  "Add it to your `mix.exs` file: `{:rustler, \">= 0.0.0\", optional: true}`"
        end
      end

    quote do
      require Logger

      opts = unquote(opts)

      otp_app = Keyword.fetch!(opts, :otp_app)

      opts =
        Keyword.put_new(
          opts,
          :force_build,
          Application.compile_env(:rustler_precompiled, [:force_build, otp_app])
        )

      case RustlerPrecompiled.__using__(__MODULE__, opts) do
        {:force_build, only_rustler_opts} ->
          unquote(force)

        {:ok, config} ->
          @on_load :load_rustler_precompiled
          @rustler_precompiled_load_from config.load_from
          @rustler_precompiled_load_data config.load_data

          @doc false
          def load_rustler_precompiled do
            # Remove any old modules that may be loaded so we don't get
            # {:error, {:upgrade, 'Upgrade not supported by this NIF library.'}}
            :code.purge(__MODULE__)
            {otp_app, path} = @rustler_precompiled_load_from

            load_path =
              otp_app
              |> Application.app_dir(path)
              |> to_charlist()

            :erlang.load_nif(load_path, @rustler_precompiled_load_data)
          end

        {:error, precomp_error} ->
          raise precomp_error
      end
    end
  end

  # A helper function to extract the logic from __using__ macro.
  @doc false
  def __using__(module, opts) do
    config =
      opts
      |> Keyword.put_new(:module, module)
      |> RustlerPrecompiled.Config.new()

    if config.force_build? do
      rustler_opts = Keyword.drop(opts, [:base_url, :version, :force_build, :targets])

      {:force_build, rustler_opts}
    else
      with {:error, precomp_error} <- RustlerPrecompiled.download_or_reuse_nif_file(config) do
        message = """
        Error while downloading precompiled NIF: #{precomp_error}.

        You can force the project to build from scratch with:

            config :rustler_precompiled, :force_build, #{config.otp_app}: true

        In order to force the build, you also need to add Rustler as a dependency in your `mix.exs`:

            {:rustler, ">= 0.0.0", optional: true}
        """

        {:error, message}
      end
    end
  end

  ## Implementation below

  alias RustlerPrecompiled.Config
  require Logger

  @available_nif_versions ~w(2.14 2.15 2.16)
  @checksum_algo :sha256
  @checksum_algorithms [@checksum_algo]

  @native_dir "priv/native"

  @doc """
  Returns URLs for NIFs based on its module name.

  The module name is the one that defined the NIF and this information
  is stored in a metadata file.
  """
  def available_nif_urls(nif_module) when is_atom(nif_module) do
    metadata =
      nif_module
      |> metadata_file()
      |> read_map_from_file()

    case metadata do
      %{targets: targets, base_url: base_url, basename: basename, version: version} ->
        for target_triple <- targets, nif_version <- @available_nif_versions do
          target = "nif-#{nif_version}-#{target_triple}"

          # We need to build again the name because each arch is different.
          lib_name = "#{lib_prefix(target)}#{basename}-v#{version}-#{target}"

          tar_gz_file_url(base_url, lib_name_with_ext(target, lib_name))
        end

      _ ->
        raise "metadata about current target for the module #{inspect(nif_module)} is not available. " <>
                "Please compile the project again with: `mix compile --force`"
    end
  end

  @doc """
  Returns the file URL to be downloaded for current target.

  It receives the NIF module.
  """
  def current_target_nif_url(nif_module) when is_atom(nif_module) do
    metadata =
      nif_module
      |> metadata_file()
      |> read_map_from_file()

    case metadata do
      %{base_url: base_url, file_name: file_name} ->
        tar_gz_file_url(base_url, file_name)

      _ ->
        raise "metadata about current target for the module #{inspect(nif_module)} is not available. " <>
                "Please compile the project again with: `mix compile --force`"
    end
  end

  @doc """
  Returns the target triple for download or compile and load.

  This function is translating and adding more info to the system
  architecture returned by Elixir/Erlang to one used by Rust.

  The returned string has the following format:

      "nif-NIF_VERSION-ARCHITECTURE-VENDOR-OS-ABI"

  ## Examples

      iex> RustlerPrecompiled.target()
      {:ok, "nif-2.16-x86_64-unknown-linux-gnu"}

      iex> RustlerPrecompiled.target()
      {:ok, "nif-2.15-aarch64-apple-darwin"}

  """
  def target(config \\ target_config(), available_targets) do
    arch_os =
      case config.os_type do
        {:unix, _} ->
          config.target_system
          |> normalize_arch_os()
          |> system_arch_to_string()

        {:win32, _} ->
          existing_target =
            config.target_system
            |> system_arch_to_string()

          # For when someone is setting "TARGET_*" vars on Windows
          if existing_target in available_targets do
            existing_target
          else
            # 32 or 64 bits
            arch =
              case config.word_size do
                4 -> "i686"
                8 -> "x86_64"
                _ -> "unknown"
              end

            config.target_system
            |> Map.put_new(:arch, arch)
            |> Map.put_new(:vendor, "pc")
            |> Map.put_new(:os, "windows")
            |> Map.put_new(:abi, "msvc")
            |> system_arch_to_string()
          end
      end

    cond do
      arch_os not in available_targets ->
        {:error,
         "precompiled NIF is not available for this target: #{inspect(arch_os)}.\n" <>
           "The available targets are:\n - #{Enum.join(available_targets, "\n - ")}"}

      config.nif_version not in @available_nif_versions ->
        {:error,
         "precompiled NIF is not available for this NIF version: #{inspect(config.nif_version)}.\n" <>
           "The available NIF versions are:\n - #{Enum.join(@available_nif_versions, "\n - ")}"}

      true ->
        {:ok, "nif-#{config.nif_version}-#{arch_os}"}
    end
  end

  defp target_config do
    current_nif_version = :erlang.system_info(:nif_version) |> List.to_string()

    nif_version =
      case find_compatible_nif_version(current_nif_version, @available_nif_versions) do
        {:ok, vsn} ->
          vsn

        :error ->
          # In case of error, use the current so we can tell the user.
          current_nif_version
      end

    current_system_arch = system_arch()

    %{
      os_type: :os.type(),
      target_system: maybe_override_with_env_vars(current_system_arch),
      word_size: :erlang.system_info(:wordsize),
      nif_version: nif_version
    }
  end

  # In case one is using this lib in a newer OTP version, we try to
  # find the latest compatible NIF version.
  @doc false
  def find_compatible_nif_version(vsn, available) do
    if vsn in available do
      {:ok, vsn}
    else
      [major, minor | _] = parse_version(vsn)

      available
      |> Enum.map(&parse_version/1)
      |> Enum.filter(fn
        [^major, available_minor | _] when available_minor <= minor -> true
        [_ | _] -> false
      end)
      |> case do
        [] -> :error
        match -> {:ok, match |> Enum.max() |> Enum.join(".")}
      end
    end
  end

  defp parse_version(vsn) do
    vsn |> String.split(".") |> Enum.map(&String.to_integer/1)
  end

  # Returns a map with `:arch`, `:vendor`, `:os` and maybe `:abi`.
  defp system_arch do
    base =
      :erlang.system_info(:system_architecture)
      |> List.to_string()
      |> String.split("-")

    triple_keys =
      case length(base) do
        4 ->
          [:arch, :vendor, :os, :abi]

        3 ->
          [:arch, :vendor, :os]

        _ ->
          # It's too complicated to find out, and we won't support this for now.
          []
      end

    triple_keys
    |> Enum.zip(base)
    |> Enum.into(%{})
  end

  # The idea is to support systems like Nerves.
  # See: https://hexdocs.pm/nerves/compiling-non-beam-code.html#target-cpu-arch-os-and-abi
  @doc false
  def maybe_override_with_env_vars(original_sys_arch, get_env \\ &System.get_env/1) do
    envs_with_keys = [
      arch: "TARGET_ARCH",
      vendor: "TARGET_VENDOR",
      os: "TARGET_OS",
      abi: "TARGET_ABI"
    ]

    updated_system_arch =
      Enum.reduce(envs_with_keys, original_sys_arch, fn {key, env_key}, acc ->
        if env_value = get_env.(env_key) do
          Map.put(acc, key, env_value)
        else
          acc
        end
      end)

    # Only replace vendor if remains the same but some other env changed the config.
    if original_sys_arch != updated_system_arch and
         original_sys_arch.vendor == updated_system_arch.vendor do
      Map.put(updated_system_arch, :vendor, "unknown")
    else
      updated_system_arch
    end
  end

  defp normalize_arch_os(target_system) do
    cond do
      target_system.os =~ "darwin" ->
        arch = with "arm" <- target_system.arch, do: "aarch64"

        %{target_system | arch: arch, os: "darwin"}

      target_system.os =~ "linux" ->
        arch = with "amd64" <- target_system.arch, do: "x86_64"
        vendor = with vendor when vendor in ~w(pc redhat) <- target_system.vendor, do: "unknown"

        %{target_system | arch: arch, vendor: vendor}

      true ->
        target_system
    end
  end

  defp system_arch_to_string(system_arch) do
    values =
      for key <- [:arch, :vendor, :os, :abi],
          value = system_arch[key],
          do: value

    Enum.join(values, "-")
  end

  # Perform the download or load of the precompiled NIF
  # It will look in the "priv/native/otp_app" first, and if
  # that file doesn't exist, it will try to fetch from cache.
  # In case there is no valid cached file, then it will try
  # to download the NIF from the provided base URL.
  @doc false
  def download_or_reuse_nif_file(%Config{} = config) do
    name = config.otp_app
    version = config.version

    native_dir = Application.app_dir(name, @native_dir)

    # NOTE: this `cache_base_dir` is a "private" option used only in tests.
    cache_dir = cache_dir(config.base_cache_dir, "precompiled_nifs")

    with {:ok, target} <- target(config.targets) do
      basename = config.crate || name
      lib_name = "#{lib_prefix(target)}#{basename}-v#{version}-#{target}"

      file_name = lib_name_with_ext(target, lib_name)
      cached_tar_gz = Path.join(cache_dir, "#{file_name}.tar.gz")

      lib_file = Path.join(native_dir, file_name)

      base_url = config.base_url
      nif_module = config.module

      metadata = %{
        otp_app: name,
        crate: config.crate,
        cached_tar_gz: cached_tar_gz,
        base_url: base_url,
        basename: basename,
        lib_name: lib_name,
        file_name: file_name,
        target: target,
        targets: config.targets,
        version: version
      }

      write_metadata(nif_module, metadata)

      result = %{
        load?: true,
        load_from: {name, Path.join("priv/native", lib_name)},
        load_data: config.load_data
      }

      # TODO: add option to only write metadata
      cond do
        File.exists?(cached_tar_gz) ->
          # Remove existing NIF file so we don't have processes using it.
          # See: https://github.com/rusterlium/rustler/blob/46494d261cbedd3c798f584459e42ab7ee6ea1f4/rustler_mix/lib/rustler/compiler.ex#L134
          File.rm(lib_file)

          with :ok <- check_file_integrity(cached_tar_gz, nif_module),
               :ok <- :erl_tar.extract(cached_tar_gz, [:compressed, cwd: Path.dirname(lib_file)]) do
            Logger.debug("Copying NIF from cache and extracting to #{lib_file}")
            {:ok, result}
          end

        true ->
          dirname = Path.dirname(lib_file)

          with :ok <- File.mkdir_p(cache_dir),
               :ok <- File.mkdir_p(dirname),
               {:ok, tar_gz} <- download_tar_gz(base_url, lib_name, cached_tar_gz),
               :ok <- File.write(cached_tar_gz, tar_gz),
               :ok <- check_file_integrity(cached_tar_gz, nif_module),
               :ok <-
                 :erl_tar.extract({:binary, tar_gz}, [:compressed, cwd: Path.dirname(lib_file)]) do
            Logger.debug("NIF cached at #{cached_tar_gz} and extracted to #{lib_file}")

            {:ok, result}
          end
      end
    end
  end

  defp checksum_map(nif_module) when is_atom(nif_module) do
    nif_module
    |> checksum_file()
    |> read_map_from_file()
  end

  defp check_file_integrity(file_path, nif_module) when is_atom(nif_module) do
    nif_module
    |> checksum_map()
    |> check_integrity_from_map(file_path, nif_module)
  end

  # It receives the map of %{ "filename" => "algo:checksum" } with the file path
  @doc false
  def check_integrity_from_map(checksum_map, file_path, nif_module) do
    with {:ok, {algo, hash}} <- find_checksum(checksum_map, file_path, nif_module),
         :ok <- validate_checksum_algo(algo),
         do: compare_checksum(file_path, algo, hash)
  end

  defp find_checksum(checksum_map, file_path, nif_module) do
    basename = Path.basename(file_path)

    case Map.fetch(checksum_map, basename) do
      {:ok, algo_with_hash} ->
        [algo, hash] = String.split(algo_with_hash, ":")
        algo = String.to_existing_atom(algo)

        {:ok, {algo, hash}}

      :error ->
        {:error,
         "the precompiled NIF file does not exist in the checksum file. " <>
           "Please consider run: `mix rustler_precompiled.download #{inspect(nif_module)} --only-local` to generate the checksum file."}
    end
  end

  defp validate_checksum_algo(algo) do
    if algo in @checksum_algorithms do
      :ok
    else
      {:error,
       "checksum algorithm is not supported: #{inspect(algo)}. " <>
         "The supported ones are:\n - #{Enum.join(@checksum_algorithms, "\n - ")}"}
    end
  end

  defp compare_checksum(file_path, algo, expected_checksum) do
    case File.read(file_path) do
      {:ok, content} ->
        file_hash =
          algo
          |> :crypto.hash(content)
          |> Base.encode16(case: :lower)

        if file_hash == expected_checksum do
          :ok
        else
          {:error, "the integrity check failed because the checksum of files does not match"}
        end

      {:error, reason} ->
        {:error,
         "cannot read the file for checksum comparison: #{inspect(file_path)}. " <>
           "Reason: #{inspect(reason)}"}
    end
  end

  defp cache_dir(sub_dir) do
    cache_opts = if System.get_env("MIX_XDG"), do: %{os: :linux}, else: %{}
    :filename.basedir(:user_cache, Path.join("rustler_precompiled", sub_dir), cache_opts)
  end

  # This arity is only used in test context. It should be private because
  # we can't provide this option in the `mix rustler_precompiled.download` task.
  defp cache_dir(basedir, sub_dir) do
    if basedir do
      Path.join(basedir, sub_dir)
    else
      cache_dir(sub_dir)
    end
  end

  defp lib_prefix(target) do
    if String.contains?(target, "windows") do
      ""
    else
      "lib"
    end
  end

  defp lib_name_with_ext(target, lib_name) do
    ext =
      if String.contains?(target, "windows") do
        "dll"
      else
        "so"
      end

    "#{lib_name}.#{ext}"
  end

  defp tar_gz_file_url(base_url, file_name) do
    uri = URI.parse(base_url)

    uri =
      Map.update!(uri, :path, fn path ->
        Path.join(path || "", "#{file_name}.tar.gz")
      end)

    to_string(uri)
  end

  defp download_tar_gz(base_url, lib_name, target_name) do
    base_url
    |> tar_gz_file_url(lib_name_with_ext(target_name, lib_name))
    |> download_nif_artifact()
  end

  defp download_nif_artifact(url) do
    url = String.to_charlist(url)
    Logger.debug("Downloading NIF from #{url}")

    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)

    if proxy = System.get_env("HTTP_PROXY") || System.get_env("http_proxy") do
      Logger.debug("Using HTTP_PROXY: #{proxy}")
      %{host: host, port: port} = URI.parse(proxy)

      :httpc.set_options([{:proxy, {{String.to_charlist(host), port}, []}}])
    end

    proxy = System.get_env("HTTPS_PROXY") || System.get_env("https_proxy")

    with true <- is_binary(proxy),
         %{host: host, port: port} when is_binary(host) and is_integer(port) <- URI.parse(proxy) do
      Logger.debug("Using HTTPS_PROXY: #{proxy}")
      :httpc.set_options([{:https_proxy, {{String.to_charlist(host), port}, []}}])
    end

    # https://erlef.github.io/security-wg/secure_coding_and_deployment_hardening/inets
    cacertfile = CAStore.file_path() |> String.to_charlist()

    http_options = [
      ssl: [
        verify: :verify_peer,
        cacertfile: cacertfile,
        depth: 2,
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ]
    ]

    options = [body_format: :binary]

    case :httpc.request(:get, {url, []}, http_options, options) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        {:ok, body}

      other ->
        {:error, "couldn't fetch NIF from #{url}: #{inspect(other)}"}
    end
  end

  # Download a list of files from URLs and calculate its checksum.
  # Returns a list with details of the download and the checksum of each file.
  @doc false
  def download_nif_artifacts_with_checksums!(urls, options \\ []) do
    ignore_unavailable? = Keyword.get(options, :ignore_unavailable, false)

    tasks =
      Task.async_stream(urls, fn url -> {url, download_nif_artifact(url)} end, timeout: :infinity)

    cache_dir = cache_dir("precompiled_nifs")
    :ok = File.mkdir_p(cache_dir)

    Enum.flat_map(tasks, fn {:ok, result} ->
      with {:download, {url, download_result}} <- {:download, result},
           {:download_result, {:ok, body}} <- {:download_result, download_result},
           hash <- :crypto.hash(@checksum_algo, body),
           path <- Path.join(cache_dir, basename_from_url(url)),
           {:file, :ok} <- {:file, File.write(path, body)} do
        checksum = Base.encode16(hash, case: :lower)

        Logger.debug(
          "NIF cached at #{path} with checksum #{inspect(checksum)} (#{@checksum_algo})"
        )

        [
          %{
            url: url,
            path: path,
            checksum: checksum,
            checksum_algo: @checksum_algo
          }
        ]
      else
        {:file, error} ->
          raise "could not write downloaded file to disk. Reason: #{inspect(error)}"

        {context, result} ->
          if ignore_unavailable? do
            Logger.debug(
              "Skip an unavailable NIF artifact. " <>
                "Context: #{inspect(context)}. Reason: #{inspect(result)}"
            )

            []
          else
            raise "could not finish the download of NIF artifacts. " <>
                    "Context: #{inspect(context)}. Reason: #{inspect(result)}"
          end
      end
    end)
  end

  defp basename_from_url(url) do
    uri = URI.parse(url)

    uri.path
    |> String.split("/")
    |> List.last()
  end

  defp read_map_from_file(file) do
    with {:ok, contents} <- File.read(file),
         {%{} = contents, _} <- Code.eval_string(contents) do
      contents
    else
      _ -> %{}
    end
  end

  defp write_metadata(nif_module, metadata) do
    metadata_file = metadata_file(nif_module)
    existing = read_map_from_file(metadata_file)

    unless Map.equal?(metadata, existing) do
      dir = Path.dirname(metadata_file)
      :ok = File.mkdir_p(dir)

      File.write!(metadata_file, inspect(metadata, limit: :infinity, pretty: true))
    end

    :ok
  end

  defp metadata_file(nif_module) when is_atom(nif_module) do
    rustler_precompiled_cache = cache_dir("metadata")
    Path.join(rustler_precompiled_cache, "metadata-#{nif_module}.exs")
  end

  # Write the checksum file with all NIFs available.
  # It receives the module name and checksums.
  @doc false
  def write_checksum!(nif_module, checksums) when is_atom(nif_module) do
    metadata =
      nif_module
      |> metadata_file()
      |> read_map_from_file()

    case metadata do
      %{otp_app: _name} ->
        file = checksum_file(nif_module)

        pairs =
          for %{path: path, checksum: checksum, checksum_algo: algo} <- checksums, into: %{} do
            basename = Path.basename(path)
            checksum = "#{algo}:#{checksum}"
            {basename, checksum}
          end

        lines =
          for {filename, checksum} <- Enum.sort(pairs) do
            ~s(  "#{filename}" => #{inspect(checksum, limit: :infinity)},\n)
          end

        File.write!(file, ["%{\n", lines, "}\n"])

      _ ->
        raise "could not find the OTP app for #{inspect(nif_module)} in the metadata file. " <>
                "Please compile the project again with: `mix compile --force`."
    end
  end

  defp checksum_file(nif_module) do
    # Saves the file in the project root.
    Path.join(File.cwd!(), "checksum-#{nif_module}.exs")
  end
end
