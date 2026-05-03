"""
backend/server.py
=================
FastAPI backend for the Marine Larval Dispersal GUI.
Connects HTML interface clicks to OceanParcels simulation engine.

Author:      [Francesco Paolo Patti] — [Zoological Station Anton Dohrn]
Email:       [francesco.patti@szn.it]
GitHub:      https://github.com/CyberTechSea/marine-larval-dispersal
DOI:         https://doi.org/10.5281/zenodo.19955061
License:     MIT

Start:
    conda activate sim_env
    python backend/server.py

Or with uvicorn directly:
    uvicorn backend.server:app --host 0.0.0.0 --port 8000 --reload

API endpoints:
    GET  /health          — server health check
    POST /run             — start simulation with user parameters
    GET  /status          — poll simulation progress
    POST /cancel          — cancel running simulation
    GET  /results         — load results from output directory
    GET  /figures/{name}  — serve a figure file
    GET  /files           — list output files with download links
    GET  /validate_grid   — validate site coordinates against NEMO grid
    GET  /verify_nc       — verify NetCDF file variables and date range
    GET  /docs            — automatic Swagger UI (FastAPI built-in)
"""

import os
import sys

# ── Ensure sim_env packages are always visible ────────────────────────────────
# This is needed when the server is launched via launcher or subprocess
# and the conda environment PATH is not fully inherited.
def _add_conda_site():
    # Dynamic: derive from current executable (works if launched with correct python)
    import sysconfig
    sp = sysconfig.get_path("purelib")
    if sp and sp not in sys.path:
        sys.path.insert(0, sp)
    # Static fallback: explicit miniconda path
    _fallback = os.path.expanduser(
        "~/miniconda3/envs/sim_env/lib/python3.11/site-packages"
    )
    if os.path.isdir(_fallback) and _fallback not in sys.path:
        sys.path.insert(0, _fallback)

_add_conda_site()
# ─────────────────────────────────────────────────────────────────────────────

import json
import time
import glob
import threading
import traceback
import subprocess
from datetime import datetime, timedelta
from pathlib import Path
from typing import List, Optional, Dict, Any

import numpy as np
import pandas as pd
from fastapi import FastAPI, HTTPException, BackgroundTasks
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

# ─── APP ─────────────────────────────────────────────────────────────────────

app = FastAPI(
    title="Marine Larval Dispersal API",
    description=(
        "Backend for OceanParcels-CMEMS larval dispersal modelling. "
        "Connects the HTML GUI to the OceanParcels simulation engine for any marine species. "
        "Author: [Francesco Paolo Patti] — [Zoological Station Anton Dohrn] | "
        "Contact: [francesco.patti@szn.it] | "
        "GitHub: https://github.com/CyberTechSea/marine-larval-dispersal | "
        "DOI: 10.5281/zenodo.19955061 | "
        "License: MIT"
    ),
    version="2.0.0",
    contact={"name": "[Francesco Paolo Patti]", "email": "[francesco.patti@szn.it]",
             "url": "https://github.com/CyberTechSea"},
    license_info={"name": "MIT",
                  "url": "https://opensource.org/licenses/MIT"},
)

# Allow requests from the HTML frontend (file:// or localhost)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# Serve the frontend HTML and assets
FRONTEND_DIR = Path(__file__).parent.parent / "app"
if FRONTEND_DIR.exists():
    app.mount("/app", StaticFiles(directory=str(FRONTEND_DIR), html=True), name="app")

# ─── REQUEST MODELS ───────────────────────────────────────────────────────────

class SiteModel(BaseModel):
    code:  str
    name:  str
    lon:   float
    lat:   float
    color: str = "#2196c4"


class ReplicateModel(BaseModel):
    name:  str
    date:  str          # ISO date string: "1993-01-01"
    color: str = "#1565c0"


class SimRequest(BaseModel):
    # Paths
    nc_file:      str   = Field(..., description="Path to CMEMS NetCDF file")
    out_dir:      str   = Field("./results", description="Output directory")

    # Species / biology — no defaults: all values come from the user via the GUI
    species_name: str   = Field("", description="Scientific name of the species (any marine species)")
    larval_stage: str   = Field("", description="Larval stage or type (e.g. Cyphonautes, Nauplius, Trochophore)")
    dev_type:     str   = Field("unknown", description="Development type: planktotrophic, lecithotrophic, direct, unknown")
    aphia_id:     Optional[int] = Field(None, description="WoRMS AphiaID if species was found via WoRMS API")

    # Simulation parameters — default PLD is neutral (user must set species-specific value)
    pld_days:     float = Field(1.0, gt=0, description="Pelagic Larval Duration in days (species-specific, from literature or WoRMS)")
    n_particles:  int   = Field(300,   ge=10, le=2000)
    depth:        float = Field(5.0,   ge=0, le=500)
    settle_km:    float = Field(50.0,  gt=0)

    # Domain / time
    year:         int   = Field(1993)

    # Sites and replicates from user
    sites:        List[SiteModel]
    replicates:   List[ReplicateModel]


