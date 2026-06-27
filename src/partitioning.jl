"""
    BlockSpec(subcircuit, qubit_indices)

A compilation unit: the sub-circuit to compile and the device-relative qubit
indices it acts on. Produced by `default_partitioner(circuit, device)` and
consumed by `compile_block`.
"""
struct BlockSpec
    subcircuit::AbstractCircuit
    qubit_indices::Vector{Int}
end

"""
    default_partitioner(circuit, device)

Return a `Vector{BlockSpec}` describing how to decompose `circuit` for
compilation. Substrate: one block covering the full circuit on qubits
`1:circuit.n_qubits` — no partitioning.

Strettissimo overrides this with a graph-based partitioner that considers
device connectivity, sub-circuit cost estimates, and crosstalk profiles.
"""
default_partitioner(circuit, device) = _DEFAULT_PARTITIONER[](circuit, device)

_substrate_default_partitioner(circuit, device) =
    [BlockSpec(circuit, collect(1:(circuit.n_qubits)))]

const _DEFAULT_PARTITIONER = Ref{Any}(_substrate_default_partitioner)

"""
    set_default_partitioner!(f)

Install `f` as the partitioner. `f` must have signature
`(circuit, device) -> Vector{BlockSpec}`.
"""
set_default_partitioner!(f) = (_DEFAULT_PARTITIONER[] = f)

@testitem "BlockSpec — basic construction" begin
    using Legato

    circuit = GateCircuit([GateOp(:H, (1,))], 1)
    block = BlockSpec(circuit, [1])
    @test block.subcircuit === circuit
    @test block.qubit_indices == [1]
end

@testitem "default_partitioner — substrate returns one whole-circuit block" begin
    using Legato

    circuit = qft_circuit(3)
    device = HeronR3()

    blocks = Legato.default_partitioner(circuit, device)

    @test length(blocks) == 1
    @test blocks[1].qubit_indices == [1, 2, 3]
    @test blocks[1].subcircuit === circuit
end
