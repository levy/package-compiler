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
| `create_sysimg_object_file` | (see below) |

The cache of the base system image works: 0.0 s in place of several minutes.

`ensurecompiled` costs 113 s but reports that it precompiled the packages in 24
seconds. The rest is the start of Julia on the fresh base system image. That
image holds no compiled code for Pkg, so `using Pkg` compiles Pkg from source.

## The multi-target build is the other big cost

The first measurement used `default_app_cpu_target()`, which names three
processors and `clone_all`. Its core-compiler step alone ran **401 seconds** and
used **400 seconds of CPU**. The system image it writes is 225 MB. The native
system image is 165 MB. The multi-target build compiles the same code three
times, and that work is serial.

The user asked for native only. `default_app_cpu_target()` now answers `native`.
`portable_app_cpu_target()` keeps the old multi-target string for an app that
ships to an unknown machine.

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

- [ ] 1. Measure the phases of a full `create_app` build. Record the numbers here.
- [ ] 2. Measure `JULIA_IMAGE_THREADS`. Compare the default with the full CPU count.
- [ ] 3. Give PackageCompiler a job count. Read `PACKAGECOMPILER_JOBS`, else the
      CPU count.
- [ ] 4. Run the precompile execution files at the same time. Each file starts its
      own Julia process, so this needs no threads in the parent.
- [ ] 5. Build the executables of an app at the same time. Each one starts a C
      compiler.
- [ ] 6. Overlap the file copies of an app with the system-image build. The
      system-image build waits on a child process, so the parent is free to copy.
      Keep every call into Pkg on one task, because Pkg is not safe for more than
      one task.
- [ ] 7. Copy the artifacts and the libraries on many threads when the parent has
      them.

## Decisions found during the work

(Record decisions here as the work proceeds.)
