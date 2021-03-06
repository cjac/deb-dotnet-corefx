#!/usr/bin/env bash

usage()
{
    echo "Usage: $0 [managed] [native] [BuildArch] [BuildType] [clean] [verbose] [clangx.y] [platform] [cross] [skiptests] [cmakeargs]"
    echo "managed - optional argument to build the managed code"
    echo "native - optional argument to build the native code"
    echo "The following arguments affect native builds only:"
    echo "BuildArch can be: x64, x86, arm, arm64"
    echo "BuildType can be: debug, release"
    echo "clean - optional argument to force a clean build."
    echo "verbose - optional argument to enable verbose build output."
    echo "clangx.y - optional argument to build using clang version x.y."
    echo "platform can be: FreeBSD, Linux, NetBSD, OSX, Windows"
    echo "cross - optional argument to signify cross compilation,"
    echo "      - will use ROOTFS_DIR environment variable if set."
    echo "skiptests - skip the tests in the './bin/*/*Tests/' subdirectory."
    echo "generateversion - if building native only, pass this in to get a version on the build output."
    echo "cmakeargs - user-settable additional arguments passed to CMake."
    exit 1
}

setup_dirs()
{
    echo Setting up directories for build

    mkdir -p "$__BinDir"
    mkdir -p "$__IntermediatesDir"
}

# Performs "clean build" type actions (deleting and remaking directories)

clean()
{
    echo "Cleaning previous output for the selected configuration"
    rm -rf "$__BinDir"
    rm -rf "$__IntermediatesDir"
    setup_dirs
}

# Check the system to ensure the right pre-reqs are in place

check_native_prereqs()
{
    echo "Checking pre-requisites..."

    # Check presence of CMake on the path
    hash cmake 2>/dev/null || { echo >&2 "Please install cmake before running this script"; exit 1; }

    # Check for clang
    hash clang-$__ClangMajorVersion.$__ClangMinorVersion 2>/dev/null ||  hash clang$__ClangMajorVersion$__ClangMinorVersion 2>/dev/null ||  hash clang 2>/dev/null || { echo >&2 "Please install clang before running this script"; exit 1; }
}

# Prepare the system for building

prepare_managed_build()
{
    # Run Init-Tools to restore BuildTools and ToolRuntime
    $__scriptpath/init-tools.sh
}

prepare_native_build()
{
    # Specify path to be set for CMAKE_INSTALL_PREFIX.
    # This is where all built CoreClr libraries will copied to.
    export __CMakeBinDir="$__BinDir"

    # Configure environment if we are doing a clean build.
    if [ $__CleanBuild == 1 ]; then
        clean
    fi

    # Configure environment if we are doing a verbose build
    if [ $__VerboseBuild == 1 ]; then
        export VERBOSE=1
    fi

    # If managed build is supported, then generate version
    if [ $__buildmanaged == true ]; then
        __generateversionsource=true
    fi

    # Ensure tools are present if we will generate version.c
    if [ $__generateversionsource == true ]; then
        $__scriptpath/init-tools.sh
    fi

    # Generate version.c if specified, else have an empty one.
    __versionSourceFile=$__scriptpath/bin/obj/version.c
    if [ ! -e "${__versionSourceFile}" ]; then
        if [ $__generateversionsource == true ]; then
            $__scriptpath/Tools/corerun $__scriptpath/Tools/MSBuild.exe "$__scriptpath/build.proj" /t:GenerateVersionSourceFile /p:GenerateVersionSourceFile=true /v:minimal
        else
            __versionSourceLine="static char sccsid[] __attribute__((used)) = \"@(#)No version information produced\";"
            echo $__versionSourceLine > $__versionSourceFile
        fi
    fi
}

build_managed()
{
    __buildproj=$__scriptpath/build.proj
    __buildlog=$__scriptpath/msbuild.log
    __binclashlog=$__scriptpath/binclash.log
    __binclashloggerdll=$__scriptpath/Tools/Microsoft.DotNet.Build.Tasks.dll

    $__scriptpath/Tools/corerun $__scriptpath/Tools/MSBuild.exe "$__buildproj" /m /nologo /verbosity:minimal "/flp:Verbosity=normal;LogFile=$__buildlog" "/flp2:warningsonly;logfile=$__scriptpath/msbuild.wrn" "/flp3:errorsonly;logfile=$__scriptpath/msbuild.err" "/l:BinClashLogger,$__binclashloggerdll;LogFile=$__binclashlog" /p:ConfigurationGroup=$__BuildType /p:TargetOS=$__BuildOS /p:OSGroup=$__BuildOS /p:SkipTests=$__SkipTests /p:COMPUTERNAME=$(hostname) /p:USERNAME=$(id -un) /p:TestNugetRuntimeId=$__TestNugetRuntimeId $__UnprocessedBuildArgs
    BUILDERRORLEVEL=$?

    echo

    # Pull the build summary from the log file
    tail -n 4 "$__buildlog"
    echo Build Exit Code = $BUILDERRORLEVEL
}

