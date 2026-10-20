using Test
using DataFrames
using CSV
using Logging

# Include source functions; guard prevents main() from running
include(joinpath(@__DIR__, "..", "src", "rebalance_optimization.jl"))

# Helper: run compute_station_balance while keeping expected unresolved-location
# warnings out of the test log.
function station_balance_quiet(trips)
    with_logger(NullLogger()) do
        compute_station_balance(trips)
    end
end

@testset "Citi Bike Rebalancing Optimization Tests" begin

    sample_path = joinpath(@__DIR__, "..", "data", "sample_trips.csv")

    # ── 1. Data loading ────────────────────────────────────────────────────
    @testset "Data loading" begin
        @test isfile(sample_path)

        trips = load_trip_data(sample_path)
        @test nrow(trips) == 750
        @test :start_station_id in propertynames(trips)
        @test :end_station_id   in propertynames(trips)
        @test eltype(trips.start_station_id) <: AbstractString
        @test eltype(trips.end_station_id)   <: AbstractString

        # Station IDs must be in canonical two-decimal format (e.g. "6839.10")
        # No single-decimal IDs (e.g. "6839.1") should remain after normalisation
        for id in vcat(trips.start_station_id, trips.end_station_id)
            @test !occursin(r"^\d+\.\d$", id)
        end
    end

    # ── 2. Station balance & GPS filtering ─────────────────────────────────
    @testset "Station balance and GPS outlier handling" begin
        trips = load_trip_data(sample_path)
        station_data, supply_stations, demand_stations = station_balance_quiet(trips)

        @test nrow(station_data) == length(unique(vcat(trips.start_station_id, trips.end_station_id)))
        @test all(s -> s in ("cluster", "authoritative", "unresolved"), skipmissing(station_data.coordinate_status))

        total_supply = sum(supply_stations.supply)
        total_demand = sum(demand_stations.demand)
        target_flow  = min(total_supply, total_demand)

        @test total_supply >= 0
        @test total_demand >= 0
        @test target_flow == min(total_supply, total_demand)

        # Every station must have valid non-NaN coordinates in NYC region
        for df in (supply_stations, demand_stations)
            @test all(!isnan, df.lat)
            @test all(!isnan, df.lng)
            @test all(l -> 40.4 <= l <= 41.0, df.lat)
            @test all(l -> -74.5 <= l <= -73.5, df.lng)
        end

        @test all(x -> !ismissing(x), station_data.station_id)
        @test all(x -> !ismissing(x), station_data.out_count)
    end

    # ── 3. Optimisation model ──────────────────────────────────────────────
    @testset "Optimisation model" begin
        trips = load_trip_data(sample_path)
        station_data, supply_stations, demand_stations = station_balance_quiet(trips)
        C = build_distance_matrix(supply_stations, demand_stations)

        obj_val, flow, results = solve_rebalancing_model(supply_stations, demand_stations, C)

        @test flow == min(sum(supply_stations.supply), sum(demand_stations.demand))
        @test nrow(results) <= nrow(supply_stations) * nrow(demand_stations)
        @test obj_val >= 0

        # Integrality guaranteed by TUM — no fractional flows
        @test sum(results.bikes) == flow
        @test all(b -> b >= 1, results.bikes)

        # No zero-distance or same-station assignments
        @test all(r -> r.distance_km > 0, eachrow(results))
        @test all(r -> r.from_station_id != r.to_station_id, eachrow(results))

        # weighted_distance_bike_km = bikes × distance_km (rounded)
        for r in eachrow(results)
            @test isapprox(r.weighted_distance_bike_km, r.bikes * r.distance_km, atol=1e-3)
        end

        # Objective ≈ sum of all weighted distances
        @test isapprox(sum(results.weighted_distance_bike_km), obj_val, atol=0.1)
    end

    @testset "Contradictory coordinates are unresolved, not averaged" begin
        obs = DataFrame(station_id=["1.01", "1.01"], station_name=["A", "A"],
                        lat=[40.70, 40.80], lng=[-74.00, -73.90])
        resolved = representative_coordinates(obs)
        @test resolved.coordinate_status[1] == "unresolved"
        @test ismissing(resolved.lat[1])
        @test ismissing(resolved.lng[1])
    end

end
