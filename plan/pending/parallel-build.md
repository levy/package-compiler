# Make a PackageCompiler build use more than one CPU

## Goal

A build of an app or a sysimage must use the CPUs that the machine has. Today a
build spends most of its wall clock in one Julia child process that runs on one
core.

## What the machine measured

Machine: 32 CPUs. The measurements ran in the shared build lane,
`nice -n 10 taskset -c 16-23` (8 CPUs), under a memory cap.

The `--output-o` child that builds the core compiler ran for 401 seconds and
used 400 seconds of CPU time. The ratio of CPU time to wall time is 0.99. The
process holds 3 operating-system threads and 311 MB. It is serial.

## The phases of a native build, with a warm base cache

`examples/MyApp`, `cpu_target = "native"`, in the 8-CPU build lane. Another agent
built on the same machine, so read the wall times as an upper bound.

| Phase | Time |
| --- | --- |
| instantiate the app | 1.4 s |
| bundle the libraries | 2.5 s |
| bundle the artifacts | 1.9 s |
| the other bundle steps | 2.1 s |
| `create_fresh_base_sysimage` | **0.0 s** (the cache answered) |
| `ensurecompiled` | **113.1 s** |
| `run_precompilation_script` | **41.5 s** |
| `create_sysimg_object_file` | **342.7 s** |
| link the system image | 1.7 s |
| build the executable | 0.9 s |
| **total** | **~509 s** |

Three numbers decide the work:

1. `create_sysimg_object_file` is **67%** of the build.
2. `ensurecompiled` is **22%**.
3. Everything that copies files is **1.6%**.

The cache of the base system image works: 0.0 s in place of several minutes.

`ensurecompiled` costs 113 s but reports that it precompiled the packages in 24
seconds. The rest is the start of Julia on the fresh base system image. That
image holds no compiled code for Pkg, so `using Pkg` compiles Pkg from source.
`get_julia_cmd` passes `--pkgimages=no` to every child, which is why. This is
still open work.

`create_sysimg_object_file` used 691.8 seconds of CPU in 316 seconds of wall
clock, a ratio of 2.18 in a lane of 8 CPUs. The phase is a serial front that
infers types and a parallel tail that writes the object file. Only the tail can
take more cores.

## The multi-target build is the other big cost

The first measurement used `default_app_cpu_target()`, which names three
processors and `clone_all`. Its core-compiler step alone ran **401 seconds** and
used **400 seconds of CPU**. The system image it writes is 225 MB. The native
system image is 165 MB. The multi-target build compiles the same code three
times, and that work is serial.

The user asked for native only. `default_app_cpu_target()` now answers `native`.
`portable_app_cpu_target()` keeps the old multi-target string for an app that
ships to an unknown machine.

## The result, stated honestly

A whole `create_app` of `examples/MyApp`, run A, B, A, B against the checkout
before this work, both for the native target and both with a warm cache:

| Run | Time |
| --- | --- |
| old | 148.3 s |
| new | 142.6 s |
| old | 136.6 s |
| new | 135.3 s |

Every run is faster than the one before it, because the other agents on the
machine finished their work while this ran. The difference between old and new is
about 2%, which is smaller than that drift. **On this app the parallel work is
not the win.**

That is the honest reading, and it follows from the phase table: `MyApp` spends
2% of its build on the files that the new code copies in parallel. The parallel
work pays on an app that this one does not represent — one with large artifacts,
several precompile execution files, or several executables.

The wins that do show on this app are the two that remove work rather than spread
it:

1. The cache of the base system image. Several minutes to 0.
2. The native processor target. A multi-target build compiles everything three
   times on one core.

`JULIA_IMAGE_THREADS` sits between the two. It is real but noisy: on a loaded
machine the measurement gave 25%, and on a quiet machine 4 threads gave 122 s and
124 s while 8 threads gave 97 s and 119 s. It shortens the parallel tail of the
phase, and the serial front is the larger half.

## `JULIA_IMAGE_THREADS` measured

`create_sysimg_object_file` alone, in the 8-CPU lane. The setup ran once. The
order interleaves A, B, A, so a busy neighbour shows as A against A.

| Threads | Time | Object file |
| --- | --- | --- |
| 4 (the default of Julia: half the CPUs) | 311.6 s | 341.5 MiB |
| 8 (every CPU of the lane) | **221.6 s** | 342.8 MiB |
| 4 again | 282.8 s | 341.5 MiB |

