#!/bin/bash
# ================================================================
#  Marine Larval Dispersal — Installer for macOS
#  CyberTechSea · https://github.com/CyberTechSea/marine-larval-dispersal
#  DOI: 10.5281/zenodo.19955061
# ================================================================

# NO set -e / NO set -o pipefail
# Errors are handled explicitly at each step

ENV_NAME="sim_env"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LAUNCHER="$REPO_DIR/MarineDispersal.command"
LOG="$REPO_DIR/install.log"

GRN='\033[0;32m'; YLW='\033[1;33m'; RED='\033[0;31m'; CYN='\033[0;36m'; NC='\033[0m'
ok()  { echo -e "  ${GRN}✓${NC}  $1"; echo "OK: $1" >> "$LOG"; }
inf() { echo -e "  ${CYN}ℹ${NC}  $1"; }
wrn() { echo -e "  ${YLW}⚠${NC}  $1"; echo "WARN: $1" >> "$LOG"; }
err() { echo -e "  ${RED}✗${NC}  $1"; echo "ERROR: $1" >> "$LOG"; }

clear
echo "" > "$LOG"
echo "Marine Larval Dispersal Installer — $(date)" >> "$LOG"
echo ""

echo -e "${CYN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYN}║${NC}   🌊  Marine Larval Dispersal  v2.0                      ${CYN}║${NC}"
echo -e "${CYN}║${NC}   OceanParcels / CMEMS · CyberTechSea                    ${CYN}║${NC}"
echo -e "${CYN}║${NC}   DOI: 10.5281/zenodo.19955061                           ${CYN}║${NC}"
echo -e "${CYN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "  Directory: $REPO_DIR"
echo "  Log:       $LOG"
echo ""

ARCH=$(uname -m)
OS_VER=$(sw_vers -productVersion 2>/dev/null || echo "unknown")
inf "macOS $OS_VER · $ARCH"
[[ "$ARCH" == "arm64" ]] && inf "Apple Silicon — native ARM build"

# ═══════════════════════════════════════════════════════
# STEP 1 — FIND CONDA
# ═══════════════════════════════════════════════════════
echo ""
echo "▶  Step 1/6 — Checking Conda..."

CONDA_CMD=""

# Try well-known paths first
for p in \
    "$HOME/miniconda3/bin/conda" \
    "$HOME/opt/miniconda3/bin/conda" \
    "$HOME/anaconda3/bin/conda" \
    "$HOME/opt/anaconda3/bin/conda" \
    "/opt/homebrew/Caskroom/miniconda/base/bin/conda" \
    "/opt/conda/bin/conda" \
    "/usr/local/bin/conda"; do
    if [ -x "$p" ]; then
        CONDA_CMD="$p"
        CONDA_BASE="$(dirname $(dirname $p))"
        break
    fi
done

# Source profile if found
if [ -n "$CONDA_CMD" ]; then
    source "$CONDA_BASE/etc/profile.d/conda.sh" 2>/dev/null || true
fi

# Fallback: conda already in PATH
if [ -z "$CONDA_CMD" ] && command -v conda &>/dev/null; then
    CONDA_CMD="$(command -v conda)"
    CONDA_BASE="$(conda info --base 2>/dev/null)"
fi

# Not found — offer to install
if [ -z "$CONDA_CMD" ]; then
    err "Conda not found."
    echo ""
    echo "  [1] Download and install Miniconda automatically (recommended)"
    echo "  [2] Open download page in browser"
    echo "  [3] Exit"
    read -p "  → Choice [1]: " choice
    choice=${choice:-1}
    if [ "$choice" = "1" ]; then
        if [ "$ARCH" = "arm64" ]; then
            URL="https://repo.anaconda.com/miniconda/Miniconda3-latest-MacOSX-arm64.sh"
        else
            URL="https://repo.anaconda.com/miniconda/Miniconda3-latest-MacOSX-x86_64.sh"
        fi
        inf "Downloading Miniconda from $URL ..."
        curl -Lo /tmp/miniconda_install.sh "$URL"
        bash /tmp/miniconda_install.sh -b -p "$HOME/miniconda3"
        source "$HOME/miniconda3/etc/profile.d/conda.sh"
        conda init zsh bash 2>/dev/null || true
        CONDA_CMD="$HOME/miniconda3/bin/conda"
        CONDA_BASE="$HOME/miniconda3"
        ok "Miniconda installed at $HOME/miniconda3"
    elif [ "$choice" = "2" ]; then
        open "https://docs.conda.io/en/latest/miniconda.html"
        exit 0
    else
        exit 0
    fi
