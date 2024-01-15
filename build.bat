@echo off

if not exist build mkdir build
if not exist run mkdir run

rem I hope your odin installation is under C:\odin...
copy C:\odin\vendor\sdl2\SDL2.dll run\SDL2.dll

echo[
echo ==========================
echo ===   BUILDING DEBUG   ===
echo ==========================

odin build code -debug -show-timings -microarch:native -o:minimal -out:"build\odin-rt_debug.exe"
if %ERRORLEVEL% NEQ 0 goto end

copy build\odin-rt_debug.exe run\odin-rt_debug.exe
copy build\odin-rt_debug.pdb run\odin-rt_debug.pdb

echo[
echo ==========================
echo ===  BUILDING RELEASE  ===
echo ==========================

odin build code -debug -show-timings -microarch:native -o:aggressive -no-bounds-check -out:"build\odin-rt.exe"

copy build\odin-rt.exe run\odin-rt.exe
copy build\odin-rt.pdb run\odin-rt.pdb

:end
