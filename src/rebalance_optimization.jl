"""
Citi Bike Rebalancing Optimization Model
Minimum-Cost Network Flow (MCNF) Formulation for Bike Sharing Systems

Models and solves the station rebalancing problem using Julia, JuMP,
and the HiGHS LP solver. Station IDs are preserved as canonical strings to
prevent splitting one physical station into duplicates. GPS coordinates are
cleaned per station by selecting a dominant geographic cluster within 500 m
of a medoid observation. Stations with no dominant cluster remain in the
balance ledger but are explicitly excluded from the distance model. An
optional authoritative station-coordinate table can override observations.
Exact integer flows are guaranteed by Total Unimodularity (TUM).
"""

using CSV
using DataFrames
using JuMP
using HiGHS
using Statistics

# ─────────────────────────────────────────────────────────────────────────────
# Haversine distance
# ─────────────────────────────────────────────────────────────────────────────

"""
    haversine_distance(lat1, lon1, lat2, lon2) -> Float64

Great-circle distance in kilometres between two WGS-84 coordinates.
Uses the Haversine formula on a spherical Earth (R = 6 371 km).
This is an as-the-crow-flies approximation; it does not account for
street networks, one-way restrictions, or actual vehicle travel distances.
"""
function haversine_distance(lat1::Real, lon1::Real, lat2::Real, lon2::Real)::Float64
    R = 6371.0
    phi1, phi2 = deg2rad(lat1), deg2rad(lat2)
    dphi  = deg2rad(lat2 - lat1)
    dlam  = deg2rad(lon2 - lon1)
    a = sin(dphi / 2.0)^2 + cos(phi1) * cos(phi2) * sin(dlam / 2.0)^2
    return 2.0 * R * atan(sqrt(a), sqrt(1.0 - a))
end

# ─────────────────────────────────────────────────────────────────────────────
# Station-ID normalisation
# ─────────────────────────────────────────────────────────────────────────────

"""
    normalize_station_id(id_val) -> String

Citi Bike station IDs are officially two-decimal strings such as "6839.10".
When a CSV is parsed as Float64 and then converted back to String, the trailing
zero is dropped ("6839.10" → "6839.1"). This function restores the canonical
two-decimal form so that "6839.10" and "6839.1" are recognised as the same
station.
"""
function normalize_station_id(id_val)::String
    s = strip(string(id_val))
    m = match(r"^(\d+)\.(\d+)$", s)
    if m !== nothing
        decimals = m.captures[2]
        if length(decimals) == 1
            decimals *= "0"
        elseif length(decimals) > 2
            # Do not truncate unexpected precision: that could merge IDs.
            return s
        end
        return "$(m.captures[1]).$decimals"
    end
    return s
end

function load_authoritative_coordinates(path::String)::DataFrame
    isfile(path) || error("Authoritative coordinate file not found: $path")
    coords = CSV.read(path, DataFrame, types=Dict(:station_id => String))
    required = [:station_id, :lat, :lng]
    all(in(propertynames(coords)), required) || error("Authoritative coordinates must contain $(required)")
    coords.station_id = normalize_station_id.(coords.station_id)
    nrow(unique(coords, :station_id)) == nrow(coords) || error("Duplicate station_id values in authoritative coordinates")
    return coords
end

# ─────────────────────────────────────────────────────────────────────────────
# Data loading
# ─────────────────────────────────────────────────────────────────────────────

"""
    load_trip_data(data_path; max_rows=nothing) -> DataFrame

Reads a Citi Bike trip CSV.  Station-ID columns are forced to String so that
`normalize_station_id` can operate on the raw text without float-conversion
artefacts.  Rows with missing station IDs or coordinates are dropped.
`max_rows` optionally restricts the dataset to the first N clean rows.
"""
function load_trip_data(data_path::String; max_rows::Union{Int,Nothing}=nothing)::DataFrame
    isfile(data_path) || error("Trip data file not found: $data_path")

    df = CSV.read(
        data_path,
        DataFrame,
        types=Dict(:start_station_id => String, :end_station_id => String)
    )

    raw_start = copy(df.start_station_id)
    raw_end = copy(df.end_station_id)
    df.start_station_id = normalize_station_id.(raw_start)
    df.end_station_id   = normalize_station_id.(raw_end)
    for (raw, normalized, label) in ((raw_start, df.start_station_id, "start_station_id"),
                                     (raw_end, df.end_station_id, "end_station_id"))
        for ids in groupby(DataFrame(raw=raw, normalized=normalized), :normalized)
            unique_raw = unique(ids.raw)
            if length(unique_raw) > 1 && any(!occursin(r"^\d+\.\d{1,2}$", String(x)) for x in unique_raw)
                error("Ambiguous station ID normalization in $label: $(unique_raw)")
            end
        end
    end

    required = [:start_station_id, :end_station_id,
                :start_lat, :start_lng, :end_lat, :end_lng]
    df_clean = dropmissing(df, required)

    if max_rows !== nothing && max_rows < nrow(df_clean)
        return first(df_clean, max_rows)
    end
    return df_clean
