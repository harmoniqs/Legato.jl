"""
    default_post_process() -> Vector{Function}

Return the ordered list of post-processing transforms applied after a block
solve. Each entry has signature `(block_result, ctx::PostProcessContext) -> block_result'`.

Substrate: empty list (no post-processing). Strategies may override with
their own `post_process::Vector{Function}` via the CompilationStrategy struct;
this seam is the codebase-wide default consulted only when no strategy is
selected.
"""
default_post_process() = _DEFAULT_POST_PROCESS[]()

_substrate_default_post_process() = Function[]

const _DEFAULT_POST_PROCESS = Ref{Any}(_substrate_default_post_process)

"""
    set_default_post_process!(f)

Install `f` as the substrate post-process builder. `f` must have signature
`() -> Vector{Function}`.
"""
set_default_post_process!(f) = (_DEFAULT_POST_PROCESS[] = f)

"""
    pulse_spectrum(pulse::AbstractPulse; n_samples=1000) -> (freqs, power)

Compute the one-sided power spectrum of each drive channel of `pulse`.

The pulse is sampled uniformly at `n_samples` points via `Piccolo.sample` and
the FFT of each drive channel is taken along the time axis. Pulse durations
are in ns, so the returned frequencies are in GHz.

Returns `(freqs, power)` where `freqs` is the vector of `n_samples ÷ 2 + 1`
non-negative frequencies (GHz) and `power` is a matrix of size
`(n_drives, length(freqs))` whose `k`-th row is the unnormalized power
spectrum `|FFT(uₖ)|²` of drive channel `k` at those frequencies.

Useful as a hardware-bandwidth diagnostic: a compiled pulse with significant
power above a device's drive bandwidth will perform poorly on real hardware
even when its simulated fidelity is high.

See also [`plot_pulse_spectrum`](@ref).
"""
function pulse_spectrum(pulse::AbstractPulse; n_samples::Int = 1000)
    controls, times = Piccolo.sample(pulse, n_samples)
    dt = times[2] - times[1]
    freqs = collect(rfftfreq(n_samples, 1 / dt))
    power = abs2.(rfft(controls, 2))
    return freqs, power
end

"""
    plot_pulse_spectrum(pulse::AbstractPulse; n_samples=1000, kwargs...) -> Figure

Plot the one-sided power spectrum of every drive channel of `pulse` on a
shared axis: frequency in GHz on the x-axis, power on a log-scale y-axis.
Keyword arguments beyond `n_samples` are forwarded to the `Makie.Axis`.

Defined as a stub here; the implementation is provided by the
`LegatoMakieExt` extension and is loaded when a Makie backend (`CairoMakie`,
`GLMakie`, `WGLMakie`) is available.

See also [`pulse_spectrum`](@ref).
"""
function plot_pulse_spectrum end


@testitem "PostProcessContext — basic construction" begin
    using Legato
    using Piccolo: UnitaryTrajectory, CubicSplinePulse, QuantumSystem, SplinePulseProblem

    σz = ComplexF64[1 0; 0 -1];
    σx = ComplexF64[0 1; 1 0]
    sys = QuantumSystem(σz, [σx], [1.0])
    times = collect(range(0.0, 10.0, length = 5))
    pulse = CubicSplinePulse(
        zeros(1, 5),
        zeros(1, 5),
        times;
        initial_value = zeros(1),
        final_value = zeros(1),
    )
    qtraj = UnitaryTrajectory(sys, pulse, ComplexF64[1 0; 0 1])
    problem = SplinePulseProblem(qtraj; Q = 100.0)

    device = HeronR3()
    circuit = GateCircuit([GateOp(:H, (1,))], 1)

    ctx = Legato.PostProcessContext(circuit, device, qtraj, problem)
    @test ctx.circuit === circuit
    @test ctx.device === device
    @test ctx.qtraj === qtraj
    @test ctx.problem === problem
end

@testitem "default_post_process — substrate is empty list" begin
    using Legato

    pp = Legato.default_post_process()
    @test pp isa Vector
    @test isempty(pp)
end

@testitem "pulse_spectrum — sine pulses peak at known frequencies" begin
    using Legato
    using Piccolo: ZeroOrderPulse

    f₁, f₂ = 0.05, 0.20  # GHz
    T = 200.0  # ns
    knot_times = collect(range(0.0, T, length = 2001))
    controls = vcat(sin.(2π * f₁ .* knot_times)', sin.(2π * f₂ .* knot_times)')
    pulse = ZeroOrderPulse(controls, knot_times)

    n_samples = 1000
    freqs, power = pulse_spectrum(pulse; n_samples = n_samples)

    @test length(freqs) == n_samples ÷ 2 + 1
    @test size(power) == (2, length(freqs))
    @test freqs[1] == 0.0
    @test issorted(freqs)

    # Each channel's spectral peak lands on the bin nearest its frequency.
    df = freqs[2] - freqs[1]
    @test isapprox(freqs[argmax(power[1, :])], f₁; atol = df)
    @test isapprox(freqs[argmax(power[2, :])], f₂; atol = df)
end

@testitem "pulse_spectrum — constant pulse is pure DC" begin
    using Legato
    using Piccolo: ZeroOrderPulse

    times = collect(range(0.0, 50.0, length = 101))
    pulse = ZeroOrderPulse(fill(0.7, 1, 101), times)

    n_samples = 256
    freqs, power = pulse_spectrum(pulse; n_samples = n_samples)

    @test argmax(power[1, :]) == 1
    @test power[1, 1] ≈ (0.7 * n_samples)^2
    @test all(power[1, 2:end] .< 1e-18 * power[1, 1])
end
