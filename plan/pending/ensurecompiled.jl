# Find out what the 113 seconds of `ensurecompiled` are made of.
#
# `ensurecompiled` starts Julia on the fresh base system image and runs
# `using Pkg; Pkg.precompile()`. The fresh base holds no stdlib, so Julia must
# compile Pkg from source. `get_julia_cmd` also passes `--pkgimages=no`.
#
# The question: does the second build pay this again, or does the depot keep the
# cache the first build wrote?

using PackageCompiler
const PC = PackageCompiler
using Pkg: Pkg

package_dir = abspath(ENV["PC_PACKAGE_DIR"])
cpu_target = get(ENV, "PC_CPU_TARGET", "native")

ctx = PC.create_pkg_context(package_dir)
Pkg.instantiate(ctx, verbose = false, allow_autoprecomp = false)
project = dirname(ctx.env.project_file)
packages = [ctx.env.pkg.name]

base = PC.create_fresh_base_sysimage(; cpu_target, sysimage_build_args = ``)
println("### base sysimage: $base")
flush(stdout)

splitter = Sys.iswindows() ? ';' : ':'
function timed(label, cmd)
    cmd = addenv(cmd, "JULIA_LOAD_PATH" => "$project$(splitter)@stdlib")
    t = @elapsed run(pipeline(cmd; stdout = devnull, stderr = devnull))
    println("### $label: $(round(t, digits=1)) s")
    flush(stdout)
    return t
end

# Just starting Julia on the base sysimage, with nothing to load.
timed("start only, run 1", `$(PC.get_julia_cmd()) --sysimage=$base -e ''`)
timed("start only, run 2", `$(PC.get_julia_cmd()) --sysimage=$base -e ''`)

# `using Pkg` is what `ensurecompiled` pays before it precompiles anything.
timed("using Pkg, run 1", `$(PC.get_julia_cmd()) --sysimage=$base -e 'using Pkg'`)
timed("using Pkg, run 2", `$(PC.get_julia_cmd()) --sysimage=$base -e 'using Pkg'`)
timed("using Pkg, run 3", `$(PC.get_julia_cmd()) --sysimage=$base -e 'using Pkg'`)

# The whole step, twice. If the second is much cheaper, the cost is paid once per
# base system image and not once per build.
println("### full ensurecompiled, run 1")
t1 = @elapsed PC.ensurecompiled(project, packages, base)
println("### full ensurecompiled run 1: $(round(t1, digits=1)) s")
flush(stdout)
println("### full ensurecompiled, run 2")
t2 = @elapsed PC.ensurecompiled(project, packages, base)
println("### full ensurecompiled run 2: $(round(t2, digits=1)) s")
