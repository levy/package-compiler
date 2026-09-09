// The launcher of a trimmed bundle. A trimmed image has no parser and no
// evaluator, so this launcher never calls `jl_eval_string`. It starts the
// runtime on the trimmed image, sets `Core.ARGS` and `Base.ARGS`, and calls
// the exported entry point `JULIA_MAIN` of the image directly.

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "julia.h"
#include "uv.h"

#ifdef NEW_DEFINE_FAST_TLS_SYNTAX
JULIA_DEFINE_FAST_TLS
#else
JULIA_DEFINE_FAST_TLS()
#endif

typedef int32_t (*trimmed_main_t)(void);

int main(int argc, char *argv[]) {
    argv = uv_setup_args(argc, argv);

    // The program arguments stop at `--julia-args`; the rest are runtime
    // options, as in the untrimmed launcher.
    int program_argc = argc;
    for (int i = 0; i < argc; i++) {
        if (strcmp(argv[i], "--julia-args") == 0) {
            program_argc = i;
            break;
        }
    }
    int julia_argc = argc - program_argc;
    if (julia_argc > 0) {
        argv[program_argc] = argv[0];
        char **julia_argv = &argv[program_argc];
        jl_parse_opts(&julia_argc, &julia_argv);
    }

    // The image next to the runtime library: `<bundle>/lib/julia/sys.so`.
    jl_init();
    jl_set_ARGS(program_argc, argv);

    // `Base.ARGS` gets the program arguments without the program name.
    jl_value_t *args = jl_get_global(jl_base_module, jl_symbol("ARGS"));
    if (args != NULL && jl_is_array(args)) {
        jl_value_t *arg = NULL;
        JL_GC_PUSH1(&arg);
        for (int i = 1; i < program_argc; i++) {
            arg = jl_cstr_to_string(argv[i]);
            jl_array_ptr_1d_push((jl_array_t *)args, arg);
        }
        JL_GC_POP();
    }

    // The entry point is an exported symbol of the image. `jl_init` loaded
    // the image at `jl_options.image_file`; `RTLD_NOLOAD` returns that handle.
    void *image = jl_dlopen(jl_options.image_file, JL_RTLD_NOW | JL_RTLD_NOLOAD);
    if (image == NULL) {
        fprintf(stderr, "ERROR: the image %s is not loaded\n", jl_options.image_file);
        jl_atexit_hook(1);
        return 1;
    }
    void *entry = NULL;
    if (!jl_dlsym(image, JULIA_MAIN, &entry, 0, 0) || entry == NULL) {
        fprintf(stderr, "ERROR: the image %s exports no entry point " JULIA_MAIN "\n",
                jl_options.image_file);
        jl_atexit_hook(1);
        return 1;
    }
    int32_t retcode = ((trimmed_main_t)entry)();
    jl_atexit_hook(retcode);
    return retcode;
}
