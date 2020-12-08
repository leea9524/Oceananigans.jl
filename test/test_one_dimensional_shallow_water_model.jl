### Set up the model with the initial conditions

using Oceananigans
using Oceananigans.Models: ShallowWaterModel
using Oceananigans.Grids: Periodic, Bounded
using Oceananigans.Advection

grid = RegularCartesianGrid(size=(1, 64, 1), extent=(10, 1, 1) , topology=(Periodic, Periodic, Bounded))

model = ShallowWaterModel(        grid = grid,
            gravitational_acceleration = 1,
                          architecture = CPU(),
                             advection = WENO5(), 
                              coriolis = FPlane(f=1.0)
                                  )

width = 0.3
 h(x, y, z) = 1.0 + 0.1 * exp(-(x - 5)^2 / (2width^2));  
uh(x, y, z) = 0.0
vh(x, y, z) = 0.0 

set!(model, uh = uh, vh = vh, h = h)

simulation = Simulation(model, Δt = 0.01, stop_iteration = 100)


### Set up the plots and save initial height field

using Plots
using Oceananigans.Grids: xnodes, ynodes

#x = xnodes(model.solution.h);
x = ynodes(model.solution.h);

#h_plot = plot(x, interior(model.solution.h)[:, 1, 1],
h_plot = plot(x, interior(model.solution.h)[1, :, 1],
              linewidth = 2,
              label = "t = 0",
              xlabel = "x",
              ylabel = "height")
savefig("initial_height_1d")


### Set up the OutputWriter using NetCDF

using Oceananigans.OutputWriters: JLD2OutputWriter, IterationInterval, NetCDFOutputWriter

simulation.output_writers[:height] =
    NetCDFOutputWriter(model, model.solution, filepath = "one_dimensional_wave_equation.nc",
                       mode = "c", schedule=IterationInterval(1))


### Find the solution

run!(simulation)

println("Done with calculation the solution!")

### Plot the initial and final solution

using Printf

#plt = plot!(h_plot, x, interior(model.solution.h)[:, 1, 1], linewidth=2,
plt = plot!(h_plot, x, interior(model.solution.h)[1, :, 1], linewidth=2,
            label=@sprintf("t = %.3f", model.clock.time))

savefig("slice")
println("Saving plot of initial and final conditions.")


### Create contour plots of the solution

using NCDatasets

NCDataset("one_dimensional_wave_equation.nc") do ds
    @info "Saving Hovmoller plots of the solution."

    contourf(ds["time"], ds["yC"], ds["h"][1, :, 1, :], linewidth=0, c = :balance)
    #contourf(ds["time"], ds["xC"], ds["h"][:, 1, 1, :], linewidth=0, c = :balance)
    savefig("Hovmoller_h.png")

    contourf(ds["time"], ds["yF"], ds["uh"][1, :, 1, :], linewidth=0, c = :balance)
    #contourf(ds["time"], ds["xF"], ds["uh"][:, 1, 1, :], linewidth=0, c = :balance)
    savefig("Hovmoller_uh.png")

    contourf(ds["time"], ds["yC"], ds["vh"][1, :, 1, :], linewidth=0, c = :balance)
    #contourf(ds["time"], ds["xC"], ds["vh"][:, 1, 1, :], linewidth=0, c = :balance)
    savefig("Hovmoller_vh.png")
end

### Create an animation of the solution
anim = NCDataset(simulation.output_writers[:height].filepath) do ds
    @info "Saving animation of the solution."
    
    anim = @animate for (n, t) in enumerate(ds["time"])
        #plot(ds["xC"], ds["h"][:, 1, 1, n], linewidth=2, title=@sprintf("t = %.3f", t),
        plot(ds["xC"], ds["h"][1, :, 1, n], linewidth=2, title=@sprintf("t = %.3f", t),
             label="", xlabel="x", ylabel="height", xlims=(0, 10), ylims=(0.95, 1.12))
    end

    return anim
end

gif(anim, "one_dimensional_shallow_water_nc.gif", fps = 15) # hide

