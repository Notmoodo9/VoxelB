@echo off
rem ===========================================================================
rem build.bat - builds VoxelB from a clean checkout.
rem
rem   build.bat                 debug build   -> build\debug\voxelb.exe
rem   build.bat release         release build -> build\release\voxelb.exe
rem   build.bat clean           wipe the config's output first, then build
rem   build.bat run             build, then launch the game
rem   (options combine, e.g.  build.bat release clean run)
rem
rem Needs on PATH: nasm (2.15+) and lld-link (LLVM). No Windows SDK needed:
rem import libraries are generated from tools\implib\*.def.
rem Tool arguments use forward slashes on purpose (accepted by both tools).
rem ===========================================================================
setlocal EnableExtensions EnableDelayedExpansion
cd /d "%~dp0"

set "CONFIG=debug"
set "CLEAN=0"
set "RUN=0"

:parse_args
if "%~1"=="" goto args_done
if /i "%~1"=="debug"   set "CONFIG=debug"   & shift & goto parse_args
if /i "%~1"=="release" set "CONFIG=release" & shift & goto parse_args
if /i "%~1"=="clean"   set "CLEAN=1"        & shift & goto parse_args
if /i "%~1"=="run"     set "RUN=1"          & shift & goto parse_args
echo usage: build.bat [debug^|release] [clean] [run]
exit /b 2
:args_done

rem ---- toolchain check ------------------------------------------------------
nasm -v >nul 2>&1
if errorlevel 1 (
    echo ERROR: nasm was not found on PATH.
    echo        Install NASM from https://www.nasm.us/ and add it to PATH.
    exit /b 1
)
lld-link --version >nul 2>&1
if errorlevel 1 (
    echo ERROR: lld-link was not found on PATH.
    echo        Install LLVM from https://github.com/llvm/llvm-project/releases
    echo        and tick "Add LLVM to the system PATH" in the installer.
    exit /b 1
)

set "OUT=build/%CONFIG%"
set "OBJ=build/%CONFIG%/obj"
set "LIBDIR=build/lib"

if "%CONFIG%"=="debug" (
    set "NASMFLAGS=-f win64 -g -F cv8 -DBUILD_DEBUG=1"
    set "LINKFLAGS=/debug /pdb:%OUT%/voxelb.pdb"
) else (
    set "NASMFLAGS=-f win64 -DBUILD_DEBUG=0"
    set "LINKFLAGS=/release /opt:ref /opt:icf"
)

if "%CLEAN%"=="1" (
    if exist "build\%CONFIG%" rmdir /s /q "build\%CONFIG%"
    if exist "build\lib" rmdir /s /q "build\lib"
)
if not exist "build\%CONFIG%\obj" mkdir "build\%CONFIG%\obj"
if not exist "build\lib" mkdir "build\lib"

echo === VoxelB %CONFIG% build ===

rem ---- import libraries -----------------------------------------------------
set "LIBS="
for %%D in (tools\implib\*.def) do (
    lld-link /lib /nologo /machine:x64 /def:tools/implib/%%~nxD /out:%LIBDIR%/%%~nD.lib
    if errorlevel 1 goto fail
    set "LIBS=!LIBS! %LIBDIR%/%%~nD.lib"
)

rem ---- assemble every module under src\ -------------------------------------
rem Module file names must be unique across src\ (objects share one folder).
type nul > "build\%CONFIG%\obj\link.rsp"
for /r src %%F in (*.asm) do (
    echo nasm %%~nxF
    nasm %NASMFLAGS% -I src/include/ -o %OBJ%/%%~nF.obj "%%F"
    if errorlevel 1 goto fail
    echo %OBJ%/%%~nF.obj>>"build\%CONFIG%\obj\link.rsp"
)

rem ---- link -----------------------------------------------------------------
echo lld-link voxelb.exe
lld-link /nologo /machine:x64 /subsystem:windows /entry:main_entry /nodefaultlib %LINKFLAGS% /out:%OUT%/voxelb.exe @%OBJ%/link.rsp %LIBS%
if errorlevel 1 goto fail
if not exist "build\%CONFIG%\voxelb.exe" goto fail

echo BUILD OK: build\%CONFIG%\voxelb.exe
if "%RUN%"=="1" start "" "build\%CONFIG%\voxelb.exe"
exit /b 0

:fail
echo BUILD FAILED
exit /b 1
