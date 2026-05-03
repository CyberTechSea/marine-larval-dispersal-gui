@echo off
REM ================================================================
REM  Marine Larval Dispersal — Installer for Windows 10/11
REM  CyberTechSea · https://github.com/CyberTechSea/marine-larval-dispersal
REM  DOI: 10.5281/zenodo.19955061
REM ================================================================

setlocal EnableDelayedExpansion
set ENV_NAME=sim_env
set REPO_DIR=%~dp0..
set REPO_DIR=%REPO_DIR:~0,-1%
set LAUNCHER=%REPO_DIR%\MarineDispersal.bat
set LOG=%REPO_DIR%\install.log
set MINICONDA_DIR=%USERPROFILE%\miniconda3

REM ── HEADER ──────────────────────────────────────────────────────
cls
echo.
echo  ============================================================
echo   Marine Larval Dispersal  v2.0
echo   OceanParcels / CMEMS  ·  CyberTechSea
echo   DOI: 10.5281/zenodo.19955061
echo  ============================================================
echo.
echo   Installation directory: %REPO_DIR%
echo   Log file: %LOG%
echo.
echo. > "%LOG%"
echo Marine Larval Dispersal Installer - %DATE% %TIME% >> "%LOG%"
echo. >> "%LOG%"

REM ── CHECK ADMIN (optional, for system-wide installs) ─────────────
net session >nul 2>&1
if %ERRORLEVEL% EQU 0 (
    echo   Running as Administrator
) else (
    echo   Running as standard user ^(recommended^)
)

REM ── DETECT ARCHITECTURE ─────────────────────────────────────────
if "%PROCESSOR_ARCHITECTURE%"=="AMD64" (
    set ARCH=x86_64
    set MINICONDA_URL=https://repo.anaconda.com/miniconda/Miniconda3-latest-Windows-x86_64.exe
) else if "%PROCESSOR_ARCHITEW6432%"=="AMD64" (
    set ARCH=x86_64
    set MINICONDA_URL=https://repo.anaconda.com/miniconda/Miniconda3-latest-Windows-x86_64.exe
) else (
    set ARCH=x86
    set MINICONDA_URL=https://repo.anaconda.com/miniconda/Miniconda3-latest-Windows-x86.exe
)
echo   Architecture: %ARCH%
echo   Architecture: %ARCH% >> "%LOG%"

REM ── STEP 1: CHECK CONDA ─────────────────────────────────────────
echo.
echo  [Step 1/6]  Checking Conda installation...
echo  [Step 1/6]  Checking Conda >> "%LOG%"

set CONDA_EXE=
set CONDA_FOUND=0

REM Check PATH first
where conda >nul 2>&1
if %ERRORLEVEL% EQU 0 (
    set CONDA_FOUND=1
    for /f "tokens=*" %%i in ('where conda 2^>nul') do set CONDA_EXE=%%i
    goto :conda_found
)

REM Check common install locations
for %%p in (
    "%USERPROFILE%\miniconda3\Scripts\conda.exe"
    "%USERPROFILE%\Miniconda3\Scripts\conda.exe"
    "%USERPROFILE%\anaconda3\Scripts\conda.exe"
    "%USERPROFILE%\Anaconda3\Scripts\conda.exe"
    "C:\ProgramData\Miniconda3\Scripts\conda.exe"
    "C:\ProgramData\Anaconda3\Scripts\conda.exe"
    "C:\miniconda3\Scripts\conda.exe"
    "C:\Miniconda3\Scripts\conda.exe"
) do (
    if exist %%p (
        set CONDA_EXE=%%p
        set CONDA_FOUND=1
        goto :conda_found
    )
)

:conda_not_found
echo   Conda not found.
echo.
echo   Choose:
echo   [1] Download and install Miniconda automatically ^(recommended^)
echo   [2] Open Miniconda download page in browser
echo   [3] Exit - I will install Conda manually
echo.
set /p CHOICE="   Choice [1]: "
if "!CHOICE!"=="" set CHOICE=1

if "!CHOICE!"=="1" goto :install_miniconda
if "!CHOICE!"=="2" (
    start https://docs.conda.io/en/latest/miniconda.html
    echo   After installing Miniconda, close and re-run this installer.
    pause & exit /b 0
)
echo   Install Miniconda from: https://docs.conda.io/en/latest/miniconda.html
pause & exit /b 0

:install_miniconda
echo.
echo   Downloading Miniconda...
echo   URL: %MINICONDA_URL%
echo.
set MINICONDA_INSTALLER=%TEMP%\miniconda_installer.exe

