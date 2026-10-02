"""
Provenance of a block's seed pulse — which branch of the warm-start fallback
chain resolved, and which catalog entry (if any) seeded the block. Queryable
programmatically via `BlockResult.seed` and the `CompilationReport` seed
fields; the chain never resolves silently.
"""
struct SeedProvenance
    branch::Symbol # :library, :retarget, :analytic, :override, :cold
    entry_id::Union{String,Nothing}
    detail::String
end

"""
Result of compiling a single circuit block to a pulse.
"""
struct BlockResult
    pulse::AbstractPulse
    fidelity::Float64
    n_qubits::Int
    seed::SeedProvenance
end

# Positional compat: direct construction predates provenance and defaults to
# the cold branch.
BlockResult(pulse, fidelity, n_qubits) =
    BlockResult(pulse, fidelity, n_qubits, SeedProvenance(:cold, nothing, ""))

"""
    resolve_seed(circuit, device, qubit_indices, times, n_drives) -> (pulse, SeedProvenance)

The warm-start fallback chain, in its fixed order:

1. **`:library`** — a hash-exact catalog hit: an entry whose `system_hash`
   matches the device/subsystem and whose gate matches the block's, loaded
   with validation-on-load. Requires a catalog via [`set_default_catalog!`](@ref).
2. **`:retarget`** — the registered retarget override (private tier's plug
   point, via [`set_default_retarget!`](@ref)) applied to the best near-miss
   entry (platform+gate match, no hash match). Absent override, or an
   override returning `nothing`, falls through without error.
3. **`:analytic`** — the analytic seed generators for single-qubit
   single-gate blocks in the standard set (`X, Y, SX, SY`); a bound-infeasible
   analytic seed (duration too short for the drive bound) falls through to
   the floor rather than failing the compilation.
4. **`:cold`** / **`:override`** — the existing `default_initial_pulse` seam:
   the substrate's random-Gaussian cold start, or the private tier's
   installed override (provenance says which).

Every resolution records where it landed — the chain never resolves
silently.
"""
function resolve_seed(
    circuit::AbstractCircuit,
    device::AbstractDevice,
    qubit_indices::AbstractVector{Int},
    times::AbstractVector{<:Real},
    n_drives::Int;
    floor::Function = default_initial_pulse,
)
    # The chain only recognizes single-gate blocks (the catalog and the
    # analytic generators are per-gate artifacts); anything else goes to the
    # floor unchanged.
    if length(circuit) == 1
        op = first(circuit.ops)
        catalog = _DEFAULT_CATALOG[]
        if catalog !== nothing && device isa TransmonDevice
            hash = compute_system_hash(device, qubit_indices)
            hits = find_pulses(
                catalog;
                platform = "transmon",
                gate = string(op.gate),
                system_hash = hash,
                exact_hash_only = true,
            )
            if !isempty(hits)
                entry = first(hits)
                pulse, _ = load_pulse(
                    joinpath(catalog, entry.id);
                    device = device,
                    subsystem = qubit_indices,
                )
                return pulse,
                SeedProvenance(:library, entry.id, "hash-exact, validated on load")
            end
            retarget = _DEFAULT_RETARGET[]
            if retarget !== nothing
                near = find_pulses(catalog; platform = "transmon", gate = string(op.gate))
                if !isempty(near)
                    entry = first(near)
                    pulse = retarget(
                        entry,
                        joinpath(catalog, entry.id),
                        device,
                        qubit_indices,
                        times,
                    )
                    if pulse !== nothing
                        return pulse,
                        SeedProvenance(
                            :retarget,
                            entry.id,
                            "no hash-exact match; retarget override applied",
                        )
                    end
                end
            end
        end
        if device isa TransmonDevice &&
           op.gate in (:X, :Y, :SX, :SY) &&
           length(op.qubits) == 1
            δ = abs(device.qubits[first(op.qubits)].δ)
            seed = try
                drag_seed(op.gate, times[end], length(times), device.drive_max, δ)
            catch err
                err isa ArgumentError ? nothing : rethrow()
            end
            if seed !== nothing
                return seed,
                SeedProvenance(:analytic, nothing, "first-order DRAG (c = 1/δ)")
            end
        end
    end
    pulse = floor(circuit, device, times, n_drives)
    # The floor's identity: the module seam at its substrate default is :cold;
    # an installed override — module seam or a strategy's customized
    # initial_pulse — is :override. The :default strategy's field is bound to
    # the seam itself, so strategy-path resolution lands here identically.
    branch =
        floor === default_initial_pulse &&
        _DEFAULT_INITIAL_PULSE[] === _substrate_default_initial_pulse ? :cold : :override
    return pulse, SeedProvenance(branch, nothing, "")
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

    # 3. Seed via the warm-start fallback chain (hash-exact library hit →
    #    retarget override → analytic seed → the default_initial_pulse seam,
    #    which is the cold floor or the private tier's installed override).
    #    The branch that resolved is recorded in the block's provenance.
    times = collect(range(0.0, T_ns, length = N_knots))
    pulse, seed = resolve_seed(circuit, device, qubit_indices, times, sys.n_drives)

    # 4. Trajectory → Problem → Solve
    qtraj = UnitaryTrajectory(sys, pulse, U_goal)
    # Default integrator seam: Piccolo's BilinearIntegrator is adequate for
    # 1-2 qubit problems. The private Legatissimo package overrides this via
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
    #    Legatissimo overrides with parallel multistart).
    result_pulse, fid = default_solver_strategy(qcp, qtraj; max_iter = max_iter)

    return BlockResult(result_pulse, fid, n, seed)
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

    # 3. Seed via the warm-start fallback chain (hash-exact library hit →
    #    retarget override → analytic seed → the strategy's initial-pulse
    #    seam, which is the cold floor or a customized override). The branch
    #    that resolved is recorded in the block's provenance.
    times = collect(range(0.0, T_ns, length = N_knots))
    pulse, seed = resolve_seed(
        circuit,
        device,
        qubit_indices,
        times,
        sys.n_drives;
        floor = strat.initial_pulse,
    )

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
    block = BlockResult(result_pulse, fid, n, seed)

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
# integration tests live in the private Legatissimo package, which overrides
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
    using Piccolo: ZeroOrderPulse
    # Import from the declaring module: the transitive `Piccolo` re-export of
    # `duration` is ambiguous (NT's TimeWarp also exports one — Piccolo#323)
    # and undefined on import (nightly Julia surfaces this as an UndefVarError).
    using Piccolo.Quantum.Pulses: duration

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
    qcp = SplinePulseProblem(qtraj; Legato._pwc_dynamics_kwargs()...)

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

