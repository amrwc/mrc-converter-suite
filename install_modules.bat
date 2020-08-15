@echo off

SETLOCAL EnableDelayedExpansion

echo Looking for required perl modules...

echo ---- App::cpanminus
perl -MApp::cpanminus -e '1' 2> nul || cpan App::cpanminus 1> nul 2> null
echo ----    Good
echo:

for %%M in ( XML::XPath Bit::Vector Date::Calc Win32::Unicode::File ) do (
    set ret=0
    echo %%M ----
    call :check ret %%M
    IF !ret! neq 0 (
	if "%%M" EQU "Win32::Unicode::File" (
	    echo:    Needs force installing
	    set force=--force
	) else (
	    echo:    Needs installing
	)
	call :install ret %%M !force!
	echo:
    )
)

echo Done installing required modules.
goto:eof

:check 
set "%~1=0"
call perl -M%2 -e '1' 2> nul
IF ERRORLEVEL 1 (
    set "%~1=2"
) ELSE (
    echo:    Already installed
    echo:
)
exit /b

:install 
set "%~1=0"
rem echo args are is %2, %3
call cpanm --quiet %3 %2
IF ERRORLEVEL 1 (
    echo +++ Module installation failed
    set "%~1=2"
)
exit /b


:eof
