# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
# SPDX-License-Identifier: Apache-2.0

# Benchmark climate4R against tests/integration/benchmark_climate4r.py.
#
# Required packages: loadeR and climate4R.climdex.
# Run from the repository root, after running the Python companion:
#
#   Rscript tests/integration/benchmark_climate4r.R

base_url <- "https://sites.ecmwf.int/repository/earthkit-climate"
datasets <- c(
  tasmax = "tasmax_ACCESS-CM2_ssp585_far_future.nc",
  tasmin = "tasmin_ACCESS-CM2_ssp585_far_future.nc",
  pr = "pr_ACCESS-CM2_ssp585_far_future.nc"
)
valid_indicators <- c("PRCPTOT", "SDII", "DTR")

default_data_dir <- function() {
  cache_root <- Sys.getenv("XDG_CACHE_HOME", unset = file.path(path.expand("~"), ".cache"))
  file.path(cache_root, "earthkit-climate", "climate4r-benchmark")
}

usage <- function() {
  cat(paste0(
    "Usage: Rscript tests/integration/benchmark_climate4r.R [options]\n\n",
    "Options:\n",
    "  --repeats N                 Timed runs per indicator (default: 5)\n",
    "  --indicators A,B,...        PRCPTOT, SDII, and/or DTR (default: all)\n",
    "  --data-dir PATH             Directory for shared input files\n",
    "  --output PATH               climate4R summary CSV path\n",
    "  --python-results PATH       Python summary CSV path\n",
    "  --comparison-output PATH    Combined comparison CSV path\n",
    "  --help                      Show this message\n"
  ))
}

parse_args <- function(arguments) {
  options <- list(
    repeats = 5L,
    indicators = valid_indicators,
    data_dir = default_data_dir(),
    output = "tests/integration/benchmark_results/climate4r.csv",
    python_results = "tests/integration/benchmark_results/earthkit_climate.csv",
    comparison_output = "tests/integration/benchmark_results/climate4r_comparison.csv"
  )
  names_by_flag <- c(
    "--repeats" = "repeats",
    "--indicators" = "indicators",
    "--data-dir" = "data_dir",
    "--output" = "output",
    "--python-results" = "python_results",
    "--comparison-output" = "comparison_output"
  )

  position <- 1L
  while (position <= length(arguments)) {
    flag <- arguments[[position]]
    if (flag == "--help") {
      usage()
      quit(status = 0L)
    }
    option_name <- unname(names_by_flag[flag])
    if (is.na(option_name) || position == length(arguments)) {
      stop("Unknown option or missing value: ", flag, call. = FALSE)
    }
    options[[option_name]] <- arguments[[position + 1L]]
    position <- position + 2L
  }

  options$repeats <- suppressWarnings(as.integer(options$repeats))
  if (is.na(options$repeats) || options$repeats < 1L) {
    stop("--repeats must be an integer of at least 1", call. = FALSE)
  }
  if (is.character(options$indicators) && length(options$indicators) == 1L) {
    options$indicators <- strsplit(options$indicators, ",", fixed = TRUE)[[1L]]
  }
  unknown <- setdiff(options$indicators, valid_indicators)
  if (length(unknown) > 0L) {
    stop("Unknown indicator(s): ", paste(unknown, collapse = ", "), call. = FALSE)
  }
  options
}

check_packages <- function() {
  required <- c("loadeR", "climate4R.climdex")
  missing <- required[!vapply(required, requireNamespace, logical(1L), quietly = TRUE)]
  if (length(missing) > 0L) {
    stop("Missing required R package(s): ", paste(missing, collapse = ", "), call. = FALSE)
  }
}

download_datasets <- function(data_dir) {
  dir.create(data_dir, recursive = TRUE, showWarnings = FALSE)
  paths <- file.path(data_dir, datasets)
  names(paths) <- names(datasets)
  for (variable in names(paths)) {
    destination <- paths[[variable]]
    if (file.exists(destination)) {
      next
    }
    temporary <- paste0(destination, ".part")
    cat("Downloading", basename(destination), "...\n")
    tryCatch(
      {
        utils::download.file(
          paste0(base_url, "/", datasets[[variable]]),
          destfile = temporary,
          mode = "wb",
          quiet = FALSE
        )
        if (!file.rename(temporary, destination)) {
          stop("Could not move downloaded file to ", destination)
        }
      },
      finally = if (file.exists(temporary)) unlink(temporary)
    )
  }
  paths
}