@testitem "compile — single-block strategy composes seams into a CompilationReport" begin
    using Legato
    using Piccolo: ZeroOrderPulse

    # Orchestration contract under test: partition → seam composition →
    # post-process chain → report. build_problem and solver_strategy are
    # stubs (the real solve pipeline is compile_block's :integration item);
    # everything else (system build, embedding, trajectory, baseline, report)
    # runs for real.
    circuit = GateCircuit([GateOp(:H, (1,))], 1)
    device = HeronR3(n_levels = 2)

    captured_pulse = Ref{Any}(nothing)
    captured_ctx = Ref{Any}(nothing)
    post_process_calls = Symbol[]

    # (Named local functions rather than inline lambdas: a `begin...end`
    # block cannot appear inside a typed array literal — `Function[begin...]`
    # parses as indexing at `begin`.)
    function make_pulse(c, d, times, n_drives)
        captured_pulse[] = ZeroOrderPulse(
            zeros(n_drives, length(times)),
            times;
            initial_value = zeros(n_drives),
            final_value = zeros(n_drives),
        )
        return captured_pulse[]
    end
    function pp_record(block, ctx)
        captured_ctx[] = ctx
        push!(post_process_calls, :first)
        return block
    end
    function pp_halve(block, ctx)
        push!(post_process_calls, :second)
        return Legato.BlockResult(block.pulse, block.fidelity / 2, block.n_qubits)
    end

    stub = Legato.CompilationStrategy(
        name = :stub_orchestration_test,
        description = "stub seams; orchestration only",
        matches = (c, d) -> 0.0,
        integrator = (qtraj, N) -> :stub_integrator,
        initial_pulse = make_pulse,
        partitioner = (c, d) -> Legato.BlockSpec[Legato.BlockSpec(c, [1])],
        build_problem = (c, d, qt; kw...) -> :stub_problem,
        solver_strategy = (problem, qt; max_iter) -> (captured_pulse[], 0.937),
        post_process = Function[pp_record, pp_halve],
    )
    Legato.register_strategy!(stub)
    try
        report = compile(
            circuit,
            device;
            strategy = :stub_orchestration_test,
            max_iter = 2,
            T_ns = 20.0,
            N_knots = 5,
        )

        @test report isa CompilationReport
        # Post-process chain ran in order and halved the stub fidelity
        @test post_process_calls == [:first, :second]
        @test report.pulse_fidelity ≈ 0.937 / 2
        # ctx carries the real circuit/device/trajectory plus the stub problem
        @test captured_ctx[] isa Legato.PostProcessContext
        @test captured_ctx[].circuit === circuit
        @test captured_ctx[].device === device
        @test captured_ctx[].problem === :stub_problem
        # Report fields: baseline vs pulse result
        @test report.circuit_name == "1Q circuit (1 gates)"
        @test report.device_name == device.name
        @test report.gate_duration_ns == device.native_gates[:H].duration_ns
        @test report.pulse_duration_ns ≈ 20.0  # duration of the initial pulse (T_ns)
        @test report.gate_n_gates == 1
    finally
        Legato.unregister_strategy!(:stub_orchestration_test)
    end
