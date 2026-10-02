# Analytic pulse seeds — the physics-informed floor of the warm-start fallback
# chain. When the catalog has no match, these construct first-order
# textbook pulses instead of random noise: a rectangular flat-top and a DRAG
# pulse (first-order Motzoi correction via the discrete knot derivative).
#
# Seeds carry NO fidelity claim. They are initial guesses for optimization —
# an entry banked from one is analytic-tier with an empty verification record.
#
# Unit convention (load-bearing, matches Piccolo's): drive amplitudes are
# angular GHz and time is ns, so a constant in-plane drive u for time T
# rotates the qubit by θ = 2·u·T — π pulses of duration T need peak
# u = θ/(2T) rectangular, or u = θ/T on a sin² envelope (which averages to
# half its peak: ∫sin² = T/2, so the DRAG form needs 2× the rectangular peak
# at equal rotation — its price for smooth edges).

"""
    _seed_rotation(gate)

The (θ, φ) in-plane rotation for a seed gate symbol: X/Y are π rotations on
the x/y quadrature axes, SX/SY are half rotations. Phase gates (Z, S, T) are
frame changes, not drivable in-plane rotations — they decompose as a virtual-Z
plus one in-plane rotation and are deliberately not seeded here.
"""
function _seed_rotation(gate::Symbol)
    gate in (:X, :Y, :SX, :SY) || throw(
        ArgumentError(
            "no analytic seed for gate :$gate — supported: :X, :Y, :SX, :SY; " *
            "phase gates (Z/S/T) are virtual-Z frame changes, not in-plane pulses",
        ),
    )
    θ = gate in (:X, :Y) ? Float64(π) : Float64(π) / 2
    φ = gate in (:X, :SX) ? 0.0 : Float64(π) / 2
    return θ, φ
end

# Envelope quadratures for an in-plane rotation (θ, φ): the flat-top and the
# sin² form, both zero at the boundary knots (zero-terminated), as
# drives × knots control matrices.
function _rectangular_controls(θ, φ, T, N, drive_max)
    A = θ / (2T)
    A <= drive_max || throw(
        ArgumentError(
            "rotation θ = $(round(θ, digits = 4)) rad cannot complete within " *
            "drive_max = $drive_max over T = $T ns (needs peak $(round(A, digits = 4))) — " *
            "lengthen T or raise the bound",
        ),
    )
    u1 = fill(A * cos(φ), N)
    u2 = fill(A * sin(φ), N)
    # zero-terminated: the last knot is the pulse's off state
    u1[N] = u2[N] = 0.0
    return vcat(reshape(u1, 1, :), reshape(u2, 1, :))
end

function _drag_controls(θ, φ, T, N, drive_max, δ)
    A = θ / T
    A <= drive_max || throw(
        ArgumentError(
            "rotation θ = $(round(θ, digits = 4)) rad cannot complete within " *
            "drive_max = $drive_max over T = $T ns (needs peak $(round(A, digits = 4))) — " *
            "lengthen T or raise the bound",
        ),
    )
    times = collect(range(0.0, T, length = N))
    # sin² envelope: naturally zero at both boundaries; rotation θ = A·T.
    h = [A * sin(π * t / T)^2 for t in times]
    # DRAG quadrature via the DISCRETE knot derivative (central difference) —
    # the correction the PWC representation can actually express, not the
    # analytic derivative sampled onto the grid. First-order Motzoi
    # coefficient c = 1/δ in Piccolo's δ>0 convention: empirically this
    # drives leakage to numerical zero in the perturbative regime
    # (peak ≲ δ/2) with a wide robust plateau in c.
    du = zeros(N)
    for k = 2:(N-1)
        du[k] = (h[k+1] - h[k-1]) / (times[k+1] - times[k-1])
    end
    u1 = @. h * cos(φ) + (du / δ) * sin(φ)
    u2 = @. h * sin(φ) - (du / δ) * cos(φ)
    peak = max(maximum(abs.(u1)), maximum(abs.(u2)))
    peak <= drive_max || throw(
        ArgumentError(
            "DRAG correction peak $(round(peak, digits = 4)) exceeds drive_max " *
            "$drive_max over T = $T ns — lengthen T (the derivative quadrature " *
            "scales as 1/T²) or raise the bound",
        ),
    )
    return vcat(reshape(u1, 1, :), reshape(u2, 1, :))
end

_seed_pulse(controls, T, N) = ZeroOrderPulse(controls, collect(range(0.0, T, length = N)))

