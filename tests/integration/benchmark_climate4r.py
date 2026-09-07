# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
# SPDX-License-Identifier: Apache-2.0

"""Benchmark earthkit-climate against the same workload used by climate4R.

Run this script from the repository root before running the R companion::

    python tests/integration/benchmark_climate4r.py
    Rscript tests/integration/benchmark_climate4r.R

Both scripts exclude downloading and data loading from the timed region. Their
default outputs are written under ``tests/integration/benchmark_results``.
"""

from __future__ import annotations

import argparse
import csv
import gc
import os
import statistics
import sys
import time
import urllib.request
import warnings
from collections.abc import Callable, Sequence
from pathlib import Path
from typing import Any

BASE_URL = "https://sites.ecmwf.int/repository/earthkit-climate"
DATASETS = {
    "tasmax": "tasmax_ACCESS-CM2_ssp585_far_future.nc",
    "tasmin": "tasmin_ACCESS-CM2_ssp585_far_future.nc",
    "pr": "pr_ACCESS-CM2_ssp585_far_future.nc",
}
INDICATORS = ("PRCPTOT", "SDII", "DTR")
RESULT_FIELDS = ("indicator", "library", "mean_seconds", "median_seconds", "std_seconds", "repeats")


def default_data_dir() -> Path:
    """Return the shared cache directory used by the Python and R scripts."""
    cache_root = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache"))
    return cache_root / "earthkit-climate" / "climate4r-benchmark"


def download_datasets(data_dir: Path) -> dict[str, Path]:
    """Download missing sample files and return their local paths."""
    data_dir.mkdir(parents=True, exist_ok=True)
    paths: dict[str, Path] = {}
    for variable, filename in DATASETS.items():
        path = data_dir / filename
        paths[variable] = path
        if path.exists():
            continue

        temporary_path = path.with_suffix(f"{path.suffix}.part")
        print(f"Downloading {filename} ...")
        try:
            urllib.request.urlretrieve(f"{BASE_URL}/{filename}", temporary_path)
            temporary_path.replace(path)
        finally:
            temporary_path.unlink(missing_ok=True)
    return paths


def load_inputs(paths: dict[str, Path]) -> dict[str, Any]:
    """Load each input fully so disk access is outside the timed region."""
    import xarray as xr

    datasets: dict[str, Any] = {}
    for variable, path in paths.items():
        with xr.open_dataset(path) as dataset:
            datasets[variable] = dataset.load()
    return datasets


def indicator_functions(data: dict[str, Any]) -> dict[str, Callable[[], Any]]:
    """Build the three earthkit-climate calls matching climate4R's indices."""
    import xarray as xr

    import earthkit.climate as ekc

    temperature = xr.merge(
        [data["tasmax"][["tasmax"]], data["tasmin"][["tasmin"]]],
        compat="override",
    )
    precipitation = data["pr"][["pr"]]
    return {
        "PRCPTOT": lambda: ekc.indicators.wet_precip_accumulation(
            ds=precipitation,
            thresh="1 mm/day",
            freq="YS",
        ),
        "SDII": lambda: ekc.indicators.daily_pr_intensity(
            ds=precipitation,
            thresh="1 mm/day",
            freq="YS",
            op=">=",
        ),
        "DTR": lambda: ekc.indicators.daily_temperature_range(ds=temperature, freq="MS"),
    }


def materialize_and_validate(result: Any, indicator: str) -> None:
    """Materialize lazy output and reject empty or entirely non-finite results."""
    import numpy as np
    import xarray as xr

    if hasattr(result, "compute"):
        result = result.compute()
    if isinstance(result, xr.Dataset):
        values = result.to_array().values
    elif isinstance(result, xr.DataArray):
        values = result.values
    else:
        values = np.asarray(result)
    if values.size == 0 or not np.isfinite(values).any():
        raise RuntimeError(f"{indicator} returned no finite values")


def benchmark(indicator: str, function: Callable[[], Any], repeats: int) -> dict[str, str | int | float]:
    """Warm up once, then time and summarize repeated executions."""
    print(f"Warming up {indicator} ...")
    materialize_and_validate(function(), indicator)

    timings: list[float] = []
    for repeat in range(1, repeats + 1):
        gc.collect()
        started = time.perf_counter()
        result = function()
        materialize_and_validate(result, indicator)
        elapsed = time.perf_counter() - started
        timings.append(elapsed)
        print(f"  {indicator} {repeat}/{repeats}: {elapsed:.6f} s")

    return {
        "indicator": indicator,
        "library": "earthkit-climate",
        "mean_seconds": statistics.mean(timings),
        "median_seconds": statistics.median(timings),
        "std_seconds": statistics.pstdev(timings),
        "repeats": repeats,
    }


def write_results(rows: list[dict[str, str | int | float]], output: Path) -> None:
    """Write benchmark summaries using the schema shared with the R script."""
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=RESULT_FIELDS)
        writer.writeheader()
        writer.writerows(rows)
    print(f"Results written to {output}")


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    """Parse command-line options."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repeats", type=int, default=5, help="Timed runs per indicator (default: 5).")
    parser.add_argument(
        "--indicators",
        nargs="+",
        choices=INDICATORS,
        default=list(INDICATORS),
        help="Indicators to run (default: all).",
    )
    parser.add_argument("--data-dir", type=Path, default=default_data_dir(), help="Directory for shared input files.")
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("tests/integration/benchmark_results/earthkit_climate.csv"),
        help="Summary CSV path.",
    )
    args = parser.parse_args(argv)
    if args.repeats < 1:
        parser.error("--repeats must be at least 1")
    return args


def main(argv: Sequence[str] | None = None) -> int:
    """Run the earthkit-climate half of the comparison."""
    args = parse_args(argv)
    warnings.filterwarnings("ignore", message=r"Variable does not have a .* attribute\.")
    print(f"Python {sys.version.split()[0]}; repeats={args.repeats}")
    paths = download_datasets(args.data_dir)
    data = load_inputs(paths)
    functions = indicator_functions(data)
    rows = [benchmark(name, functions[name], args.repeats) for name in args.indicators]
    write_results(rows, args.output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
