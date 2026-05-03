#!/bin/bash
# ================================================================
#  Marine Larval Dispersal — Installer for Linux
#  CyberTechSea · https://github.com/CyberTechSea/marine-larval-dispersal
#  DOI: 10.5281/zenodo.19955061
#  Tested: Ubuntu 22.04, Debian 12, Fedora 38, Rocky Linux 9
# ================================================================

set -e

ENV_NAME="sim_env"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LAUNCHER="$REPO_DIR/MarineDispersal.sh"
DESKTOP_FILE="$HOME/Desktop/MarineDispersal.desktop"
SERVICE_FILE="$HOME/.config/systemd/user/marine-dispersal.service"
LOG="$REPO_DIR/install.log"

# ── COLORS ──────────────────────────────────────────────────────
GRN='\033[0;32m'; YLW='\033[1;33m'; RED='\033[0;31m'; CYN='\033[0;36m'; NC='\033[0m'
ok()  { echo -e "  ${GRN}✓${NC}  $1" | tee -a "$LOG"; }
inf() { echo -e "  ${CYN}ℹ${NC}  $1"; }
wrn() { echo -e "  ${YLW}⚠${NC}  $1" | tee -a "$LOG"; }
err() { echo -e "  ${RED}✗${NC}  $1" | tee -a "$LOG"; }

# ── HEADER ──────────────────────────────────────────────────────
clear
echo "" | tee "$LOG"
echo -e "${CYN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYN}║${NC}   🌊  Marine Larval Dispersal  v2.0                      ${CYN}║${NC}"
echo -e "${CYN}║${NC}   OceanParcels / CMEMS · CyberTechSea                    ${CYN}║${NC}"
echo -e "${CYN}║${NC}   DOI: 10.5281/zenodo.19955061                           ${CYN}║${NC}"
echo -e "${CYN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "  Installation directory: $REPO_DIR"
echo "  Log: $LOG"
echo ""

# Detect distro
DISTRO="unknown"
[ -f /etc/os-release ] && source /etc/os-release && DISTRO="$NAME"
ARCH=$(uname -m)
inf "Linux: $DISTRO · Arch: $ARCH"

# ── SYSTEM DEPENDENCIES ─────────────────────────────────────────
echo ""
echo "▶  Step 1/7 — Checking system dependencies..."

# curl / wget
if ! command -v curl &>/dev/null && ! command -v wget &>/dev/null; then
    wrn "Neither curl nor wget found. Attempting to install..."
    if command -v apt-get &>/dev/null; then
        sudo apt-get install -y curl 2>/dev/null || true
    elif command -v dnf &>/dev/null; then
        sudo dnf install -y curl 2>/dev/null || true
    elif command -v yum &>/dev/null; then
        sudo yum install -y curl 2>/dev/null || true
    fi
fi

# libGL (needed by Cartopy/Matplotlib on headless systems)
if ! ldconfig -p 2>/dev/null | grep -q libGL; then
    wrn "libGL not found — installing (needed for Cartopy rendering)..."
    if command -v apt-get &>/dev/null; then
        sudo apt-get install -y libgl1-mesa-glx libglib2.0-0 2>/dev/null || \
        sudo apt-get install -y libgl1 2>/dev/null || true
    elif command -v dnf &>/dev/null; then
        sudo dnf install -y mesa-libGL 2>/dev/null || true
    fi
fi
ok "System dependencies OK"

# ── CHECK / INSTALL CONDA ────────────────────────────────────────
echo ""
echo "▶  Step 2/7 — Checking Conda..."

CONDA_FOUND=false
for p in \
    "$HOME/miniconda3/bin/conda" \
    "$HOME/anaconda3/bin/conda" \
    "/opt/conda/bin/conda" \
    "/usr/local/miniconda3/bin/conda" \
    "/opt/miniconda3/bin/conda"; do
    if [ -f "$p" ]; then
        CONDA_BASE="$(dirname $(dirname $p))"
        source "$CONDA_BASE/etc/profile.d/conda.sh" 2>/dev/null || true
        CONDA_FOUND=true
        break
    fi
done

if ! $CONDA_FOUND && command -v conda &>/dev/null; then
    CONDA_BASE="$(conda info --base 2>/dev/null)"
    source "$CONDA_BASE/etc/profile.d/conda.sh" 2>/dev/null || true
    CONDA_FOUND=true
