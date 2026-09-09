# The command line of a reactive store (Stage H of the plan): `julia -m
# PackageCompiler <verb> <app_dir> [options]`, the verbs `build`, `status`,
# `stop` and `watch`. `build` founds the store when the output holds none —
# then `--package` names the package, its tracked sources are the includes of
# its root file, and `--workload` the script the founding traces — else it
# rebuilds. `watch` builds once, then rebuilds on every change of a tracked
# file until Ctrl-C. A front end with a catalog of its own (the omnet build
# tool) calls the same functions and keeps its catalog.

const CLI_USAGE = """
usage: julia -m PackageCompiler <verb> <app_dir> [options]

  build <app_dir>     found the store when <app_dir> holds none, else rebuild
  status <app_dir>    print the store: the founding, the snapshots, the chain,
                      the server, the growth
  stop <app_dir>      stop the compiler server of the store
  watch <app_dir>     build once, then rebuild on every change of a tracked
                      file until Ctrl-C, which stops the watch and the server

options of a rebuild (the keywords of `materialize_app`):
  --no-server         rebuild in a child process, not the server that stays
  --image=<mode>      how a rebuild writes the image: overlay (default),
                      pages, whole
  --delta-opt=<n>     the optimization level of the delta's code, 0 to 3
                      (default: the build's)
  --found             found the store again now: a whole build
  --compact=<n>,<f>   found again after <n> saves or a growth of <f> of the
                      image since the founding (default: 50,0.25)
  --trim              write the trimmed product beside the bundle too

options of a founding:
  --package=<dir>     the package to build (needed without a store)
  --tracked=<file>=<Module>,...   the tracked files, instead of the includes
                      of the package's root file
  --workload=<file>   the script the founding traces
  --executable=<name>=<main>   the launcher and its entry point (default:
                      the package's name and julia_main)
  --optimization=<n>, --debug-info=<n>, --cpu-target=<target>
                      the image: -O (default 3), -g (default 1), the processor
                      (default native)
"""

struct CliError <: Exception
    message::String
end

# The verb, the app directory and the options of a command line.
function parse_cli(args::Vector{String})
    isempty(args) && throw(CliError("no verb"))
    verb = args[1]
    verb in ("build", "status", "stop", "watch") || throw(CliError("unknown verb `$verb`"))
    length(args) >= 2 || throw(CliError("`$verb` needs the app directory"))
    app_dir = abspath(args[2])
    options = Dict{String, Any}("server" => true, "image" => :overlay, "delta_opt" => -1,
                                "found" => false, "compact" => (50, 0.25), "trim" => false,
                                "package" => nothing, "tracked" => nothing, "workload" => nothing,
                                "executable" => nothing, "optimization" => 3, "debug_info" => 1,
                                "cpu_target" => "native")
    value(argument, name) = argument[length(name) + 2:end]
    for argument in args[3:end]
        if argument == "--no-server"
            options["server"] = false
        elseif startswith(argument, "--image=")
            mode = Symbol(value(argument, "--image"))
            mode in (:whole, :pages, :overlay) || throw(CliError("--image is overlay, pages or whole, not `$mode`"))
            options["image"] = mode
        elseif startswith(argument, "--delta-opt=")
            n = tryparse(Int, value(argument, "--delta-opt"))
            n !== nothing && 0 <= n <= 3 || throw(CliError("--delta-opt takes 0 to 3"))
            options["delta_opt"] = n
        elseif argument == "--found"
            options["found"] = true
        elseif startswith(argument, "--compact=")
            parts = split(value(argument, "--compact"), ',')
            n = length(parts) == 2 ? tryparse(Int, parts[1]) : nothing
            f = length(parts) == 2 ? tryparse(Float64, parts[2]) : nothing
            n !== nothing && f !== nothing || throw(CliError("--compact takes <saves>,<growth>, such as 50,0.25"))
            options["compact"] = (n, f)
        elseif argument == "--trim"
            options["trim"] = true
        elseif startswith(argument, "--package=")
            options["package"] = abspath(value(argument, "--package"))
        elseif startswith(argument, "--tracked=")
            tracked = Pair{String, String}[]
            for entry in split(value(argument, "--tracked"), ',')
                parts = split(entry, '='; limit = 2)
                length(parts) == 2 || throw(CliError("--tracked takes <file>=<Module>,..."))
                push!(tracked, abspath(String(parts[1])) => String(parts[2]))
            end
            options["tracked"] = tracked
        elseif startswith(argument, "--workload=")
            options["workload"] = abspath(value(argument, "--workload"))
        elseif startswith(argument, "--executable=")
            parts = split(value(argument, "--executable"), '='; limit = 2)
            length(parts) == 2 || throw(CliError("--executable takes <name>=<main>"))
            options["executable"] = String(parts[1]) => String(parts[2])
        elseif startswith(argument, "--optimization=")
            n = tryparse(Int, value(argument, "--optimization"))
            n !== nothing && 0 <= n <= 3 || throw(CliError("--optimization takes 0 to 3"))
            options["optimization"] = n
        elseif startswith(argument, "--debug-info=")
            n = tryparse(Int, value(argument, "--debug-info"))
            n !== nothing && 0 <= n <= 2 || throw(CliError("--debug-info takes 0 to 2"))
            options["debug_info"] = n
        elseif startswith(argument, "--cpu-target=")
            options["cpu_target"] = value(argument, "--cpu-target")
        else
            throw(CliError("unknown option `$argument`"))
        end
    end
    return verb, app_dir, options
