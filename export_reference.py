"""
Export Python reference data for the MATLAB tool (PLAN.md section 9).

Writes matlab/reference/ref_default.mat, ref_e200.mat, ref_reversed.mat.
Read-only with respect to analytic_model/ and output/.

    python export_reference.py              # all three cases
    python export_reference.py --only e200  # one case

IMPORTANT CAVEAT (PLAN.md section 9): in ref_reversed.mat (K_B > K_A) the fields
nl_a_k, nl_u and nl_delta_dose_Gy come from the DEFECTIVE Python spectral_weight()
(defect D2: the second branch is unreachable when K_B >= K_A, so sum_k a_k != 0).
That file carries nl_valid = 0 and those three fields must NOT be used as a target.
"""
import argparse
import sys
from pathlib import Path

import numpy as np
from scipy.io import savemat

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "analytic_model"))

import dataclasses                                     # noqa: E402
from config import ModelParams                         # noqa: E402
from physics import DDD, RangeEnergy                   # noqa: E402
from geometry import (make_spots, rashi_weights, build_pins, n_levels,   # noqa: E402
                      level_wepl_nominal)
from fluence import make_grid, fluence_rashi, fluence_2drm               # noqa: E402
from dose import level_props, compute_dose             # noqa: E402
import nonlocality as nl                               # noqa: E402

OUT_DIR = HERE / "reference"

# (name, overrides) -- all three use expand_mode='replicate', lateral_pixel_mm=0.5
CASES = {
    "default": dict(),
    "e200": dict(energy_MeVu=200.0),
    # K_B > K_A: the ordering Python's spectral_weight() gets wrong
    "reversed": dict(zoneA_levels=(1, 30), zoneB_levels=(1, 50)),
}


def base_params(**over):
    """Default GUI geometry: A 15 mm/60 WEPL, B 15 mm/40 WEPL, x 30 mm, D 3, replicate."""
    p = dataclasses.replace(
        ModelParams(),
        expand_mode="replicate",      # GUI default (user-confirmed)
        lateral_pixel_mm=0.5,         # high-fidelity grid
        **over,
    )
    return p


def lp_struct(lp):
    """LevelProps -> plain dict of float arrays for savemat."""
    return dict(
        wepl=np.asarray(lp.wepl, float),
        t_geom=np.asarray(lp.t_geom, float),
        d_exit0=np.asarray(lp.d_exit0, float),
        theta_dev=np.asarray(lp.theta_dev, float),
        theta_air=np.asarray(lp.theta_air, float),
        E_after=np.asarray(lp.E_after, float),
        air_wepl=float(lp.air_wepl),
    )


def params_struct(p):
    """ModelParams -> dict savemat can write (tuples -> arrays, Path -> str)."""
    d = {}
    for k, v in p.to_dict().items():
        if isinstance(v, tuple):
            d[k] = np.asarray(v, float)
        elif isinstance(v, bool):
            d[k] = int(v)
        elif isinstance(v, (int, float, str)):
            d[k] = v
        else:
            d[k] = str(v)
    return d


def sample_pins(pins, p):
    """Three named pins: in-field zone A, in-field zone B, and an outside pin."""
    half_x = p.n_rows_x * p.spot_spacing_mm / 2.0
    half_y_A = p.n_cols_zoneA * p.spot_spacing_mm
    half_y_B = p.n_cols_zoneB * p.spot_spacing_mm

    def infield(pin):
        return (abs(pin.cx) < half_x and -half_y_A < pin.cy < half_y_B)

    picks = {}
    for pin in pins:
        if infield(pin) and pin.cy < 0 and "inA" not in picks:
            picks["inA"] = pin
        if infield(pin) and pin.cy > 0 and "inB" not in picks:
            picks["inB"] = pin
        if not infield(pin) and "outside" not in picks:
            picks["outside"] = pin
    out = {}
    for tag, pin in picks.items():
        out[tag] = dict(
            cx_mm=float(pin.cx), cy_mm=float(pin.cy),
            original=int(pin.original),
            levels=np.asarray(pin.levels, float),       # 1-based global level indices
            weights=np.asarray(pin.weights, float),
            half_widths_mm=np.asarray(pin.half_widths, float),
        )
    return out


