@echo off
setlocal enabledelayedexpansion

set TOOLCHAIN=C:\Users\cachi\arm-toolchain\arm-gnu-toolchain-13.3.rel1-mingw-w64-i686-arm-none-eabi\bin
set AS=%TOOLCHAIN%\arm-none-eabi-as.exe
set LD=%TOOLCHAIN%\arm-none-eabi-ld.exe
set OBJCOPY=%TOOLCHAIN%\arm-none-eabi-objcopy.exe
set OBJDUMP=%TOOLCHAIN%\arm-none-eabi-objdump.exe

echo ========================================================
echo  Compilando Videojuego Space Invaders ARM RP2040
echo ========================================================

echo [1/9] Ensamblando boot2.s...
"%AS%" -mcpu=cortex-m0plus -mthumb boot2.s -o boot2.o
if %ERRORLEVEL% neq 0 goto error

echo [2/9] Ensamblando crt0.s...
"%AS%" -mcpu=cortex-m0plus -mthumb crt0.s -o crt0.o
if %ERRORLEVEL% neq 0 goto error

echo [3/9] Ensamblando system.s...
"%AS%" -mcpu=cortex-m0plus -mthumb system.s -o system.o
if %ERRORLEVEL% neq 0 goto error

echo [4/9] Ensamblando timer.s...
"%AS%" -mcpu=cortex-m0plus -mthumb timer.s -o timer.o
if %ERRORLEVEL% neq 0 goto error

echo [5/9] Ensamblando inputs.s...
"%AS%" -mcpu=cortex-m0plus -mthumb inputs.s -o inputs.o
if %ERRORLEVEL% neq 0 goto error

echo [6/9] Ensamblando video.s...
"%AS%" -mcpu=cortex-m0plus -mthumb video.s -o video.o
if %ERRORLEVEL% neq 0 goto error

echo [7/9] Ensamblando font.s...
"%AS%" -mcpu=cortex-m0plus -mthumb font.s -o font.o
if %ERRORLEVEL% neq 0 goto error

echo [8/9] Ensamblando main.s...
"%AS%" -mcpu=cortex-m0plus -mthumb main.s -o main.o
if %ERRORLEVEL% neq 0 goto error

echo [9/9] Enlazando objetos con memmap.ld...
"%LD%" -T memmap.ld -o space_invaders.elf boot2.o crt0.o system.o timer.o inputs.o video.o font.o main.o
if %ERRORLEVEL% neq 0 goto error

echo Generando binario raw space_invaders.bin...
"%OBJCOPY%" -O binary space_invaders.elf space_invaders.bin
if %ERRORLEVEL% neq 0 goto error

echo Convirtiendo binario a space_invaders.uf2...
python uf2conv.py space_invaders.bin space_invaders.uf2
if %ERRORLEVEL% neq 0 goto error

echo ========================================================
echo  COMPILACION EXITOSA!
echo  Archivo generado: space_invaders.uf2
echo ========================================================

if exist D:\ (
    echo Pico detectada en unidad D:!
    echo Copiando space_invaders.uf2 a D:\ ...
    copy space_invaders.uf2 D:\
    echo Listo! La Raspberry Pi Pico se reiniciara ejecutando Space Invaders!
) else (
    echo Unidad D: no detectada. Conecta tu Pico en modo BOOTSEL para cargar space_invaders.uf2
)

goto end

:error
echo ========================================================
echo  ERROR DURANTE LA COMPILACION
echo ========================================================
exit /b 1

:end