end

# ─────────────────────────────────────────────────────────────────────────────
# Robust representative-coordinate estimation
# ─────────────────────────────────────────────────────────────────────────────

"""
    representative_coordinates(obs_df::DataFrame) -> DataFrame

Given a DataFrame with columns [:station_id, :station_name, :lat, :lng],
returns one representative (lat, lng) per station_id.

Algorithm
─────────
1. For each observation, count the observations within 500 m.
2. Choose the largest such medoid-centred cluster, breaking ties by compactness.
3. Resolve only if that cluster is a strict majority (or a singleton). If not,
   return missing coordinates with status `unresolved`; never average
   contradictory locations.
4. Average only observations in the selected, internally consistent cluster.
"""
function representative_coordinates(obs_df::DataFrame; authoritative_coordinates::Union{DataFrame,Nothing}=nothing)::DataFrame
    rows = NamedTuple{(:station_id, :station_name, :lat, :lng, :coordinate_status, :observation_count),
                      Tuple{String,String,Union{Float64,Missing},Union{Float64,Missing},String,Int}}[]
    auth = authoritative_coordinates === nothing ? Dict{String,Tuple{Float64,Float64}}() :
        Dict(String(r.station_id) => (Float64(r.lat), Float64(r.lng)) for r in eachrow(authoritative_coordinates))

    for grp in groupby(obs_df, :station_id)
        id = String(grp.station_id[1])
        name = String(grp.station_name[1])
        if haskey(auth, id)
            lat, lng = auth[id]
            push!(rows, (id, name, lat, lng, "authoritative", nrow(grp)))
            continue
        end

        n = nrow(grp)
        distances = [haversine_distance(grp.lat[i], grp.lng[i], grp.lat[j], grp.lng[j]) for i in 1:n, j in 1:n]
        counts = [count(distances[i, :] .<= 0.5) for i in 1:n]
        best_count = maximum(counts)
        candidates = findall(==(best_count), counts)
        medoid = candidates[argmin([sum(distances[i, :] .* (distances[i, :] .<= 0.5)) for i in candidates])]
        cluster = findall(distances[medoid, :] .<= 0.5)

        reliable = n == 1 || 2 * length(cluster) > n
        if reliable
            push!(rows, (id, name, mean(grp.lat[cluster]), mean(grp.lng[cluster]), "cluster", n))
        else
            @warn "Station $id ($name) has no dominant GPS cluster within 500 m; excluding it from distance optimization while retaining its balance record."
            push!(rows, (id, name, missing, missing, "unresolved", n))
        end
    end
    return DataFrame(rows)
end

# ─────────────────────────────────────────────────────────────────────────────
# Station balance
# ─────────────────────────────────────────────────────────────────────────────

"""
    compute_station_balance(trips_df) -> (station_data, supply_stations, demand_stations)

Computes per-station inflow, outflow, and net balance from a trips DataFrame.

Net balance is defined as (arrivals − departures) within the sample window.
This is a sample-derived proxy for station inventory shift, NOT a measurement
of physical rack capacity or real-time fill level.

Supply stations: net_change > 0  (more arrivals than departures → surplus)
Demand stations: net_change < 0  (more departures than arrivals → deficit)
Balanced:        net_change = 0
"""
function compute_station_balance(trips_df::DataFrame; authoritative_coordinates::Union{DataFrame,Nothing}=nothing)
    departures = combine(groupby(trips_df, :start_station_id), nrow => :out_count)
    rename!(departures, :start_station_id => :station_id)

    arrivals = combine(groupby(trips_df, :end_station_id), nrow => :in_count)
    rename!(arrivals, :end_station_id => :station_id)

    stations = outerjoin(departures, arrivals, on=:station_id)
    stations.out_count  = coalesce.(stations.out_count, 0)
    stations.in_count   = coalesce.(stations.in_count, 0)
    stations.net_change = stations.in_count .- stations.out_count

    # Pool all coordinate observations for robust filtering
    start_meta = select(trips_df,
        :start_station_id => :station_id,
        :start_station_name => :station_name,
        :start_lat => :lat,
        :start_lng => :lng)
    end_meta = select(trips_df,
        :end_station_id => :station_id,
        :end_station_name => :station_name,
        :end_lat => :lat,
        :end_lng => :lng)
    all_meta = vcat(start_meta, end_meta)

    station_metadata = representative_coordinates(all_meta; authoritative_coordinates=authoritative_coordinates)

    station_data = leftjoin(stations, station_metadata, on=:station_id)
    resolved = filter(row -> !ismissing(row.lat) && !ismissing(row.lng), station_data)

    supply_stations = filter(row -> row.net_change > 0, resolved)
    demand_stations = filter(row -> row.net_change < 0, resolved)

    supply_stations.supply = supply_stations.net_change
    demand_stations.demand = abs.(demand_stations.net_change)

    return station_data, supply_stations, demand_stations
