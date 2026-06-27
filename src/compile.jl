"""
Result of compiling a single circuit block to a pulse.
"""
struct BlockResult
    pulse::AbstractPulse
    fidelity::Float64
    n_qubits::Int
end

"""
    compile_block(circuit, device, qubit_indices; max_iter, T_ns, N_knots, Q, free_phase)

Compile a circuit block to a single optimized pulse on a device qubit subset.

1. Build QuantumSystem from device
2. Compute target unitary → EmbeddedOperator (multi-level)
3. Cold-start pulse via `default_initial_pulse` (substrate: `ZeroOrderPulse`)
4. UnitaryTrajectory → `build_problem` (substrate: `SmoothPulseProblem`) → solve!
5. Extract optimized pulse
"""
function compile_block(
    circuit::AbstractCircuit,
    device::TransmonDevice,
    qubit_indices::AbstractVector{Int};
    max_iter::Int = 500,
    T_ns::Float64 = 200.0,
    N_knots::Int = 21,
    Q::Float64 = 100.0,
    free_phase::Bool = true,
    integrator = nothing,
)
    # 1. Build a composite Piccolo system directly (no flattening)
    sys = MultiTransmonSystem(device, qubit_indices)
    n = length(qubit_indices)

    # 2. Target unitary → embedded using the composite's own subsystem_levels
    U_target = circuit_unitary(circuit)
    U_goal = EmbeddedOperator(U_target, sys)

    # 3. Initial pulse via the seam (substrate: random Gaussian cold start;
    #    Strettissimo overrides with catalog warm-starts).
    times = collect(range(0.0, T_ns, length = N_knots))
    pulse = default_initial_pulse(circuit, device, times, sys.n_drives)

    # 4. Trajectory → Problem → Solve
    qtraj = UnitaryTrajectory(sys, pulse, U_goal)
    # Default integrator seam: Piccolo's BilinearIntegrator is adequate for
    # 1-2 qubit problems. The private Strettissimo package overrides this via
    # `set_default_integrator!` to install Piccolissimo's SplineIntegrator for
    # multi-qubit compilation. Caller can also pass `integrator=` directly.
    integ = integrator === nothing ? default_integrator(qtraj, N_knots) : integrator
    qcp = build_problem(
        circuit,
        device,
        qtraj;
        N_knots = N_knots,
        integrator = integ,
        Q = Q,
        free_phase = free_phase,
    )
    # 5. Solve via the strategy seam (substrate: single cold start;
    #    Strettissimo overrides with parallel multistart).
    result_pulse, fid = default_solver_strategy(qcp, qtraj; max_iter = max_iter)

    return BlockResult(result_pulse, fid, n)
end

"""
    compile(circuit, device; strategy=nothing, max_iter, kwargs...)

Compile an entire circuit on a device, dispatching through a `CompilationStrategy`.

- When `strategy === nothing` (default), `select_strategy(circuit, device)` picks
  the highest-scoring registered strategy (or falls back to `:default`).
- When `strategy` is a `Symbol`, the named strategy is used directly and an
  `ArgumentError` is thrown if it isn't registered.

v0.3: single-block compilation only. Multi-block support requires a future
release that can glue block results into a joint report.
"""
function compile(
    circuit::AbstractCircuit,
    device::AbstractDevice;
    strategy::Union{Nothing,Symbol} = nothing,
    max_iter::Int = 500,
    kwargs...,
)
    # Resolve the strategy
    strat = if strategy === nothing
        select_strategy(circuit, device)
    else
        get(_STRATEGY_REGISTRY, strategy, nothing) !== nothing || throw(
            ArgumentError(
                "unknown strategy :$strategy; available: $(collect(keys(_STRATEGY_REGISTRY)))",
            ),
        )
        _STRATEGY_REGISTRY[strategy]
    end

    # Partition via the strategy's partitioner (not the global seam)
    blocks = strat.partitioner(circuit, device)
    length(blocks) == 1 || error(
        "Multi-block compilation requires a Legato release that can glue block results into a joint report. v0.3 accepts only single-block strategies.",
    )

    spec = blocks[1]
    block = _compile_block_with_strategy(
        strat,
        spec.subcircuit,
        device,
        spec.qubit_indices;
        max_iter,
        kwargs...,
    )
    baseline = gate_level_baseline(circuit, device)
    return CompilationReport(circuit, device, block, baseline)
end

