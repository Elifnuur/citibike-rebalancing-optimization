# Citi Bike Rebalancing Optimization

An **Industrial Engineering and Operations Research portfolio project** that models Citi Bike station rebalancing as a minimum-cost network flow problem using **Julia, JuMP, and HiGHS**.

The objective is to determine how bikes can be redistributed from stations with surplus to stations with demand while minimizing total bike-kilometres.

## Project Overview

Bike-sharing systems often experience imbalances between stations: some accumulate excess bikes while others experience shortages. This project formulates a simplified rebalancing problem as a network optimization model.

The project demonstrates:
- Mathematical optimization using linear programming
- Minimum-cost network flow modeling
- Data cleaning and station-balance analysis
- Geographic coordinate validation and distance calculation
- Reproducible computational experiments and automated testing

## Technologies

- **Julia** — programming language
- **JuMP** — mathematical optimization modeling
- **HiGHS** — optimization solver
- **CSV.jl and DataFrames.jl** — data processing
- **Haversine formula** — straight-line geographic distance calculation

## Benchmark Results

The included benchmark dataset, `data/sample_trips.csv`, contains **750 cleaned trip records**. It is intended as a reproducible modeling benchmark, not as a complete Citi Bike operating period.

| Metric | Result |
|---|---:|
| Stations in the balance ledger | 817 |
| Supply stations | 364 |
| Demand stations | 331 |
| Balanced stations | 122 |
| Stations with resolved coordinates | 814 |
| Nodes in the optimization network | 694 |
| Bikes redistributed | 463 |
| Active origin-destination pairs | 420 |
| Total objective | 255.32 bike-km |
| Weighted average distance per bike | 0.551 km |
| Simple average distance per pair | 0.563 km |
| Median pair distance | 0.446 km |
| Minimum pair distance | 0.060 km |
| Maximum pair distance | 2.596 km |

Three stations — `6644.07`, `8582.09`, and `4617.01` — have unresolved coordinates. They remain in the station balance ledger but are excluded from the distance-based optimization network.

## Methodology

### 1. Station Balance Calculation

For each station, the sample-derived balance is calculated as:

`net_change = arrivals - departures`

Positive balances represent supply, negative balances represent demand, and zero balances indicate balanced stations.

### 2. Coordinate Validation

Station coordinates can be obtained from an optional authoritative station table. If no such table is provided, the model identifies a dominant cluster of trip-observation coordinates within 500 metres of a medoid.

Stations with contradictory observations and no dominant cluster are marked as unresolved. Conflicting coordinates are not averaged.

### 3. Optimization Model

The model routes bikes from supply stations to demand stations while minimizing the total bike-kilometre objective.

The network includes stations with resolved coordinates and nonzero supply or demand. The amount redistributed is limited by the available supply and demand represented in the sample.

### 4. Distance Calculation

Distances are calculated using the Haversine formula. They represent straight-line, as-the-crow-flies distances, not road distances, vehicle odometer distances, or actual travel times.

## Repository Structure

```text
.
├── data/
│   ├── README.md
│   └── sample_trips.csv
├── report/
│   ├── project_report.md
│   └── report_anonymized.qmd
├── results/
│   ├── README.md
│   ├── optimization_results.csv
│   └── station_balance.csv
├── src/
│   └── rebalance_optimization.jl
├── test/
│   └── runtests.jl
├── Project.toml
├── Manifest.toml
├── LICENSE
└── README.md
```

## Reproducing the Results

Install **Julia 1.9 or later** and run the following commands from the repository root.

### 1. Install dependencies

```bash
julia --project=. -e "using Pkg; Pkg.instantiate()"
```

### 2. Run the optimization model

```bash
julia --project=. src/rebalance_optimization.jl
```

### 3. Run automated tests

```bash
julia --project=. test/runtests.jl
```

The default model run reads `data/sample_trips.csv` and generates:

- `results/optimization_results.csv`
- `results/station_balance.csv`

The station balance output uses the following schema:

`station_id, station_name, out_count, in_count, net_change, coordinate_status`

To run the model on another compatible CSV:

```bash
julia --project=. src/rebalance_optimization.jl path/to/trips.csv [max_rows] [path/to/authoritative_station_coordinates.csv]
```

The optional authoritative station-coordinate file must contain unique `station_id`, `lat`, and `lng` columns.

The checked-in `Manifest.toml` records the Julia package environment used by the project.

## Assumptions and Limitations

- Station balances are derived from the included trip sample; they do not represent actual real-time bike inventory.
- The benchmark contains 750 cleaned trip records and is not a complete operating-period dataset.
- Unresolved-coordinate stations are excluded from distance-based optimization.
- Haversine distances are straight-line approximations and do not represent road routes or travel times.
- Results depend on the sample data, coordinate resolution, and model assumptions.

## Data Attribution

The sample was prepared from publicly available [Citi Bike NYC system data](https://citibikenyc.com/system-data).

See [`data/README.md`](data/README.md) for details about the included sample and data-source policy.

## License

The project code is released under the MIT License. See [`LICENSE`](LICENSE) for details.