# ─── GLOBAL SIMULATION STATE ─────────────────────────────────────────────────

class SimState:
    def __init__(self):
        self.reset()

    def reset(self):
        self.running   = False
        self.cancelled = False
        self.step      = 0       # 0-3
        self.progress  = 0       # 0-100
        self.message   = "Ready"
        self.done      = False
        self.error     = None
        self.out_dir   = None
        self.thread    = None
        self.figures   = {}
        self.stats     = []
        self.files     = []

    def update(self, step=None, progress=None, message=None):
        if step     is not None: self.step     = step
        if progress is not None: self.progress = progress
        if message  is not None: self.message  = message


STATE = SimState()

# ─── ENDPOINTS ────────────────────────────────────────────────────────────────

@app.get("/health")
def health():
    return {"status": "ok", "version": "2.0.0",
            "running": STATE.running, "timestamp": datetime.now().isoformat()}


@app.get("/status")
def status():
    return {
        "running":  STATE.running,
        "step":     STATE.step,
        "progress": STATE.progress,
        "message":  STATE.message,
        "done":     STATE.done,
        "error":    STATE.error,
    }


@app.post("/run")
async def run_simulation(req: SimRequest, background_tasks: BackgroundTasks):
    if STATE.running:
        raise HTTPException(409, "A simulation is already running. Cancel it first.")

    # Validate NC file exists (expand ~ if present)
    nc_file_expanded = str(Path(req.nc_file).expanduser())
    req = req.copy(update={"nc_file": nc_file_expanded})
    if not os.path.exists(req.nc_file):
        raise HTTPException(400, f"NetCDF file not found: {req.nc_file}")

    if not req.sites:
        raise HTTPException(400, "At least one release site is required.")
    if not req.replicates:
        raise HTTPException(400, "At least one replicate is required.")

    STATE.reset()
    STATE.running  = True
    STATE.out_dir  = req.out_dir
    os.makedirs(req.out_dir, exist_ok=True)

    background_tasks.add_task(run_simulation_task, req)
    return {"status": "started", "message": "Simulation queued."}


@app.post("/cancel")
def cancel():
    if not STATE.running:
        return {"status": "not_running"}
    STATE.cancelled = True
    STATE.message   = "Cancelling…"
    return {"status": "cancelling"}


@app.get("/results")
def get_results(out_dir: str = "./results"):
    """Return stats, figure URLs, and file list from an output directory."""
    out = Path(out_dir)
    if not out.exists():
        raise HTTPException(404, f"Output directory not found: {out_dir}")

    # Statistics
    stats = []
    csv_path = out / "dispersal_statistics.csv"
    if csv_path.exists():
        df = pd.read_csv(csv_path)
        stats = df.to_dict(orient="records")

    # Connectivity
    conn_path = out / "connectivity_matrix.csv"
    connectivity = {}
    if conn_path.exists():
        df_c = pd.read_csv(conn_path, index_col=0)
        connectivity = df_c.to_dict()

    # Figure URLs
    figure_map = {
        "overview":     "overview_all_sites.png",
        "seasonal":     "seasonal_patterns_overview.png",
        "connectivity": "connectivity_matrix.png",
        "boxplot":      "dispersal_boxplot.png",
    }
    figures = {}
    for key, fname in figure_map.items():
        p = out / fname
        if p.exists():
            figures[key] = f"/figures/{out_dir}/{fname}"

    # File list (all PNG + CSV in output dir)
    files = []
    for p in sorted(out.glob("*.png")) + sorted(out.glob("*.csv")):
        entry = {
            "name":    p.name,
            "url":     f"/figures/{out_dir}/{p.name}",
            "size_mb": round(p.stat().st_size / 1e6, 2),
        }
        # SVG / PDF variants (if they exist)
        svg = p.with_suffix(".svg")
        pdf = p.with_suffix(".pdf")
        if svg.exists(): entry["svg_url"] = f"/figures/{out_dir}/{svg.name}"
        if pdf.exists(): entry["pdf_url"] = f"/figures/{out_dir}/{pdf.name}"
        if p.suffix == ".csv": entry["csv_url"] = entry["url"]
        files.append(entry)

    return {
        "stats":        stats,
        "connectivity": connectivity,
        "figures":      figures,
        "files":        files,
    }


@app.get("/figures/{path:path}")
def serve_figure(path: str):
    """Serve any figure file by path."""
    p = Path(path)
    if not p.exists():
        raise HTTPException(404, f"File not found: {path}")
    media = {".png": "image/png", ".svg": "image/svg+xml",
             ".pdf": "application/pdf", ".csv": "text/csv"}
    return FileResponse(str(p), media_type=media.get(p.suffix, "application/octet-stream"))