fi

# Refresh CONDA_BASE
CONDA_BASE=$("$CONDA_CMD" info --base 2>/dev/null || echo "$CONDA_BASE")
source "$CONDA_BASE/etc/profile.d/conda.sh" 2>/dev/null || true
ok "Conda: $($CONDA_CMD --version 2>/dev/null)"

# ═══════════════════════════════════════════════════════
# STEP 2 — CONDA TOS (required since conda 24+)
# ═══════════════════════════════════════════════════════
echo ""
echo "▶  Step 2/6 — Accepting Conda Terms of Service..."
"$CONDA_CMD" tos accept --override-channels \
    --channel https://repo.anaconda.com/pkgs/main 2>/dev/null || true
"$CONDA_CMD" tos accept --override-channels \
    --channel https://repo.anaconda.com/pkgs/r 2>/dev/null || true
"$CONDA_CMD" tos accept 2>/dev/null || true
ok "Conda Terms of Service accepted"

# ═══════════════════════════════════════════════════════
# STEP 3 — CONDA ENVIRONMENT
# ═══════════════════════════════════════════════════════
echo ""
echo "▶  Step 3/6 — Creating Conda environment '$ENV_NAME'..."
inf "This may take 5–15 minutes on first install"
echo ""

ENV_EXISTS=false
"$CONDA_CMD" env list 2>/dev/null | grep -q "^$ENV_NAME " && ENV_EXISTS=true

if $ENV_EXISTS; then
    inf "Environment '$ENV_NAME' already exists — skipping creation"
    ok "Conda environment '$ENV_NAME' ready"
else
    inf "Creating new environment..."
    "$CONDA_CMD" env create -n "$ENV_NAME" \
        -f "$REPO_DIR/environment.yml" >> "$LOG" 2>&1
    EXITCODE=$?
    # Check if env exists now (exit code may be non-zero due to pip conflicts)
    if "$CONDA_CMD" env list 2>/dev/null | grep -q "^$ENV_NAME "; then
        ok "Conda environment '$ENV_NAME' created"
    else
        err "Environment creation failed (exit code: $EXITCODE)"
        err "Check $LOG for details"
        echo ""
        echo "  Try manually:"
        echo "    $CONDA_CMD tos accept"
        echo "    $CONDA_CMD env create -n $ENV_NAME -f $REPO_DIR/environment.yml"
        exit 1
    fi
fi

# ═══════════════════════════════════════════════════════
# STEP 4 — BACKEND DEPENDENCIES
# ═══════════════════════════════════════════════════════
echo ""
echo "▶  Step 4/6 — Installing backend (FastAPI, uvicorn)..."
"$CONDA_CMD" run -n "$ENV_NAME" pip install \
    "fastapi==0.111.0" \
    "uvicorn[standard]==0.29.0" \
    "python-multipart==0.0.9" \
    --quiet >> "$LOG" 2>&1
ok "FastAPI and uvicorn installed"

# ═══════════════════════════════════════════════════════
# STEP 5 — RE-PIN ZARR / NUMPY / NUMCODECS via conda
# ═══════════════════════════════════════════════════════
echo ""
echo "▶  Step 5/7 — Pinning zarr==2.16.1 · numpy==1.26.4 · numcodecs==0.11.0..."
inf "Using conda (not pip) to get precompiled ARM/x86 binaries"

# Remove pip-installed versions first if present
"$CONDA_CMD" run -n "$ENV_NAME" pip uninstall zarr numcodecs -y >> "$LOG" 2>&1 || true

# Install with conda — precompiled binaries, no wheel build issues
"$CONDA_CMD" install -n "$ENV_NAME" -c conda-forge \
    "numcodecs=0.11.0" \
    "zarr=2.16.1" \
    "numpy=1.26.4" \
    --freeze-installed -y >> "$LOG" 2>&1