build_native()
{
    # All set to commence the build

    echo "Commencing build of corefx native components for $__BuildOS.$__BuildArch.$__BuildType"
    cd "$__IntermediatesDir"

    # Regenerate the CMake solution
    echo "Invoking cmake with arguments: \"$__nativeroot\" $__CMakeArgs $__CMakeExtraArgs"
    "$__nativeroot/gen-buildsys-clang.sh" "$__nativeroot" $__ClangMajorVersion $__ClangMinorVersion $__BuildArch $__CMakeArgs "$__CMakeExtraArgs"

    # Check that the makefiles were created.

    if [ ! -f "$__IntermediatesDir/Makefile" ]; then
        echo "Failed to generate native component build project!"
        exit 1
    fi

    # Get the number of processors available to the scheduler
    # Other techniques such as `nproc` only get the number of
    # processors available to a single process.
    if [ `uname` = "FreeBSD" ]; then
        NumProc=`sysctl hw.ncpu | awk '{ print $2+1 }'`
    elif [ `uname` = "NetBSD" ]; then
        NumProc=$(($(getconf NPROCESSORS_ONLN)+1))
    else
        NumProc=$(($(getconf _NPROCESSORS_ONLN)+1))
    fi

    # Build

    echo "Executing make install -j $NumProc"

    make install -j $NumProc
    if [ $? != 0 ]; then
        echo "Failed to build corefx native components."
        exit 1
    fi

    echo "CoreFX native components successfully built."
    echo "Product binaries are available at $__BinDir"
}

__scriptpath=$(cd "$(dirname "$0")"; pwd -P)
__nativeroot=$__scriptpath/src/Native
__packageroot=$__scriptpath/packages
__sourceroot=$__scriptpath/src
__rootbinpath="$__scriptpath/bin"
__generateversionsource=false
__buildmanaged=false
__buildnative=false
__TestNugetRuntimeId=win7-x64

# Use uname to determine what the CPU is.
CPUName=$(uname -p)
# Some Linux platforms report unknown for platform, but the arch for machine.
if [ $CPUName == "unknown" ]; then
    CPUName=$(uname -m)
fi

case $CPUName in
    i686)
        __BuildArch=x86
        ;;

    x86_64)
        __BuildArch=x64
        ;;

    armv7l)
        __BuildArch=arm
        ;;

    aarch64)
        __BuildArch=arm64
        ;;

    *)
        echo "Unknown CPU $CPUName detected, configuring as if for x64"
        __BuildArch=x64
        ;;
esac

# Use uname to determine what the OS is.
OSName=$(uname -s)
case $OSName in
    Darwin)
        __HostOS=OSX
        __TestNugetRuntimeId=osx.10.10-x64
        ;;

    FreeBSD)
        __HostOS=FreeBSD
        # TODO: Add native version
        __TestNugetRuntimeId=osx.10.10-x64
        ;;

    Linux)
        __HostOS=Linux
        if [ ! -e /etc/os-release ]; then
            echo "Cannot determine Linux distribution, assuming Ubuntu 14.04"
             __TestNugetRuntimeId=ubuntu.14.04-x64
        else
            source /etc/os-release
            __TestNugetRuntimeId=$ID.$VERSION_ID-$__BuildArch
        fi
        ;;

    NetBSD)
        __HostOS=NetBSD
        # TODO: Add native version
        __TestNugetRuntimeId=osx.10.10-x64
        ;;

    *)
        echo "Unsupported OS '$OSName' detected. Configuring as if for Ubuntu."
        __HostOS=Linux
        __TestNugetRuntimeId=ubuntu.14.04-x64
        ;;
esac
__BuildOS=$__HostOS
__BuildType=Debug
__CMakeArgs=DEBUG
__CMakeExtraArgs=""

BUILDERRORLEVEL=0