@app.get("/verify_nc")
def verify_nc(path: str):
    """
    Verify that a NetCDF file exists and contains the expected
    velocity variables (uo/vo or equivalents).
    """
    p = Path(path).expanduser()  # expand ~ to full home path
    if not p.exists():
        return {"valid": False, "error": f"File not found: {p}"}
    if not p.suffix == ".nc":
        return {"valid": False, "error": "File must have .nc extension"}
    try:
        import netCDF4 as nc4
        ds = nc4.Dataset(str(p), "r")
        avail   = list(ds.variables.keys())
        u_name  = next((v for v in ["uo", "uo_avg", "vozocrtx"] if v in avail), None)
        v_name  = next((v for v in ["vo", "vo_avg", "vomecrty"] if v in avail), None)
        t_units = ds.variables["time"].units
        t_cal   = getattr(ds.variables["time"], "calendar", "standard")
        dates   = nc4.num2date(ds.variables["time"][:], units=t_units, calendar=t_cal)
        n_t     = len(dates)
        d_start = str(dates[0])[:10]
        d_end   = str(dates[-1])[:10]
        size_gb = round(p.stat().st_size / 1e9, 2)
        ds.close()
        if not u_name or not v_name:
            return {"valid": False,
                    "error": f"Missing velocity variables. Found: {avail}"}
        return {
            "valid":      True,
            "variables":  [u_name, v_name] + [v for v in avail if v not in [u_name, v_name]],
            "timesteps":  n_t,
            "date_range": f"{d_start} → {d_end}",
            "size_gb":    size_gb,
        }
    except Exception as e:
        return {"valid": False, "error": str(e)}



def validate_grid(nc_file: str, lon: float, lat: float):
    """
    Check if a coordinate falls on an ocean cell in the NEMO grid.
    Returns the nearest valid ocean cell if the given point is on land.
    """
    try:
        import netCDF4 as nc4
        ds = nc4.Dataset(nc_file, "r")
        lons_v = ds.variables.get("longitude") or ds.variables.get("lon")
        lats_v = ds.variables.get("latitude")  or ds.variables.get("lat")
        lons_arr = np.array(lons_v[:])
        lats_arr = np.array(lats_v[:])

        best = None
        FILL = 1e10
        for dlon in np.arange(-0.5, 0.55, 0.1):
            for dlat in np.arange(-0.5, 0.55, 0.1):
                li = int(np.argmin(np.abs(lons_arr - (lon + dlon))))
                la = int(np.argmin(np.abs(lats_arr - (lat + dlat))))
                try:
                    u = float(np.array(ds.variables["uo"][0, 0, la, li]))
                except Exception:
                    try:
                        u = float(np.array(ds.variables["uo_avg"][0, 0, la, li]))
                    except Exception:
                        continue
                if abs(u) < FILL:
                    dist = (dlon**2 + dlat**2) ** 0.5
                    if best is None or dist < best["dist"]:
                        best = {
                            "dist": round(dist, 3),
                            "lon":  round(float(lons_arr[li]), 4),
                            "lat":  round(float(lats_arr[la]), 4),
                            "u":    round(u, 5),
                        }
        ds.close()
        if best is None:
            return {"valid": False, "message": "No ocean cell found within 0.5° radius"}
        original_valid = best["dist"] < 0.05
        return {
            "valid":          original_valid,
            "nearest_lon":    best["lon"],
            "nearest_lat":    best["lat"],
            "offset_deg":     best["dist"],
            "relocated":      not original_valid,
            "message":        "Original coordinate is valid." if original_valid
                              else f"Land cell — relocated to {best['lon']}°E, {best['lat']}°N",
        }
    except Exception as e:
        raise HTTPException(500, str(e))


# ─── SIMULATION TASK ─────────────────────────────────────────────────────────

