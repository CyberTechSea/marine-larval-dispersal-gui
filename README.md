# Marine Larval Dispersal — Graphical User Interface

[![Python 3.11](https://img.shields.io/badge/python-3.11-blue.svg)](https://python.org)
[![FastAPI](https://img.shields.io/badge/FastAPI-0.111-green.svg)](https://fastapi.tiangolo.com)
[![OceanParcels 3.0.2](https://img.shields.io/badge/OceanParcels-3.0.2-green.svg)](https://oceanparcels.org)
[![WoRMS API](https://img.shields.io/badge/WoRMS-API-blue.svg)](https://marinespecies.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A browser-based graphical interface for the **Marine Larval Dispersal** pipeline,
designed for researchers with no command-line experience. The GUI connects to a
local FastAPI backend that runs OceanParcels simulations based on user-defined
species, sites, and temporal replicates.

> **Companion repository (simulation scripts + DOI):**
> https://github.com/CyberTechSea/marine-larval-dispersal
> DOI: https://doi.org/10.5281/zenodo.19955061

---

## What this repository provides

| Component | Description |
|-----------|-------------|
| `app/index.html` | Standalone HTML/JS interface — opens in any browser |
| `app/logo.png` | CyberTechSea logo |
| `backend/server.py` | FastAPI server connecting GUI clicks to OceanParcels |
| `installer/install_mac.sh` | macOS installer (creates conda environments, launcher) |
| `installer/install_linux.sh` | Linux installer |
| `installer/install_windows.bat` | Windows 10/11 installer |
| `download_cmems.sh` | Guided CMEMS data download helper |
| `environment.yml` | Pinned Conda environment for exact reproducibility |

**The simulation scripts** (`larval_dispersal.py`, `plot_comprehensive.py`,
`plot_overview.py`) are maintained in the companion repository above.

---

## Key Features

- **WoRMS API integration** — search any marine species by scientific name;
  larval traits (development type, PLD, larval stage) are auto-populated
  from the World Register of Marine Species
- **CMEMS download wizard** — step-by-step guided download of ocean current
  forcing data directly from the Copernicus Marine Service
- **Flexible simulation design** — configurable sites, temporal replicates
  (hours to years), particle count, PLD, connectivity threshold
- **Real-time progress** — 4-step progress bar with live status updates
- **Publication-quality figures** — trajectory maps, seasonal overview,
  connectivity heatmap, dispersal boxplots (Cartopy rendering)
- **File manager** — download output figures as PNG/SVG/PDF and statistics as CSV
- **Multi-platform** — macOS (Intel + Apple Silicon), Linux, Windows 10/11

---

## Requirements

### Software
- [Miniconda](https://docs.conda.io/en/latest/miniconda.html) or Anaconda
- Free account at [marine.copernicus.eu](https://marine.copernicus.eu) for data

### Hardware

| Platform | CPU | RAM | Disk |
|----------|-----|-----|------|
| macOS Apple Silicon (M1/M2/M3) | M1 or newer | 8 GB | 35 GB |
| macOS Intel | Core i5 or newer | 8 GB | 35 GB |
| Windows 10/11 | Intel/AMD quad-core | 8 GB | 35 GB |
| Linux (Ubuntu 20.04+) | Intel/AMD quad-core | 8 GB | 35 GB |
| Virtual Machine | 4 vCPU | 8 GB | 35 GB |

> Tested on Apple MacBook Pro M2 Pro, 16 GB RAM, 1 TB SSD.
> Simulation runtime: ~45 min for 10,800 particles (M2 Pro).

---

## Installation

### 1. Clone this repository

```bash
git clone https://github.com/CyberTechSea/marine-larval-dispersal-gui.git
cd marine-larval-dispersal-gui
```

### 2. Run the installer for your platform

**macOS:**
```bash
chmod +x installer/install_mac.sh
bash installer/install_mac.sh
```

**Linux:**
```bash
chmod +x installer/install_linux.sh
bash installer/install_linux.sh
```

**Windows:**
Double-click `installer/install_windows.bat`

The installer will:
1. Check and install Miniconda if not present
2. Accept Conda Terms of Service (required since conda 24+)
3. Create the `sim_env` conda environment with all pinned dependencies
4. Create a separate `cmems_download` environment for data download
5. Install the FastAPI backend
6. Create a launcher (`MarineDispersal.command` / `.sh` / `.bat`)
7. Create Desktop and Start Menu shortcuts

> **Important dependency note:** OceanParcels 3.0.2 requires `zarr==2.16.1`
> and `numpy==1.26.4`, which conflict with `copernicusmarine` (requires
> `zarr>=2.18`, `numpy>=2.1`). The installer resolves this by creating
> **two separate environments** — `sim_env` for simulations and
> `cmems_download` for data download. This conflict is documented in:
> https://doi.org/10.5281/zenodo.19955061

---

## Usage

### Step 1 — Download CMEMS forcing data (first time only)

```bash
conda activate cmems_download
bash download_cmems.sh
```

Or follow the step-by-step wizard in the **Data tab** of the GUI.

### Step 2 — Start the application

Double-click `MarineDispersal.command` (macOS) / `MarineDispersal.sh` (Linux) /
`MarineDispersal.bat` (Windows).

Or from terminal:
```bash
conda activate sim_env
python backend/server.py
```

The browser opens automatically at `http://localhost:8000/app/index.html`.

### Step 3 — Run a simulation

1. **Species tab** — search your species via WoRMS or enter parameters manually
2. **Sites tab** — add release coordinates (or load Mediterranean/Adriatic presets)
3. **Replicates tab** — configure temporal replicates (monthly, seasonal, annual…)
4. **Data tab** — set CMEMS file path and output directory
5. Click **Run Simulation**

---

## Architecture

```
Browser (index.html)
    │  HTTP/JSON
    ▼
FastAPI backend (server.py) ←── conda activate sim_env
    │
    ├── /run          POST  Start simulation
    ├── /status       GET   Poll progress (step 0–3, 0–100%)
    ├── /cancel       POST  Cancel running simulation
    ├── /results      GET   Load stats + figure URLs
    ├── /figures/...  GET   Serve PNG/SVG/PDF/CSV files
    ├── /verify_nc    GET   Check NetCDF file (variables, date range)
    ├── /validate_grid GET  Check NEMO grid cell validity
    ├── /health       GET   Server status
    └── /docs         GET   Swagger UI (automatic)
         │
         └── OceanParcels 3.0.2 (RK4 advection + JIT kernels)
                  │
                  └── CMEMS NetCDF (uo, vo velocity fields)
```

---

## Simulation Parameters

All parameters are sent from the GUI to the backend as JSON. Key fields:

| Parameter | Description |
|-----------|-------------|
| `species_name` | Scientific name (for figure labels) |
| `aphia_id` | WoRMS AphiaID (optional, from species search) |
| `pld_days` | Pelagic Larval Duration in days |
| `n_particles` | Particles per site per replicate |
| `depth` | Release depth in metres |
| `settle_km` | Connectivity threshold in km |
| `sites` | List of release sites (code, name, lon, lat, color) |
| `replicates` | List of replicates (name, release date, color) |
| `nc_file` | Path to CMEMS NetCDF file |
| `out_dir` | Output directory for Zarr trajectories and figures |

---

## Dependency Notes

### zarr / numpy / numcodecs pinning

OceanParcels 3.0.2 requires specific versions that must be installed
**via conda** (not pip) to get precompiled ARM/x86 binaries:

```bash
conda install -c conda-forge zarr=2.16.1 numcodecs=0.11.0 numpy=1.26.4 -y
```

Installing via pip may fail on Apple Silicon due to missing C compiler
for `numcodecs`.

### JIT kernel variables

OceanParcels compiles Python kernels to C via JIT. Python closures are
not supported in JIT context. Domain bounds and PLD are stored as
FieldSet constants:

```python
fieldset.add_constant("lon_min", lon_min)
fieldset.add_constant("pld_days", pld_days)

def boundary_check(particle, fieldset, time):
    if particle.lon < fieldset.lon_min:  # correct
        particle.delete()
```

---

## Related Repositories

| Repository | Contents | DOI |
|------------|----------|-----|
| [marine-larval-dispersal](https://github.com/CyberTechSea/marine-larval-dispersal) | Simulation scripts, methods, scientific documentation | [10.5281/zenodo.19955061](https://doi.org/10.5281/zenodo.19955061) |
| [marine-larval-dispersal-gui](https://github.com/CyberTechSea/marine-larval-dispersal-gui) | This repository — GUI frontend and backend | [DOI pending] |

---

## Citation

If you use this GUI in your research, please cite both repositories:

**Simulation pipeline:**
> [CyberTechSea] (2026). A Validated Python Pipeline for Coastal Lagrangian
> Dispersal Modelling with OceanParcels 3.x and CMEMS (v1.0.0). Zenodo.
> https://doi.org/10.5281/zenodo.19955061

**GUI:**
> [CyberTechSea] (2026). Marine Larval Dispersal — Graphical User Interface (v1.0.0).
> Zenodo. https://doi.org/[GUI-DOI-PENDING]
> GitHub: https://github.com/CyberTechSea/marine-larval-dispersal-gui

---

## References

- Delandmeter P. & Van Sebille E. (2019). The Parcels v2.0 Lagrangian framework.
  *Geoscientific Model Development*, 12: 3571–3584.
  https://doi.org/10.5194/gmd-12-3571-2019
- CMEMS Mediterranean Sea Physics Reanalysis.
  https://doi.org/10.48670/mds-00375
- WoRMS Editorial Board (2024). World Register of Marine Species.
  https://www.marinespecies.org

---

## License

MIT License — see [LICENSE](LICENSE) for details.
