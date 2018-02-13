const depsfile = joinpath(@__DIR__, "..", "deps", "deps.jl")

if isfile(depsfile)
    include(depsfile)
    gccworks = try
        success(`$gcc -v`)
    catch
        false
    end
    if !gccworks
        error("GCC wasn't found. Please make sure that gcc is on the path and run Pkg.build(\"PackageCompiler\")")
    end
else
    error("Package wasn't build correctly. Please run Pkg.build(\"PackageCompiler\")")
end

system_compiler() = gcc

"""
    julia_compile(julia_program::String; kw_args...)

compiles the julia file at path `julia_program` with keyword arguments:

    cprog = nothing           C program to compile (required only when building an executable; if not provided a minimal driver program is used)
    builddir = "builddir"     directory used for building
    julia_program_basename    basename for the compiled artifacts

    autodeps                  automatically build required dependencies
    object                    build object file
    shared                    build shared library
    executable                build executable file (Bool)
    julialibs                 sync Julia libraries to builddir

    verbose                   increase verbosity
    quiet                     suppress non-error messages
    clean                     delete builddir


    sysimage <file>           start up with the given system image file
    compile {yes|no|all|min}  enable or disable JIT compiler, or request exhaustive compilation
    cpu_target <target>       limit usage of CPU features up to <target>
    optimize {0,1,2,3}        set optimization level (type: Int64)
    debug {0,1,2}             set debugging information level (type: Int64)
    inline {yes|no}           control whether inlining is permitted
    check_bounds {yes|no}     emit bounds checks always or never
    math_mode {ieee,fast}     set floating point optimizations
    depwarn {yes|no|error}    set syntax and method deprecation warnings


"""
function julia_compile(
        julia_program;
        julia_program_basename = splitext(basename(julia_program))[1],
        cprog = nothing, builddir = "builddir",
        verbose = false, quiet = false, clean = false, sysimage = nothing,
        compile = nothing, cpu_target = nothing, optimize = nothing,
        debug = nothing, inline = nothing, check_bounds = nothing,
        math_mode = nothing, depwarn = nothing, autodeps = false,
        object = false, shared = false, executable = true, julialibs = true,
        cc = system_compiler()
    )

    verbose && quiet && (quiet = false)

    if autodeps
        executable && (shared = true)
        shared && (object = true)
    end

    julia_program = abspath(julia_program)
    isfile(julia_program) || error("Cannot find file:\n  \"$julia_program\"")
    quiet || println("Julia program file:\n  \"$julia_program\"")

    if executable
        cprog = cprog == nothing ? joinpath(@__DIR__, "..", "examples", "program.c") : abspath(cprog)
        isfile(cprog) || error("Cannot find file:\n  \"$cprog\"")
        quiet || println("C program file:\n  \"$cprog\"")
    end

    cd(dirname(julia_program))

    builddir = abspath(builddir)
    quiet || println("Build directory:\n  \"$builddir\"")

    if clean
        if isdir(builddir)
            verbose && println("Delete build directory")
            rm(builddir, recursive=true)
        else
            verbose && println("Build directory does not exist, nothing to delete")
        end
    end

    if !isdir(builddir)
        verbose && println("Make build directory")
        mkpath(builddir)
    end

    if pwd() != builddir
        verbose && println("Change to build directory")
        cd(builddir)
    else
        verbose && println("Already in build directory")
    end

    o_file = julia_program_basename * ".o"
    s_file = julia_program_basename * ".$(Libdl.dlext)"
    if julia_v07
        e_file = julia_program_basename * (Sys.iswindows() ? ".exe" : "")
    else
        e_file = julia_program_basename * (is_windows() ? ".exe" : "")
    end
    tmp_dir = "tmp_v$VERSION"

    # TODO: these should probably be emitted from julia-config also:
    if julia_v07
        shlibdir = Sys.iswindows() ? Sys.BINDIR : abspath(Sys.BINDIR, Base.LIBDIR)
        private_shlibdir = abspath(Sys.BINDIR, Base.PRIVATE_LIBDIR)
    else
        shlibdir = is_windows() ? JULIA_HOME : abspath(JULIA_HOME, Base.LIBDIR)
        private_shlibdir = abspath(JULIA_HOME, Base.PRIVATE_LIBDIR)
    end

    if object
        julia_cmd = `$(Base.julia_cmd())`
        if length(julia_cmd.exec) != 5 || !all(startswith.(julia_cmd.exec[2:5], ["-C", "-J", "--compile", "--depwarn"]))
            error("Unexpected format of \"Base.julia_cmd()\", you may be using an incompatible version of Julia")
        end
        sysimage == nothing || (julia_cmd.exec[3] = "-J$sysimage")
        push!(julia_cmd.exec, "--startup-file=no")
        compile == nothing || (julia_cmd.exec[4] = "--compile=$compile")
        cpu_target == nothing || (julia_cmd.exec[2] = "-C$cpu_target")
        optimize == nothing || push!(julia_cmd.exec, "-O$optimize")
        debug == nothing || push!(julia_cmd.exec, "-g$debug")
        inline == nothing || push!(julia_cmd.exec, "--inline=$inline")
        check_bounds == nothing || push!(julia_cmd.exec, "--check-bounds=$check_bounds")
        math_mode == nothing || push!(julia_cmd.exec, "--math-mode=$math_mode")
        depwarn == nothing || (julia_cmd.exec[5] = "--depwarn=$depwarn")
        if julia_v07
            Sys.iswindows() && (julia_program = replace(julia_program, "\\", "\\\\"))
            expr = "
  Base.init_depot_path() # initialize package depots
  Base.init_load_path() # initialize location of site-packages
  empty!(Base.LOAD_CACHE_PATH) # reset / remove any builtin paths
  push!(Base.LOAD_CACHE_PATH, abspath(\"$tmp_dir\")) # enable usage of precompiled files
  include(\"$julia_program\") # include \"julia_program\" file
  empty!(Base.LOAD_CACHE_PATH) # reset / remove build-system-relative paths"
        else
            is_windows() && (julia_program = replace(julia_program, "\\", "\\\\"))
            expr = "
  empty!(Base.LOAD_CACHE_PATH) # reset / remove any builtin paths
  push!(Base.LOAD_CACHE_PATH, abspath(\"$tmp_dir\")) # enable usage of precompiled files
  include(\"$julia_program\") # include \"julia_program\" file
  empty!(Base.LOAD_CACHE_PATH) # reset / remove build-system-relative paths"
        end
        isdir(tmp_dir) || mkpath(tmp_dir)
        command = `$julia_cmd -e $expr`
        verbose && println("Build module image files \".ji\" in subdirectory \"$tmp_dir\":\n  $command")
        run(command)
        command = `$julia_cmd --output-o $(joinpath(tmp_dir, o_file)) -e $expr`
        verbose && println("Build object file \"$o_file\" in subdirectory \"$tmp_dir\":\n  $command")
        run(command)
    end

    if shared || executable
        if julia_v07
            command = `$(Base.julia_cmd()) --startup-file=no $(joinpath(dirname(Sys.BINDIR), "share", "julia", "julia-config.jl"))`
            flags = `$(Base.shell_split(read(\`$command --allflags\`, String)))`
        else
            command = `$(Base.julia_cmd()) --startup-file=no $(joinpath(dirname(JULIA_HOME), "share", "julia", "julia-config.jl"))`
            cflags = `$(Base.shell_split(readstring(\`$command --cflags\`)))`
            ldflags = `$(Base.shell_split(readstring(\`$command --ldflags\`)))`
            ldlibs = `$(Base.shell_split(readstring(\`$command --ldlibs\`)))`
            flags = `$cflags $ldflags $ldlibs`
        end
    end
    bitness = Int == Int32 ? "-m32" : "-m64"
    if shared
        command = `$cc $bitness -shared -o $s_file $(joinpath(tmp_dir, o_file)) $flags`
        if julia_v07
            if Sys.isapple()
                command = `$command -Wl,-install_name,@rpath/\"$s_file\"`
            elseif Sys.iswindows()
                command = `$command -Wl,--export-all-symbols`
            end
        else
            if is_apple()
                command = `$command -Wl,-install_name,@rpath/\"$s_file\"`
            elseif is_windows()
                command = `$command -Wl,--export-all-symbols`
            end
        end
        verbose && println("Build shared library \"$s_file\" in build directory:\n  $command")
        run(command)
    end

    if executable
        command = `$cc $bitness -DJULIAC_PROGRAM_LIBNAME=\"$s_file\" -o $e_file $cprog $s_file $flags`
        if julia_v07
            if Sys.isapple()
                command = `$command -Wl,-rpath,@executable_path`
            elseif Sys.isunix()
                command = `$command -Wl,-rpath,\$ORIGIN`
            end
        else
            if is_apple()
                command = `$command -Wl,-rpath,@executable_path`
            elseif is_unix()
                command = `$command -Wl,-rpath,\$ORIGIN`
            end
        end
        if Sys.is_windows()
            RPMbindir = Pkg.dir("WinRPM","deps","usr","x86_64-w64-mingw32","sys-root","mingw","bin")
            incdir = Pkg.dir("WinRPM","deps","usr","x86_64-w64-mingw32","sys-root","mingw","include")
            push!(Base.Libdl.DL_LOAD_PATH, RPMbindir) # TODO does this need to be reversed?
            ENV["PATH"] = ENV["PATH"] * ";" * RPMbindir
            command = `$command -I$incdir`
        end
        verbose && println("Build executable file \"$e_file\" in build directory:\n  $command")
        run(command)
    end

    if julialibs
        verbose && println("Sync Julia libraries to build directory:")
        libfiles = String[]
        dlext = "." * Libdl.dlext
        for dir in (shlibdir, private_shlibdir)
            if julia_v07
                if Sys.iswindows() || Sys.isapple()
                    append!(libfiles, joinpath.(dir, filter(x -> endswith(x, dlext), readdir(dir))))
                else
                    append!(libfiles, joinpath.(dir, filter(x -> contains(x, r"^lib.+\.so(?:\.\d+)*$"), readdir(dir))))
                end
            else
                if is_windows() || is_apple()
                    append!(libfiles, joinpath.(dir, filter(x -> endswith(x, dlext), readdir(dir))))
                else
                    append!(libfiles, joinpath.(dir, filter(x -> ismatch(r"^lib.+\.so(?:\.\d+)*$", x), readdir(dir))))
                end
            end
        end
        sync = false
        for src in libfiles
            if julia_v07
                contains(src, r"debug") && continue
            else
                ismatch(r"debug", src) && continue
            end
            dst = basename(src)
            if filesize(src) != filesize(dst) || ctime(src) > ctime(dst) || mtime(src) > mtime(dst)
                verbose && println("  $dst")
                cp(src, dst, remove_destination=true, follow_symlinks=false)
                sync = true
            end
        end
        sync || verbose && println("  none")
    end
end