def export_case(name, overrides):
    p = base_params(**overrides)
    KA, KB, K = nl.zone_levels(p)
    print(f"[{name}] K_A={KA} K_B={KB} E={p.energy_MeVu:g} MeV/u  h={p.lateral_pixel_mm} mm")

    ddd = DDD.read(p.ddd_file())
    rng = RangeEnergy(p.dedx_file())
    spots = make_spots(p)
    N = rashi_weights(p, spots)
    W = N.sum(axis=1)
    pins, pin_info = build_pins(p, spots)

    # grid exactly as model.run builds it
    half_x = max(abs(pin_info["pinned_x"][0]), abs(pin_info["pinned_x"][1])) + p.lateral_margin_mm
    half_y = max(abs(pin_info["pinned_y"][0]), abs(pin_info["pinned_y"][1])) + p.lateral_margin_mm
    grid = make_grid(half_x, half_y, p.lateral_pixel_mm)
    sigma0 = p.fwhm0_mm / (2.0 * np.sqrt(2.0 * np.log(2.0)))

    F_R = fluence_rashi(grid, spots, N, sigma0)
    F_M = fluence_2drm(grid, spots, W, sigma0, pins, p.spot_spacing_mm, K)
    lp_R = level_props(p, "rashi", rng)
    lp_M = level_props(p, "2drm", rng)
    z_max = p.z_max_mm if p.z_max_mm > 0 else np.ceil(ddd.peak_depth() + 30.0)

    print(f"[{name}]   grid {grid.shape}, {len(pins)} pins, computing dose ...")
    dose_R, z_edges = compute_dose(p, grid, F_R, lp_R, ddd, z_max)
    dose_M, _ = compute_dose(p, grid, F_M, lp_M, ddd, z_max)

    # non-locality closed form, on the same half-width the GUI will use
    half = float(np.ceil(max(half_x, half_y)))
    nl_dose, nl_ze, nl_xe, nl_ye = nl.predict_delta_dose(p, 1.0, half, ddd=ddd, rng=rng)
    a_k = nl.spectral_weight(p)
    cxe, cye, u, px, v = nl.spatial_profile(p)
    yc_f, f_A = nl.f_zoneA(p)
    _, _, pyA, pyB = nl.zone_fluence_profiles(p)[1:]

    # D2: is this case one the Python spectral_weight gets wrong?
    nl_valid = int(KA > KB)
    sum_a = float(a_k.sum())
    if not nl_valid:
        print(f"[{name}]   *** K_B >= K_A: Python sum(a_k) = {sum_a:g} (should be 0) "
              f"-> nl_valid = 0, nl_* fields are NOT a target")

    md = dict(
        case_name=name,
        params=params_struct(p),
        nl_valid=nl_valid,
        python_sum_a_k=sum_a,
        # --- physics tables
        level_wepl_nominal=level_wepl_nominal(p),
        lp_rashi=lp_struct(lp_R),
        lp_2drm=lp_struct(lp_M),
        ddd_energy=float(ddd.energy),
        ddd_z_mm=ddd.z_mm, ddd_dedz=ddd.dedz,
        ddd_fwhm1=ddd.fwhm1, ddd_factor=ddd.factor, ddd_fwhm2=ddd.fwhm2,
        rng_R0_mm=float(rng.range_mm(p.energy_MeVu)),
        ddd_peak_depth_mm=float(ddd.peak_depth()),
        # --- geometry
        K_A=KA, K_B=KB, K_max=K,
        spot_x_mm=spots.x, spot_y_mm=spots.y,
        spot_x_centers_mm=spots.x_centers, spot_y_centers_mm=spots.y_centers,
        pin_count=int(pin_info["n_pins"]),
        pin_n_original=int(pin_info["n_original"]),
        pin_n_expand=int(pin_info["n_expand"]),
        pinned_x_mm=np.asarray(pin_info["pinned_x"], float),
        pinned_y_mm=np.asarray(pin_info["pinned_y"], float),
        pin_sample=sample_pins(pins, p),
        # --- fluence, Python index order (K+1, nx, ny)
        F_R=F_R, F_M=F_M,
        grid_h_mm=float(grid.h), grid_xe_mm=grid.xe, grid_ye_mm=grid.ye,
        # --- dose
        dose_rashi_Gy=dose_R, dose_2drm_Gy=dose_M,
        z_edges_mm=z_edges, x_edges_mm=grid.xe, y_edges_mm=grid.ye,
        z_max_mm=float(z_max),
        # --- non-locality (see nl_valid)
        nl_half_mm=half,
        nl_delta_dose_Gy=nl_dose,
        nl_z_edges_mm=nl_ze, nl_x_edges_mm=nl_xe, nl_y_edges_mm=nl_ye,
        nl_a_k=a_k, nl_u=u, nl_px=px, nl_v=v,
        nl_f_A=f_A, nl_f_A_yc_mm=yc_f,
        nl_pyA=pyA, nl_pyB=pyB,
        cell_xe_mm=cxe, cell_ye_mm=cye,
    )

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    path = OUT_DIR / f"ref_{name}.mat"
    savemat(str(path), md, do_compression=True, oned_as="column")
    print(f"[{name}]   -> {path}  ({path.stat().st_size/1e6:.1f} MB)")
    return path


def main():
    ap = argparse.ArgumentParser(description="export Python reference data for MATLAB")
    ap.add_argument("--only", help="export just this case (default/e200/reversed)")
    a = ap.parse_args()
    names = [a.only] if a.only else list(CASES)
    for n in names:
        if n not in CASES:
            raise SystemExit(f"unknown case {n!r}; choose from {list(CASES)}")
        export_case(n, CASES[n])
    print("\ndone.")


if __name__ == "__main__":
    main()
