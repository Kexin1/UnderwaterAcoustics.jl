using DifferentialEquations
using ForwardDiff
using Optim

export RaySolver

Base.@kwdef struct RaySolver{T} <: PropagationModel{T}
  env::T
  nbeams::Int = 0
  minangle::Float64 = -80°
  maxangle::Float64 = +80°
  atol::Float64 = 1e-3
  rugocity::Float64 = 1.5
  athreshold::Float64 = 1e-5
  function RaySolver(env, nbeams, minangle, maxangle, atol, rugocity, athreshold)
    nbeams < 0 && (nbeams = 0)
    -π/2 ≤ minangle ≤ π/2 || throw(ArgumentError("minangle should be between -π/2 and π/2"))
    -π/2 ≤ maxangle ≤ π/2 || throw(ArgumentError("maxangle should be between -π/2 and π/2"))
    minangle < maxangle || throw(ArgumentError("maxangle should be more than minangle"))
    new{typeof(env)}(check(Bellhop, env), nbeams, minangle, maxangle, atol, rugocity, athreshold)
  end
end

RaySolver(env; kwargs...) = RaySolver(; env=env, kwargs...)

### interface functions

# TODO: check for 3D coordinates and report error

function check(::Type{RaySolver}, env::Union{<:UnderwaterEnvironment,Missing})
  if env !== missing
    altimetry(env) isa FlatSurface || throw(ArgumentError("RaySolver only supports environments with flat sea surface"))
    bathymetry(env) isa ConstantDepth || throw(ArgumentError("RaySolver only supports constant depth environments"))
  end
  env
end

function arrivals(model::RaySolver, tx1::AcousticSource, rx1::AcousticReceiver)
  a = [RayArrival(r.time, r.phasor, r.surface, r.bottom, r.launchangle, r.arrivalangle) for r ∈ eigenrays(model, tx1, rx1; ds=0.0)]
  sort(a; by = a1 -> a1.time)
end

function eigenrays(model::RaySolver, tx1::AcousticSource, rx1::AcousticReceiver; ds=1.0)
  p2 = location(rx1)
  nbeams = model.nbeams
  if nbeams == 0
    p1 = location(tx1)
    R = abs(p2[1] - p1[1])
    h = maxdepth(bathymetry(model.env))
    nbeams = ceil(Int, 4 * (model.maxangle - model.minangle) / atan(h, R))
  end
  θ = range(model.minangle, model.maxangle; length=nbeams)
  n = length(θ)
  err = fill(NaN64, n)
  r1 = traceray(model, tx1, θ[1], p2[1])  # needed to get type
  Threads.@threads for i ∈ 1:n
    p3 = (i == 1 ? r1 : traceray(model, tx1, θ[i], p2[1])).raypath[end]
    if isapprox(p3[1], p2[1]; atol=model.atol) && isapprox(p3[2], p2[2]; atol=model.atol)
      err[i] = p3[3] - p2[3]
    end
  end
  erays = Array{typeof(r1)}(undef, 0)
  for i ∈ 1:n
    if isapprox(err[i], 0.0; atol=model.atol)
      push!(erays, traceray(model, tx1, θ[i], p2[1], ds))
    elseif i > 1 && !isnan(err[i-1]) && !isnan(err[i]) && sign(err[i-1]) != sign(err[i])
      a, b = ordered(θ[i-1], θ[i])
      soln = optimize(ϕ -> abs2(traceray(model, tx1, ϕ, p2[1]).raypath[end][3] - p2[3]), a, b; abs_tol=model.atol)
      push!(erays, traceray(model, tx1, soln.minimizer, p2[1], ds))
    elseif i > 2 && isnearzero(err[i-2], err[i-1], err[i])
      a, b = ordered(θ[i-2], θ[i])
      soln = optimize(ϕ -> abs2(traceray(model, tx1, ϕ, p2[1]).raypath[end][3] - p2[3]), a, b; abs_tol=model.atol)
      push!(erays, traceray(model, tx1, soln.minimizer, p2[1], ds))
    end
  end
  erays
end

function rays(model::RaySolver, tx1::AcousticSource, θ::Real, rmax)
  traceray(model, tx1, θ, rmax, 1.0)
end

function transfercoef(model::RaySolver, tx1::AcousticSource, rx::AcousticReceiverGrid2D; mode=:coherent)
  tc = zeros(ComplexF64, size(rx,1), size(rx,2), Threads.nthreads())
  rmax = maximum(rx.xrange)
  nbeams = model.nbeams
  if nbeams == 0
    p1 = location(tx1)
    R = abs(rmax - p1[1])
    h = maxdepth(bathymetry(model.env))
    nbeams = 161 #clamp(ceil(Int, 10 * (model.maxangle - model.minangle) / atan(h, R)), 100, 1000)
  end
  θ = range(model.minangle, model.maxangle; length=nbeams)
  δθ = 1° #Float64(θ.step)
  c₀ = soundspeed(ssp(model.env), location(tx1)...)
  f = nominalfrequency(tx1)
  Threads.@threads for θ1 ∈ θ
    traceray(model, tx1, θ1, rmax, 1.0; cb = (s1, u1, s2, u2, A₀, D₀, cₛ) -> begin
      r1, z1, ξ1, ζ1, t1, _, q1 = u1
      r2, z2, ξ2, ζ2, t2, _, q2 = u2
      ndx = findall(r -> r1 ≤ r < r2, rx.xrange)
      t = (t1 + t2) / 2
      s = (s1 + s2) / 2
      r = (r1 + r2) / 2
      q = (q1 + q2) / 2
      if length(ndx) > 0
        for i ∈ 1:length(rx.zrange)
          dz = abs(rx.zrange[i] - (z1 + z2) / 2)
          A = A₀
          A *= √(2cₛ * cos(θ1) / (r * c₀ * q))
          A *= fast_absorption(f, D₀ + s, salinity(model.env))
          A *= cis(2π * t * f)
          tc[ndx, i, Threads.threadid()] .+= A * exp(-(dz/(q*δθ))^2)
        end
      end
    end)
  end
  dropdims(sum(tc; dims=3); dims=3)
