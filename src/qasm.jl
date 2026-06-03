const QASM_GATE_MAP = Dict{String,Symbol}(
    "h" => :H,
    "x" => :X,
    "y" => :Y,
    "z" => :Z,
    "s" => :S,
    "t" => :T,
    "sx" => :SX,
    "cx" => :CX,
    "cnot" => :CX,
    "cz" => :CZ,
    "ccx" => :CCX,
    "ccz" => :CCZ,
)

const QASM_GATE_ARITY = Dict{Symbol,Int}(
    :H => 1,
    :X => 1,
    :Y => 1,
    :Z => 1,
    :S => 1,
    :T => 1,
    :SX => 1,
    :CX => 2,
    :CZ => 2,
    :CCX => 3,
    :CCZ => 3,
)

"""
    from_qasm(qasm::AbstractString) -> GateCircuit

Parse a small OpenQASM 3 static-gate subset into a `GateCircuit`.

Supported declarations:

- `OPENQASM 3;`
- `include ...;`
- `qubit[n] q;`
- `qubit q;`

Supported gates are `h`, `x`, `y`, `z`, `s`, `t`, `sx`, `cx`/`cnot`, `cz`,
`ccx`, and `ccz`. QASM qubit indices are converted from 0-based to Stretto's
1-based indexing. Parametric gates, measurement, reset, control flow, and
classical operations are intentionally out of scope.
"""
function from_qasm(qasm::AbstractString)
    registers = Dict{String,NamedTuple{(:offset, :size),Tuple{Int,Int}}}()
    ops = GateOp[]
    next_offset = 0

    source = _strip_qasm_comments(String(qasm))
    for raw_stmt in split(source, ';')
        stmt = strip(raw_stmt)
        isempty(stmt) && continue

        if startswith(stmt, "OPENQASM") || startswith(stmt, "include ")
            continue
        end

        qubit_decl = match(r"^qubit(?:\[(\d+)\])?\s+([A-Za-z_]\w*)$", stmt)
        if qubit_decl !== nothing
            width_capture, name = qubit_decl.captures
            width = width_capture === nothing ? 1 : parse(Int, width_capture)
            width > 0 || throw(ArgumentError("qubit register width must be positive"))
            haskey(registers, name) &&
                throw(ArgumentError("duplicate qubit register `$name`"))
            registers[name] = (offset = next_offset, size = width)
            next_offset += width
            continue
        end

        if startswith(stmt, "bit") || startswith(stmt, "creg")
            continue
        end

        if startswith(stmt, "barrier ")
            continue
        end

        gate_stmt = match(r"^([A-Za-z_]\w*)\s+(.+)$", stmt)
        gate_stmt === nothing &&
            throw(ArgumentError("unsupported OpenQASM statement: `$stmt`"))

        gate_name, arg_source = gate_stmt.captures
        gate = get(QASM_GATE_MAP, lowercase(gate_name), nothing)
        gate === nothing &&
            throw(ArgumentError("unsupported OpenQASM gate `$gate_name`"))

        qubits = Tuple(
            _parse_qasm_qubit(strip(token), registers) for token in split(arg_source, ',')
        )
        expected_arity = QASM_GATE_ARITY[gate]
        length(qubits) == expected_arity ||
            throw(
                ArgumentError(
                    "gate `$gate_name` expects $expected_arity qubits, got $(length(qubits))",
                ),
            )

        push!(ops, GateOp(gate, qubits))
    end

    next_offset > 0 || throw(ArgumentError("OpenQASM input did not declare any qubits"))
    return GateCircuit(ops, next_offset)
end

function _strip_qasm_comments(qasm::String)
    without_block_comments = replace(qasm, r"(?s)/\*.*?\*/" => "")
    lines = split(without_block_comments, '\n')
    return join((replace(line, r"//.*$" => "") for line in lines), '\n')
end

function _parse_qasm_qubit(
    token::AbstractString,
    registers::Dict{String,NamedTuple{(:offset, :size),Tuple{Int,Int}}},
)
    indexed = match(r"^([A-Za-z_]\w*)\[(\d+)\]$", token)
    if indexed !== nothing
        name, index_capture = indexed.captures
        reg = get(registers, name, nothing)
        reg === nothing && throw(ArgumentError("unknown qubit register `$name`"))
        index = parse(Int, index_capture)
        0 <= index < reg.size ||
            throw(ArgumentError("qubit index $index is out of bounds for `$name`"))
        return reg.offset + index + 1
    end

    scalar = match(r"^[A-Za-z_]\w*$", token)
    if scalar !== nothing
        reg = get(registers, token, nothing)
        reg === nothing && throw(ArgumentError("unknown qubit register `$token`"))
        reg.size == 1 ||
            throw(ArgumentError("register `$token` must be indexed"))
        return reg.offset + 1
    end

    throw(ArgumentError("unsupported qubit operand `$token`"))
end

@testitem "from_qasm parses a Bell circuit" begin
    using LinearAlgebra
    using Stretto

    qasm = """
    OPENQASM 3;
    qubit[2] q;
    h q[0];
    cx q[0], q[1];
    """

    circuit = Stretto.from_qasm(qasm)
    expected = GateCircuit([GateOp(:H, (1,)), GateOp(:CX, (1, 2))], 2)

    @test circuit.n_qubits == 2
    @test circuit.ops == expected.ops
    @test isapprox(
        Stretto.circuit_unitary(circuit),
        Stretto.circuit_unitary(expected);
        atol = 1e-12,
    )
end

@testitem "from_qasm supports comments and scalar qubits" begin
    using Stretto

    qasm = """
    OPENQASM 3;
    // single-qubit declaration
    qubit q;
    /* block comment */
    sx q;
    """

    circuit = Stretto.from_qasm(qasm)
    @test circuit.n_qubits == 1
    @test circuit.ops == [GateOp(:SX, (1,))]
end

@testitem "from_qasm rejects unsupported statements" begin
    using Stretto

    @test_throws ArgumentError Stretto.from_qasm("OPENQASM 3; qubit[1] q; rz(0.1) q[0];")
    @test_throws ArgumentError Stretto.from_qasm("OPENQASM 3; qubit[1] q; h q[1];")
    @test_throws ArgumentError Stretto.from_qasm("OPENQASM 3; h q[0];")
end
