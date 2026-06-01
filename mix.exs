defmodule Volt.MixProject do
  use Mix.Project

  @version "0.14.0"
  @source_url "https://github.com/elixir-volt/volt"
  @zigler_zig_version "0.15.2"

  def project do
    ensure_zigler_zig()

    [
      app: :volt,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      dialyzer: [plt_add_apps: [:mix]],
      name: "Volt",
      description:
        "Elixir-native frontend build tool — dev server, HMR, and production builds powered by OXC and Vize.",
      source_url: @source_url,
      homepage_url: @source_url,
      package: package(),
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Volt.Application, []}
    ]
  end

  defp deps do
    [
      {:reach, "~> 2.6.1", only: [:dev, :test], runtime: false},
      {:glob_ex, "~> 0.1"},
      {:oxc,
       git: "https://github.com/skunkwerks/oxc_ex.git",
       branch: "feature/add-freebsd",
       override: true},
      {:vize, git: "https://github.com/skunkwerks/vize_ex.git", branch: "feature/add-freebsd"},
      {:rustler, "~> 0.37", optional: true},
      {:oxide_ex,
       git: "https://github.com/skunkwerks/oxide_ex.git", branch: "feature/add-freebsd"},
      {:quickbeam,
       git: "https://github.com/skunkwerks/quickbeam.git",
       branch: "feature/add-freebsd",
       override: true},
      {:zigler, "~> 0.15.2", runtime: false, optional: true},
      {:dotenvy, "~> 1.1"},
      {:floki, "~> 0.38"},
      {:plug, "~> 1.16"},
      {:websock_adapter, "~> 0.5"},
      {:file_system, "~> 1.0"},
      {:jason, "~> 1.4"},
      {:igniter, "~> 0.5", optional: true},
      {:npm, "~> 0.7.4"},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:ex_dna, "~> 1.1", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.35", only: :dev, runtime: false},
      {:makeup_js, "~> 0.1", only: :dev, runtime: false},
      {:bandit, "~> 1.0", only: :test},
      {:playwright_ex, "~> 0.5", only: :test}
    ]
  end

  defp aliases do
    [
      lint: [
        "format --check-formatted",
        "volt.js.check --type-aware --type-check",
        "credo --strict",
        "ex_dna --min-mass 20",
        "reach.check --arch --dead-code --smells --strict",
        "dialyzer"
      ],
      setup: ["deps.get"],
      ci: ["lint", "cmd env MIX_ENV=test mix test"]
    ]
  end

  defp ensure_zigler_zig do
    if freebsd?() and
         blank?(System.get_env("ZIG_EXECUTABLE_PATH")) and
         blank?(System.get_env("ZIG_ARCHIVE_PATH")) and
         !compatible_zig?(System.find_executable("zig")) do
      case find_cached_freebsd_zig() || fetch_freebsd_zig() do
        nil -> :ok
        path -> System.put_env("ZIG_EXECUTABLE_PATH", path)
      end
    end
  end

  defp freebsd?, do: :os.type() == {:unix, :freebsd}

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  defp find_cached_freebsd_zig do
    cache_dir = :filename.basedir(:user_cache, ~c"zigler") |> List.to_string()

    [
      Path.join(cache_dir, "zig-#{freebsd_zig_arch()}-freebsd-#{@zigler_zig_version}/zig"),
      Path.join(cache_dir, "zig-amd64-freebsd15.1-#{@zigler_zig_version}/zig")
    ]
    |> Enum.find(&compatible_zig?/1)
  end

  defp fetch_freebsd_zig do
    cache_dir = :filename.basedir(:user_cache, ~c"zigler") |> List.to_string()
    arch = freebsd_zig_arch()
    archive_name = "zig-#{arch}-freebsd-#{@zigler_zig_version}.tar.xz"
    archive_path = Path.join(System.tmp_dir!(), archive_name)
    zig_path = Path.join(cache_dir, "zig-#{arch}-freebsd-#{@zigler_zig_version}/zig")
    url = "https://ziglang.org/download/#{@zigler_zig_version}/#{archive_name}"

    Mix.shell().info("Downloading Zig #{@zigler_zig_version} for #{arch}-freebsd")

    with :ok <- File.mkdir_p(cache_dir),
         :ok <- download_file(url, archive_path),
         :ok <- extract_archive(archive_path, cache_dir),
         true <- compatible_zig?(zig_path) do
      File.rm(archive_path)
      zig_path
    else
      false ->
        Mix.shell().error(
          "Downloaded Zig archive did not install a compatible binary at #{zig_path}"
        )

        nil

      {:error, message} ->
        Mix.shell().error(message)
        nil
    end
  end

  defp download_file(url, path) do
    cond do
      fetch = System.find_executable("fetch") ->
        run_tool(fetch, ["-o", path, url], "Could not download Zig from #{url}")

      curl = System.find_executable("curl") ->
        run_tool(curl, ["--fail", "-L", "-o", path, url], "Could not download Zig from #{url}")

      true ->
        {:error, "Could not download Zig: neither fetch nor curl is available"}
    end
  end

  defp extract_archive(archive_path, cache_dir) do
    case System.find_executable("tar") do
      nil ->
        {:error, "Could not extract Zig: tar is not available"}

      tar ->
        run_tool(tar, ["-C", cache_dir, "-xf", archive_path], "Could not extract Zig archive")
    end
  end

  defp run_tool(executable, args, error_message) do
    case System.cmd(executable, args, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> {:error, "#{error_message} (exit #{status}): #{String.trim(output)}"}
    end
  end

  defp freebsd_zig_arch do
    :system_architecture
    |> :erlang.system_info()
    |> to_string()
    |> String.split("-")
    |> List.first()
    |> case do
      "amd64" -> "x86_64"
      arch -> arch
    end
  end

  defp compatible_zig?(nil), do: false

  defp compatible_zig?(path) do
    File.exists?(path) and
      match?({version, 0} when version == @zigler_zig_version, zig_version(path))
  end

  defp zig_version(path) do
    case System.cmd(path, ["version"], stderr_to_stdout: true) do
      {version, 0} -> {String.trim(version), 0}
      other -> other
    end
  rescue
    _ -> :error
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w[lib priv guides mix.exs README.md CHANGELOG.md LICENSE]
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: [
        "README.md",
        "CHANGELOG.md",
        "guides/introduction/getting-started.md",
        "guides/introduction/why-volt.md",
        "guides/features/features.md",
        "guides/features/frameworks.md",
        "guides/features/tailwind.md",
        "guides/features/hmr.md",
        "guides/features/code-splitting.md",
        "guides/features/css-modules.md",
        "guides/features/static-assets.md",
        "guides/features/environment-variables.md",
        "guides/features/glob-imports.md",
        "guides/features/plugins.md",
        "guides/features/formatting-and-linting.md",
        "guides/deployment/production-builds.md",
        "guides/migration/from-esbuild.md",
        "guides/cheatsheets/configuration.cheatmd",
        "guides/cheatsheets/cli.cheatmd"
      ],
      groups_for_extras: [
        Introduction: ~r/guides\/introduction\//,
        Features: ~r/guides\/features\//,
        Deployment: ~r/guides\/deployment\//,
        Migration: ~r/guides\/migration\//,
        Cheatsheets: ~r/guides\/cheatsheets\//
      ],
      groups_for_modules: [
        Core: [Volt, Volt.Preload, Volt.Config, Volt.Plugin],
        "Dev Server": [Volt.DevServer, Volt.Watcher, Volt.Dev.ConsoleForwarder],
        "Production Build": [Volt.Builder, Volt.ChunkGraph, Volt.PublicDir],
        "Tailwind CSS": [Volt.Tailwind],
        CSS: [Volt.CSS.Modules],
        Plugins: [
          Volt.Plugin.Vue,
          Volt.Plugin.Svelte,
          Volt.Plugin.React,
          Volt.Plugin.Solid,
          Volt.Plugin.Helpers,
          Volt.PluginRunner
        ],
        JavaScript: [
          Volt.Assets,
          Volt.Env,
          Volt.JS.Runtime,
          Volt.JS.Format
        ],
        Formatting: [Volt.Formatter, Volt.Format],
        "Mix Tasks": [
          Mix.Tasks.Volt.Build,
          Mix.Tasks.Volt.Dev,
          Mix.Tasks.Volt.Lint,
          Mix.Tasks.Volt.Js.Format,
          Mix.Tasks.Volt.Js.Check,
          Mix.Tasks.Volt.Install
        ],
        "Internals: Builder": [
          Volt.Builder.Collector,
          Volt.Builder.Collector.State,
          Volt.Builder.Context,
          Volt.Builder.BuildContext,
          Volt.Builder.Dependencies,
          Volt.Builder.Externals,
          Volt.Builder.Output,
          Volt.Builder.OutputContext,
          Volt.Builder.OutputFile,
          Volt.Builder.Resolver,
          Volt.Builder.Result,
          Volt.Builder.Rewriter,
          Volt.Builder.Writer,
          Volt.HTMLEntry,
          Volt.Pipeline,
          Volt.Pipeline.Result
        ],
        "Internals: Config": [
          Volt.Config.Build,
          Volt.Config.Profile,
          Volt.Config.Server
        ],
        "Internals: CSS": [
          Volt.CSS.AST,
          Volt.CSS.AssetURLRewriter
        ],
        "Internals: Dev Server": [
          Volt.Cache,
          Volt.DevServer.CacheEntry,
          Volt.DevServer.Config
        ],
        "Internals: HMR": [
          Volt.HMR.Boundary,
          Volt.HMR.GlobGraph,
          Volt.HMR.ImportGraph,
          Volt.HMR.Message,
          Volt.HMR.ModuleGraph,
          Volt.HMR.ModuleGraph.Node,
          Volt.HMR.Socket
        ],
        "Internals: JavaScript": [
          Volt.Assets.Query,
          Volt.JS.Asset,
          Volt.JS.AST,
          Volt.JS.Extensions,
          Volt.JS.Helpers,
          Volt.JS.ImportExtractor,
          Volt.JS.ImportExtractor.Result,
          Volt.JS.Patch,
          Volt.JS.PrebundleEntry,
          Volt.JS.PrebundleEntry.Export,
          Volt.JS.PrebundleEntry.Import,
          Volt.JS.Resolution,
          Volt.JS.Resolver,
          Volt.JS.Runtime.Bundler,
          Volt.JS.Runtime.Entry,
          Volt.JS.Runtime.Error,
          Volt.JS.Runtime.Installer,
          Volt.JS.Transforms.AssetURLs,
          Volt.JS.Transforms.DynamicImports,
          Volt.JS.Transforms.DynamicImports.Replacement,
          Volt.JS.Transforms.GlobImports,
          Volt.JS.Transforms.GlobImports.Call,
          Volt.JS.Transforms.GlobImports.File,
          Volt.JS.Transforms.ImportMetaEnv,
          Volt.JS.Transforms.Imports,
          Volt.JS.Transforms.Specifiers,
          Volt.JS.Transforms.Workers,
          Volt.JS.TSConfig,
          Volt.JS.Vendor
        ],
        "Internals: Support": [
          Volt.Application,
          Volt.ETS,
          Volt.Path,
          Volt.Tailwind.Loader,
          Volt.Tailwind.Resolver,
          Volt.URL
        ],
        "Internals: Plugin Options": [
          Volt.Plugin.Solid.CompilerOptions,
          Volt.Plugin.Solid.CompilerOptions.SolidOptions,
          Volt.Plugin.Svelte.CompilerOptions
        ]
      ],
      skip_undefined_reference_warnings_on: ["CHANGELOG.md"]
    ]
  end
end