def run_simulation_task(req: SimRequest):
    """
    Background task: builds and executes the OceanParcels simulation
    dynamically from the user's request parameters.
    All parameters are injected at runtime — no hardcoded values.
    """
    try:
        import netCDF4 as nc4
        import xarray as xr
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        import matplotlib.ticker as mticker
        import matplotlib.patches as mpatches
        from matplotlib.lines import Line2D
        from parcels import FieldSet, ParticleSet, JITParticle, AdvectionRK4, Variable

        out_dir = Path(req.out_dir).expanduser()
        out_dir.mkdir(parents=True, exist_ok=True)

        # ── 1. VALIDATE GRID AND BUILD FIELDSET ──────────────────────────────
        STATE.update(step=0, progress=2, message="Validating grid cells and building FieldSet…")

        # Detect variable names
        ds = nc4.Dataset(req.nc_file, "r")
        avail   = list(ds.variables.keys())
        u_name  = next((v for v in ["uo", "uo_avg", "vozocrtx"] if v in avail), None)
        v_name  = next((v for v in ["vo", "vo_avg", "vomecrty"] if v in avail), None)
        lo_name = next((v for v in ["longitude", "lon"] if v in avail), None)
        la_name = next((v for v in ["latitude",  "lat"] if v in avail), None)
        has_dep = "depth" in ds.variables
        lons_arr = np.array(ds.variables[lo_name][:])
        lats_arr = np.array(ds.variables[la_name][:])
        t_units  = ds.variables["time"].units
        t_cal    = getattr(ds.variables["time"], "calendar", "standard")
        dates    = nc4.num2date(ds.variables["time"][:], units=t_units, calendar=t_cal)
        ds.close()

        if not u_name or not v_name:
            raise ValueError(f"Cannot find U/V velocity variables in {req.nc_file}. Available: {avail}")

        # Validate and relocate sites if on land
        sites_validated = []
        for site in req.sites:
            lon_v, lat_v = _find_ocean_cell(req.nc_file, u_name, lons_arr, lats_arr, site.lon, site.lat)
            sites_validated.append({
                "code":  site.code,
                "name":  site.name,
                "lon":   lon_v,
                "lat":   lat_v,
                "color": site.color,
            })

        # Build FieldSet
        variables  = {"U": u_name, "V": v_name}
        dims_u = {"lon": lo_name, "lat": la_name, "time": "time"}
        dims_v = {"lon": lo_name, "lat": la_name, "time": "time"}
        if has_dep:
            dims_u["depth"] = "depth"
            dims_v["depth"] = "depth"
        dimensions = {"U": dims_u, "V": dims_v}

        fieldset = FieldSet.from_netcdf(
            req.nc_file, variables=variables, dimensions=dimensions,
            allow_time_extrapolation=True,
        )

        # Compute domain bounds for boundary check
        lon_min = float(lons_arr.min()) + 1.0
        lon_max = float(lons_arr.max()) - 1.0
        lat_min = float(lats_arr.min()) + 1.0
        lat_max = float(lats_arr.max()) - 1.0

        # ── 2. PARTICLE CLASS & KERNELS ──────────────────────────────────────
        # OceanParcels JIT compiles kernels to C — Python closures are NOT
        # supported. Domain bounds and PLD must be stored as FieldSet constants
        # so the C compiler can access them as fieldset.lon_min etc.

        pld_days = float(req.pld_days)

        # Store constants in FieldSet so JIT kernels can access them
        fieldset.add_constant("lon_min", lon_min)
        fieldset.add_constant("lon_max", lon_max)
        fieldset.add_constant("lat_min", lat_min)
        fieldset.add_constant("lat_max", lat_max)
        fieldset.add_constant("pld_days", pld_days)

        class LarvaParticle(JITParticle):
            age_days  = Variable("age_days",  initial=0.0, dtype=np.float32)
            start_lon = Variable("start_lon", to_write=True, dtype=np.float32)
            start_lat = Variable("start_lat", to_write=True, dtype=np.float32)

        def age_kernel(particle, fieldset, time):
            particle.age_days += particle.dt / 86400.0

        def boundary_check(particle, fieldset, time):
            if particle.lon < fieldset.lon_min or particle.lon > fieldset.lon_max:
                particle.delete()
            if particle.lat < fieldset.lat_min or particle.lat > fieldset.lat_max:
                particle.delete()

        def settle_kernel(particle, fieldset, time):
            if particle.age_days >= fieldset.pld_days:
                particle.delete()

        STATE.update(step=0, progress=10, message="FieldSet ready. Starting particle tracking…")

        # ── 3. RUN SIMULATIONS ───────────────────────────────────────────────
        STATE.update(step=1, progress=12, message="Running particle tracking (RK4)…")

        traj_files = {}
        total_runs = len(sites_validated) * len(req.replicates)
        run_count  = 0

        for site in sites_validated:
            for rep in req.replicates:
                if STATE.cancelled:
                    STATE.running = False
                    STATE.message = "Cancelled by user"
                    return

                run_count += 1
                pct = 12 + int(run_count / total_runs * 58)
                STATE.update(
                    step=1, progress=pct,
                    message=f"[{run_count}/{total_runs}] {site['code']} | {rep.name}"
                )

                np.random.seed(abs(hash(site["code"] + rep.name)) % 2**31)
                lons_r = site["lon"] + np.random.uniform(-0.1, 0.1, req.n_particles)
                lats_r = site["lat"] + np.random.uniform(-0.1, 0.1, req.n_particles)
                deps_r = np.full(req.n_particles, req.depth)

                # Parse release date from ISO string
                rdate  = datetime.fromisoformat(rep.date)
                times  = np.array([rdate] * req.n_particles)

                pset = ParticleSet(
                    fieldset=fieldset, pclass=LarvaParticle,
                    lon=lons_r, lat=lats_r, depth=deps_r, time=times,
                    start_lon=lons_r, start_lat=lats_r,
                )

                fname = str(out_dir / f"traj_{site['code']}_{rep.name}.zarr")
                output  = pset.ParticleFile(name=fname, outputdt=timedelta(hours=24))
                kernels = (AdvectionRK4 + pset.Kernel(boundary_check)
                           + pset.Kernel(age_kernel) + pset.Kernel(settle_kernel))

                pset.execute(
                    kernels,
                    runtime=timedelta(days=pld_days),
                    dt=timedelta(minutes=20),
                    output_file=output,
                )
                traj_files[(site["code"], rep.name)] = fname

        # ── 4. STATISTICS ────────────────────────────────────────────────────
        STATE.update(step=2, progress=72, message="Computing dispersal statistics…")

        def haversine_km(lon1, lat1, lon2, lat2):
            R = 6371.0
            phi1, phi2 = np.radians(lat1), np.radians(lat2)
            a = (np.sin(np.radians(lat2 - lat1) / 2)**2
                 + np.cos(phi1) * np.cos(phi2)
                 * np.sin(np.radians(lon2 - lon1) / 2)**2)
            return 2 * R * np.arcsin(np.sqrt(np.clip(a, 0, 1)))

        records = []
        for (sc, rn), fpath in traj_files.items():
            site = next(s for s in sites_validated if s["code"] == sc)
            ds2  = xr.open_zarr(fpath)
            lons2 = ds2["lon"].values; lats2 = ds2["lat"].values
            ds2.close()
            flons, flats = [], []
            for i in range(lons2.shape[0]):
                v = ~np.isnan(lons2[i])
                flons.append(lons2[i][v][-1] if v.any() else site["lon"])
                flats.append(lats2[i][v][-1] if v.any() else site["lat"])
            flons = np.array(flons); flats = np.array(flats)
            dists = haversine_km(site["lon"], site["lat"], flons, flats)
            records.append({
                "site":           sc,
                "site_name":      site["name"],
                "replicate":      rn,
                "dist_mean_km":   float(np.nanmean(dists)),
                "dist_median_km": float(np.nanmedian(dists)),
                "dist_max_km":    float(np.nanmax(dists)),
                "dist_p95_km":    float(np.nanpercentile(dists, 95)),
                "dist_std_km":    float(np.nanstd(dists)),
                "pct_retained":   float(np.mean(dists < req.settle_km) * 100),
            })

        df = pd.DataFrame(records)
        df.to_csv(out_dir / "dispersal_statistics.csv", index=False, float_format="%.2f")
        STATE.stats = df.to_dict(orient="records")

        # Connectivity matrix
        site_codes = [s["code"] for s in sites_validated]
        n    = len(site_codes)
        conn = np.zeros((n, n)); counts = np.zeros(n)
        for (sc, rn), fpath in traj_files.items():
            s_idx = site_codes.index(sc)
            site  = next(s for s in sites_validated if s["code"] == sc)
            ds2   = xr.open_zarr(fpath)
            lons2 = ds2["lon"].values; lats2 = ds2["lat"].values
            ds2.close()
            flons, flats = [], []
            for i in range(lons2.shape[0]):
                v = ~np.isnan(lons2[i])
                flons.append(lons2[i][v][-1] if v.any() else site["lon"])
                flats.append(lats2[i][v][-1] if v.any() else site["lat"])
            flons = np.array(flons); flats = np.array(flats)
            counts[s_idx] += len(flons)
            for d_idx, dc in enumerate(site_codes):
                dst = next(s for s in sites_validated if s["code"] == dc)
                d   = haversine_km(dst["lon"], dst["lat"], flons, flats)
                conn[s_idx, d_idx] += np.sum(d <= req.settle_km)
        for i in range(n):
            if counts[i] > 0: conn[i, :] = conn[i, :] / counts[i] * 100
        df_conn = pd.DataFrame(conn, index=site_codes, columns=site_codes)
        df_conn.to_csv(out_dir / "connectivity_matrix.csv", float_format="%.2f")

        # ── 5. FIGURES ───────────────────────────────────────────────────────
        STATE.update(step=3, progress=82, message="Generating Cartopy figures…")

        try:
            import cartopy.crs as ccrs
            import cartopy.feature as cfeature
            HAS_CARTOPY = True
        except ImportError:
            HAS_CARTOPY = False

        sp_italic = req.species_name  # italic in figure titles

        def setup_ax(ax, extent=None):
            ext = extent or [5.5, 20, 36.5, 45.5]
            if HAS_CARTOPY:
                ax.set_extent(ext, crs=ccrs.PlateCarree())
                ax.add_feature(cfeature.LAND,      facecolor="#c8b89a", zorder=2)
                ax.add_feature(cfeature.OCEAN,     facecolor="#d0e8f5")
                ax.add_feature(cfeature.COASTLINE, linewidth=0.7, edgecolor="#3a2a10", zorder=4)
                ax.add_feature(cfeature.BORDERS,   linewidth=0.3, edgecolor="#999", zorder=4)
                gl = ax.gridlines(draw_labels=True, linewidth=0.35,
                                  color="gray", alpha=0.5, linestyle="--")
                gl.top_labels = False; gl.right_labels = False
                gl.xlocator = mticker.FixedLocator([6, 9, 12, 15, 18])
                gl.ylocator = mticker.FixedLocator([37, 39, 41, 43, 45])
                gl.xlabel_style = {"size": 7, "color": "gray"}
                gl.ylabel_style = {"size": 7, "color": "gray"}
            else:
                ax.set_facecolor("#d0e8f5")
                ax.set_xlim(ext[0], ext[1]); ax.set_ylim(ext[2], ext[3])
                ax.set_xticks([6, 9, 12, 15, 18]); ax.set_yticks([37, 39, 41, 43, 45])
                ax.tick_params(labelsize=7); ax.grid(True, alpha=0.3, linestyle="--")

        def draw_traj(ax, lons2, lats2, color, alpha=0.55, lw=0.8):
            for i in range(lons2.shape[0]):
                v = ~np.isnan(lons2[i])
                if v.sum() > 1:
                    kw = dict(color=color, alpha=alpha, linewidth=lw, zorder=5)
                    if HAS_CARTOPY: ax.plot(lons2[i][v], lats2[i][v], transform=ccrs.PlateCarree(), **kw)
                    else:           ax.plot(lons2[i][v], lats2[i][v], **kw)

        def draw_marker(ax, lon, lat, color, label, ms=9, fs=9):
            kw_p = dict(color=color, ms=ms, markeredgecolor="white", markeredgewidth=1.3, zorder=8)
            kw_t = dict(fontsize=fs, fontweight="bold", color=color, zorder=9)
            if HAS_CARTOPY:
                ax.plot(lon, lat, "o", transform=ccrs.PlateCarree(), **kw_p)
                ax.text(lon+0.25, lat+0.18, label, transform=ccrs.PlateCarree(), **kw_t)
            else:
                ax.plot(lon, lat, "o", **kw_p); ax.text(lon+0.25, lat+0.18, label, **kw_t)

        rep_colors = [r.color for r in req.replicates]
        rep_names  = [r.name  for r in req.replicates]

        # Figure A: Overview all sites
        STATE.update(progress=84, message="Generating overview map…")
        if HAS_CARTOPY:
            fig, ax = plt.subplots(figsize=(16, 10),
                                   subplot_kw={"projection": ccrs.PlateCarree()})
        else:
            fig, ax = plt.subplots(figsize=(16, 10))
        setup_ax(ax)
        ax.set_title(
            f"{sp_italic} — Overview larval dispersal (all sites · all replicates)\n"
            f"OceanParcels / CMEMS NEMO-OPA · {req.n_particles} particles/site · PLD {req.pld_days} days",
            fontsize=11, fontweight="bold")
        for site in sites_validated:
            for rep in req.replicates:
                fpath = traj_files.get((site["code"], rep.name))
                if not fpath: continue
                ds2 = xr.open_zarr(fpath)
                draw_traj(ax, ds2["lon"].values, ds2["lat"].values, site["color"], alpha=0.25, lw=0.6)
                ds2.close()
        for site in sites_validated:
            draw_marker(ax, site["lon"], site["lat"], site["color"], site["code"]+" "+site["name"], ms=10)
        handles = [mpatches.Patch(color=s["color"], label=s["code"]+" — "+s["name"]) for s in sites_validated]
        ax.legend(handles=handles, loc="upper right", fontsize=8, title="Sites", framealpha=0.9)
        plt.tight_layout()
        out_ov = str(out_dir / "overview_all_sites.png")
        plt.savefig(out_ov, dpi=200, bbox_inches="tight"); plt.close()

        # Figure B: Seasonal overview (one panel per replicate)
        STATE.update(progress=88, message="Generating seasonal overview…")
        n_reps = len(req.replicates)
        ncols  = min(3, n_reps); nrows = (n_reps + ncols - 1) // ncols
        if HAS_CARTOPY:
            fig, axes = plt.subplots(nrows, ncols, figsize=(8*ncols, 7*nrows),
                                     subplot_kw={"projection": ccrs.PlateCarree()})
        else:
            fig, axes = plt.subplots(nrows, ncols, figsize=(8*ncols, 7*nrows))
        axes_flat = np.array(axes).flatten() if n_reps > 1 else [axes]
        for r_idx, (rep, rcol) in enumerate(zip(req.replicates, rep_colors)):
            ax = axes_flat[r_idx]
            setup_ax(ax)
            ax.set_title(f"{rep.name}  ({rep.date})", fontsize=10, fontweight="bold", color=rcol, pad=4)
            for site in sites_validated:
                fpath = traj_files.get((site["code"], rep.name))
                if not fpath: continue
                ds2 = xr.open_zarr(fpath)
                draw_traj(ax, ds2["lon"].values, ds2["lat"].values, site["color"], alpha=0.55, lw=0.8)
                ds2.close()
            for site in sites_validated:
                draw_marker(ax, site["lon"], site["lat"], site["color"], site["code"], ms=8, fs=8)
            site_handles = [mpatches.Patch(color=s["color"], label=s["code"]) for s in sites_validated]
            ax.legend(handles=site_handles, loc="upper right", fontsize=7, framealpha=0.85)
        for ax in axes_flat[n_reps:]: ax.set_visible(False)
        fig.suptitle(
            f"{sp_italic} — Seasonal larval dispersal patterns\n"
            f"CMEMS NEMO-OPA · {req.n_particles} particles/site · PLD {req.pld_days} days · colored by site",
            fontsize=12, fontweight="bold", y=0.98)
        plt.tight_layout(rect=[0, 0, 1, 0.95])
        out_seas = str(out_dir / "seasonal_patterns_overview.png")
        plt.savefig(out_seas, dpi=180, bbox_inches="tight"); plt.close()

        # Figure C: Connectivity matrix
        STATE.update(progress=92, message="Generating connectivity matrix…")
        fig, ax = plt.subplots(figsize=(9, 8))
        vmax = max(conn.max(), 1)
        im   = ax.imshow(conn, cmap="YlOrRd", vmin=0, vmax=vmax)
        cbar = plt.colorbar(im, ax=ax, shrink=0.85,
                            label=f"% particles within {req.settle_km:.0f} km of destination")
        cbar.ax.tick_params(labelsize=9)
        slbls = [s["code"]+"\n"+s["name"] for s in sites_validated]
        ax.set_xticks(range(n)); ax.set_xticklabels(slbls, fontsize=9)
        ax.set_yticks(range(n)); ax.set_yticklabels(slbls, fontsize=9)
        ax.set_xlabel("Destination site", fontsize=10, labelpad=8)
        ax.set_ylabel("Source site",      fontsize=10, labelpad=8)
        ax.set_title(
            f"Connectivity matrix — {sp_italic}\n"
            f"% particles within {req.settle_km:.0f} km  |  {req.n_particles} particles/site  |  PLD {req.pld_days} days",
            fontsize=11, pad=10)
        for i in range(n):
            for j in range(n):
                val = conn[i, j]
                ax.text(j, i, f"{val:.1f}%", ha="center", va="center", fontsize=9,
                        color="white" if val > vmax * 0.6 else "black",
                        fontweight="bold" if i == j else "normal")
        for tick, site in zip(ax.get_xticklabels(), sites_validated):
            tick.set_color(site["color"])
        for tick, site in zip(ax.get_yticklabels(), sites_validated):
            tick.set_color(site["color"])
        plt.tight_layout()
        out_conn = str(out_dir / "connectivity_matrix.png")
        plt.savefig(out_conn, dpi=150, bbox_inches="tight"); plt.close()

        # Figure D: Dispersal boxplots
        STATE.update(progress=95, message="Generating dispersal boxplots…")
        n_sites = len(sites_validated)
        ncols_b = min(3, n_sites); nrows_b = (n_sites + ncols_b - 1) // ncols_b
        fig, axes_b = plt.subplots(nrows_b, ncols_b, figsize=(5*ncols_b, 4*nrows_b), sharey=False)
        axes_b_flat = np.array(axes_b).flatten() if n_sites > 1 else [axes_b]
        for s_idx, site in enumerate(sites_validated):
            ax = axes_b_flat[s_idx]
            all_dists = []; labels = []
            for rep, rcol in zip(req.replicates, rep_colors):
                fpath = traj_files.get((site["code"], rep.name))
                if not fpath: all_dists.append(np.array([0.])); labels.append(rep.name); continue
                ds2 = xr.open_zarr(fpath)
                lons2 = ds2["lon"].values; lats2 = ds2["lat"].values; ds2.close()
                flons, flats = [], []
                for i in range(lons2.shape[0]):
                    v = ~np.isnan(lons2[i])
                    flons.append(lons2[i][v][-1] if v.any() else site["lon"])
                    flats.append(lats2[i][v][-1] if v.any() else site["lat"])
                dists = haversine_km(site["lon"], site["lat"], np.array(flons), np.array(flats))
                all_dists.append(dists); labels.append(rep.name)
            bp = ax.boxplot(all_dists, patch_artist=True,
                            medianprops=dict(color="black", linewidth=2),
                            whiskerprops=dict(linewidth=1.2), capprops=dict(linewidth=1.2),
                            flierprops=dict(marker=".", markersize=3, alpha=0.4))
            for patch, col in zip(bp["boxes"], rep_colors): patch.set_facecolor(col); patch.set_alpha(0.78)
            ax.set_xticklabels(labels, fontsize=8)
            ax.set_ylabel("Dispersal distance (km)", fontsize=8)
            ax.set_title(site["code"]+" — "+site["name"], fontsize=10,
                         fontweight="bold", color=site["color"])
            ax.grid(axis="y", alpha=0.3, linestyle="--")
            ax.axhline(req.settle_km, color="gray", linestyle=":", linewidth=1.2)
            ax.text(0.01, req.settle_km+2, f"{req.settle_km:.0f} km",
                    transform=ax.get_yaxis_transform(), fontsize=7, color="gray")
        for ax in axes_b_flat[n_sites:]: ax.set_visible(False)
        fig.suptitle(
            f"Dispersal distance — {sp_italic}\n"
            f"PLD {req.pld_days} days · {req.n_particles} particles/site  ·  dashed = {req.settle_km:.0f} km threshold",
            fontsize=10, y=1.01)
        plt.tight_layout()
        out_box = str(out_dir / "dispersal_boxplot.png")
        plt.savefig(out_box, dpi=150, bbox_inches="tight"); plt.close()

        # ── SAVE METADATA JSON ────────────────────────────────────────────────
        meta = {
            "species":      req.species_name,
            "larval_stage": req.larval_stage,
            "aphia_id":     req.aphia_id,
            "pld_days":     req.pld_days,
            "n_particles":  req.n_particles,
            "settle_km":    req.settle_km,
            "depth_m":      req.depth,
            "sites":        [s for s in sites_validated],
            "replicates":   [r.dict() for r in req.replicates],
            "completed_at": datetime.now().isoformat(),
        }
        with open(out_dir / "simulation_metadata.json", "w") as f:
            json.dump(meta, f, indent=2)

        # ── DONE ─────────────────────────────────────────────────────────────
        STATE.figures = {
            "overview":     f"/figures/{req.out_dir}/overview_all_sites.png",
            "seasonal":     f"/figures/{req.out_dir}/seasonal_patterns_overview.png",
            "connectivity": f"/figures/{req.out_dir}/connectivity_matrix.png",
            "boxplot":      f"/figures/{req.out_dir}/dispersal_boxplot.png",
        }
        STATE.update(step=3, progress=100, message="Simulation complete!")
        STATE.done    = True
        STATE.running = False

    except Exception as e:
        STATE.error   = str(e)
        STATE.message = f"Error: {str(e)[:120]}"
        STATE.running = False
        STATE.done    = False
        traceback.print_exc()