fi

if ! $CONDA_FOUND; then
    err "Conda not found."
    echo ""
    echo "  Choose:"
    echo "  [1] Download and install Miniconda automatically"
    echo "  [2] Exit — I will install Conda manually"
    read -p "  → Choice [1]: " choice
    choice=${choice:-1}

    if [ "$choice" = "1" ]; then
        inf "Downloading Miniconda for $ARCH..."
        if [ "$ARCH" = "aarch64" ]; then
            URL="https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-aarch64.sh"
        else
            URL="https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh"
        fi
        if command -v curl &>/dev/null; then
            curl -Lo /tmp/miniconda.sh "$URL"
        else
            wget -O /tmp/miniconda.sh "$URL"
        fi
        bash /tmp/miniconda.sh -b -p "$HOME/miniconda3"
        source "$HOME/miniconda3/etc/profile.d/conda.sh"
        conda init bash 2>/dev/null || true
        ok "Miniconda installed at $HOME/miniconda3"
    else
        inf "Install from: https://docs.conda.io/en/latest/miniconda.html"
        exit 0
    fi
fi

CONDA_BASE=$(conda info --base)
ok "Conda: $(conda --version)"

# ── CONDA ENVIRONMENT ────────────────────────────────────────────
echo ""
echo "▶  Step 3/7 — Creating Conda environment '$ENV_NAME'..."
inf "This may take 5–15 minutes on first install"
echo ""

if conda env list 2>/dev/null | grep -q "^$ENV_NAME "; then
    inf "Environment '$ENV_NAME' already exists — updating..."
    conda env update -n "$ENV_NAME" \
        -f "$REPO_DIR/environment.yml" \
        --prune 2>&1 | tee -a "$LOG"
else
    conda env create -n "$ENV_NAME" \
        -f "$REPO_DIR/environment.yml" 2>&1 | tee -a "$LOG"
fi
ok "Conda environment ready"

# ── BACKEND DEPENDENCIES ─────────────────────────────────────────
echo ""
echo "▶  Step 4/7 — Installing backend (FastAPI, uvicorn)..."
conda run -n "$ENV_NAME" pip install \
    "fastapi==0.111.0" \
    "uvicorn[standard]==0.29.0" \
    "python-multipart==0.0.9" \
    --quiet 2>&1 | tee -a "$LOG"
ok "FastAPI backend installed"

# ── RE-PIN ZARR / NUMPY ──────────────────────────────────────────
echo ""
echo "▶  Step 5/7 — Resolving OceanParcels dependency conflict..."
conda run -n "$ENV_NAME" pip install \
    "numpy==1.26.4" "zarr==2.16.1" \
    --force-reinstall --quiet 2>&1 | tee -a "$LOG"
ok "zarr==2.16.1 · numpy==1.26.4 pinned"