end

### helper functions

ordered(a, b) = a < b ? (a, b) : (b, a)

function isnearzero(a, b, c)
  (isnan(a) || isnan(b) || isnan(c)) && return false
  sign(a) != sign(b) && return false
  sign(a) != sign(c) && return false
  abs(a) < abs(b) && return false
  abs(c) < abs(b) && return false
  return true
end

function rayeqns!(du, u, params, s)
  r, z, ξ, ζ, t, p, q = u
  c, ∂c, ∂²c = params
  cᵥ = c(z)
  cᵥ² = cᵥ * cᵥ
  c̄ₙₙ = ∂²c(z) * ξ * ξ
  du[1] = cᵥ * ξ
  du[2] = cᵥ * ζ
  du[3] = 0               # TODO: support range-dependent soundspeed
  du[4] = -∂c(z) / cᵥ²
  du[5] = 1 / cᵥ
  du[6] = -c̄ₙₙ * q
  du[7] = cᵥ * p
end

function checkray!(out, u, s, integrator, a::Altimetry, b::Bathymetry, rmax)
  bz = u[4] ≥ 0 ? altitude(a, u[1], 0.0) : -depth(b, u[1], 0.0)
  out[1] = u[2] - bz
  out[2] = u[3]
  out[3] = u[1] - rmax
end

# FIXME: type inference fails for prob and soln, but will be fixed in PR570 for DiffEqBase soon
function traceray1(model, r0, z0, θ, rmax, ds, q0)
  a = altimetry(model.env)
  b = bathymetry(model.env)
  c = z -> soundspeed(ssp(model.env), 0.0, 0.0, z)
  ∂c = z -> ForwardDiff.derivative(c, z)
  ∂²c = z -> ForwardDiff.derivative(∂c, z)
  cᵥ = c(z0)
  u0 = [r0, z0, cos(θ)/cᵥ, sin(θ)/cᵥ, 0.0, 1/cᵥ, q0]
  prob = ODEProblem(rayeqns!, u0, (0.0, model.rugocity * (rmax-r0)/cos(θ)), (c, ∂c, ∂²c))
  cb = VectorContinuousCallback(
    (out, u, s, i) -> checkray!(out, u, s, i, a, b, rmax),
    (i, ndx) -> terminate!(i), 3; rootfind=true)
  soln = ds ≤ 0 ? solve(prob; save_everystep=false, callback=cb) : solve(prob; saveat=ds, callback=cb)
  s2 = soln[end]
  soln.t[end], s2[1], s2[2], atan(s2[4], s2[3]), s2[5], s2[7], soln.u, soln.t
end

function traceray(model::RaySolver, tx1::AcousticSource, θ::Real, rmax, ds=0.0; cb=nothing)
  θ₀ = θ
  f = nominalfrequency(tx1)
  zmax = -maxdepth(bathymetry(model.env))
  p = location(tx1)
  c₀ = soundspeed(ssp(model.env), p...)
  raypath = Array{typeof(p)}(undef, 0)
  A = Complex(1.0, 0.0)
  s = 0
  b = 0
  t = 0.0
  D = 0.0
  q = 0.0
  while true
    dD, r, z, θ, dt, q, u, svec = traceray1(model, p[1], p[3], θ, rmax, ds, q)
    for u1 ∈ u
      push!(raypath, (u1[1], 0.0, u1[2]))
    end
    if cb !== nothing
      for i ∈ 2:length(u)
        cₛ = soundspeed(ssp(model.env), (u[i-1][1]+u[i][1])/2, 0.0, (u[i-1][2]+u[i][2])/2)
        cb(svec[i-1], u[i-1], svec[i], u[i], A, D, cₛ)
      end
    end
    t += dt
    D += dD
    p = (r, 0.0, z)
    if isapprox(z, 0.0; atol=1e-3)        # FIXME: assumes flat altimetry
      s += 1
      A *= reflectioncoef(seasurface(model.env), f, π/2 - θ)
    elseif isapprox(z, zmax; atol=1e-3)   # FIXME: assumes flat bathymetry
      b += 1
      A *= reflectioncoef(seabed(model.env), f, π/2 + θ)
    else
      break
    end
    if abs(A)/q < model.athreshold
      break
    end
    θ = -θ                                # FIXME: assumes flat altimetry/bathymetry
  end
  cₛ = soundspeed(ssp(model.env), p...)
  A *= √(cₛ * cos(θ₀) / (p[1] * c₀ * q))
  A *= fast_absorption(f, D, salinity(model.env))
  RayArrival(t, conj(A), s, b, θ₀, -θ, raypath)    # conj(A) needed to match with Bellhop
end
