@echo off
REM ================================================================
REM  mpv-omniphony — Blu-ray BD-J 菜单启动器（Windows）
REM ================================================================
REM 双击或命令行执行：
REM    MPV-BD菜单启动.bat  "D:\蓝光\壮志凌云2.iso"
REM
REM 功能：
REM   * 预先设置 LIBBLURAY_CP -> 本目录下 share\libbluray\libbluray.jar
REM     （注意：libbluray 读取的是 LIBBLURAY_CP 变量名 —— libbluray 1.4.1
REM     bdj.c:556 中用 getenv("LIBBLURAY_CP") 读取，写错名会找不到 jar）
REM   * 若本机已配置 JAVA_HOME，则导出 BLURAY_JVM_LIB_PATH 指向 jvm.dll，
REM     libbluray 会直接通过该路径 dlopen JVM，避免依赖 PATH 查找。
REM   * 自动附加 --disc-menu=yes --bluray-device= 两个 mpv 参数进入菜单模式。
REM
REM 要求：Windows 本机必须先安装 JRE 17+（推荐 Adoptium Temurin，~55 MB，
REM       下载地址：https://adoptium.net/ ；选择 JRE、x64 安装包即可）。
REM       安装后 JAVA_HOME 通常为
REM         C:\Program Files\Eclipse Adoptium\jre-21.0.4.7-hotspot
REM       只要安装程序在系统环境变量里写了 JAVA_HOME，本脚本就会自动拾取。
REM
REM 如果不使用本 .bat 启动器，也可以手动执行：
REM    set LIBBLURAY_CP=D:\程序\mpv\share\libbluray\libbluray.jar
REM    set BLURAY_JVM_LIB_PATH=C:\Program Files\Eclipse Adoptium\jre-21\bin\server\jvm.dll
REM    mpv.exe --disc-menu=yes --bluray-device="D:\蓝光\碟.iso"  bd://
REM ================================================================
setlocal
  set HERE=%~dp0
  if exist "%HERE%share\libbluray\libbluray.jar" (
    set LIBBLURAY_CP=%HERE%share\libbluray\libbluray.jar
  )
  if not "%JAVA_HOME%"=="" (
    if exist "%JAVA_HOME%\bin\server\jvm.dll" (
      set BLURAY_JVM_LIB_PATH=%JAVA_HOME%\bin\server\jvm.dll
    ) else (
      echo [mpv-omniphony BD-J] 警告: JAVA_HOME=%JAVA_HOME% 下没有 bin\server\jvm.dll
      echo   请确认你安装的是 JRE 而不是只有 JRE 头文件；或前往 https://adoptium.net/ 重新下载。
    )
  ) else (
    echo [mpv-omniphony BD-J] 提示: 未检测到 JAVA_HOME。
    echo   BD-J 蓝光菜单需要 JRE 17+：请安装 Adoptium Temurin JRE 并在 系统属性-环境变量 中设置 JAVA_HOME。
    echo   继续启动可能会报告 "BD-J menus not supported. Java VM: 0, libbluray.jar: 0" 并直接播放主片。
  )
  "%HERE%mpv.exe" --disc-menu=yes --bluray-device=%*
endlocal