end

# ─────────────────────────────────────────────────────────────────────────────
# Distance matrix
# ─────────────────────────────────────────────────────────────────────────────

"""
    build_distance_matrix(supply_stations, demand_stations) -> Matrix{Float64}

Pairwise Haversine distances (km) between every supply and demand station.
Distances represent as-the-crow-flies separation, not actual road distances.
"""
function build_distance_matrix(supply_stations::DataFrame, demand_stations::DataFrame)::Matrix{Float64}
    ns = nrow(supply_stations)
    nd = nrow(demand_stations)
    C  = zeros(Float64, ns, nd)
    for i in 1:ns
        slat, slng = supply_stations.lat[i], supply_stations.lng[i]
        for j in 1:nd
            C[i, j] = haversine_distance(slat, slng, demand_stations.lat[j], demand_stations.lng[j])
        end
    end
    return C
end

# ─────────────────────────────────────────────────────────────────────────────
# Optimisation model
# ─────────────────────────────────────────────────────────────────────────────

"""
    solve_rebalancing_model(supply_stations, demand_stations, cost_matrix)
        -> (obj_val, total_flow, transfer_results::DataFrame)

Minimum-Cost Network Flow LP solved with HiGHS.

Model
─────
Decision variable x[i,j] ≥ 0: bikes moved from supply node i to demand node j.

Objective: minimise Σ c[i,j] · x[i,j]   [bike-km]

Constraints:
  Σ_j x[i,j] ≤ S[i]               ∀ i  (supply cap)
  Σ_i x[i,j] ≤ D[j]               ∀ j  (demand cap)
  Σ_{i,j} x[i,j] = min(ΣS, ΣD)       (total-flow target)

Integrality: because this is a classical transportation problem on a bipartite
network with integer RHS, the constraint matrix is Totally Unimodular (TUM).
Every LP basic feasible solution is therefore integer-valued. No branch-and-
bound is needed; the LP relaxation is solved and the result is exact integers.

The objective value is in bike-km: Σ (bikes transferred) × (Haversine km).
This is NOT equivalent to vehicle odometer kilometres or fuel cost.
"""
function solve_rebalancing_model(
    supply_stations::DataFrame,
    demand_stations::DataFrame,
    cost_matrix::Matrix{Float64}
)
    ns = nrow(supply_stations)
    nd = nrow(demand_stations)
    I  = 1:ns
    J  = 1:nd

    S = supply_stations.supply
    D = demand_stations.demand
    total_flow = min(sum(S), sum(D))

    model = Model(HiGHS.Optimizer)
    set_silent(model)

    @variable(model, x[I, J] >= 0)

    @objective(model, Min, sum(cost_matrix[i, j] * x[i, j] for i in I, j in J))

    @constraint(model, supply_cap[i in I], sum(x[i, j] for j in J) <= S[i])
    @constraint(model, demand_cap[j in J], sum(x[i, j] for i in I) <= D[j])
    @constraint(model, flow_target,        sum(x[i, j] for i in I, j in J) == total_flow)

    optimize!(model)

    status = termination_status(model)
    status == OPTIMAL || error("Solver did not find optimal solution; status: $status")

    obj_val = objective_value(model)

    rows = NamedTuple{(:from_station_id, :from_station_name,
                        :to_station_id,   :to_station_name,
                        :bikes, :distance_km, :weighted_distance_bike_km),
                      Tuple{String,String,String,String,Int,Float64,Float64}}[]

    for i in I, j in J
        v = value(x[i, j])
        if v > 1e-4
            bikes = Int(round(v))
            dist  = cost_matrix[i, j]
            push!(rows, (
                supply_stations.station_id[i],
                supply_stations.station_name[i],
                demand_stations.station_id[j],
                demand_stations.station_name[j],
                bikes,
                round(dist, digits=4),
                round(bikes * dist, digits=4)
            ))
        end
    end

    results = DataFrame(rows)
    sort!(results, [:bikes, :distance_km], rev=[true, false])

    return obj_val, total_flow, results
end

