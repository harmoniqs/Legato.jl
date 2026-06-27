"""
    native_gate_set(device::AbstractDevice) -> Set{Symbol}

Return the set of gate symbols the device implements natively — the keys of
`device.native_gates`. `to_native` rewrites any non-native gate into a sequence
of native ones.
"""
function native_gate_set end

native_gate_set(device::TransmonDevice) = Set(keys(device.native_gates))

# Decomposition rules: symbol → (op::GateOp) -> Vector{GateOp}
const _NATIVE_REWRITES = Dict{Symbol,Function}(
    :CNOT => op -> begin
        @assert length(op.qubits) == 2 "CNOT requires 2 qubits"
        c, t = op.qubits
        [GateOp(:H, (t,)), GateOp(:CZ, (c, t)), GateOp(:H, (t,))]
    end,
    :CX => op -> begin
        @assert length(op.qubits) == 2 "CX requires 2 qubits"
        c, t = op.qubits
        [GateOp(:H, (t,)), GateOp(:CZ, (c, t)), GateOp(:H, (t,))]
    end,
)

"""
    to_native(circuit::GateCircuit, device::AbstractDevice) -> GateCircuit

Rewrite `circuit` so every `GateOp` uses a gate in `native_gate_set(device)`.
Pure circuit rewriting; preserves the overall unitary up to a known sequence.

Supported decompositions (v0.4):
- `:CNOT(c, t)` → `[:H(t), :CZ(c, t), :H(t)]`      (when CZ ∈ native, CNOT ∉ native)
- `:CX(c, t)`   → same as CNOT (alias already handled by resolve_gate)
- Pass-through for any gate already in `native_gate_set(device)`.

Throws `ArgumentError` for gates that cannot be rewritten with the rules above.
"""
function to_native(circuit::GateCircuit, device::AbstractDevice)
    native = native_gate_set(device)
    out = GateOp[]
    for op in circuit.ops
        if op.gate in native
            push!(out, op)
        elseif haskey(_NATIVE_REWRITES, op.gate)
            replacement = _NATIVE_REWRITES[op.gate](op)
            for r in replacement
                if r.gate in native
                    push!(out, r)
                else
                    sub = get(_NATIVE_REWRITES, r.gate, nothing)
                    sub === nothing && throw(
                        ArgumentError(
                            "Rewrite of :$(op.gate) produced :$(r.gate) which is neither native nor rewritable",
                        ),
                    )
                    append!(out, sub(r))
                end
            end
        else
            throw(
                ArgumentError(
                    "Gate :$(op.gate) is not in device's native set $(native) and has no rewrite rule. " *
                    "Known rewrites: $(collect(keys(_NATIVE_REWRITES)))",
                ),
            )
        end
    end
    return GateCircuit(out, circuit.n_qubits)
end

# ============================================================================ #
# Tests
# ============================================================================ #

@testitem "native_gate_set — HeronR3 exposes CZ, X, SX, H" begin
    using Legato
    device = HeronR3()
    s = Legato.native_gate_set(device)
    @test :CZ in s
    @test :X in s
    @test :SX in s
    @test :H in s
end

@testitem "to_native — pass-through when all gates native" begin
    using Legato
    device = HeronR3()
    circuit = GateCircuit([GateOp(:CZ, (1, 2)), GateOp(:SX, (1,))], 2)
    out = to_native(circuit, device)
    @test out.ops == circuit.ops
    @test out.n_qubits == circuit.n_qubits
end

@testitem "to_native — CNOT → H·CZ·H on target qubit" begin
    using Legato
    using LinearAlgebra

    device = HeronR3()
    circuit = GateCircuit([GateOp(:CNOT, (1, 2))], 2)
    native = to_native(circuit, device)

    # The rewritten circuit must reproduce the same unitary
    U_orig = circuit_unitary(circuit)
    U_native = circuit_unitary(native)
    @test U_native ≈ U_orig atol = 1e-12

    # And every gate in the output must be in the device's native set
    ns = Legato.native_gate_set(device)
    @test all(op.gate in ns for op in native.ops)

    # Specifically: H(2), CZ(1,2), H(2) — three ops
    @test length(native.ops) == 3
    @test native.ops[1].gate == :H && native.ops[1].qubits == (2,)
    @test native.ops[2].gate == :CZ && native.ops[2].qubits == (1, 2)
    @test native.ops[3].gate == :H && native.ops[3].qubits == (2,)
end

@testitem "to_native — unknown non-native gate throws ArgumentError" begin
    using Legato
    device = HeronR3()
    # :T is in EXTRA_GATES but not native to HeronR3 and has no rewrite rule
    circuit = GateCircuit([GateOp(:T, (1,))], 1)
    @test_throws ArgumentError to_native(circuit, device)
end
