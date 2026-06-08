const QASM_GATE_MAP = Dict(
    "h" => :H,
    "cx" => :CX,
    "cz" => :CZ,
    "x" => :X,
    "y" => :Y,
    "z" => :Z,
    "s" => :S,
    "t" => :T,
    "ccx" => :CCX,
)

"""
    from_qasm(qasm::String) -> GateCircuit

Parse a small OpenQASM 3 circuit into a [`GateCircuit`](@ref).

The supported subset is intentionally static: one qubit register declaration,
standard gate statements for `h`, `cx`, `cz`, `x`, `y`, `z`, `s`, `t`, and
`ccx`, and optional `include` statements. OpenQASM qubit indices are 0-based;
the returned `GateOp`s use Stretto's 1-based indexing.
"""
function from_qasm(qasm::String)
    saw_header = false
    register_name = nothing
    n_qubits = nothing
    ops = GateOp[]

    for (line_number, line) in _qasm_statements(qasm)
        if !saw_header
            _is_qasm_header(line) || throw(
                ArgumentError("OpenQASM input must start with an `OPENQASM 3;` header."),
            )
            saw_header = true
        elseif _is_include_statement(line)
            continue
        elseif startswith(line, "include ")
            throw(ArgumentError("Invalid OpenQASM include statement on line $line_number."))
        elseif register_name === nothing
            parsed = _parse_qubit_register(line, line_number)
            register_name, n_qubits = parsed
        elseif startswith(line, "qubit[")
            throw(ArgumentError("OpenQASM input may declare only one qubit register."))
        else
            push!(ops, _parse_gate_op(line, register_name, n_qubits, line_number))
        end
    end

    register_name === nothing &&
        throw(ArgumentError("OpenQASM input must declare one qubit register."))

    return GateCircuit(ops, n_qubits)
end

function _qasm_statements(qasm::String)
    statements = Tuple{Int,String}[]
    pending = ""
    pending_line = 0

    for (line_number, raw_line) in enumerate(split(qasm, '\n'))
        line = split(raw_line, "//"; limit = 2)[1]
        isempty(strip(line)) && continue

        if isempty(pending)
            pending_line = line_number
            pending = line
        else
            pending *= " " * line
        end

        while occursin(';', pending)
            statement, remainder = split(pending, ';'; limit = 2)
            statement = strip(statement)
            !isempty(statement) && push!(statements, (pending_line, statement))
            pending = strip(remainder)
            pending_line = isempty(pending) ? 0 : line_number
        end
    end

    isempty(strip(pending)) ||
        throw(ArgumentError("OpenQASM statement on line $pending_line must end with `;`."))
    return statements
end

function _is_qasm_header(line::AbstractString)
    return occursin(r"^OPENQASM\s+3(?:\.0)?$"i, line)
end

function _is_include_statement(line::AbstractString)
    startswith(line, "include ") && return occursin(r"^include\s+\"[^\"]+\"$"i, line)
    return false
end

function _parse_qubit_register(line::AbstractString, line_number::Int)
    match_result = match(r"^qubit\[(\d+)\]\s+([A-Za-z_]\w*)$", line)
    if match_result === nothing
        throw(
            ArgumentError(
                "Expected a qubit register declaration on line $line_number, got `$line`.",
            ),
        )
    end

    n_qubits = parse(Int, match_result.captures[1])
    n_qubits > 0 || throw(ArgumentError("Qubit register size must be positive."))
    return (match_result.captures[2], n_qubits)
end

function _parse_gate_op(
    line::AbstractString,
    register_name::AbstractString,
    n_qubits::Int,
    line_number::Int,
)
    occursin('(', line) && throw(
        ArgumentError("Parametric OpenQASM gates are not supported on line $line_number."),
    )

    match_result = match(r"^([A-Za-z_]\w*)\s+(.+)$", line)
    match_result === nothing &&
        throw(ArgumentError("Expected a gate statement on line $line_number, got `$line`."))

    gate_name = lowercase(match_result.captures[1])
    gate = get(QASM_GATE_MAP, gate_name, nothing)
    gate === nothing &&
        throw(ArgumentError("Unsupported OpenQASM gate `$gate_name` on line $line_number."))

    qubits = _parse_qubit_operands(
        match_result.captures[2],
        register_name,
        n_qubits,
        line_number,
    )
    _validate_gate_arity(gate, qubits, line_number)
    return GateOp(gate, qubits)
end

