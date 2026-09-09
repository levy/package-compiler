# Reactive materialization: rebuild an application bundle after a source edit
# for about the cost of the edit's cone, on a Julia whose runtime supports
# JULIA_REACTIVE_REUSE (the `reactive-compiler` branch).
#
# The system is described in the `julia-reactive` checkout:
# `contrib/reactive-compiler/doc/architecture.md` says what is built and why,
# and `contrib/reactive-compiler/plan/pending/reactive-materialization.md`
# holds the chronological record and the measurements.
# The harness — the ledger, the classifier, the apply, the trace precompile,
# the save and the server — is the stdlib `ReactiveCompiler` of that Julia,
# in every image it builds; this file is a client of its protocol.


# The harness of the reactive compiler: the stdlib `ReactiveCompiler` of the
# reactive Julia, in its system image, found by its uuid so that no
# environment has to name it; a plain build on another Julia never asks.
const REACTIVE_COMPILER_UUID = Base.UUID("1dda119b-71a3-45fb-bd14-d17b1eb16859")
_reactive_compiler() = Base.require(Base.PkgId(REACTIVE_COMPILER_UUID, "ReactiveCompiler"))
_reactive_compiler_load() = "const ReactiveCompiler = Base.require(Base.PkgId(Base.UUID(\"1dda119b-71a3-45fb-bd14-d17b1eb16859\"), \"ReactiveCompiler\"))"

const REACTIVE_STORE_DIR = "reactive-store"
const REACTIVE_STORE_FILE = "store.toml"
const REACTIVE_TRACE_FILE = "trace.jl"

_reactive_store_dir(app_dir) = joinpath(abspath(app_dir), REACTIVE_STORE_DIR)
_reactive_snapshot_dir(store, id) = joinpath(store, "s$id")
_reactive_sysimage(app_dir) = joinpath(abspath(app_dir), "lib", "julia", "sys." * Libdl.dlext)
_reactive_trace(store) = joinpath(store, REACTIVE_TRACE_FILE)

"""
    materialize_app(package_dir, app_dir; tracked, workload = nothing, kwargs...)

Build the application the way `create_app` does, but keep a store of the
emitted text objects, of the tracked sources and of the trace inside the
bundle — and when the store already holds a snapshot, rebuild only the delta
of the edit.

- With no store: trace the workload in a throwaway process, run
  `create_app(package_dir, app_dir; kwargs...)` with the statements of the
  trace, and found the store as snapshot 1 with the trace as
  `reactive-store/trace.jl`.
- With a store: spawn one child that boots from the bundle's own system
  image with `JULIA_REACTIVE_REUSE=1`, applies the changes of the tracked
  files, precompiles the statements of the trace, and emits the delta; then
  link the text objects of every snapshot in front of the delta into a fresh
  system image. Only `lib/julia/sys.<ext>` of the bundle changes.

`tracked` is a vector of `file => module` pairs: a source file to watch, and
the dotted path of the module whose `include` loads it — the empty path for
the root file of the package, whose top level is the `module` block itself.
`workload` is a file that calls the program: the founding traces it, and
`refresh_trace` traces it again from the current image. No build executes
it. The trace is the set of roots of the image: a statement that an edit
invalidated is inferred again by the rebuild child, and a specialization
that no statement names is compiled by the binary at run time. On a rebuild
`tracked` names the files to track now — a file that joined the program is
added, a removed one leaves — and without it the list of the previous
snapshot stays; the workload and the keyword arguments of `create_app` are
read from the store (`cpu_target`, `sysimage_build_args` are recorded; the
bundle steps do not run again). `precompile_execution_file` is refused: the
workload is the one script; `precompile_statements_file` joins the trace.

Both builds write the reactive image format (`reactive_image = true`, version
3): one function table in id order, one section per function, and a link with
`--gc-sections` that drops every function the table does not name. A rebuild
keeps the ids of the functions it reuses and drops the rest, so the image does
not grow with the edits. The format holds one CPU target, and a rebuild from
an image of the stock format is refused.

A rebuild classifies every changed top-level expression with an id of the
change catalog of the plan (see the stdlib `ReactiveCompiler`), and refuses the ones
that only a founding build applies: a module option, a new dependency, a
type that an untracked file names, a changed module header, an `include` of
an untracked file. A refusal raises with the reasons, and leaves the store
and the bundle as they were.

This needs the reactive Julia: a rebuild on a stock Julia refuses.
"""
function materialize_app(package_dir::String, app_dir::String;
                         tracked::Vector{Pair{String, String}} = Pair{String, String}[],
                         workload::Union{Nothing, String} = nothing,
                         incremental::Bool = true,
                         precompile_statements_file::Union{String, Vector{String}} = String[],
                         cpu_target::String = default_app_cpu_target(),
                         sysimage_build_args::Cmd = ``,
                         server::Bool = get(ENV, "JULIA_REACTIVE_SERVER", "") == "1",
                         delta_opt::Int = parse(Int, get(ENV, "JULIA_REACTIVE_DELTA_OPT", "-1")),
                         kwargs...)
    store = _reactive_store_dir(app_dir)
    if isfile(joinpath(store, REACTIVE_STORE_FILE)) && isfile(_reactive_sysimage(app_dir))
        -1 <= delta_opt <= 3 || error("materialize_app: `delta_opt` is 0 to 3, or -1 for the build's level, not ", delta_opt)
            return _materialize_delta(app_dir, store, tracked; server, trim, image, delta_opt)
    end
    incremental ||
        error("materialize_app: the trace runs from the image of this process; `incremental = false` is not supported")
    haskey(kwargs, :precompile_execution_file) &&
        error("materialize_app: pass the script through `workload`; its trace is the store's trace.jl")