end

@testitem "compile — multi-block partitioner rejected (single-block v0.3 contract)" begin
    using Legato

    device = HeronR3()
    circuit = GateCircuit([GateOp(:H, (1,))], 1)

    two_block = Legato.CompilationStrategy(
        name = :two_block_test,
        description = "",
        matches = (c, d) -> 0.0,
        partitioner = (c, d) -> Legato.BlockSpec[
            Legato.BlockSpec(GateCircuit([GateOp(:H, (1,))], 1), [1]),
            Legato.BlockSpec(GateCircuit([GateOp(:X, (1,))], 1), [1]),
        ],
    )
    Legato.register_strategy!(two_block)
    try
        err = try
            compile(circuit, device; strategy = :two_block_test, max_iter = 2)
            nothing
        catch e
            e
        end
        @test err !== nothing
        @test err isa ErrorException
        @test occursin("Multi-block compilation requires", sprint(showerror, err))
    finally
        Legato.unregister_strategy!(:two_block_test)
    end
end

# ——— Warm-start fallback chain ———————————————————————————————————————— #

# A catalog fixture: one hash-exact (or near-miss) entry for (transmon, X) on
# HeronR3's first qubit, with a loadable pulse on the compilation grid.
function _chain_catalog_entry(
    device,
    subsystem;
    system_hash,
    T = 40.0,
    N = 21,
    id = "transmon-X-v1",
)
    dir = mktempdir()
    times = collect(range(0.0, T, length = N))
    pulse =
        ZeroOrderPulse(zeros(2, N), times; initial_value = zeros(2), final_value = zeros(2))
    entry = Legato.CatalogEntry(
        id,
        "transmon",
        "X",
        1,
        "curated",
        device.name,
        subsystem,
        [3],
        system_hash,
        "ZeroOrderPulse",
        N,
        true,
        T / 1000,
        0.99,
        Legato.VerificationRecord(0.99, "rollout: test", "2026-10-02"),
        nothing,
        nothing,
        nothing,
        "2026-10-02",
        String[],
        "pulses/$id/pulse.jld2",
    )
    entry_dir = joinpath(dir, id)
    write_entry(entry_dir, entry)
    JLD2.save(joinpath(entry_dir, "pulse.jld2"), "pulse", pulse)
    return dir
end

@testitem "resolve_seed — hash-exact library hit seeds and records provenance" begin
    using Legato
    using JLD2
    using Legato:
        resolve_seed, set_default_catalog!, write_entry, compute_system_hash, SeedProvenance

    device = HeronR3()
    h = compute_system_hash(device, [1])
    catalog = Legato._chain_catalog_entry(device, [1]; system_hash = h)
    set_default_catalog!(catalog)
    try
        circuit = GateCircuit([GateOp(:X, (1,))], 1)
        times = collect(range(0.0, 200.0, length = 21))
        pulse, seed = resolve_seed(circuit, device, [1], times, 2)
        @test seed.branch === :library
        @test seed.entry_id == "transmon-X-v1"
        @test pulse isa Legato.Piccolo.AbstractPulse

        # The full pipeline carries provenance end-to-end
        block = compile_block(circuit, device, [1]; T_ns = 40.0, N_knots = 21, max_iter = 2)
        @test block.seed.branch === :library
        @test block.seed.entry_id == "transmon-X-v1"
    finally
        set_default_catalog!(nothing)
    end