NV=$("$CONDA_CMD" run -n "$ENV_NAME" python -c "import numpy; print(numpy.__version__)" 2>/dev/null || echo "?")
ZV=$("$CONDA_CMD" run -n "$ENV_NAME" python -c "import zarr; print(zarr.__version__)" 2>/dev/null || echo "?")
NC=$("$CONDA_CMD" run -n "$ENV_NAME" python -c "import numcodecs; print(numcodecs.__version__)" 2>/dev/null || echo "?")
if [ "$NV" = "1.26.4" ] && [ "$ZV" = "2.16.1" ] && [ "$NC" = "0.11.0" ]; then
    ok "numpy==1.26.4 · zarr==2.16.1 · numcodecs==0.11.0 confirmed"
else
    wrn "numpy=$NV zarr=$ZV numcodecs=$NC — check $LOG"
    inf "Try manually: conda install -n sim_env -c conda-forge numcodecs=0.11.0 zarr=2.16.1 numpy=1.26.4 --freeze-installed"
fi

# ═══════════════════════════════════════════════════════
# STEP 6 — CMEMS DOWNLOAD ENVIRONMENT (separate)
# ═══════════════════════════════════════════════════════
echo ""
echo "▶  Step 6/7 — Creating CMEMS download environment (cmems_download)..."
inf "Separate environment avoids zarr/numpy conflicts with OceanParcels"

DL_ENV="cmems_download"
DL_EXISTS=false
"$CONDA_CMD" env list 2>/dev/null | grep -q "^$DL_ENV " && DL_EXISTS=true

if $DL_EXISTS; then
    inf "Environment '$DL_ENV' already exists — skipping"
    ok "CMEMS download environment ready"
else
    "$CONDA_CMD" create -n "$DL_ENV" python=3.11 -y >> "$LOG" 2>&1
    "$CONDA_CMD" run -n "$DL_ENV" pip install copernicusmarine --quiet >> "$LOG" 2>&1
    DL_VER=$("$CONDA_CMD" run -n "$DL_ENV" python -c \
        "import copernicusmarine; print(copernicusmarine.__version__)" 2>/dev/null || echo "?")
    if [ "$DL_VER" != "?" ]; then
        ok "CMEMS download environment ready (copernicusmarine $DL_VER)"
    else
        wrn "cmems_download setup had issues — install manually:"
        inf "  conda create -n cmems_download python=3.11 -y"
        inf "  conda activate cmems_download && pip install copernicusmarine"
    fi
fi

# Create download helper script
DLSCRIPT="$REPO_DIR/download_cmems.sh"
cat > "$DLSCRIPT" << 'DLEOF'
#!/bin/bash
# ─────────────────────────────────────────────────────────
#  CMEMS Data Download Helper — Marine Larval Dispersal
#  Run this script to download ocean current data.
#  Requires free account at: https://marine.copernicus.eu
# ─────────────────────────────────────────────────────────
for base in "$HOME/miniconda3" "$HOME/opt/miniconda3" \
            "$HOME/anaconda3"  "$HOME/opt/anaconda3"; do
    [ -f "$base/etc/profile.d/conda.sh" ] && \
        source "$base/etc/profile.d/conda.sh" 2>/dev/null && break
done

echo ""
echo "  🌊  CMEMS Data Download"
echo "  ─────────────────────────────────────────────────────"
echo "  Dataset: MEDSEA_MULTIYEAR_PHY_006_004 (~15-25 GB)"
echo "  Requires free account at marine.copernicus.eu"
echo "  ─────────────────────────────────────────────────────"
echo ""

conda activate cmems_download 2>/dev/null || {
    echo "ERROR: Run the main installer first to create cmems_download environment."
    read -p "Press Enter to exit." && exit 1
}

echo "▶  Logging in to Copernicus Marine Service..."
copernicusmarine login

read -p "  Output folder [~/cmems_data/]: " OUTDIR
OUTDIR="${OUTDIR:-$HOME/cmems_data}"
mkdir -p "$OUTDIR"
read -p "  Start year [1993]: " YS; YS="${YS:-1993}"
read -p "  End year   [2002]: " YE; YE="${YE:-2002}"

echo ""
echo "▶  Downloading..."
copernicusmarine subset \
    --dataset-id cmems_mod_med_phy-cur_my_4.2km_P1D-m \
    --variable uo --variable vo \
    --minimum-longitude 3.0  --maximum-longitude 22.0 \
    --minimum-latitude  35.0 --maximum-latitude  47.0 \
    --minimum-depth 1        --maximum-depth 43 \
    --start-datetime "${YS}-01-01T00:00:00" \
    --end-datetime   "${YE}-12-31T23:59:59" \
    --output-filename "med_currents_${YS}_${YE}.nc" \
    --output-directory "$OUTDIR"

