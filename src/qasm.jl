const QASM_GATE_MAP = Dict(
    "h" => :H,
    "cx" => :CX,
    "cz" => :CZ,
    "x" => :X,
    "y" => :Y,
    "z" => :Z,
    "s" => :S,
    "t" => :T,
    "sx" => :SX,
    "ccx" => :CCX,
)

# Parametric gates: QASM name → (IR symbol, arity). Angles are evaluated to
# Float64 at parse time — literals and the standard π-constant forms; no
# symbolic algebra engine.
const QASM_PARAMETRIC_GATE_MAP = Dict(
    "rx" => (:Rx, 1),
    "ry" => (:Ry, 1),
    "rz" => (:Rz, 1),
    "p" => (:P, 1),
    "cp" => (:Cp, 2),
)

_qasm_supported_list() =
    "supported static: $(join(sort(collect(keys(QASM_GATE_MAP))), ", ")); " *
    "supported parametric: $(join(sort(collect(keys(QASM_PARAMETRIC_GATE_MAP))), ", ")) " *
    "(angle = literal, π, π*k, π/k)"

"""
    from_qasm(qasm::String) -> GateCircuit

Parse an OpenQASM 3 circuit into a [`GateCircuit`](@ref).

The supported subset: any number of qubit registers (operands resolve into
one flat index space, registers in declaration order); the static gates
`h, x, y, z, s, t, sx, cx, cz, ccx`; the parametric gates
`rx(θ), ry(θ), rz(θ), p(θ), cp(θ)` with angles as numeric literals or the
standard π-constant forms (`pi/2`, `pi*3`, `-pi/4`); optional `include`
statements. OpenQASM indices are 0-based per register; the returned
`GateOp`s use Legato's 1-based flat indexing. Unsupported gates fail with
the gate named and the supported set listed.
"""
function from_qasm(qasm::String)
    saw_header = false
    registers = Dict{String,Int}() # name → declared size
    offsets = Dict{String,Int}()   # name → flat-index offset (declaration order)
    n_qubits = 0
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
        elseif startswith(line, "qubit[")
            name, size = _parse_qubit_register(line, line_number)
            haskey(registers, name) && throw(
                ArgumentError(
                    "Qubit register `$name` is declared more than once (line $line_number).",
                ),
            )
            registers[name] = size
            offsets[name] = n_qubits
            n_qubits += size
        else
            push!(ops, _parse_gate_op(line, registers, offsets, line_number))
        end
    end

    isempty(registers) &&
        throw(ArgumentError("OpenQASM input must declare at least one qubit register."))

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
    registers::Dict{String,Int},
    offsets::Dict{String,Int},
    line_number::Int,
)
    # Parametric form: name(angle) operands…
    m_param = match(r"^([A-Za-z_]\w*)\(([^)]*)\)\s+(.+)$", line)
    if m_param !== nothing
        gate_name = lowercase(m_param.captures[1])
        haskey(QASM_PARAMETRIC_GATE_MAP, gate_name) || throw(
            ArgumentError(
                "Unsupported OpenQASM gate `$gate_name` on line $line_number — " *
                _qasm_supported_list(),
            ),
        )
        θ = _parse_qasm_angle(m_param.captures[2], line_number)
        gate, arity = QASM_PARAMETRIC_GATE_MAP[gate_name]
        qubits = _parse_qubit_operands(m_param.captures[3], registers, offsets, line_number)
        _validate_gate_arity(gate, qubits, line_number)
        return GateOp(gate, qubits, θ)
    end

    # Static form: name operands…
    m_static = match(r"^([A-Za-z_]\w*)\s+(.+)$", line)
    m_static === nothing &&
        throw(ArgumentError("Expected a gate statement on line $line_number, got `$line`."))
    gate_name = lowercase(m_static.captures[1])
    haskey(QASM_GATE_MAP, gate_name) || throw(
        ArgumentError(
            "Unsupported OpenQASM gate `$gate_name` on line $line_number — " *
            _qasm_supported_list(),
        ),
    )
    gate = QASM_GATE_MAP[gate_name]
    qubits = _parse_qubit_operands(m_static.captures[2], registers, offsets, line_number)
    _validate_gate_arity(gate, qubits, line_number)
    return GateOp(gate, qubits)
end

