cd /D %~dp0\luajit\
luajit.exe ..\main.lua %*
cd ../
pause
@REM timeout 5