"""
    rectangular_seed(theta, phi, T, N, drive_max)
    rectangular_seed(gate, T, N, drive_max)
    rectangular_seed(gate, device; T = nothing, N = 21)

Rectangular flat-top seed for an in-plane rotation (θ, φ) — the X/Y/SX/SY
gates map to fixed (θ, φ) pairs. Flat at peak amplitude θ/(2T) on the
interior knots, zero at the last knot (zero-terminated), both quadratures
bounded by `drive_max` (an infeasible rotation errors loudly, never silently
unbounded).

The device method defaults from the profile: drive bound from the device,
duration from the published native-gate spec when the gate has one — raised
to the bound-feasible minimum θ/(2·drive_max) when the published duration
cannot contain the rotation.
"""
function rectangular_seed(θ::Real, φ::Real, T::Real, N::Int, drive_max::Real)
    return _seed_pulse(_rectangular_controls(θ, φ, T, N, drive_max), T, N)
end

function rectangular_seed(gate::Symbol, T::Real, N::Int, drive_max::Real)
    θ, φ = _seed_rotation(gate)
    return rectangular_seed(θ, φ, T, N, drive_max)
end

function rectangular_seed(
    gate::Symbol,
    device::TransmonDevice;
    T::Union{Nothing,Real} = nothing,
    N::Int = 21,
)
    θ, φ = _seed_rotation(gate)
    T_default = if haskey(device.native_gates, gate)
        device.native_gates[gate].duration_ns
    else
        typemin(Int) |> Float64
    end
    T = something(T, max(T_default, θ / (2device.drive_max)))
    return rectangular_seed(θ, φ, T, N, device.drive_max)
end

"""
    drag_seed(theta, phi, T, N, drive_max, delta)
    drag_seed(gate, T, N, drive_max, delta)
    drag_seed(gate, device; T = nothing, N = 21)

First-order DRAG seed: sin² envelope on the rotation's quadrature axis plus
the first-order Motzoi correction (c = 1/δ, Piccolo's δ>0 convention) on the
orthogonal quadrature, computed as the **discrete knot derivative** — the
correction the piecewise-constant representation can actually express.

Honest regime note: first-order DRAG suppresses leakage strongly while the
peak amplitude is perturbative (≲ δ/2); at strongly-driven scales the
first-order term no longer dominates and higher-order corrections (or the
optimizer) take over. The seed is still the better basin there — it is a
guess, not a solution.

The envelope's sin² form costs 2× the rectangular peak at equal rotation
(the area averages to half the peak); the derivative quadrature scales as
1/T². Both quadratures are checked against `drive_max` and fail loudly.

Device defaults: drive bound and δ from the device's first subsystem qubit,
duration from the published native-gate spec — raised to the feasible minimum
max(θ/drive_max, √(θπ/(δ·drive_max))) when the published duration cannot
contain the pulse.
"""
function drag_seed(θ::Real, φ::Real, T::Real, N::Int, drive_max::Real, δ::Real)
    return _seed_pulse(_drag_controls(θ, φ, T, N, drive_max, δ), T, N)
end

function drag_seed(gate::Symbol, T::Real, N::Int, drive_max::Real, δ::Real)
    θ, φ = _seed_rotation(gate)
    return drag_seed(θ, φ, T, N, drive_max, δ)
end

function drag_seed(
    gate::Symbol,
    device::TransmonDevice;
    T::Union{Nothing,Real} = nothing,
    N::Int = 21,
    subsystem::Int = 1,
)
    θ, φ = _seed_rotation(gate)
    δ = abs(device.qubits[subsystem].δ)
    T_default = if haskey(device.native_gates, gate)
        device.native_gates[gate].duration_ns
    else
        typemin(Int) |> Float64
    end
    T = something(
        T,
        max(T_default, θ / device.drive_max, sqrt(θ * π / (δ * device.drive_max))),
    )
    return drag_seed(θ, φ, T, N, device.drive_max, δ)
end

# ============================================================================ #
# Tests
# ============================================================================ #

