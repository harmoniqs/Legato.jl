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

Construct the Piccolo problem to solve. Substrate: `SmoothPulseProblem(qtraj, N_knots; kwargs...)`
— derivative-of-control regularization gives cold-start reliability that
plain spline problems lack. Strategies may override to use `SplinePulseProblem`,
`BangBangProblem`, custom constraint sets, density-matrix trajectories,
or multi-objective formulations.

`kwargs` are forwarded to the underlying problem constructor (Q, R, free_phase,
integrator, subsystem_levels, etc.); callers pass them through from
`compile_block`.
"""
build_problem(circuit, device, qtraj; kwargs...) =
    _BUILD_PROBLEM[](circuit, device, qtraj; kwargs...)

function _substrate_build_problem(circuit, device, qtraj; N_knots::Int, kwargs...)
    return SmoothPulseProblem(qtraj, N_knots; kwargs...)
end

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

    σz = ComplexF64[1 0; 0 -1];
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