# ─────────────────────────────────────────────────────────────────────────────
# Entry point
# ─────────────────────────────────────────────────────────────────────────────

"""
    main()

CLI entry point.  Usage:
    julia --project=. src/rebalance_optimization.jl [data_file [max_rows [authoritative_coordinates_file]]]

data_file defaults to data/sample_trips.csv relative to the repo root.
max_rows optionally limits the clean rows loaded (useful for quick tests on
the full raw dataset without pre-filtering).
"""
function main()
    println("=================================================================")
    println("      CITI BIKE REBALANCING OPTIMIZATION (JuMP + HiGHS)         ")
    println("=================================================================")

    repo_root    = normpath(joinpath(@__DIR__, ".."))
    default_path = joinpath(repo_root, "data", "sample_trips.csv")

    data_file = length(ARGS) >= 1 ? ARGS[1] : default_path
    max_rows  = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : nothing
    auth_path = length(ARGS) >= 3 ? ARGS[3] : nothing

    isfile(data_file) || error("Data file not found: $data_file")
    println("Input : $data_file")
    max_rows !== nothing && println("Limit : $max_rows rows")

    trips = load_trip_data(data_file; max_rows=max_rows)
    println("Loaded: $(nrow(trips)) trip records.")

    authoritative = auth_path === nothing ? nothing : load_authoritative_coordinates(auth_path)
    station_data, supply_stations, demand_stations = compute_station_balance(trips; authoritative_coordinates=authoritative)
    total_supply = sum(supply_stations.supply)
    total_demand = sum(demand_stations.demand)
    target_flow  = min(total_supply, total_demand)

    ledger_supply = filter(r -> r.net_change > 0, station_data)
    ledger_demand = filter(r -> r.net_change < 0, station_data)
    ledger_balanced = filter(r -> r.net_change == 0, station_data)
    resolved_count = count(x -> x != "unresolved", station_data.coordinate_status)
    println("\nStation balance (sample-derived net flow):")
    println("  Full balance ledger: $(nrow(station_data)) [$(nrow(ledger_supply)) supply, $(nrow(ledger_demand)) demand, $(nrow(ledger_balanced)) balanced]")
    println("  Resolved coordinates: $resolved_count [$(nrow(supply_stations)) supply, $(nrow(demand_stations)) demand, $(resolved_count - nrow(supply_stations) - nrow(demand_stations)) balanced]")
    println("  Optimization network: $(nrow(supply_stations) + nrow(demand_stations)) nodes")
    unresolved_count = count(isequal("unresolved"), station_data.coordinate_status)
    println("  Unresolved coordinates: $unresolved_count")
    println("  Target flow      : $target_flow bikes")

    C     = build_distance_matrix(supply_stations, demand_stations)
    nvars = length(C)
    println("  Candidate pairs  : $nvars ($(nrow(supply_stations)) × $(nrow(demand_stations)))")

    println("\nSolving Minimum-Cost Network Flow…")
    t0 = time()
    obj_val, flow, results = solve_rebalancing_model(supply_stations, demand_stations, C)
    elapsed = round(time() - t0, digits=2)

    dists = results.distance_km
    println("\n================ OPTIMAL SOLUTION ================")
    println("Solver time                  : $elapsed s")
    println("Objective (bike-km)          : $(round(obj_val, digits=2))")
    println("Total bikes rebalanced       : $flow")
    println("Active assignment pairs      : $(nrow(results))")
    if nrow(results) > 0
        println("Weighted avg dist / bike     : $(round(obj_val/flow, digits=3)) km")
        println("Simple avg dist / pair       : $(round(mean(dists), digits=3)) km")
        println("Median transfer distance     : $(round(median(dists), digits=3)) km")
        println("Min transfer distance        : $(round(minimum(dists), digits=3)) km")
        println("Max transfer distance        : $(round(maximum(dists), digits=3)) km")
    else
        println("No active transfer pairs.")
    end
    println("==================================================\n")

    println("Top 10 assignments (by volume, then distance):")
    show(first(results, min(10, nrow(results))), allrows=true, allcols=true)
    println("\n")

    results_dir  = joinpath(repo_root, "results")
    mkpath(results_dir)
    out_results  = joinpath(results_dir, "optimization_results.csv")
    out_balance  = joinpath(results_dir, "station_balance.csv")

    CSV.write(out_results, results)
    # Export coordinate status so unresolved stations remain identifiable.
    balance_out = select(station_data, :station_id, :station_name,
                         :out_count, :in_count, :net_change,
                         :coordinate_status)
    CSV.write(out_balance, balance_out)

    println("Wrote: $out_results")
    println("Wrote: $out_balance")
    println("Done.")
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
