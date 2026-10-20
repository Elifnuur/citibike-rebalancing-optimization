# Citi Bike Rebalancing Optimization

An Industrial Engineering / Operations Research portfolio project that formulates Citi Bike station rebalancing as a minimum-cost network-flow model. It uses Julia, JuMP, and HiGHS.

The included benchmark is `data/sample_trips.csv`: 750 cleaned trip records, stored as a text CSV so station IDs such as `6839.10` retain their trailing zeros. The sample is a reproducible modeling benchmark, not a complete Citi Bike operating period.

Latest verified run: the full balance ledger contains 817 stations (364 supply, 331 demand, 122 balanced). Of these, 814 have resolved coordinates; the optimization network contains 694 resolved supply/demand nodes (364 supply, 330 demand). The three unresolved stations are `6644.07`, `8582.09`, and `4617.01`; they remain in the ledger and are excluded from the distance network. The model transferred 463 bikes across 420 active pairs with a 255.32 bike-km objective. Distances were 0.551 km/bike weighted average, 0.563 km/pair simple average, 0.446 km median, 0.060 km minimum, and 2.596 km maximum.

## Method

For each station, the sample-derived balance is arrivals minus departures. Positive balances are supply and negative balances are demand. The model routes the smaller of total supply and total demand while minimizing bike-kilometres.

Station coordinates are resolved from an optional authoritative station table when supplied. Otherwise, the code selects a dominant cluster of trip observations within 500 metres of a medoid. Contradictory observations without a dominant cluster are marked `unresolved` internally and excluded from distance optimization. No conflicting coordinates are averaged.

Distances use the Haversine formula. They are straight-line, as-the-crow-flies distances—not road-network distances, vehicle odometer distances, or route travel times.

## Reproduce

Install Julia 1.9 or later, then from the repository root:

```bash
julia --project=. -e "using Pkg; Pkg.instantiate()"
julia --project=. src/rebalance_optimization.jl
julia --project=. test/runtests.jl
```

The default run reads `data/sample_trips.csv` and writes `results/optimization_results.csv` and `results/station_balance.csv`. The latter has the schema `station_id, station_name, out_count, in_count, net_change, coordinate_status`.

For another compatible CSV, use:

```bash
julia --project=. src/rebalance_optimization.jl path/to/trips.csv [max_rows] [path/to/authoritative_station_coordinates.csv]
```

The optional authoritative file must contain unique `station_id`, `lat`, and `lng` columns. The checked-in `Manifest.toml` pins the Julia package environment; do not commit raw source datasets or local machine paths.

## Repository layout

```text
Project.toml / Manifest.toml       Julia environment
src/rebalance_optimization.jl     model, coordinate validation, CLI
data/sample_trips.csv             reproducible benchmark input
results/                           generated model outputs
test/runtests.jl                   automated tests
report/                             technical reports
```

## Data attribution

The sample was prepared from the public [Citi Bike NYC system data](https://citibikenyc.com/system-data). See `data/README.md` for the included-file description and source policy. Code is released under the MIT License.