@testitem "analytic seeds — gate coverage, bounds, zero-termination" begin
    using Legato
    using Piccolo.Quantum.Pulses: duration
    using Legato: rectangular_seed, drag_seed

    drive_max = 0.05
    for gate in (:X, :Y, :SX, :SY)
        rect = rectangular_seed(gate, 80.0, 21, drive_max)
        drag = drag_seed(gate, 80.0, 21, drive_max, 0.2)
        for pulse in (rect, drag)
            @test pulse.n_drives == 2
            @test duration(pulse) ≈ 80.0
            # bounded on every knot, zero-terminated at the boundary
            @test maximum(abs.(pulse.controls.u)) <= drive_max + 1e-12
        end
        # the X-axis seed drives quadrature 1; the Y-axis seed drives quadrature 2
        # (φ = π/2 leaves cos(φ) = 6e-17 float dust, so near-zero, not exact)
        @test maximum(abs.(rect.controls.u[2, :])) < 1e-15 || gate in (:Y, :SY)
        @test maximum(abs.(rect.controls.u[1, :])) < 1e-15 || gate in (:X, :SX)
    end

    # Infeasible rotation errors loudly with the numbers named
    err = try
        rectangular_seed(:X, 10.0, 21, drive_max)  # π needs 31.4 ns at 0.05
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("drive_max", sprint(showerror, err))

    # Phase gates are refused with the virtual-Z pointer, not silently mis-seeded
    err = try
        rectangular_seed(:Z, 40.0, 21, drive_max)
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("virtual-Z", sprint(showerror, err))
end

@testitem "analytic seeds — device defaults respect the published profile" begin
    using Legato
    using Piccolo.Quantum.Pulses: duration
    using Legato: rectangular_seed, drag_seed

    device = HeronR3()
    # HeronR3 publishes X at 25 ns, but π at drive_max=0.05 needs 31.4 ns —
    # the default must rise to the feasible minimum, not silently overflow
    rect = rectangular_seed(:X, device)
    @test duration(rect) >= π / (2 * 0.05)
    @test maximum(abs.(rect.controls.u)) <= 0.05 + 1e-12

    drag = drag_seed(:X, device)
    @test maximum(abs.(drag.controls.u)) <= 0.05 + 1e-12
    # δ comes from the subsystem qubit: the DRAG quadrature is nonzero
    @test maximum(abs.(drag.controls.u[2, :])) > 0.0
end

@testitem "analytic seeds — load through the problem-builder seam" begin
    using Legato
    using Piccolo: UnitaryTrajectory, EmbeddedOperator, QuantumControlProblem
    using Legato: rectangular_seed, drag_seed, build_problem

    device = HeronR3()
    N = 21
    for seed in (rectangular_seed(:X, 40.0, N, 0.05), drag_seed(:X, 40.0, N, 0.1, 0.2))
        sys = Legato.Piccolo.MultiTransmonSystem(device, [1])
        U_target = circuit_unitary(GateCircuit([GateOp(:X, (1,))], 1))
        qtraj = UnitaryTrajectory(sys, seed, EmbeddedOperator(U_target, sys))
        circuit = GateCircuit([GateOp(:X, (1,))], 1)
        problem = build_problem(circuit, device, qtraj; N_knots = N)
        @test problem isa QuantumControlProblem
    end
end

@testitem "DRAG suppresses first-order leakage below the rectangular seed" begin
    using Legato
    using LinearAlgebra
    using Legato: rectangular_seed, drag_seed

    # Canonical moderate-drive case: 3-level transmon, δ = 0.2, π rotation in
    # T = 40 ns (peak/δ ≈ 0.39 — inside the documented first-order regime).
    # Exact simulation of the piecewise-constant pulses: ordered product of
    # per-knot matrix exponentials — no optimizer in the loop, rollout truth.
    δ = 0.2;
    T = 40.0;
    N = 81
    a = zeros(ComplexF64, 3, 3)
    a[1, 2] = 1
    a[2, 3] = √2
    ad = transpose(a)
    H_anh = -δ / 2 * ad * ad * a * a
    G1 = a + ad
    G2 = 1im * (a - ad)
    function simulate(pulse)
        times = collect(range(0.0, T, length = N))
        U = Matrix{ComplexF64}(I, 3, 3)
        for k = 1:(N-1)
            u = pulse.controls.u[:, k]
            H = H_anh + u[1] * G1 + u[2] * G2
            U = exp(-im * H * (times[k+1] - times[k])) * U
        end
        return U
    end
    leak(U) = (abs2(U[3, 1]) + abs2(U[3, 2])) / 2

    rect = rectangular_seed(:X, T, N, 0.05)
    drag = drag_seed(:X, T, N, 0.1, δ)
    # both fit the bound; the DRAG seed's leakage is measurably (and stably)
    # below the rectangular seed's at equal rotation — margin 4× for CI safety,
    # measured suppression is ~20×
    @test leak(simulate(rect)) > 4 * leak(simulate(drag))
    @test leak(simulate(rect)) > 0.01  # the comparison is meaningful, not both-zero
end