# Angle expressions: numeric literals (incl. scientific notation, leading
# sign) and the standard π-constant forms — bare `pi`, `pi*k`, `pi/k`, with
# an optional leading sign. Everything else is rejected by name; no symbolic
# algebra.
function _parse_qasm_angle(expr::AbstractString, line_number::Int)
    e = strip(expr)
    m = match(
        r"^([-+]?)\s*(?:(pi)(?:\s*(?:\*\s*(\d+(?:\.\d+)?))|(?:/\s*(\d+(?:\.\d+)?)))?|(\d+(?:\.\d+)?(?:[eE][-+]?\d+)?))$",
        e,
    )
    m === nothing && throw(
        ArgumentError(
            "Cannot parse OpenQASM angle expression `$e` on line $line_number — " *
            "supported: literals, `pi`, `pi*k`, `pi/k`",
        ),
    )
    sign = m.captures[1] == "-" ? -1 : 1
    if m.captures[2] == "pi"
        k = m.captures[3] !== nothing ? parse(Float64, m.captures[3]) : nothing
        d = m.captures[4] !== nothing ? parse(Float64, m.captures[4]) : nothing
        return sign * (d !== nothing ? π / d : k !== nothing ? π * k : π)
    end
    return sign * parse(Float64, m.captures[5])
end

function _parse_qubit_operands(
    operands::AbstractString,
    registers::Dict{String,Int},
    offsets::Dict{String,Int},
    line_number::Int,
)
    parsed = Int[]
    for operand in split(operands, ',')
        token = strip(operand)
        m = match(r"^([A-Za-z_]\w*)\[(\d+)\]$", token)
        m === nothing && throw(
            ArgumentError(
                "Expected a `register[i]` operand on line $line_number, got `$token`.",
            ),
        )
        name = m.captures[1]
        haskey(registers, name) || throw(
            ArgumentError(
                "Operand references undeclared register `$name` on line $line_number.",
            ),
        )
        i = parse(Int, m.captures[2])
        0 <= i < registers[name] || throw(
            ArgumentError(
                "Qubit index $i is outside register `$name` on line $line_number.",
            ),
        )
        # Flat index: the register's declaration-order offset + its 0-based index
        push!(parsed, offsets[name] + i + 1)
    end

    return Tuple(parsed)
end

function _validate_gate_arity(gate::Symbol, qubits::Tuple{Vararg{Int}}, line_number::Int)
    expected = gate == :CCX ? 3 : gate in (:CX, :CZ, :Cp) ? 2 : 1
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
    using Legato

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
    using Legato

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
    using Legato

    qasm = """
    OPENQASM 3; include "stdgates.inc"; // exported tools may compact statements
    qubit[2] q; h q[0]; cx q[0], q[1]; // Bell preparation
    """

    circuit = from_qasm(qasm)

    @test circuit.ops == [GateOp(:H, (1,)), GateOp(:CX, (1, 2))]
end

@testitem "from_qasm — parametric gates parse with angle expressions" begin
    using Legato

    qasm = """
    OPENQASM 3;
    qubit[1] q;
    rx(pi/2) q[0];
    ry(pi*2) q[0];
    rz(-pi/4) q[0];
    p(0.5) q[0];
    """
    circuit = from_qasm(qasm)
    @test [op.gate for op in circuit.ops] == [:Rx, :Ry, :Rz, :P]
    @test circuit.ops[1].angle ≈ π / 2
    @test circuit.ops[3].angle ≈ -π / 4
    @test circuit.ops[4].angle == 0.5

    # Malformed angles are still rejected by name
    err = try
        from_qasm("""
        OPENQASM 3;
        qubit[1] q;
        rx(q[0]) q[0];
        """)
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("angle", sprint(showerror, err))
end

@testitem "from_qasm — rejects out-of-range qubits" begin
    using Legato

    qasm = """
    OPENQASM 3;
    qubit[1] q;
    h q[1];
    """

    @test_throws ArgumentError from_qasm(qasm)
end