The two A runs are 311.6 s and 282.8 s, a mean of 297 s. B is 221.6 s, which is
**25% faster** and well outside the spread of A. The object file grows by 0.4%,
so the extra partitions cost nothing worth counting.

This phase is 67% of a build, so the setting takes about 17% off the whole build.

## The three thread knobs are different things

A reader can confuse three separate settings. They are not the same.

1. `--threads` (also `-t`) on the process that calls `create_app`. It sets
   `Threads.nthreads()` inside PackageCompiler. The default is 1. PackageCompiler
   can not change this for itself. The user sets it when the user starts Julia.
   It decides whether the file copies of PackageCompiler can run on many cores.

2. `--threads` on the Julia child processes that PackageCompiler starts.
   PackageCompiler pins this to 1 in two places. It sets the runtime worker
   threads of the child. It does **not** reach the code that writes the system
   image: `src/aotcompile.cpp` never reads `jl_options.nthreads`. The pin at
   `create_sysimg_object_file` is a workaround for a known bug (issues 963 and
   990). Keep the pin.

3. `JULIA_IMAGE_THREADS`, an environment variable. It sets the number of threads
   that emit the object file. `compute_image_thread_count` reads it. The default
   is `jl_effective_threads() / 2`, which is half of the CPUs. This is the one
   setting that gives more cores to a system-image build.

## What can not be parallel

Julia infers types under one global lock, `jl_typeinf_lock` in `src/gf.c`. The
script `contrib/generate_precompile.jl` of Julia warns that more than one thread
causes a build error. Therefore PackageCompiler can not split the front half of a
`--output-o` build, and it can not replay precompile statements on many threads.

## The steps

- [x] 1. Measure the phases of a full `create_app` build. Recorded above.
- [x] 2. Measure `JULIA_IMAGE_THREADS`. Done. See the table below.
- [x] 3. Give PackageCompiler a job count. `build_jobs` reads
      `PACKAGECOMPILER_JOBS`, else `jl_effective_threads`.
- [x] 4. Run the precompile execution files at the same time.
- [x] 5. Build the executables of an app at the same time.
- [x] 6. Overlap the file copies of an app with the system-image build.
- [x] 7. Ask for every CPU when Julia writes the object file. `with_image_threads`
      sets `JULIA_IMAGE_THREADS` on all three `--output-o` children.
- [x] 9. Measure the whole `create_app` before and against after. Done, and the
      answer is "about 2% on this app". See the section above.
- [ ] 8. Still open, and now the most valuable thing left. `ensurecompiled` is
      about 20% of the build. It starts Julia on the fresh base system image and
      runs `using Pkg; Pkg.precompile()`. The base holds no stdlib and
      `get_julia_cmd` passes `--pkgimages=no`, so Julia compiles Pkg from source.
      A first measurement gave 113 s of which `Pkg.precompile` itself reported
      24 s. A later run of the same step took much less, so some of it is paid
      once per base system image and not once per build. Measure it with
      `ensurecompiled.jl` before you change anything: dropping `--pkgimages=no`
      for this one child would make `using Pkg` fast but would make
      `Pkg.precompile` write native code as well.

## Decisions found during the work

**Put the copies on the spawned task, not the compiler.** A default Julia process
has one thread, so a spawned task runs only when the running task gives the
thread back. A system-image build waits inside `run` on a child process and gives
the thread back often. A file copy is a blocking system call and never gives it
back. Therefore the copies go on the spawned task and the system-image build
stays on the main task. The other order would copy every file first and start the
compiler late.

**`--threads` on a child does not make a system image build faster.** It sets the
runtime worker threads of the child. `src/aotcompile.cpp` of Julia never reads
`jl_options.nthreads`. The pin to `--threads=1` in `create_sysimg_object_file` is
a workaround for issues 963 and 990, and it stays.

**`build_jobs` follows the CPU affinity.** It calls `jl_effective_threads`, the
same count that Julia uses, instead of `Sys.CPU_THREADS`. A build under `taskset`
then asks for the CPUs it may use. `Sys.CPU_THREADS` would ask for all 32 CPUs of
the machine even inside an 8-CPU lane.

**The cache needed an atomic publish.** Two builds on this machine shared the key
`c37c13e8cbe01f86` and wrote the same path. The build now writes a private
directory inside the cache and publishes the finished file with a rename.

**Native is now the default target.** The user asked for native only. A
multi-target build compiles every function three times, and that work is serial.