# Set the various build properties here so that CMake and MSBuild can pick them up
__UnprocessedBuildArgs=
__CleanBuild=false
__CrossBuild=0
__SkipTests=false
__ServerGC=0
__VerboseBuild=false
__ClangMajorVersion=3
__ClangMinorVersion=5

while :; do
    if [ $# -le 0 ]; then
        break
    fi

    lowerI="$(echo $1 | awk '{print tolower($0)}')"
    case $lowerI in
        -?|-h|--help)
            usage
            exit 1
            ;;
        managed)
            __buildmanaged=true
            ;;
        native)
            __buildnative=true
            ;;
        x86)
            __BuildArch=x86
            ;;
        x64)
            __BuildArch=x64
            ;;
        arm)
            __BuildArch=arm
            ;;
        arm64)
            __BuildArch=arm64
            ;;
        debug)
            __BuildType=Debug
            ;;
        release)
            __BuildType=Release
            __CMakeArgs=RELEASE
            ;;
        clean)
            __CleanBuild=1
            ;;
        verbose)
            __VerboseBuild=1
            ;;
        generateversion)
            __generateversionsource=true
            ;;
        clang3.5)
            __ClangMajorVersion=3
            __ClangMinorVersion=5
            ;;
        clang3.6)
            __ClangMajorVersion=3
            __ClangMinorVersion=6
            ;;
        clang3.7)
            __ClangMajorVersion=3
            __ClangMinorVersion=7
            ;;
        freebsd)
            __BuildOS=FreeBSD
            __TestNugetRuntimeId=osx.10.10-x64
            ;;
        linux)
            __BuildOS=Linux
            # If the Host OS is also Linux, then use the RID of the host.
            # Otherwise, override it to Ubuntu by default.
            if [ "$__HostOS" != "Linux" ]; then
                __TestNugetRuntimeId=ubuntu.14.04-x64
            fi
            ;;
        netbsd)
            __BuildOS=NetBSD
            __TestNugetRuntimeId=osx.10.10-x64
            ;;
        osx)
            __BuildOS=OSX
            __TestNugetRuntimeId=osx.10.10-x64
            ;;
        windows)
            __BuildOS=Windows_NT
            __TestNugetRuntimeId=win7-x64
            ;;
        cross)
            __CrossBuild=1
            ;;
        skiptests)
            __SkipTests=true
            ;;
        cmakeargs)
            if [ -n "$2" ]; then
                __CMakeExtraArgs="$2"
                shift
            else
                echo "ERROR: 'cmakeargs' requires a non-empty option argument"
                exit 1
            fi
            ;;
        useservergc)
            __ServerGC=1
            ;;
        *)
            __UnprocessedBuildArgs="$__UnprocessedBuildArgs $1"
    esac

    shift
done

# If neither managed nor native are passed as arguments, default to building both

if [ "$__buildmanaged" = false -a "$__buildnative" = false ]; then
    __buildmanaged=true
    __buildnative=true
fi

# Disable the native build when targeting Windows.

if [ "$__BuildOS" != "$__HostOS" ]; then
    echo "Warning: cross compiling native components is not yet supported"
    __buildnative=false
fi

if [ ! -e "$__nativeroot" ]; then
   __buildnative=false
fi

# Set the remaining variables based upon the determined build configuration
__IntermediatesDir="$__rootbinpath/obj/$__BuildOS.$__BuildArch.$__BuildType/Native"
__BinDir="$__rootbinpath/$__BuildOS.$__BuildArch.$__BuildType/Native"

# Make the directories necessary for build if they don't exist

setup_dirs

# Configure environment if we are doing a cross compile.
if [ "$__CrossBuild" == 1 ]; then
    export CROSSCOMPILE=1
    if ! [[ -n "$ROOTFS_DIR" ]]; then
        export ROOTFS_DIR="$__scriptpath/cross/rootfs/$__BuildArch"
    fi
fi

export CORECLR_SERVER_GC="$__ServerGC"

if $__buildnative; then

    # Check prereqs.

    check_native_prereqs

    # Prepare the system

    prepare_native_build

    # Build the corefx native components.

    build_native

    # Build complete
fi

if $__buildmanaged; then

    # Prepare the system

    prepare_managed_build

    # Build the corefx native components.

    build_managed

    # Build complete
fi

# If managed build failed, exit with the status code of the managed build
if [ $BUILDERRORLEVEL != 0 ]; then
    exit $BUILDERRORLEVEL
fi

exit $BUILDERRORLEVEL
