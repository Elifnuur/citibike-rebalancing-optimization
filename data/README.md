# Data

`sample_trips.csv` is the checked-in reproducibility input: 750 cleaned trip records and 83,475 bytes in this release copy. Station IDs are stored as text to preserve canonical decimal formatting, including trailing zeros.

Columns are `start_station_id`, `start_station_name`, `start_lat`, `start_lng`, `end_station_id`, `end_station_name`, `end_lat`, and `end_lng`. The sample is a deterministic benchmark subset prepared from public 2023 Citi Bike system data; it is not the complete raw dataset.

The original raw source is not included. See the [Citi Bike NYC system data](https://citibikenyc.com/system-data) page and its data-sharing policy for source and license information. Do not add raw downloads, personal information, or local machine paths to this repository.

Run from the repository root:

```bash
julia --project=. src/rebalance_optimization.jl data/sample_trips.csv
```

An optional authoritative coordinate file may be passed as the fourth CLI argument after the input path and row limit. It must contain unique `station_id`, `lat`, and `lng` columns.