load_inputs <- function(paths) {
  list(
    tasmax = loadeR::loadGridData(dataset = paths[["tasmax"]], var = "tasmax", dictionary = FALSE),
    tasmin = loadeR::loadGridData(dataset = paths[["tasmin"]], var = "tasmin", dictionary = FALSE),
    pr = loadeR::loadGridData(dataset = paths[["pr"]], var = "pr", dictionary = FALSE)
  )
}

run_indicator <- function(indicator, inputs) {
  if (indicator == "PRCPTOT" || indicator == "SDII") {
    return(climate4R.climdex::climdexGrid(
      index.code = indicator,
      pr = inputs$pr,
      cal = "gregorian",
      parallel = FALSE
    ))
  }
  climate4R.climdex::climdexGrid(
    index.code = indicator,
    tn = inputs$tasmin,
    tx = inputs$tasmax,
    cal = "gregorian",
    parallel = FALSE
  )
}

validate_result <- function(result, indicator) {
  if (is.null(result$Data) || length(result$Data) == 0L || !any(is.finite(result$Data))) {
    stop(indicator, " returned no finite values", call. = FALSE)
  }
}

benchmark_indicator <- function(indicator, inputs, repeats) {
  cat("Warming up", indicator, "...\n")
  validate_result(run_indicator(indicator, inputs), indicator)

  timings <- numeric(repeats)
  for (repeat_number in seq_len(repeats)) {
    gc(verbose = FALSE)
    started <- proc.time()[["elapsed"]]
    result <- run_indicator(indicator, inputs)
    validate_result(result, indicator)
    timings[[repeat_number]] <- proc.time()[["elapsed"]] - started
    cat(sprintf("  %s %d/%d: %.6f s\n", indicator, repeat_number, repeats, timings[[repeat_number]]))
  }

  data.frame(
    indicator = indicator,
    library = "climate4R",
    mean_seconds = mean(timings),
    median_seconds = stats::median(timings),
    std_seconds = sqrt(mean((timings - mean(timings))^2)),
    repeats = repeats,
    stringsAsFactors = FALSE
  )
}

write_results <- function(results, output) {
  dir.create(dirname(output), recursive = TRUE, showWarnings = FALSE)
  utils::write.csv(results, output, row.names = FALSE)
  cat("Results written to", output, "\n")
}

write_comparison <- function(r_results, python_results_path, output) {
  if (!file.exists(python_results_path)) {
    cat("Python results not found at", python_results_path, "- skipping combined comparison.\n")
    return(invisible(NULL))
  }

  python_results <- utils::read.csv(python_results_path, stringsAsFactors = FALSE)
  python_results <- python_results[python_results$library == "earthkit-climate", ]
  comparison <- merge(
    python_results[c("indicator", "median_seconds")],
    r_results[c("indicator", "median_seconds")],
    by = "indicator",
    suffixes = c("_earthkit", "_climate4r")
  )
  comparison$earthkit_speedup <- comparison$median_seconds_climate4r / comparison$median_seconds_earthkit
  comparison <- comparison[order(match(comparison$indicator, valid_indicators)), ]

  dir.create(dirname(output), recursive = TRUE, showWarnings = FALSE)
  utils::write.csv(comparison, output, row.names = FALSE)
  cat("\nMedian-time comparison (speedup > 1 means earthkit-climate is faster):\n")
  print(comparison, row.names = FALSE)
  cat("Comparison written to", output, "\n")
}

main <- function() {
  options <- parse_args(commandArgs(trailingOnly = TRUE))
  check_packages()
  cat("R", R.version.string, "; repeats=", options$repeats, "\n", sep = "")
  paths <- download_datasets(options$data_dir)
  inputs <- load_inputs(paths)
  rows <- lapply(options$indicators, benchmark_indicator, inputs = inputs, repeats = options$repeats)
  results <- do.call(rbind, rows)
  write_results(results, options$output)
  write_comparison(results, options$python_results, options$comparison_output)
}

main()