REM Try PowerShell download (Windows 10+)
powershell -Command "& {[Net.ServicePointManager]::SecurityProtocol = 'Tls12'; Invoke-WebRequest -Uri '%MINICONDA_URL%' -OutFile '%MINICONDA_INSTALLER%' -UseBasicParsing}" 2>nul
if not exist "%MINICONDA_INSTALLER%" (
    REM Fallback: bitsadmin
    bitsadmin /transfer "MinicondaDownload" /download /priority normal "%MINICONDA_URL%" "%MINICONDA_INSTALLER%" >nul 2>&1
)
if not exist "%MINICONDA_INSTALLER%" (
    echo   ERROR: Download failed. Please download manually from:
    echo   https://docs.conda.io/en/latest/miniconda.html
    pause & exit /b 1
)

echo   Installing Miniconda silently...
start /wait "" "%MINICONDA_INSTALLER%" /S /D=%MINICONDA_DIR%
if %ERRORLEVEL% NEQ 0 (
    echo   ERROR: Miniconda installation failed.
    pause & exit /b 1
)
set CONDA_EXE=%MINICONDA_DIR%\Scripts\conda.exe
set CONDA_FOUND=1
echo   Miniconda installed at %MINICONDA_DIR%

:conda_found
echo   OK  Conda found: %CONDA_EXE%
echo   OK  Conda found: %CONDA_EXE% >> "%LOG%"

REM Derive CONDA_BASE from CONDA_EXE
for %%i in ("%CONDA_EXE%") do set CONDA_SCRIPTS=%%~dpi
set CONDA_BASE=%CONDA_SCRIPTS:~0,-9%

REM ── STEP 2: CREATE CONDA ENVIRONMENT ────────────────────────────
echo.
echo  [Step 2/6]  Creating Conda environment '%ENV_NAME%'...
echo   This may take 5-20 minutes on first install.
echo   Please wait...
echo.
echo  [Step 2/6]  Creating environment >> "%LOG%"

call "%CONDA_EXE%" env list 2>nul | findstr /b "%ENV_NAME% " >nul 2>&1
if %ERRORLEVEL% EQU 0 (
    echo   Environment '%ENV_NAME%' already exists - updating...
    call "%CONDA_EXE%" env update -n %ENV_NAME% -f "%REPO_DIR%\environment.yml" --prune >> "%LOG%" 2>&1
) else (
    call "%CONDA_EXE%" env create -n %ENV_NAME% -f "%REPO_DIR%\environment.yml" >> "%LOG%" 2>&1
)
if %ERRORLEVEL% NEQ 0 (
    echo   ERROR: Failed to create Conda environment. Check %LOG% for details.
    pause & exit /b 1
)
echo   OK  Conda environment '%ENV_NAME%' ready
echo   OK  Conda environment ready >> "%LOG%"

REM ── STEP 3: BACKEND DEPENDENCIES ────────────────────────────────
echo.
echo  [Step 3/6]  Installing backend ^(FastAPI, uvicorn^)...
echo  [Step 3/6]  Installing backend >> "%LOG%"

call "%CONDA_EXE%" run -n %ENV_NAME% pip install ^
    "fastapi==0.111.0" ^
    "uvicorn[standard]==0.29.0" ^
    "python-multipart==0.0.9" ^
    --quiet >> "%LOG%" 2>&1
if %ERRORLEVEL% NEQ 0 (
    echo   WARNING: Backend install may have issues. Check %LOG%
) else (
    echo   OK  FastAPI and uvicorn installed
)

REM ── STEP 4: RE-PIN ZARR / NUMPY ─────────────────────────────────
echo.
echo  [Step 4/6]  Resolving OceanParcels dependency conflict...
echo              ^(pinning zarr==2.16.1 and numpy==1.26.4^)
echo  [Step 4/6]  Pinning zarr/numpy >> "%LOG%"

call "%CONDA_EXE%" run -n %ENV_NAME% pip install ^
    "numpy==1.26.4" "zarr==2.16.1" ^
    --force-reinstall --quiet >> "%LOG%" 2>&1
if %ERRORLEVEL% NEQ 0 (
    echo   WARNING: Re-pinning may have issues. Check %LOG%
) else (
    echo   OK  zarr==2.16.1 and numpy==1.26.4 pinned
)

REM ── STEP 5: VERIFY ───────────────────────────────────────────────
echo.
echo  [Step 5/6]  Verifying installation...
echo  [Step 5/6]  Verification >> "%LOG%"

call "%CONDA_EXE%" run -n %ENV_NAME% python -c ^
    "import parcels,fastapi,numpy,zarr; print('parcels:',parcels.__version__,'fastapi:',fastapi.__version__,'numpy:',numpy.__version__,'zarr:',zarr.__version__)" ^
    >> "%LOG%" 2>&1
if %ERRORLEVEL% EQU 0 (
    echo   OK  All packages verified successfully
) else (
    echo   WARNING: Verification had issues. Check %LOG%
)

REM ── STEP 6: CREATE LAUNCHER ─────────────────────────────────────
echo.
echo  [Step 6/6]  Creating launcher and shortcuts...
echo  [Step 6/6]  Creating launcher >> "%LOG%"

