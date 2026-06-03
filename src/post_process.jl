using FFTW: fft, fftfreq
using Piccolo: sample

"""
    pulse_spectrum(pulse; n_samples=1000) -> freqs_GHz, power

Sample `pulse` uniformly and compute the one-sided power spectrum for every
drive channel. Pulse time is measured in nanoseconds, so the returned frequency
bins are in GHz. `power` has shape `(n_drives, length(freqs_GHz))`.
"""
function pulse_spectrum(pulse; n_samples::Integer = 1000)
    n_samples >= 2 ||
        throw(ArgumentError("n_samples must be at least 2, got $n_samples"))

    controls, times = sample(pulse, Int(n_samples))
    dt_ns = times[2] - times[1]
    dt_ns > 0 || throw(ArgumentError("sample times must be strictly increasing"))

    freqs_GHz = fftfreq(length(times), 1 / dt_ns)
    keep = 1:(div(length(times), 2)+1)
    one_sided_freqs = freqs_GHz[keep]

    power = Matrix{Float64}(undef, size(controls, 1), length(keep))
    for drive in axes(controls, 1)
        spectrum = fft(vec(controls[drive, :]))
        power[drive, :] .= abs2.(spectrum[keep]) ./ length(times)
    end

    return one_sided_freqs, power
end

"""
    plot_pulse_spectrum(pulse; kwargs...)

Plot the one-sided pulse power spectrum when Makie is loaded. The Makie-backed
method is defined in `StrettoMakieExt`.
"""
function plot_pulse_spectrum end

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

@testitem "PostProcessContext — basic construction" begin
    using Stretto
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

    ctx = Stretto.PostProcessContext(circuit, device, qtraj, problem)
    @test ctx.circuit === circuit
    @test ctx.device === device
    @test ctx.qtraj === qtraj
    @test ctx.problem === problem
end

@testitem "default_post_process — substrate is empty list" begin
    using Stretto

    pp = Stretto.default_post_process()
    @test pp isa Vector
    @test isempty(pp)
end

@testitem "pulse_spectrum detects a sinusoidal drive peak" begin
    using Stretto
    using Piccolo: ZeroOrderPulse

    n_samples = 1024
    dt_ns = 1.0
    target_freq_GHz = 0.125
    times = collect(0.0:dt_ns:((n_samples - 1) * dt_ns))
    controls = reshape(sin.(2pi * target_freq_GHz .* times), 1, :)
    pulse = ZeroOrderPulse(
        controls,
        times;
        initial_value = [controls[1, 1]],
        final_value = [controls[1, end]],
    )

    freqs, power = Stretto.pulse_spectrum(pulse; n_samples)
    @test size(power) == (1, length(freqs))

    peak_idx = argmax(power[1, 2:end]) + 1
    @test isapprox(freqs[peak_idx], target_freq_GHz; atol = 1e-12)
    @test power[1, peak_idx] >
          100 * maximum(power[1, setdiff(eachindex(freqs), peak_idx)])
end

@testitem "pulse_spectrum validates sample count" begin
    using Stretto
    using Piccolo: ZeroOrderPulse

    pulse = ZeroOrderPulse(zeros(1, 2), [0.0, 1.0])
    @test_throws ArgumentError Stretto.pulse_spectrum(pulse; n_samples = 1)
end

@testitem "plot_pulse_spectrum returns a Makie figure" begin
    using Stretto
    using CairoMakie
    using Piccolo: ZeroOrderPulse

    times = collect(0.0:1.0:15.0)
    controls = reshape(sin.(2pi * 0.25 .* times), 1, :)
    pulse = ZeroOrderPulse(
        controls,
        times;
        initial_value = [controls[1, 1]],
        final_value = [controls[1, end]],
    )

    fig = Stretto.plot_pulse_spectrum(pulse; n_samples = length(times))
    @test fig isa Figure
end
