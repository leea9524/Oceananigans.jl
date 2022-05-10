using Statistics
using JLD2
using Printf
using Oceananigans
using Oceananigans.Units

using Oceananigans.MultiRegion
using Oceananigans.MultiRegion: multi_region_object_from_array
using Oceananigans.Fields: interpolate, Field
using Oceananigans.Architectures: arch_array
using Oceananigans.Coriolis: HydrostaticSphericalCoriolis
using Oceananigans.BoundaryConditions
using Oceananigans.ImmersedBoundaries: ImmersedBoundaryGrid, GridFittedBoundary, inactive_node, peripheral_node
using CUDA: @allowscalar, device!
using Oceananigans.Operators
using Oceananigans.Operators: Δzᵃᵃᶜ
using Oceananigans: prognostic_fields

@inline function visualize(field, lev, dims) 
    (dims == 1) && (idx = (lev, :, :))
    (dims == 2) && (idx = (:, lev, :))
    (dims == 3) && (idx = (:, :, lev))

    r = deepcopy(Array(interior(field)))[idx...]
    r[ r.==0 ] .= NaN
    return r
end

#####
##### Grid
#####

arch = CPU()
reference_density = 1029

latitude = (-75, 75)

# 0.25 degree resolution
Nx = 1440
Ny = 600

const Nyears  = 1
const Nmonths = 12 
const thirty_days = 30days

output_prefix = "near_global_lat_lon_$(Nx)_$(Ny)__fine"
pickup_file   = false 

#####
##### Load forcing files and inital conditions from ECCO version 4
##### https://ecco.jpl.nasa.gov/drive/files
##### Bathymetry is interpolated from ETOPO1 https://www.ngdc.noaa.gov/mgg/global/
#####

using DataDeps

path = "https://github.com/CliMA/OceananigansArtifacts.jl/raw/ss/new_hydrostatic_data_after_cleared_bugs/quarter_degree_near_global_input_data/"

datanames = ["z_faces-50-levels",
             "bathymetry-1440x600",
             "tau_x-1440x600-latitude-75",
             "tau_y-1440x600-latitude-75"]

dh = DataDep("quarter_degree_near_global_lat_lon",
    "Forcing data for global latitude longitude simulation",
    [path * data * ".jld2" for data in datanames]
)

DataDeps.register(dh)

datadep"quarter_degree_near_global_lat_lon"

files = [:file_z_faces, :file_bathymetry, :file_tau_x, :file_tau_y]
for (data, file) in zip(datanames, files)
    datadep_path = @datadep_str "quarter_degree_near_global_lat_lon/" * data * ".jld2"
    @eval $file = jldopen($datadep_path)
end

bathymetry = file_bathymetry["bathymetry"]

τˣ = zeros(Nx, Ny, Nmonths)
τʸ = zeros(Nx, Ny, Nmonths)

# Files contain 1 year (1992) of 12 monthly averages
τˣ = file_tau_x["field"] ./ reference_density
τʸ = file_tau_y["field"] ./ reference_density

# Remember the convention!! On the surface a negative flux increases a positive decreases
boundary = Int.(bathymetry .> 0)
bathymetry = arch_array(arch, bathymetry)

# A spherical domain
@show underlying_grid = LatitudeLongitudeGrid(arch,
                                              size = (Nx, Ny),
                                              longitude = (-180, 180),
                                              latitude = latitude,
					      z = (0, 0),
					      halo = (4, 4),
					      topology = (Periodic, Bounded, Flat),
                                              precompute_metrics = true)

grid = ImmersedBoundaryGrid(underlying_grid, GridFittedBoundary(boundary))

τˣ = arch_array(arch, - τˣ)
τʸ = arch_array(arch, - τʸ)
    
#####
##### Boundary conditions / time-dependent fluxes 
#####

@inline current_time_index(time, tot_months)     = mod(unsafe_trunc(Int32, time / thirty_days), tot_months) + 1
@inline next_time_index(time, tot_months)        = mod(unsafe_trunc(Int32, time / thirty_days) + 1, tot_months) + 1
@inline cyclic_interpolate(u₁::Number, u₂, time) = u₁ + mod(time / thirty_days, 1) * (u₂ - u₁)

@inline function boundary_stress_u(i, j, k, grid, clock, fields, p)
    time = clock.time
    n₁ = current_time_index(time, Nmonths)
    n₂ = next_time_index(time, Nmonths)

    @inbounds begin
        τ₁ = p.τ[i, j, n₁]
        τ₂ = p.τ[i, j, n₂]
    end

    return (cyclic_interpolate(τ₁, τ₂, time) - p.μ * fields.u[i, j, k]) / fields.h[i, j, k]
end


@inline function boundary_stress_v(i, j, k, grid, clock, fields, p)
    time = clock.time
    n₁ = current_time_index(time, Nmonths)
    n₂ = next_time_index(time, Nmonths)

    @inbounds begin
        τ₁ = p.τ[i, j, n₁]
        τ₂ = p.τ[i, j, n₂]
    end

    return (cyclic_interpolate(τ₁, τ₂, time) - p.μ * fields.v[i, j, k]) / fields.h[i, j, k]
end

# Linear bottom drag:
μ = 0.001 # ms⁻¹

Fu = Forcing(boundary_stress_u, discrete_form = true, parameters = (μ = μ, τ = τˣ))
Fv = Forcing(boundary_stress_v, discrete_form = true, parameters = (μ = μ, τ = τʸ))

using Oceananigans.Models.ShallowWaterModels: VectorInvariantFormulation
using Oceananigans.Advection: VelocityStencil

model = ShallowWaterModel(grid = grid,
			  gravitational_acceleration = 9.8065,
                          advection = WENO5(vector_invariant = VelocityStencil()),
                          coriolis = HydrostaticSphericalCoriolis(),
                          forcing = (u=Fu, v=Fv),
#			  bathymetry = bathymetry,
			  formulation = VectorInvariantFormulation())

#####
##### Initial condition:
#####

h_init = 5000.0 # .+ bathymetry
set!(model, h=h_init)
@info "model initialized"

#####
##### Simulation setup
#####

#  Δt = 6minutes  # for initialization, then we can go up to 6 minutes?
#  
#  simulation = Simulation(model, Δt = Δt, stop_time = Nyears*years)
#  
#  start_time = [time_ns()]
#  
#  function progress(sim)
#      wall_time = (time_ns() - start_time[1]) * 1e-9
#  
#      u = sim.model.solution.u
#  
#      @info @sprintf("Time: % 12s, iteration: %d, max(|u|): %.2e ms⁻¹, wall time: %s", 
#                      prettytime(sim.model.clock.time),
#                      sim.model.clock.iteration, maximum(abs, u), # maximum(abs, η),
#                      prettytime(wall_time))
#  
#      start_time[1] = time_ns()
#  
#      return nothing
#  end
#  
#  simulation.callbacks[:progress] = Callback(progress, IterationInterval(10))
#  
#  u, v, h = model.solution
#  
#  save_interval = 5days
#  
#  simulation.output_writers[:surface_fields] = JLD2OutputWriter(model, (; u, v, h),
#                                                                schedule = TimeInterval(save_interval),
#                                                                filename = output_prefix * "_surface",
#                                                                overwrite_existing = true)
#  
#  # Let's goo!
#  @info "Running with Δt = $(prettytime(simulation.Δt))"
#  
#  run!(simulation, pickup = pickup_file)
#  
#  @info """
#  
#      Simulation took $(prettytime(simulation.run_wall_time))
#      Free surface: $(typeof(model.free_surface).name.wrapper)
#      Time step: $(prettytime(Δt))
#  """
#  
#  