(
echo @echo off
echo REM Marine Larval Dispersal - Launcher for Windows
echo REM Double-click to start the application.
echo.
echo cd /d "%REPO_DIR%"
echo.
echo REM Activate Conda environment
echo set CONDA_BASE=%CONDA_BASE%
echo call "%%CONDA_BASE%%\Scripts\activate.bat" %ENV_NAME% 2^>nul
echo if %%ERRORLEVEL%% NEQ 0 ^(
echo     call "%CONDA_EXE%" activate %ENV_NAME% 2^>nul
echo ^)
echo if %%ERRORLEVEL%% NEQ 0 ^(
echo     echo ERROR: Cannot activate environment '%ENV_NAME%'. Run installer first.
echo     pause ^& exit /b 1
echo ^)
echo.
echo cls
echo echo.
echo echo   Marine Larval Dispersal  v2.0
echo echo   OceanParcels / CMEMS  ·  CyberTechSea
echo echo   --------------------------------------------------
echo echo   Backend starting at: http://localhost:8000
echo echo   Browser will open automatically in 3 seconds.
echo echo   Close this window to stop the server.
echo echo   --------------------------------------------------
echo echo.
echo.
echo REM Open browser after 3 seconds
echo start /b cmd /c "timeout /t 3 /nobreak ^>nul ^&^& start http://localhost:8000/app/index.html"
echo.
echo REM Start backend server
echo python backend\server.py
echo.
echo echo.
echo echo   Server stopped. Press any key to close.
echo pause ^>nul
) > "%LAUNCHER%"

echo   OK  Launcher created: MarineDispersal.bat
echo   OK  Launcher created >> "%LOG%"

REM ── DESKTOP SHORTCUT ─────────────────────────────────────────────
echo.
set /p DESK="  Create Desktop shortcut? [Y/n]: "
if /i "!DESK!"=="" set DESK=Y
if /i "!DESK!"=="Y" (
    set SHORTCUT_PATH=%USERPROFILE%\Desktop\MarineDispersal.lnk
    powershell -ExecutionPolicy Bypass -Command ^
        "$s=(New-Object -ComObject WScript.Shell).CreateShortcut('!SHORTCUT_PATH!');" ^
        "$s.TargetPath='%LAUNCHER%';" ^
        "$s.WorkingDirectory='%REPO_DIR%';" ^
        "$s.Description='Marine Larval Dispersal - OceanParcels/CMEMS';" ^
        "$s.WindowStyle=1;" ^
        "$s.Save()" >nul 2>&1
    if exist "!SHORTCUT_PATH!" (
        echo   OK  Desktop shortcut created
    ) else (
        echo   WARNING: Could not create Desktop shortcut
    )
)

REM ── START MENU ────────────────────────────────────────────────────
set /p SMENU="  Create Start Menu shortcut? [Y/n]: "
if /i "!SMENU!"=="" set SMENU=Y
if /i "!SMENU!"=="Y" (
    set SMENU_DIR=%APPDATA%\Microsoft\Windows\Start Menu\Programs\CyberTechSea
    mkdir "!SMENU_DIR!" >nul 2>&1
    set SM_PATH=!SMENU_DIR!\MarineDispersal.lnk
    powershell -ExecutionPolicy Bypass -Command ^
        "$s=(New-Object -ComObject WScript.Shell).CreateShortcut('!SM_PATH!');" ^
        "$s.TargetPath='%LAUNCHER%';" ^
        "$s.WorkingDirectory='%REPO_DIR%';" ^
        "$s.Description='Marine Larval Dispersal - OceanParcels/CMEMS';" ^
        "$s.Save()" >nul 2>&1
    echo   OK  Start Menu shortcut created in CyberTechSea folder
)

REM ── WINDOWS FIREWALL NOTE ─────────────────────────────────────────
echo.
echo   NOTE: Windows may show a Firewall alert when the server
echo   first starts. Click "Allow access" to enable the local
echo   server on port 8000.

REM ── DONE ─────────────────────────────────────────────────────────
echo.
echo  ============================================================
echo   Installation complete!
echo  ============================================================
echo.
echo   To start the application:
echo     - Double-click  MarineDispersal.bat
echo     - Or use the Desktop / Start Menu shortcut
echo.
echo   The browser will open at:
echo     http://localhost:8000/app/index.html
echo.
echo   Before first simulation:
echo     1. Open the app and go to the Data tab
echo     2. Register free at marine.copernicus.eu
echo     3. Follow the download wizard for CMEMS data
echo.
echo   Installation log saved to: %LOG%
echo  ============================================================
echo.

set /p START_NOW="  Start the application now? [Y/n]: "
if /i "!START_NOW!"=="" set START_NOW=Y
if /i "!START_NOW!"=="Y" (
    start "" "%LAUNCHER%"
)

endlocal
pause