# ─── GRID VALIDATION HELPER ───────────────────────────────────────────────────

def _find_ocean_cell(nc_file, u_name, lons_arr, lats_arr, lon_target, lat_target, radius=0.5):
    """Return the nearest valid ocean cell for a given coordinate."""
    import netCDF4 as nc4
    FILL = 1e10
    best_dist = None; best_lon = lon_target; best_lat = lat_target
    try:
        ds = nc4.Dataset(nc_file, "r")
        for dlon in np.arange(-radius, radius + 0.1, 0.1):
            for dlat in np.arange(-radius, radius + 0.1, 0.1):
                li = int(np.argmin(np.abs(lons_arr - (lon_target + dlon))))
                la = int(np.argmin(np.abs(lats_arr - (lat_target + dlat))))
                try:
                    u = float(np.array(ds.variables[u_name][0, 0, la, li]))
                except Exception:
                    continue
                if abs(u) < FILL:
                    dist = (dlon**2 + dlat**2) ** 0.5
                    if best_dist is None or dist < best_dist:
                        best_dist = dist
                        best_lon  = float(lons_arr[li])
                        best_lat  = float(lats_arr[la])
        ds.close()
    except Exception:
        pass
    return best_lon, best_lat


# ─── ENTRY POINT ─────────────────────────────────────────────────────────────

if __name__ == "__main__":
    import uvicorn
    print("=" * 60)
    print("  Marine Larval Dispersal — Backend Server v2.0")
    print("  OceanParcels / CMEMS / CyberTechSea")
    print("  Author:  [Francesco Paolo Patti] — [Zoological Station Anton Dohrn]")
    print("  Contact: [francesco.patti@szn.it]")
    print("  GitHub:  https://github.com/CyberTechSea/marine-larval-dispersal")
    print("=" * 60)
    print(f"  API docs:  http://localhost:8000/docs")
    print(f"  Frontend:  http://localhost:8000/app/index.html")
    print(f"  Health:    http://localhost:8000/health")
    print("=" * 60)
    uvicorn.run(
        "server:app",
        host="0.0.0.0",
        port=8000,
        reload=False,
        log_level="info",
    )
