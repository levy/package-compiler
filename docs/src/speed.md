# [Build speed](@id speed)

A build spends nearly all of its wall clock in one place: the Julia child process
that writes the system image. This page says what that process does, which part
of it can use more than one CPU, and which settings change the time.

The shares below come from `examples/MyApp` on a machine with 32 CPUs, in a lane
of 8 CPUs. Read them as shares and not as times: the wall clock of a build moves
by a factor of two or three with the other work on the machine.

| Phase | Share |
| --- | --- |
| copy the libraries, the artifacts and the other files | about 2% |
| build the fresh base system image | 0, when the cache answers |
| `Pkg.precompile` on the base system image | about 20% |
| run the precompile execution file | about 8% |
| compile the system image | about 70% |
| link the system image and build the executable | under 1% |

## Choose the processor target

`create_app` and `create_library` compile for `native`: the processor of the
machine that builds. This is the fast choice. Julia compiles each function once.

An app that you send to a machine that you do not know needs more. Pass
`cpu_target = PackageCompiler.portable_app_cpu_target()`. That target names three
processors and `clone_all`, so Julia compiles every function three times. The
cost is large and it is serial. On the machine above, one step of a multi-target
build ran for over six minutes on a single core, and the base system image grew
from 165 MB to 225 MB.

This is the largest single choice on this page. Build native unless you ship the
app.

## The base system image comes from a cache

A build with `incremental = false` first builds a *fresh base* system image from
the sources of Julia. That file holds nothing of your program, so it is the same
file for every build with the same Julia, the same processor target and the same
build flags. PackageCompiler keeps it in the depot and reuses it.

- `PACKAGECOMPILER_CACHE_BASE=0` turns the cache off.
- `PACKAGECOMPILER_BASE_CACHE=<dir>` puts the cache somewhere else.

A build writes a private directory inside the cache and publishes the finished
file with a rename, so two builds can run at the same time.

## What uses more than one CPU

Three settings control three different things. They are easy to confuse.

**`JULIA_IMAGE_THREADS`** sets the number of threads that write the object file
of a system image. This is the only setting that gives more cores to a
system-image build. Julia asks for half of the CPUs by default;
PackageCompiler asks for all of them. Set the variable yourself to choose another
number. Each thread needs memory, so lower the number on a machine with little
free memory.

**`PACKAGECOMPILER_JOBS`** sets how many build steps PackageCompiler starts at
the same time: the precompile execution files, and the executables of an app.
Without it the number is the count of CPUs that the process may use, so a build
under `taskset` asks only for the CPUs of its lane.

**`--threads` on the Julia process that you start** sets the threads of
PackageCompiler itself. PackageCompiler copies the files of an app while the
compiler runs, and that overlap needs no threads. More threads help only when the
copies are large.

Do not try to speed a system-image build up with `--threads` on the child. Julia
never reads that number when it writes an image.

## What can not go faster

The first half of a system-image build infers types. Julia infers under one
global lock, and its own build script warns that more than one thread causes a
build error. That half runs on one core, and no setting changes this. A measured
phase used 692 seconds of CPU in 316 seconds of wall clock, an average of about
two cores: a serial front, then a parallel tail. More threads shorten the tail
only, so the gain from `JULIA_IMAGE_THREADS` is real but small beside the cost of
the front.

Therefore the way to a faster build is to give the compiler less to do:

- Build for `native` and not for three processors.
- Keep the fresh base system image in the cache.
- Put only the packages you need in the image.