"""
    _compile_block_with_strategy(strat, circuit, device, qubit_indices; ...)

Strategy-aware version of `compile_block`. Uses the seam functions from `strat`
(integrator, initial_pulse, build_problem, solver_strategy, post_process)
instead of the module-level substrate seams.

Not exported — an implementation detail of `compile()`. Direct callers that
want substrate behavior can continue to use `compile_block(...)`.
"""
function _compile_block_with_strategy(
    strat::CompilationStrategy,
    circuit::AbstractCircuit,
    device::TransmonDevice,
    qubit_indices::AbstractVector{Int};
    max_iter::Int = 500,
    T_ns::Float64 = 200.0,
    N_knots::Int = 21,
    Q::Float64 = 100.0,
    free_phase::Bool = true,
    integrator = nothing,
    build_problem_kwargs...,
)
    # 1. Build system (unchanged)
    sys = MultiTransmonSystem(device, qubit_indices)
    n = length(qubit_indices)

    # 2. Target unitary (unchanged)
    U_target = circuit_unitary(circuit)
    U_goal = EmbeddedOperator(U_target, sys)

    # 3. Initial pulse via the strategy's seam
    times = collect(range(0.0, T_ns, length = N_knots))
    pulse = strat.initial_pulse(circuit, device, times, sys.n_drives)

    # 4. Integrator via the strategy's seam (unless caller passes one explicitly)
    qtraj = UnitaryTrajectory(sys, pulse, U_goal)
    integ = integrator === nothing ? strat.integrator(qtraj, N_knots) : integrator

    # 5. Problem via the strategy's build_problem seam.
    # Extra kwargs (R, ddu_bound, etc.) flow through from compile() to the
    # underlying problem template (substrate: SmoothPulseProblem).
    qcp = strat.build_problem(
        circuit,
        device,
        qtraj;
        N_knots = N_knots,
        integrator = integ,
        Q = Q,
        free_phase = free_phase,
        build_problem_kwargs...,
    )

    # 6. Solve via the strategy's solver_strategy seam
    result_pulse, fid = strat.solver_strategy(qcp, qtraj; max_iter = max_iter)
    block = BlockResult(result_pulse, fid, n)

    # 7. Post-process chain
    ctx = PostProcessContext(circuit, device, qtraj, qcp)
    for transform in strat.post_process
        block = transform(block, ctx)
    end

    return block
end

# ============================================================================ #
# Tests
# ============================================================================ #
# Legato's default test suite uses Piccolo's BilinearIntegrator. Multi-qubit
# integration tests live in the private Strettissimo package, which overrides
# `default_integrator` with Piccolissimo's SplineIntegrator.

@testitem "default_integrator — substrate returns BilinearIntegrator" begin
    using Legato
    using Piccolo: BilinearIntegrator, UnitaryTrajectory, CubicSplinePulse, QuantumSystem

    σz = ComplexF64[1 0; 0 -1]
    σx = ComplexF64[0 1; 1 0]
    sys = QuantumSystem(σz, [σx], [1.0])
    times = collect(range(0.0, 10.0, length = 5))
    pulse = CubicSplinePulse(zeros(1, 5), zeros(1, 5), times)
    qtraj = UnitaryTrajectory(sys, pulse, ComplexF64[1 0; 0 1])

    integ = Legato.default_integrator(qtraj, 5)
    @test integ isa BilinearIntegrator
end

@testitem "default_initial_pulse — substrate returns zero-boundary ZeroOrderPulse" begin
    using Legato
    using Piccolo: ZeroOrderPulse, duration

    times = collect(range(0.0, 10.0, length = 5))
    n_drives = 2
    circuit = GateCircuit([GateOp(:H, (1,))], 1)
    device = HeronR3()

    pulse = Legato.default_initial_pulse(circuit, device, times, n_drives)

    @test pulse isa ZeroOrderPulse
    @test duration(pulse) ≈ 10.0
    @test pulse.n_drives == n_drives
    # Substrate contract: zero-clamped at both boundaries via explicit
    # initial_value / final_value (load-bearing for SmoothPulseProblem,
    # which uses these to set up final-value constraints).
    @test pulse.initial_value == zeros(n_drives)
    @test pulse.final_value == zeros(n_drives)
end