# ── VERIFY ───────────────────────────────────────────────────────
echo ""
echo "▶  Step 6/7 — Verifying installation..."
VERIFY=$(conda run -n "$ENV_NAME" python -c "
import parcels, fastapi, uvicorn, numpy, zarr, cartopy
print('parcels:',  parcels.__version__)
print('fastapi:',  fastapi.__version__)
print('numpy:',    numpy.__version__)
print('zarr:',     zarr.__version__)
" 2>&1)
if echo "$VERIFY" | grep -q "parcels:"; then
    ok "All packages verified"
    echo "$VERIFY" | while read line; do inf "  $line"; done
else
    wrn "Verification warning — check $LOG"
    echo "$VERIFY" | tee -a "$LOG"
fi

# ── LAUNCHER + SHORTCUTS ─────────────────────────────────────────
echo ""
echo "▶  Step 7/7 — Creating launcher and shortcuts..."

cat > "$LAUNCHER" << LAUNCHER
#!/bin/bash
# Marine Larval Dispersal — Launcher (Linux)

cd "\$(dirname "\$0")"
CONDA_BASE="\$(conda info --base 2>/dev/null || echo '$HOME/miniconda3')"
source "\$CONDA_BASE/etc/profile.d/conda.sh" 2>/dev/null || {
    echo "ERROR: Cannot find Conda. Run the installer first."
    read -p "Press Enter to exit." && exit 1
}

conda activate $ENV_NAME 2>/dev/null || {
    echo "ERROR: Cannot activate environment '$ENV_NAME'. Run installer first."
    read -p "Press Enter to exit." && exit 1
}

clear
echo ""
echo "  🌊  Marine Larval Dispersal  v2.0"
echo "  ──────────────────────────────────────────────────"
echo "  Backend: http://localhost:8000"
echo "  Opening browser in 3 seconds..."
echo "  Press Ctrl+C to stop the server."
echo "  ──────────────────────────────────────────────────"
echo ""

# Open browser (try multiple options)
(sleep 3 && (
    xdg-open   "http://localhost:8000/app/index.html" 2>/dev/null ||
    firefox    "http://localhost:8000/app/index.html" 2>/dev/null ||
    chromium   "http://localhost:8000/app/index.html" 2>/dev/null ||
    google-chrome "http://localhost:8000/app/index.html" 2>/dev/null ||
    echo "  Open your browser at: http://localhost:8000/app/index.html"
)) &

python backend/server.py
LAUNCHER
chmod +x "$LAUNCHER"
ok "Launcher: $LAUNCHER"

# Desktop shortcut
if [ -d "$HOME/Desktop" ]; then
    mkdir -p "$HOME/Desktop"
    cat > "$DESKTOP_FILE" << DESK
[Desktop Entry]
Version=1.0
Type=Application
Name=Marine Larval Dispersal
GenericName=Larval Dispersal Modelling
Comment=OceanParcels/CMEMS Lagrangian simulation GUI
Exec=bash "$LAUNCHER"
Icon=$REPO_DIR/app/logo.png
Terminal=true
StartupNotify=true
Categories=Science;Education;Biology;
Keywords=marine;biology;oceanography;OceanParcels;CMEMS;dispersal;
DESK
    chmod +x "$DESKTOP_FILE"
    ok "Desktop shortcut created"
fi

# Systemd service (optional)
echo ""
read -p "  Install as systemd user service (auto-start on login)? [y/N]: " svc
if [[ "$svc" =~ ^[Yy]$ ]]; then
    mkdir -p "$(dirname $SERVICE_FILE)"
    cat > "$SERVICE_FILE" << SVC
[Unit]
Description=Marine Larval Dispersal Backend (OceanParcels/CMEMS)
After=network.target graphical-session.target
Wants=network.target

[Service]
Type=simple
WorkingDirectory=$REPO_DIR
ExecStart=/bin/bash -c 'source $CONDA_BASE/etc/profile.d/conda.sh && conda activate $ENV_NAME && python backend/server.py'
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
SVC
    systemctl --user daemon-reload 2>/dev/null || true
    systemctl --user enable marine-dispersal.service 2>/dev/null || true
    ok "Systemd service installed"
    inf "  Start:  systemctl --user start marine-dispersal"
    inf "  Stop:   systemctl --user stop marine-dispersal"
    inf "  Logs:   journalctl --user -u marine-dispersal -f"
fi

# ── DONE ─────────────────────────────────────────────────────────
echo ""
echo -e "${GRN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GRN}║  ✓  Installation complete!                               ║${NC}"
echo -e "${GRN}╠══════════════════════════════════════════════════════════╣${NC}"
echo -e "${GRN}║${NC}                                                          ${GRN}║${NC}"
echo -e "${GRN}║${NC}  To start:   bash MarineDispersal.sh                     ${GRN}║${NC}"
echo -e "${GRN}║${NC}  Or open:    Desktop shortcut                            ${GRN}║${NC}"
echo -e "${GRN}║${NC}  Browser:    http://localhost:8000/app/index.html        ${GRN}║${NC}"
echo -e "${GRN}║${NC}                                                          ${GRN}║${NC}"
echo -e "${GRN}║${NC}  Before first simulation:                                ${GRN}║${NC}"
echo -e "${GRN}║${NC}  1. Open the app → Data tab                              ${GRN}║${NC}"
echo -e "${GRN}║${NC}  2. Register at marine.copernicus.eu (free)              ${GRN}║${NC}"
echo -e "${GRN}║${NC}  3. Follow the download wizard                           ${GRN}║${NC}"
echo -e "${GRN}║${NC}                                                          ${GRN}║${NC}"
echo -e "${GRN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""

read -p "  Start the application now? [Y/n]: " start
if [[ ! "$start" =~ ^[Nn]$ ]]; then
    bash "$LAUNCHER"
fi