end

# The build of `build` and of `watch`: the founding or the rebuild.
function cli_build(app_dir::String, options::Dict{String, Any})
    store = _reactive_store_dir(app_dir)
    rebuild = isfile(joinpath(store, REACTIVE_STORE_FILE))
    package_dir = options["package"]
    if package_dir === nothing
        rebuild || throw(CliError("$app_dir holds no store: a founding needs --package=<dir>"))
        package_dir = String(TOML.parsefile(joinpath(store, REACTIVE_STORE_FILE))["config"]["package_dir"])
    end
    keywords = (server = options["server"], image = options["image"], delta_opt = options["delta_opt"],
                founding = options["found"], compact = options["compact"],
                trim = options["trim"] ? :on : :off)
    if rebuild && !options["found"]
        return materialize_app(package_dir, app_dir; keywords...)
    end
    executable = options["executable"]
    if executable === nothing
        name = get(TOML.parsefile(joinpath(package_dir, "Project.toml")), "name", basename(package_dir))
        executable = String(name) => "julia_main"
    end
    tracked = something(options["tracked"], Pair{String, String}[])
    return materialize_app(package_dir, app_dir;
                           tracked, workload = options["workload"], executables = [executable],
                           force = true, incremental = true, include_lazy_artifacts = true,
                           cpu_target = options["cpu_target"],
                           sysimage_build_args = `-O$(options["optimization"]) -g$(options["debug_info"])`,
                           keywords...)
end

# The command line: the exit code.
function cli(args::Vector{String})::Cint
    verb, app_dir, options = try
        parse_cli(args)
    catch error
        error isa CliError || rethrow()
        println(stderr, "PackageCompiler: ", error.message)
        println(stderr)
        print(stderr, CLI_USAGE)
        return 2
    end
    try
        if verb == "status"
            return print_store_status(stdout, app_dir) ? 0 : 1
        elseif verb == "stop"
            stopped = stop_server(app_dir)
            println(stopped ? "the compiler server of $app_dir was stopped" : "no compiler server runs for $app_dir")
            return 0
        elseif verb == "build"
            cli_build(app_dir, options)
            return 0
        elseif verb == "watch"
            cli_build(app_dir, options)
            options["found"] = false
            watch_app(app_dir, () -> cli_build(app_dir, options))
            return 0
        end
    catch error
        error isa CliError || rethrow()
        println(stderr, "PackageCompiler: ", error.message)
        return 2
    end
    return 0
end

function (@main)(args::Vector{String})::Cint
    return cli(args)
end
