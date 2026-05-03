#!/bin/bash
# ─────────────────────────────────────────────────────────────────
#  CMEMS Data Download Helper
#  Marine Larval Dispersal GUI
#  https://github.com/CyberTechSea/marine-larval-dispersal-gui
#
#  Run in the cmems_download environment:
#    conda activate cmems_download
#    bash download_cmems.sh
# ─────────────────────────────────────────────────────────────────

for base in "$HOME/miniconda3" "$HOME/opt/miniconda3" \
            "$HOME/anaconda3"  "$HOME/opt/anaconda3"; do
    [ -f "$base/etc/profile.d/conda.sh" ] && \
        source "$base/etc/profile.d/conda.sh" 2>/dev/null && break
done

echo ""
echo "  🌊  CMEMS Data Download"
echo "  ─────────────────────────────────────────────────────────"
echo "  Dataset: MEDSEA_MULTIYEAR_PHY_006_004"
echo "  Simulation scripts: github.com/CyberTechSea/marine-larval-dispersal"
echo "  DOI: 10.5281/zenodo.19955061"
echo "  ─────────────────────────────────────────────────────────"
echo ""

if ! command -v copernicusmarine &>/dev/null; then
    echo "  ERROR: copernicusmarine not found."
    echo "  Run first:"
    echo "    conda create -n cmems_download python=3.11 -y"
    echo "    conda activate cmems_download"
    echo "    pip install copernicusmarine"
    exit 1
fi

echo "▶  Logging in..."
copernicusmarine login

echo ""
read -p "  Output folder [~/cmems_data/]: " OUTDIR
OUTDIR="${OUTDIR:-$HOME/cmems_data}"
OUTDIR="${OUTDIR/#\~/$HOME}"
mkdir -p "$OUTDIR"
read -p "  Start year [1993]: " YS; YS="${YS:-1993}"
read -p "  End year   [2002]: " YE; YE="${YE:-2002}"

echo ""
echo "▶  Downloading med_currents_${YS}_${YE}.nc to $OUTDIR ..."

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
echo "  ✓  Done: $OUTDIR/med_currents_${YS}_${YE}.nc"
echo "  → Open the app, Data tab → Step ③, paste this path."