@testitem "from_qasm — rejects unsupported QASM input" begin
    using Legato

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
    qubit[2] q;
    cx q[0], q[0];
    """)
end

@testitem "from_qasm — rejects malformed include statements" begin
    using Legato

    # `include` with an unquoted filename looks like an include statement but
    # fails the quoted-path form; the parser must reject it by line number
    # (not confuse it with a gate or the valid `include "file"` form).
    err = try
        from_qasm("""
        OPENQASM 3;
        include stdgates.inc;
        qubit[1] q;
        h q[0];
        """)
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("Invalid OpenQASM include statement on line 2", sprint(showerror, err))

    # The well-formed quoted include is still accepted alongside it
    @test from_qasm("""
    OPENQASM 3;
    include "stdgates.inc";
    qubit[1] q;
    h q[0];
    """) isa GateCircuit
end

@testitem "from_qasm — multi-register circuits, cross-register operands" begin
    using Legato
    using LinearAlgebra

    # Two registers; flat index space in declaration order: q ↦ 1..2, r ↦ 3..5
    qasm = """
    OPENQASM 3;
    qubit[2] q;
    qubit[3] r;
    h q[1];
    cx q[0], r[2];
    """
    circuit = from_qasm(qasm)
    @test circuit.n_qubits == 5
    @test circuit.ops[1] == GateOp(:H, (2,))
    @test circuit.ops[2] == GateOp(:CX, (1, 5))   # cross-register: q[0] → 1, r[2] → 5

    # Operand validation is per-register: index 2 is valid in `r` (size 3)
    # but invalid in `q` (size 2)
    err = try
        from_qasm("""
        OPENQASM 3;
        qubit[2] q;
        qubit[3] r;
        h q[2];
        """)
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("outside register `q`", sprint(showerror, err))

    # Undeclared registers are named
    err = try
        from_qasm("""
        OPENQASM 3;
        qubit[1] q;
        h s[0];
        """)
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("undeclared register `s`", sprint(showerror, err))

    # A 5-qubit circuit is a 5-qubit unitary
    U = circuit_unitary(circuit)
    @test size(U) == (32, 32)
    @test U' * U ≈ Matrix{ComplexF64}(I, 32, 32) atol = 1e-12
end

@testitem "from_qasm — parametric circuit unitary matches reference semantics" begin
    using Legato
    using LinearAlgebra
    using Legato: GATES

    # rx(pi) q[0] must equal X up to global phase (the reference semantics)
    circuit = from_qasm("""
    OPENQASM 3;
    qubit[1] q;
    rx(pi) q[0];
    """)
    U = circuit_unitary(circuit)
    X = ComplexF64[0 1; 1 0]
    @test abs(tr(X' * U)) ≈ 2 atol = 1e-12

    # cp(pi) on (q0, q1) is CZ exactly
    circuit = from_qasm("""
    OPENQASM 3;
    qubit[2] q;
    cp(pi) q[0], q[1];
    """)
    @test circuit_unitary(circuit) ≈ GATES[:CZ] atol = 1e-12

    # A multi-register parametric composite against the hand-built reference
    circuit = from_qasm("""
    OPENQASM 3;
    qubit[1] a;
    qubit[1] b;
    rx(pi/2) a[0];
    ry(pi/2) b[0];
    cp(pi/4) a[0], b[0];
    """)
    U = circuit_unitary(circuit)
    Rx = ComplexF64[cos(π/4) -im*sin(π/4); -im*sin(π/4) cos(π/4)]
    Ry = ComplexF64[cos(π/4) -sin(π/4); sin(π/4) cos(π/4)]
    Cp = ComplexF64[1 0 0 0; 0 1 0 0; 0 0 1 0; 0 0 0 exp(im*π/4)]
    reference = Cp * kron(Rx, Ry)
    @test U ≈ reference atol = 1e-12
end

@testitem "from_qasm — unknown gates fail naming gate and supported set" begin
    using Legato

    err = try
        from_qasm("""
        OPENQASM 3;
        qubit[1] q;
        fancy_custom_gate q[0];
        """)
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    msg = sprint(showerror, err)
    @test occursin("`fancy_custom_gate`", msg)          # the gate is named
    @test occursin("supported static", msg)              # and the set listed
    @test occursin("rx", msg)                            # parametric set too

    # Unknown parametric gates name the set as well
    err = try
        from_qasm("""
        OPENQASM 3;
        qubit[1] q;
        u(pi/2) q[0];
        """)
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("`u`", sprint(showerror, err))
end

@testitem "from_qasm — parametric gates ride through transpilation" begin
    using Legato
    using LinearAlgebra

    # Parametric ops survive to_native unchanged (the compile target is the
    # circuit unitary; free-phase absorbs Z-class rotations); static
    # non-native gates still rewrite.
    circuit = from_qasm("""
    OPENQASM 3;
    qubit[2] q;
    rz(pi/4) q[0];
    cx q[0], q[1];
    """)
    device = HeronR3()
    native = to_native(circuit, device)
    @test native.ops[1] == GateOp(:Rz, (1,), π / 4)
    # cx rewrote to the native H·CZ·H sandwich
    @test [op.gate for op in native.ops[2:end]] == [:H, :CZ, :H]
    # and the rewrite preserved the unitary
    U0 = circuit_unitary(circuit)
    U1 = circuit_unitary(native)
    @test abs(tr(U0' * U1)) / size(U0, 1) ≥ 1 - 1e-10
end
