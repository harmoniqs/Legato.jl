# Random-circuit generation — the fuzz and benchmark substrate. The generator
# is public API: the compile fuzz test consumes it, and the seed-efficacy
# benchmark surface (cold vs analytic vs bank convergence curves over
# ensembles) will consume the same deterministic stream.
using Random

"""
    random_circuit(device, n_gates; seed)

A deterministic random `GateCircuit` on `device`: gates drawn uniformly from
the device's native set, 1-qubit gates on any qubit, 2-qubit gates only on
the device's coupling edges (connectivity-constrained by construction — a
malformed operand cannot be generated, not merely filtered). Same `seed`
always reproduces the same sequence; benchmarks need reproducible ensembles.
"""
function random_circuit(device::TransmonDevice, n_gates::Int; seed::Integer)
    rng = MersenneTwister(seed)
    one_qubit =
        sort(collect(setdiff(native_gate_set(device), (:CZ, :CNOT, :CX, :CCX, :CCZ))))
    two_qubit = sort(collect(intersect(native_gate_set(device), (:CZ, :CNOT, :CX))))
    n_qubits = length(device.qubits)
    ops = Vector{GateOp}(undef, n_gates)
    for k = 1:n_gates
        if !isempty(two_qubit) && rand(rng) < 0.3
            edge = device.edges[rand(rng, 1:length(device.edges))]
            op =
                rand(rng) < 0.5 ?
                GateOp(two_qubit[rand(rng, 1:length(two_qubit))], (edge.i, edge.j)) :
                GateOp(two_qubit[rand(rng, 1:length(two_qubit))], (edge.j, edge.i))
        else
            op = GateOp(one_qubit[rand(rng, 1:length(one_qubit))], (rand(rng, 1:n_qubits),))
        end
        ops[k] = op
    end
    return GateCircuit(ops, n_qubits)
end

# ============================================================================ #
# Tests
# ============================================================================ #

@testitem "random_circuit — deterministic, connectivity-safe, covering" begin
    using Legato
    using Legato: random_circuit

    device = HeronR3()

    # Same seed reproduces the exact sequence
    a = random_circuit(device, 12; seed = 20261003)
    b = random_circuit(device, 12; seed = 20261003)
    @test a.ops == b.ops

    # A different seed (almost surely) differs
    c = random_circuit(device, 12; seed = 20261004)
    @test a.ops != c.ops

    # Connectivity-constrained by construction: every 2-qubit op sits on an edge
    edge_set =
        Set(vcat([(e.i, e.j) for e in device.edges], [(e.j, e.i) for e in device.edges]))
    for k = 1:40
        circuit = random_circuit(device, 15; seed = k)
        @test circuit.n_qubits == length(device.qubits)
        for op in circuit.ops
            if length(op.qubits) == 2
                @test op.qubits in edge_set
            else
                @test 1 ≤ only(op.qubits) ≤ length(device.qubits)
            end
        end
    end

    # Coverage: every native gate appears across a modest batch
    seen = Set{Symbol}()
    for k = 1:50
        circuit = random_circuit(device, 12; seed = k)
        union!(seen, [op.gate for op in circuit.ops])
    end
    @test seen ⊇ native_gate_set(device)
end

@testitem "random_circuit — transpilation preserves unitaries (fuzz)" begin
    using Legato
    using LinearAlgebra
    using Legato: random_circuit

    # The transpile fuzz: arbitrary well-formed circuits rewritten into the
    # native set must preserve the circuit unitary up to global phase.
    # Matrix-only — microseconds per circuit, no compilation.
    device = HeronR3()
    for k = 1:40
        circuit = random_circuit(device, 8; seed = 10_000 + k)
        U_original = circuit_unitary(circuit)
        U_native = circuit_unitary(to_native(circuit, device))
        # global-phase-free comparison
        overlap = abs(tr(U_original' * U_native)) / size(U_original, 1)
        @test overlap ≥ 1 - 1e-10
    end
end

@testitem "random_circuit — end-to-end compile fuzz (seconds-scale)" begin
    using Legato
    using Legato: random_circuit

    # The front-door fuzz: generated 1-qubit circuits compile end-to-end at
    # token budget (the pipeline must RUN on arbitrary well-formed input;
    # convergence is not the assertion — the existing quality tests own it).
    device = HeronR3()
    for k = 1:4
        circuit = random_circuit(device, 2; seed = 20_000 + k)
        # project to a 1-qubit circuit so the fuzz stays seconds-scale:
        # rewrite every op onto qubit 1 (1-qubit gates only)
        ops = [GateOp(op.gate, (1,)) for op in circuit.ops if length(op.qubits) == 1]
        isempty(ops) && continue
        one_q = GateCircuit(ops, 1)
        report = compile(one_q, device; T_ns = 200.0, N_knots = 21, max_iter = 2)
        @test report.n_qubits == 1
        @test 0.0 ≤ report.pulse_fidelity ≤ 1.0
        @test report.seed_branch ∈ (:analytic, :library, :cold, :override)
    end
end