echo ""
echo "  ✓  Download complete!"
echo "  File: $OUTDIR/med_currents_${YS}_${YE}.nc"
echo ""
echo "  → Now open the app, go to Data tab → Step ③"
echo "    and set this file path."
DLEOF
chmod +x "$DLSCRIPT"
ok "Download helper created: download_cmems.sh"

# ═══════════════════════════════════════════════════════
# STEP 7 — VERIFY + CREATE LAUNCHER
# ═══════════════════════════════════════════════════════
echo ""
echo "▶  Step 7/7 — Verifying packages and creating launcher..."

VER=$("$CONDA_CMD" run -n "$ENV_NAME" python -c \
    "import parcels,fastapi,numpy,zarr; print('parcels',parcels.__version__,'fastapi',fastapi.__version__,'numpy',numpy.__version__,'zarr',zarr.__version__)" \
    2>/dev/null || echo "")
if [ -n "$VER" ]; then
    ok "Packages: $VER"
else
    wrn "Could not verify all packages — check $LOG"
fi

# Write launcher
cat > "$LAUNCHER" << 'LAUNCH_EOF'
#!/bin/bash
# Marine Larval Dispersal — Launcher (macOS)
# Double-click this file to start the application.

APP_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$APP_DIR"

# Find and activate conda
for base in \
    "$HOME/miniconda3" "$HOME/opt/miniconda3" \
    "$HOME/anaconda3"  "$HOME/opt/anaconda3"  \
    "/opt/homebrew/Caskroom/miniconda/base"; do
    if [ -f "$base/etc/profile.d/conda.sh" ]; then
        source "$base/etc/profile.d/conda.sh" 2>/dev/null && break
    fi
done

conda activate sim_env 2>/dev/null || {
    echo "ERROR: Cannot activate 'sim_env'. Please run install_mac.sh first."
    read -p "Press Enter to exit." dummy
    exit 1
}

clear
echo ""
echo "  🌊  Marine Larval Dispersal  v2.0"
echo "  ───────────────────────────────────────────────────────"
echo "  Backend:  http://localhost:8000"
echo "  Opening browser in 3 seconds..."
echo "  Press Ctrl+C to stop the server."
echo "  ───────────────────────────────────────────────────────"
echo ""

(sleep 3 && open "http://localhost:8000/app/index.html") &
python backend/server.py
LAUNCH_EOF

chmod +x "$LAUNCHER"
xattr -d com.apple.quarantine "$LAUNCHER" 2>/dev/null || true
ok "Launcher created: MarineDispersal.command"

# Desktop alias
echo ""
read -p "  Create alias on Desktop? [Y/n]: " desk
if [[ ! "$desk" =~ ^[Nn]$ ]]; then
    ln -sf "$LAUNCHER" "$HOME/Desktop/MarineDispersal.command" 2>/dev/null || true
    xattr -d com.apple.quarantine "$HOME/Desktop/MarineDispersal.command" 2>/dev/null || true
    ok "Desktop alias created"
fi

# ═══════════════════════════════════════════════════════
# DONE
# ═══════════════════════════════════════════════════════
echo ""
echo -e "${GRN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GRN}║  ✓  Installation complete!                               ║${NC}"
echo -e "${GRN}╠══════════════════════════════════════════════════════════╣${NC}"
echo -e "${GRN}║${NC}  To start: double-click  MarineDispersal.command         ${GRN}║${NC}"
echo -e "${GRN}║${NC}  Or run:   bash MarineDispersal.command                  ${GRN}║${NC}"
echo -e "${GRN}║${NC}                                                          ${GRN}║${NC}"
echo -e "${GRN}║${NC}  Before first simulation:                                ${GRN}║${NC}"
echo -e "${GRN}║${NC}  1. Open app → Data tab                                  ${GRN}║${NC}"
echo -e "${GRN}║${NC}  2. Register free at marine.copernicus.eu                ${GRN}║${NC}"
echo -e "${GRN}║${NC}  3. Follow the download wizard for CMEMS data            ${GRN}║${NC}"
echo -e "${GRN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""

read -p "  Start the application now? [Y/n]: " start
if [[ ! "$start" =~ ^[Nn]$ ]]; then
    bash "$LAUNCHER"
fi