end

@testitem "resolve_seed — retarget override on near-misses; falls to analytic when absent" begin
    using Legato
    using JLD2
    using Legato:
        resolve_seed, set_default_catalog!, set_default_retarget!, compute_system_hash
    using Piccolo: ZeroOrderPulse

    device = HeronR3()
    # A NEAR-miss catalog: the entry exists for (transmon, X) but is solved on
    # a different device — no hash match, so the retarget branch is the one
    # that can pick it up.
    other_hash = compute_system_hash(device, [1, 2])
    catalog = Legato._chain_catalog_entry(device, [1]; system_hash = other_hash)
    times = collect(range(0.0, 200.0, length = 21))
    circuit = GateCircuit([GateOp(:X, (1,))], 1)

    set_default_catalog!(catalog)
    try
        # Without the override: near-miss entries are visible but unusable →
        # analytic (never an error)
        _, seed = resolve_seed(circuit, device, [1], times, 2)
        @test seed.branch === :analytic
        @test seed.detail == "first-order DRAG (c = 1/δ)"

        # With the override installed: the near-miss routes through it
        set_default_retarget!(
            (entry, entry_dir, dev, sub, ts) -> begin
                return ZeroOrderPulse(
                    zeros(2, length(ts)),
                    ts;
                    initial_value = zeros(2),
                    final_value = zeros(2),
                )
            end,
        )
        try
            _, seed = resolve_seed(circuit, device, [1], times, 2)
            @test seed.branch === :retarget
            @test seed.entry_id == "transmon-X-v1"

            # An override that declines (returns nothing) falls through clean
            set_default_retarget!((entry, dir, dev, sub, ts) -> nothing)
            _, seed = resolve_seed(circuit, device, [1], times, 2)
            @test seed.branch === :analytic
        finally
            set_default_retarget!(nothing)
        end
    finally
        set_default_catalog!(nothing)
    end
end

@testitem "resolve_seed — analytic for the standard set, floor otherwise" begin
    using Legato
    using Legato: resolve_seed, set_default_initial_pulse!

    device = HeronR3()
    times = collect(range(0.0, 200.0, length = 21))

    # Single-qubit standard gates seed analytically (no catalog configured)
    for gate in (:X, :Y, :SX, :SY)
        circuit = GateCircuit([GateOp(gate, (1,))], 1)
        _, seed = resolve_seed(circuit, device, [1], times, 2)
        @test seed.branch === :analytic
    end

    # A block outside the analytic set (2 gates) goes to the floor: cold
    circuit = GateCircuit([GateOp(:H, (1,)), GateOp(:X, (1,))], 1)
    _, seed = resolve_seed(circuit, device, [1], times, 2)
    @test seed.branch === :cold

    # An installed seam override is the floor and provenance says so
    set_default_initial_pulse!(
        (c, d, ts, n) -> Legato.Piccolo.ZeroOrderPulse(
            zeros(n, length(ts)),
            ts;
            initial_value = zeros(n),
            final_value = zeros(n),
        ),
    )
    try
        _, seed = resolve_seed(circuit, device, [1], times, 2)
        @test seed.branch === :override
    finally
        # restore the substrate default for the other testitems
        Legato._DEFAULT_INITIAL_PULSE[] = Legato._substrate_default_initial_pulse
    end
end

@testitem "compile — report carries queryable seed provenance" begin
    using Legato
    using Legato: compute_system_hash, set_default_catalog!, JLD2

    device = HeronR3()
    circuit = GateCircuit([GateOp(:X, (1,))], 1)
    report = compile(circuit, device; T_ns = 200.0, N_knots = 21, max_iter = 2)
    @test report.seed_branch === :analytic
    @test report.seed_entry === nothing

    h = compute_system_hash(device, [1])
    catalog = Legato._chain_catalog_entry(device, [1]; system_hash = h, T = 200.0)
    set_default_catalog!(catalog)
    try
        report = compile(circuit, device; T_ns = 200.0, N_knots = 21, max_iter = 2)
        @test report.seed_branch === :library
        @test report.seed_entry == "transmon-X-v1"
        # rendered, not just queryable
        @test occursin("library (transmon-X-v1)", sprint(show, report))
    finally
        set_default_catalog!(nothing)
    end
end