function _parse_qubit_operands(
    operands::AbstractString,
    register_name::AbstractString,
    n_qubits::Int,
    line_number::Int,
)
    parsed = Int[]
    for operand in split(operands, ',')
        token = strip(operand)
        match_result = match(Regex("^$(escape_string(register_name))\\[(\\d+)\\]\$"), token)
        match_result === nothing && throw(
            ArgumentError(
                "Expected qubit operand `$register_name[i]` on line $line_number.",
            ),
        )

        qasm_index = parse(Int, match_result.captures[1])
        0 <= qasm_index < n_qubits || throw(
            ArgumentError(
                "Qubit index $qasm_index is outside register `$register_name` on line $line_number.",
            ),
        )
        push!(parsed, qasm_index + 1)
    end

    return Tuple(parsed)
end

function _validate_gate_arity(gate::Symbol, qubits::Tuple{Vararg{Int}}, line_number::Int)
    expected = gate == :CCX ? 3 : gate in (:CX, :CZ) ? 2 : 1
    length(qubits) == expected || throw(
        ArgumentError(
            "Gate :$gate expects $expected qubit(s) on line $line_number, got $(length(qubits)).",
        ),
    )
    length(unique(qubits)) == length(qubits) ||
        throw(ArgumentError("Gate :$gate uses repeated qubits on line $line_number."))
    return nothing
end

# ============================================================================ #
# Tests
# ============================================================================ #

@testitem "from_qasm — Bell circuit" begin
    using LinearAlgebra
    using Stretto

    qasm = """
    OPENQASM 3;
    include "stdgates.inc";
    qubit[2] q;
    h q[0];
    cx q[0], q[1];
    """

    circuit = from_qasm(qasm)

    @test circuit.n_qubits == 2
    @test circuit.ops == [GateOp(:H, (1,)), GateOp(:CX, (1, 2))]
    @test circuit_unitary(circuit) ≈ circuit_unitary(bell_circuit()) atol = 1e-12
end

@testitem "from_qasm — supported static gate names" begin
    using LinearAlgebra
    using Stretto

    qasm = """
    OPENQASM 3.0;
    qubit[3] q;
    x q[0];
    y q[1];
    z q[2];
    s q[0];
    t q[1];
    cz q[0], q[1];
    ccx q[0], q[1], q[2];
    """

    circuit = from_qasm(qasm)

    @test circuit.n_qubits == 3
    @test [op.gate for op in circuit.ops] == [:X, :Y, :Z, :S, :T, :CZ, :CCX]
    @test circuit.ops[end].qubits == (1, 2, 3)
    U = circuit_unitary(circuit)
    @test U' * U ≈ I(8) atol = 1e-12
end

@testitem "from_qasm — multiple statements per line and comments" begin
    using Stretto

    qasm = """
    OPENQASM 3; include "stdgates.inc"; // exported tools may compact statements
    qubit[2] q; h q[0]; cx q[0], q[1]; // Bell preparation
    """

    circuit = from_qasm(qasm)

    @test circuit.ops == [GateOp(:H, (1,)), GateOp(:CX, (1, 2))]
end

@testitem "from_qasm — rejects parametric gates" begin
    using Stretto

    qasm = """
    OPENQASM 3;
    qubit[1] q;
    rz(0.1) q[0];
    """

    @test_throws ArgumentError from_qasm(qasm)
end

@testitem "from_qasm — rejects out-of-range qubits" begin
    using Stretto

    qasm = """
    OPENQASM 3;
    qubit[1] q;
    h q[1];
    """

    @test_throws ArgumentError from_qasm(qasm)
end

@testitem "from_qasm — rejects unsupported QASM input" begin
    using Stretto

    @test_throws ArgumentError from_qasm("""
    qubit[1] q;
    h q[0];
    """)

    @test_throws ArgumentError from_qasm("""
    OPENQASM 2.0;
    qreg q[1];
    h q[0];
    """)

    @test_throws ArgumentError from_qasm("""
    OPENQASM 3;
    qubit[1] q
    h q[0];
    """)

    @test_throws ArgumentError from_qasm("""
    OPENQASM 3;
    qubit[1] q;
    measure q[0];
    """)

    @test_throws ArgumentError from_qasm("""
    OPENQASM 3;
    qubit[1] q;
    qubit[1] r;
    h q[0];
    """)

    @test_throws ArgumentError from_qasm("""
    OPENQASM 3;
    qubit[2] q;
    cx q[0], q[0];
    """)
end