end

                           tracked, workload, precompile_statements_file, cpu_target,
                           sysimage_build_args, kwargs...)
    package_dir = abspath(package_dir)
    files = [abspath(file) for (file, _) in tracked]
    roots = [root for (_, root) in tracked]
    for file in files
        isfile(file) || error("materialize_app: no tracked file $file")
    end
    workload === nothing || isfile(workload) ||
        error("materialize_app: no workload file $workload")
    for file in precompile_statements_file
        isfile(file) || error("materialize_app: no statements file $file")
    end
    ctx = create_pkg_context(package_dir)
    package_name = ctx.env.pkg.name
    executables = get(kwargs, :executables, nothing)
    executables === nothing && (executables = [package_name => "julia_main"])
    # The trace: the workload in a throwaway process, from the image of this
    # process and the source-only cache, so that every specialization it
    # executes is compiled there and recorded. The entries of the executables
    # are roots too: `create_app` precompiles them in the founding, and the
    # rebuild must keep them valid.
    Pkg.instantiate(ctx, verbose = true, allow_autoprecomp = false)
    base_sysimage = unsafe_string(Base.JLOptions().image_file)
    statements = String["precompile(Tuple{typeof($package_name.$julia_main)})"
                        for (_, julia_main) in executables]
    if workload !== nothing
        ensurecompiled(package_dir, [package_name], base_sysimage)
        tracefile = run_precompilation_script(package_dir, base_sysimage, abspath(workload), mktempdir())
        append!(statements, _reactive_statements(tracefile))
    end
    for file in precompile_statements_file
        append!(statements, _reactive_statements(file))
    end
    statements = _reactive_roots(statements)
    # `create_app` clears `app_dir`, so the archive and the trace land outside
    # it and the store is founded after the build.
    trace = tempname() * "-trace.jl"
    write(trace, join(statements, '\n') * "\n")
    archive = tempname() * "-reactive.a"
    # Incremental: the app image grows from the image of this process, the
    # one the trace ran from. The image is written in the reactive format: a
    # rebuild reuses its functions by id and by name, and the link drops the
    # functions that lost their id.
    # The founding writes whole, whatever the environment of a gate says.
    create_app(package_dir, app_dir;
               incremental = true, cpu_target,
               sysimage_build_args = Cmd(vcat(String.(sysimage_build_args.exec), ["--reactive-image=whole"])),
               keep_object_archive = archive,
    snapshot = _reactive_snapshot_dir(store, 1)
    mkpath(snapshot)
    _reactive_extract_text(archive, snapshot)
    rm(archive)
    mv(trace, _reactive_trace(store); force = true)
    _reactive_copy_sources(files, snapshot)
    _reactive_write_reads(files, snapshot)
    config = Dict{String, Any}(
        "package_dir" => package_dir,
        "cpu_target" => cpu_target,
        "sysimage_build_args" => collect(sysimage_build_args.exec),
        "tracked" => [Dict{String, Any}("file" => file, "root" => root)
                      for (file, root) in zip(files, roots)],
    _reactive_save(store, Dict{String, Any}("config" => config,
                                            "snapshot" => Any[_reactive_entry(1)]))
    @info "materialize_app: the store is founded" store statements = length(statements)
    return app_dir
end

"""
    refresh_trace(app_dir)

Trace the workload again from the current image of the bundle, and replace
`reactive-store/trace.jl` with the union of the old statements and the new
ones. A throwaway process boots from the image and runs the workload under
`--trace-compile`: what the image already compiles is not recorded, so the
new statements are the roots that the edits since the founding added. An
old statement that no longer precompiles from the image is dropped. Run it
after a rebuild whose edit calls new code, then rebuild once more.
"""
function refresh_trace(app_dir::String)
    store = _reactive_store_dir(app_dir)
    isfile(joinpath(store, REACTIVE_STORE_FILE)) && isfile(_reactive_sysimage(app_dir)) ||
        error("refresh_trace: no store under $app_dir")
    config = TOML.parsefile(joinpath(store, REACTIVE_STORE_FILE))["config"]
    workload = config["workload"]
    isempty(workload) && error("refresh_trace: the store of $app_dir has no workload")
    isfile(workload) || error("refresh_trace: no workload file $workload")
    trace = _reactive_trace(store)
    old = isfile(trace) ? _reactive_statements(trace) : String[]
    dir = mktempdir()
    kept_file = joinpath(dir, "kept.jl")
    script = joinpath(dir, "refresh.jl")
    write(script, _reactive_refresh_script(workload, trace, kept_file))
    tracefile = run_precompilation_script(config["package_dir"], _reactive_sysimage(app_dir), script, dir)
    kept = _reactive_roots(_reactive_statements(kept_file))
    new = _reactive_statements(tracefile)
    statements = _reactive_roots(vcat(kept, new))
    write(trace, join(statements, '\n') * "\n")
    @info "refresh_trace: the trace is refreshed" statements = length(statements) kept = length(kept) dropped = length(old) - length(kept) added = length(statements) - length(kept)
    return trace
end

# The refresh process: the workload first, so that the trace records what the
# image does not compile; then the old statements, kept when they still
# precompile from this image.
function _reactive_refresh_script(workload, trace, kept_file)
    io = IOBuffer()
    println(io, "# generated by PackageCompiler.refresh_trace — the trace child")
    println(io, "include($(repr(workload)))")
    println(io, _reactive_compiler_load())
    println(io, "ReactiveCompiler.rc_keep_statements($(repr(trace)), $(repr(kept_file)))")
    return String(take!(io))
end

_reactive_statements(file) = String[line for line in eachline(file) if startswith(line, "precompile(")]

# The roots among the statements of a trace: each once, and none of `Main`.
# A workload script runs in the Main of the trace process, so its own
# functions and closures are traced there; no rebuild child can precompile
# them, and the binary never calls them.
_reactive_roots(statements) = unique!(filter(line -> !occursin(r"\bMain\.", line), statements))

                            image::Symbol = :whole, delta_opt::Int = -1)
    data = TOML.parsefile(joinpath(store, REACTIVE_STORE_FILE))
    config = data["config"]
    snapshots = sort(data["snapshot"]; by = s -> s["id"])
    id = snapshots[end]["id"] + 1
    parent = _reactive_snapshot_dir(store, snapshots[end]["id"])
    snapshot = _reactive_snapshot_dir(store, id)
    mkpath(snapshot)
    sysimage = _reactive_sysimage(app_dir)
    old_files = String[entry["file"] for entry in config["tracked"]]
    old_roots = String[entry["root"] for entry in config["tracked"]]
    old_copies = String[joinpath(parent, "source", string(index, "-", basename(file)))
                        for (index, file) in enumerate(old_files)]
    files = isempty(tracked) ? old_files : String[abspath(file) for (file, _) in tracked]
    roots = isempty(tracked) ? old_roots : String[root for (_, root) in tracked]
    for file in files
        isfile(file) || error("materialize_app: no tracked file $file")
    end
    old_reads = _reactive_read_reads(joinpath(parent, "reads.txt"))
    reads = joinpath(snapshot, "reads.txt")
    refusal = joinpath(snapshot, "refusal.txt")
    trace = _reactive_trace(store)
    isfile(trace) || error("materialize_app: the store $store has no $REACTIVE_TRACE_FILE; found it again")
    script = joinpath(snapshot, "child.jl")
    write(script, _reactive_child_script(old_files, _reactive_paths(old_roots), old_copies,
    archive = joinpath(snapshot, "delta.a")
    next_sysimage = sysimage * ".next"
    base = snapshots[end]["id"]
    if server
        # The server loaded the image of its base snapshot; its delta holds
        # every change since, so the link takes the texts of the base chain
        # and the delta.
        session = _reactive_server_ensure(app_dir, store, config, snapshots, image, delta_opt)
        base = session["base"]
        spec = joinpath(snapshot, "spec.toml")
        _reactive_write_spec(spec, old_files, old_roots, old_copies, files, roots,
                             joinpath(parent, "reads.txt"), reads, refusal, trace)
        reply = _reactive_request(session["socket"], "apply " * spec)
        if startswith(reply, "refused")
            reasons = isfile(refusal) ? read(refusal, String) : reply
            rm(snapshot; recursive = true, force = true)
            error("materialize_app: the rebuild is refused; a founding build applies the change:\n", reasons)
        end
        startswith(reply, "ok") || error("materialize_app: the server answered `", reply, "`; see ", joinpath(store, "server.log"))
        elapsed = @elapsed begin
            reply = _reactive_request(session["socket"], "save " * archive)
            startswith(reply, "ok") || error("materialize_app: the save answered `", reply, "`; see ", joinpath(store, "server.log"))
        end
    else
    ancestors = _reactive_link_texts(store, snapshots, base)
    # base it loads (Stage F); the founding above writes whole. The reuse,
    # the way of the write and the delta's level are flags of the child.
    elapsed = @elapsed begin
        try
            create_sysimage(nothing;
                            sysimage_path = next_sysimage,
                            project = config["package_dir"],
                            incremental = true,
                            base_sysimage = sysimage,
                            cpu_target = config["cpu_target"],
                            script,
                            sysimage_build_args = Cmd(vcat(String.(config["sysimage_build_args"]),
                                                           _reactive_flags(image, delta_opt))),
                            extra_object_files = ancestors,
                            keep_object_archive = archive,
                            reactive_image = true,
                            soname = basename(sysimage),
                            # The previous image carries the Main bindings of its
                            # own build; a new import would only warn. The child
                            # resolves modules through `Base.loaded_modules`.
                            import_into_main = false)
        catch e
            e isa ProcessFailedException && isfile(refusal) || rethrow()
            reasons = read(refusal, String)
            rm(snapshot; recursive = true, force = true)
            rm(next_sysimage; force = true)
            error("materialize_app: the rebuild is refused; a founding build applies the change:\n", reasons)
        end
    end
    end
    _reactive_extract_text(archive, snapshot)
    rm(archive)
    _reactive_copy_sources(files, snapshot)
    config["tracked"] = [Dict{String, Any}("file" => file, "root" => root)
                         for (file, root) in zip(files, roots)]
    entry = _reactive_entry(id)
    entry["base"] = base
    push!(data["snapshot"], entry)
    _reactive_save(store, data)
    return app_dir
end

# The module path of a dotted root: the empty path for the root file.
_reactive_paths(roots) = Vector{Symbol}[isempty(root) ? Symbol[] : Symbol.(split(root, '.')) for root in roots]

# The top level of the rebuild child. Everything that varies is a literal
# here; the function bodies are the stdlib's, compiled in the image.
function _reactive_child_script(old_files, old_roots, old_copies, files, roots, old_reads,
    io = IOBuffer()
    println(io, "# generated by PackageCompiler.materialize_app — the rebuild child")
    println(io, _reactive_compiler_load())
    println(io, "rc_state = try")
    println(io, "    ReactiveCompiler.rc_apply_tracked($(repr(old_files)), $(repr(old_roots)), $(repr(old_copies)),")
    println(io, "                     $(repr(files)), $(repr(roots)),")
    println(io, "                     $(repr(old_reads)), $(repr(reads)), $(repr(refusal)))")
    println(io, "catch e")
    println(io, "    e isa ReactiveCompiler.RcRefusal || rethrow()")
    println(io, "    exit(3)")
    println(io, "end")
    println(io, "ReactiveCompiler.rc_precompile_trace($(repr(trace)))")
    println(io, "ReactiveCompiler.rc_report_new(rc_state)")
    # A global of Main stays in the image: the set of every method instance
    # would root the dead ones.
    println(io, "rc_state = nothing")
        println(io, "        ReactiveCompiler.rc_save($(repr(trimmed)); trim = true, overrides = $(repr(overrides)))")
    return String(take!(io))
end

# The files that a top-level expression of a tracked file can read, with the
# hash of their content, as `<hash> <path>` lines: the child compares them
# with the files of the next rebuild. The founding writes the listing the
# way the child does.
function _reactive_write_reads(files, snapshot)
    reads = Tuple{String, String}[]
    for file in files
        diff = _reactive_compiler().ReactiveSourceDiff
        for entry in diff.file_entries(read(file, String), file)
            for path in diff.read_paths(entry.expr, dirname(file))
                push!(reads, (path, string(hash(read(path, String)); base = 16)))
            end
        end
    end
    unique!(reads)
    open(joinpath(snapshot, "reads.txt"), "w") do io
        for (path, h) in reads
            println(io, h, " ", path)
        end
    end
    return nothing
end

function _reactive_read_reads(listing)
    reads = Tuple{String, String}[]
    isfile(listing) || return reads
    for line in eachline(listing)
        parts = split(line, " "; limit = 2)
        length(parts) == 2 && push!(reads, (String(parts[2]), String(parts[1])))
    end
    return reads
end

# The text objects of the archive, extracted into the snapshot; the heap and
# the tables of an old build are never linked again.
function _reactive_extract_text(archive, dir)
    members = split(read(`ar t $archive`, String))
    texts = String[String(m) for m in members if startswith(m, "text") && endswith(m, ".o")]
    isempty(texts) || run(Cmd(`ar x $(abspath(archive)) $texts`; dir))
    return nothing
end

_reactive_texts(dir) = String[joinpath(dir, name) for name in sort(readdir(dir))
                              if startswith(name, "text") && endswith(name, ".o")]

# The text objects that the image of a new snapshot links: the founding's,
# then the delta of every snapshot on the base chain of `base`, the snapshot
# whose image the writer loaded. A chain entry's base is the snapshot before
# it; the server's base is the snapshot it started from.
function _reactive_link_texts(store, snapshots, base)
    byid = Dict{Int, Any}(s["id"] => s for s in snapshots)
    founding = snapshots[1]["id"]
    chain = Int[]
    id = base
    while id != founding
        push!(chain, id)
        id = get(byid[id], "base", id - 1)
    end
    texts = _reactive_texts(_reactive_snapshot_dir(store, founding))
    for id in reverse(chain)
        append!(texts, _reactive_texts(_reactive_snapshot_dir(store, id)))
    end
    return texts
end

# ── the compiler server ──────────────────────────────────────────────────────

_reactive_server_session(store) = joinpath(store, "server.toml")

# A Unix socket path holds 107 bytes; a store path can be longer. The socket
# sits in the temp directory under a name derived from the store.
_reactive_server_socket(store) = joinpath(tempdir(), "jlrc-" * bytes2hex(sha256(store))[1:16] * ".sock")

function _reactive_sockaddr(path::String)
    length(path) < 108 || error("materialize_app: the socket path is too long: ", path)
    addr = zeros(UInt8, 110)
    addr[1] = 0x01   # AF_UNIX
    copyto!(addr, 3, codeunits(path), 1, length(path))
    return addr
end

# One request to the server: connect, one line, the reply line, close. An
# empty reply when the socket does not answer and `quiet` is set.
function _reactive_request(socket::String, line::String; quiet::Bool = false)
    fd = ccall(:socket, Cint, (Cint, Cint, Cint), 1, 1, 0)
    fd < 0 && error("materialize_app: socket: ", Libc.strerror())
    addr = _reactive_sockaddr(socket)
    if ccall(:connect, Cint, (Cint, Ptr{UInt8}, UInt32), fd, addr, length(addr)) != 0
        reason = Libc.strerror()
        ccall(:close, Cint, (Cint,), fd)
        quiet && return ""
        error("materialize_app: cannot connect to the server socket ", socket, ": ", reason)
    end
    data = codeunits(line * "\n")
    offset = 0
    while offset < length(data)
        n = ccall(:write, Cssize_t, (Cint, Ptr{UInt8}, Csize_t), fd, pointer(data, offset + 1), length(data) - offset)
        n > 0 || (ccall(:close, Cint, (Cint,), fd); error("materialize_app: write to the server: ", Libc.strerror()))
        offset += n
    end
    reply = UInt8[]
    buffer = Vector{UInt8}(undef, 4096)
    while true
        n = ccall(:read, Cssize_t, (Cint, Ptr{UInt8}, Csize_t), fd, buffer, length(buffer))
        n > 0 || break
        append!(reply, view(buffer, 1:n))
    end
    ccall(:close, Cint, (Cint,), fd)
    return String(strip(String(reply)))
end

function _reactive_write_spec(spec, old_files, old_roots, old_copies, files, roots, old_reads, reads, refusal, trace)
    open(spec, "w") do io
        TOML.print(io, Dict{String, Any}(
            "old_files" => old_files, "old_roots" => old_roots, "old_copies" => old_copies,
            "files" => files, "roots" => roots, "old_reads" => old_reads,
            "reads_out" => reads, "refusal_out" => refusal, "trace" => trace))
    end
    return nothing
end

# The flags of a rebuild child or a server: the reuse of the loaded image,
# the way the image is written, and the delta's optimization level (none
# for the build's own).
function _reactive_flags(image::Symbol, delta_opt::Int)
    flags = ["--reactive-reuse", "--reactive-image=$image"]
    delta_opt < 0 || push!(flags, "--reactive-delta-opt=$delta_opt")
    return flags
end

# The server of the store: the one that answers, else a new one from the
# image of the last snapshot. The session file names its socket, its base
# snapshot and its pid.

function _reactive_server_ensure(app_dir, store, config, snapshots, image = :whole, delta_opt::Int = -1)
    session_file = _reactive_server_session(store)
    socket = _reactive_server_socket(store)
    if isfile(session_file)
        session = TOML.parsefile(session_file)
        status = _reactive_request(session["socket"], "status"; quiet = true)
        if startswith(status, "ok")
            # The memory of the server: the code of every save and every
            # old method version stay until a restart. Past a number of
            # saves or a resident size the builder restarts it from the
            saves = parse(Int, something(match(r"saves=(\d+)", status), ["0"])[1])
            rss_kb = parse(Int, something(match(r"rss_kb=(\d+)", status), ["0"])[1])
            max_saves = parse(Int, get(ENV, "JULIA_REACTIVE_SERVER_SAVES", "200"))
            max_rss_kb = parse(Int, get(ENV, "JULIA_REACTIVE_SERVER_RSS_KB", string(16 * 1024 * 1024)))
            same_image = get(session, "image", "whole") == string(image) &&
                         get(session, "delta_opt", -1) == delta_opt
                return session
            end
            _reactive_request(session["socket"], "quit"; quiet = true)
        else
            @warn "materialize_app: the server of the store does not answer; a new one starts" session
        end
        rm(session_file; force = true)
    end
    base = snapshots[end]["id"]
    log = joinpath(store, "server.log")
    sysimage = _reactive_sysimage(app_dir)
    # The server is the runtime's: `--reactive-server` makes the process
    # serve on the socket from the image of the last snapshot, in the output
    # mode of a rebuild child, with the stdlib `ReactiveCompiler` of the image.
    cmd = with_image_threads(`$(get_julia_cmd()) --cpu-target=$(config["cpu_target"])
        $(Cmd(String.(config["sysimage_build_args"]))) --sysimage=$sysimage
        --project=$(config["package_dir"]) --output-o=$(joinpath(store, "server.a")) --threads=1
        $(Cmd(_reactive_flags(image, delta_opt))) --reactive-server=$socket`)
    process = run(pipeline(detach(cmd); stdout = log, stderr = log); wait = false)
    deadline = time() + 300
    while time() < deadline
        ispath(socket) && startswith(_reactive_request(socket, "status"; quiet = true), "ok") && break
        process_exited(process) && error("materialize_app: the server exited at start; see ", log)
        sleep(0.5)
    end
    time() < deadline || error("materialize_app: the server did not answer within 300 s; see ", log)
                                "image" => string(image), "overlay" => "", "delta_opt" => delta_opt,
                                "started" => Libc.strftime("%Y-%m-%d %H:%M:%S", time()))
    open(session_file, "w") do io
        TOML.print(io, session)
    end
    @info "materialize_app: the server started" pid = session["pid"] base
    return session
end

    println(io, _reactive_compiler_load())
    println(io, "ReactiveCompiler.trim_entrypoints!()   # the entry points of the trim")
            --strip-ir --strip-metadata --experimental --trim=safe --threads=1
            --reactive-reuse --reactive-trim-memo=$(joinpath(store, "trim-memo.txt")) $script`)
"""
    store_status(app_dir) -> NamedTuple, or nothing

What the reactive store of `app_dir` holds: `founding_size`, `snapshots` (the
ids), `chain` (the overlays of the bundle, as `name => size`), `session` (the
server's session as a `Dict`, or `nothing`), `growth` (the fraction the image
grew since the founding), `tracked` (the files), `workload`. Nothing without
a store.
"""
function store_status(app_dir::String)
    store = _reactive_store_dir(app_dir)
    isfile(joinpath(store, REACTIVE_STORE_FILE)) || return nothing
    data = TOML.parsefile(joinpath(store, REACTIVE_STORE_FILE))
    config = data["config"]
    snapshots = sort(Int[s["id"] for s in data["snapshot"]])
    lib = dirname(_reactive_sysimage(app_dir))
    chain = Pair{String, Int}[name => (isfile(joinpath(lib, name)) ? filesize(joinpath(lib, name)) : 0)
                              for name in _reactive_chain_read(app_dir)]
    session_file = _reactive_server_session(store)
    session = nothing
    if isfile(session_file)
        session = TOML.parsefile(session_file)
        session["alive"] = startswith(_reactive_request(session["socket"], "status"; quiet = true), "ok")
    end
    return (founding_size = get(config, "founding_size", 0),
            image_size = filesize(_reactive_sysimage(app_dir)),
            snapshots = snapshots, chain = chain, session = session,
            growth = _reactive_growth(app_dir, config),
            tracked = String[e["file"] for e in config["tracked"]],
            workload = get(config, "workload", ""))
end

"""
    stop_server(app_dir)

Stop the compiler server of the store of `app_dir`, if one runs.
"""
function stop_server(app_dir::String)
    store = _reactive_store_dir(app_dir)
    session_file = _reactive_server_session(store)
    isfile(session_file) || return false
    session = TOML.parsefile(session_file)
    reply = _reactive_request(session["socket"], "quit"; quiet = true)
    rm(session_file; force = true)
    rm(session["socket"]; force = true)
    return startswith(reply, "ok")
end

"""
    server_status(app_dir) -> String

The status line of the compiler server of the store of `app_dir`: the world,
the saves and the resident size; an empty string without a server.
"""
function server_status(app_dir::String)
    store = _reactive_store_dir(app_dir)
    isfile(_reactive_server_session(store)) || return ""
    session = TOML.parsefile(_reactive_server_session(store))
    return _reactive_request(session["socket"], "status"; quiet = true)
end

function _reactive_copy_sources(files, snapshot)
    source = joinpath(snapshot, "source")
    mkpath(source)
    for (index, file) in enumerate(files)
        cp(file, joinpath(source, string(index, "-", basename(file))); force = true)
    end
    return nothing
end

_reactive_entry(id) = Dict{String, Any}(
    "id" => id,
    "created" => Libc.strftime("%Y-%m-%d %H:%M:%S", time()))

function _reactive_save(store, data)
    open(joinpath(store, REACTIVE_STORE_FILE), "w") do io
        TOML.print(io, data)
    end
    return nothing
end
