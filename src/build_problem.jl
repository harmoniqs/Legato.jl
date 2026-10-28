"""
    PostProcessContext(circuit, device, qtraj, problem)

Carries the inter-stage state needed by `post_process` transforms.
Passed to each entry of a strategy's `post_process::Vector{Function}` list.
"""
struct PostProcessContext
    circuit::AbstractCircuit
    device::AbstractDevice
    qtraj::Any      # UnitaryTrajectory, but avoid tight type binding at compile-time
    problem::Any    # AbstractPiccoloProblem
end

"""
    build_problem(circuit, device, qtraj; N_knots, kwargs...)

Construct the Piccolo problem to solve. The substrate is **basis-aware** — the
seed pulse's interpolation basis picks the template, so catalog (`:library`,
`:retarget`) seeds keep their stored basis instead of being refused:

- `ZeroOrderPulse` → `SmoothPulseProblem(qtraj, N_knots; kwargs...)` —
  derivative-of-control regularization gives cold-start reliability;
- `LinearSplinePulse` / `CubicSplinePulse` → `SplinePulseProblem(qtraj, N_knots; kwargs...)`.

Pair it with a matching integrator ([`default_integrator`](@ref) is). Strategies
may override to use `BangBangProblem`, custom constraint sets, density-matrix
trajectories, or multi-objective formulations.

`kwargs` are forwarded to the underlying problem constructor (Q, R, free_phase,
integrator, subsystem_levels, etc.); callers pass them through from
`compile_block`.
"""
build_problem(circuit, device, qtraj; kwargs...) =
    _BUILD_PROBLEM[](circuit, device, qtraj; kwargs...)

_substrate_build_problem(circuit, device, qtraj; N_knots::Int, kwargs...) =
    _basis_problem(get_pulse(qtraj), qtraj, N_knots; kwargs...)

_basis_problem(::ZeroOrderPulse, qtraj, N; kwargs...) =
    SmoothPulseProblem(qtraj, N; kwargs...)
_basis_problem(::AbstractSplinePulse, qtraj, N; kwargs...) =
    SplinePulseProblem(qtraj, N; kwargs...)
_basis_problem(pulse, qtraj, N; kwargs...) = throw(
    ArgumentError(
        "build_problem: no substrate problem template for a $(nameof(typeof(pulse))); " *
        "seed a ZeroOrderPulse or a spline pulse, or install a builder with " *
        "`set_build_problem!`.",
    ),
)

const _BUILD_PROBLEM = Ref{Any}(_substrate_build_problem)

"""
    set_build_problem!(f)

Install `f` as the problem builder. `f` must have signature
`(circuit, device, qtraj; kwargs...) -> AbstractPiccoloProblem`.
"""
set_build_problem!(f) = (_BUILD_PROBLEM[] = f)

@testitem "build_problem — substrate constructs SmoothPulseProblem" begin
    using Legato
    using Piccolo: UnitaryTrajectory, ZeroOrderPulse, QuantumSystem, QuantumControlProblem

    σz = ComplexF64[1 0; 0 -1]
    σx = ComplexF64[0 1; 1 0]
    sys = QuantumSystem(σz, [σx], [1.0])
    times = collect(range(0.0, 10.0, length = 5))
    pulse =
        ZeroOrderPulse(zeros(1, 5), times; initial_value = zeros(1), final_value = zeros(1))
    qtraj = UnitaryTrajectory(sys, pulse, ComplexF64[1 0; 0 1])

    device = HeronR3()
    circuit = GateCircuit([GateOp(:H, (1,))], 1)

    problem = Legato.build_problem(circuit, device, qtraj; N_knots = 5)
    # Piccolo's concrete problem type returned by SmoothPulseProblem.
    # (Piccolo does not export an `AbstractPiccoloProblem` supertype.)
    @test problem isa QuantumControlProblem
end

@testitem "build_problem — substrate picks the template from the pulse basis" begin
    using Legato
    using Piccolo:
        UnitaryTrajectory,
        ZeroOrderPulse,
        LinearSplinePulse,
        CubicSplinePulse,
        QuantumSystem,
        SmoothPulseProblem,
        SplinePulseProblem,
        PiccoloOptions

    σz = ComplexF64[1 0; 0 -1]
    σx = ComplexF64[0 1; 1 0]
    sys = QuantumSystem(σz, [σx], [1.0])
    times = collect(range(0.0, 10.0, length = 5))
    I2 = ComplexF64[1 0; 0 1]
    device = HeronR3()
    circuit = GateCircuit([GateOp(:H, (1,))], 1)
    opts = PiccoloOptions(verbose = false)
    build(pulse) = begin
        qtraj = UnitaryTrajectory(sys, pulse, I2)
        Legato.build_problem(
            circuit,
            device,
            qtraj;
            N_knots = 5,
            integrator = Legato.default_integrator(qtraj, 5),
            piccolo_options = opts,
        )
    end

    @test build(ZeroOrderPulse(zeros(1, 5), times)) isa SmoothPulseProblem
    @test build(LinearSplinePulse(zeros(1, 5), times)) isa SplinePulseProblem
    @test build(CubicSplinePulse(zeros(1, 5), zeros(1, 5), times)) isa SplinePulseProblem
end
