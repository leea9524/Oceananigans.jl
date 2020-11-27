module LagrangianParticleTracking

export LagrangianParticles, advect_particles!

using Adapt
using KernelAbstractions
using StructArrays

using Oceananigans.Grids
using Oceananigans.Architectures: device
using Oceananigans.Fields: interpolate, datatuple, compute!, location
using Oceananigans.Utils: MAX_THREADS_PER_BLOCK

import Base: size, length, show

abstract type AbstractParticle end

struct Particle{T} <: AbstractParticle
    x :: T
    y :: T
    z :: T
end

struct LagrangianParticles{P, R, T}
         particles :: P
       restitution :: R
    tracked_fields :: T
end

function LagrangianParticles(; x, y, z, restitution=1.0, tracked_fields::NamedTuple=NamedTuple())
    size(x) == size(y) == size(z) ||
        throw(ArgumentError("x, y, z must all have the same size!"))

    (ndims(x) == 1 && ndims(y) == 1 && ndims(z) == 1) ||
        throw(ArgumentError("x, y, z must have dimension 1 but ndims=($(ndims(x)), $(ndims(y)), $(ndims(z)))"))

    particles = StructArray{Particle}((x, y, z))

    return LagrangianParticles(particles; restitution, tracked_fields)
end

function LagrangianParticles(particles::StructArray; restitution=1.0, tracked_fields::NamedTuple=NamedTuple())
    for (field_name, tracked_field) in pairs(tracked_fields)
        field_name in propertynames(particles) ||
            throw(ArgumentError("$field_name is a tracked field but $(eltype(particles)) has no $field_name field! " *
                                "You might have to define your own particle type."))
    end

    return LagrangianParticles(particles, restitution, tracked_fields)
end

size(lagrangian_particles::LagrangianParticles) = size(lagrangian_particles.particles)
length(lagrangian_particles::LagrangianParticles) = length(lagrangian_particles.particles)

function Base.show(io::IO, lagrangian_particles::LagrangianParticles)
    particles = lagrangian_particles.particles
    properties = propertynames(particles)
    fields = lagrangian_particles.tracked_fields
    print(io, "$(length(particles)) Lagrangian particles with\n",
        "├── $(length(properties)) properties: $properties\n",
        "└── $(length(fields)) tracked fields: $(propertynames(fields))")
end

include("advect_particles.jl")

end # module