@testitem "default_solver_strategy — substrate returns fidelity + pulse tuple" begin
    using Legato
    using Piccolo:
        AbstractPulse,
        QuantumSystem,
        CubicSplinePulse,
        UnitaryTrajectory,
        SplinePulseProblem

    # Exercise the strategy seam directly on the smallest possible problem
    # (1Q, 2-dim, 1 drive, max_iter=2) to confirm the tuple shape without
    # asserting convergence. Uses a flat QuantumSystem (not MultiTransmonSystem)
    # so the test only stresses the strategy seam, independent of any
    # composite-system EmbeddedOperator constructor that may be Piccolo-version
    # dependent.
    σz = ComplexF64[1 0; 0 -1]
    σx = ComplexF64[0 1; 1 0]
    sys = QuantumSystem(σz, [σx], [1.0])
    times = collect(range(0.0, 10.0, length = 5))
    pulse = CubicSplinePulse(zeros(1, 5), zeros(1, 5), times)
    qtraj = UnitaryTrajectory(sys, pulse, ComplexF64[1 0; 0 1])
    qcp = SplinePulseProblem(qtraj; integrator = Legato.default_integrator(qtraj, 5))

    result_pulse, fid = Legato.default_solver_strategy(qcp, qtraj; max_iter = 2)

    @test result_pulse isa AbstractPulse
    @test 0.0 ≤ fid ≤ 1.0
end

@testitem "compile — strategy=nothing dispatches via select_strategy (falls to :default)" begin
    using Legato

    device = HeronR3()
    circuit = GateCircuit([GateOp(:H, (1,))], 1)

    # Prove dispatch reaches :default's partitioner without running the full
    # (EmbeddedOperator-on-CompositeQuantumSystem) solve pipeline, which is
    # Piccolo-post-v1.6-only and breaks on registered Piccolo v1.6 / Julia 1.10.
    # Instrument :default's partitioner to throw a sentinel error when called.
    saved_default = Legato.strategies()[:default]
    instrumented = Legato.CompilationStrategy(
        name = :default,
        description = saved_default.description,
        matches = saved_default.matches,
        integrator = saved_default.integrator,
        initial_pulse = saved_default.initial_pulse,
        partitioner = (c, d) -> error("SENTINEL_DEFAULT_CALLED"),
        build_problem = saved_default.build_problem,
        solver_strategy = saved_default.solver_strategy,
        post_process = saved_default.post_process,
        state = saved_default.state,
    )
    # Suppress the overwrite warning — we're reinstalling :default on purpose.
    Base.with_logger(Base.NullLogger()) do
        Legato.register_strategy!(instrumented)
    end

    try
        # With only :default registered, dispatch should resolve to :default
        # and invoke its (instrumented) partitioner, throwing our sentinel.
        err = try
            compile(circuit, device; max_iter = 2, T_ns = 20.0, N_knots = 5)
            nothing
        catch e
            e
        end
        @test err !== nothing
        @test occursin("SENTINEL_DEFAULT_CALLED", sprint(showerror, err))
    finally
        # Restore the real :default so subsequent testitems don't inherit the
        # sentinel-partitioner installation.
        Base.with_logger(Base.NullLogger()) do
            Legato.register_strategy!(saved_default)
        end
    end
end

@testitem "compile — explicit strategy override" begin
    using Legato

    device = HeronR3()
    circuit = GateCircuit([GateOp(:H, (1,))], 1)

    # Prove the explicit strategy kwarg routes through the named strategy's
    # partitioner without running the full solve pipeline (see rationale in
    # the sibling testitem: registered-Piccolo EmbeddedOperator signature gap
    # on Julia 1.10).
    override_strat = Legato.CompilationStrategy(
        name = :forced_override_test,
        description = "",
        matches = (c, d) -> 0.0,
        partitioner = (c, d) -> error("SENTINEL_OVERRIDE_CALLED"),
    )
    Legato.register_strategy!(override_strat)
    try
        err = try
            compile(
                circuit,
                device;
                strategy = :forced_override_test,
                max_iter = 2,
                T_ns = 20.0,
                N_knots = 5,
            )
            nothing
        catch e
            e
        end
        @test err !== nothing
        @test occursin("SENTINEL_OVERRIDE_CALLED", sprint(showerror, err))
    finally
        Legato.unregister_strategy!(:forced_override_test)
    end
end

@testitem "compile — unknown strategy throws ArgumentError" begin
    using Legato

    device = HeronR3()
    circuit = GateCircuit([GateOp(:H, (1,))], 1)

    @test_throws ArgumentError compile(circuit, device; strategy = :nonexistent_xyz)
end
