# ============================================================================ #
# OpenQASM 3 source-anchored gate tables
#
# Source links used for this mapping:
# - OpenQASM standard library (`stdgates.inc` gate names and definitions;
#   gates used here are marked as added in version 3.0):
#   https://openqasm.com/language/standard_library.html
#   https://openqasm.com/_sources/language/standard_library.rst.txt
# - OpenQASM 3.0 grammar (statement categories and syntax boundaries):
#   https://openqasm.com/versions/3.0/grammar/index.html
# - OpenQASM 3.0 language reference:
#   https://openqasm.com/versions/3.0/index.html
#
# Stretto only accepts syntax that can lower to a static unitary GateCircuit.
# Keep QASM_STDGATES_3_GATE_NAMES aligned with the standard-library docs; the
# :qasm testitems at the end of this file assert the implementation table.
# ============================================================================ #

const QASM_FIXED_GATE_ALIASES = Dict{String,Symbol}(
    "id" => :ID,
    "h" => :H,
    "x" => :X,
    "y" => :Y,
    "z" => :Z,
    "s" => :S,
    "sdg" => :SDG,
    "sx" => :SX,
    "t" => :T,
    "tdg" => :TDG,
    "cx" => :CX,
    "CX" => :CX,
    "cnot" => :CX,
    "cy" => :CY,
    "cz" => :CZ,
    "ch" => :CH,
    "swap" => :SWAP,
    "ccx" => :CCX,
    "toffoli" => :CCX,
    "ccz" => :CCZ,
    "cswap" => :CSWAP,
)

# Number of qubit operands for fixed gates after alias resolution.
const QASM_FIXED_GATE_QUBIT_COUNTS = Dict{Symbol,Int}(
    :ID => 1,
    :H => 1,
    :X => 1,
    :Y => 1,
    :Z => 1,
    :S => 1,
    :SDG => 1,
    :SX => 1,
    :T => 1,
    :TDG => 1,
    :CX => 2,
    :CY => 2,
    :CZ => 2,
    :CH => 2,
    :SWAP => 2,
    :CCX => 3,
    :CCZ => 3,
    :CSWAP => 3,
)

# Number of qubit operands for parameterized OpenQASM gate calls.
const QASM_PARAMETERIZED_GATE_QUBIT_COUNTS = Dict{String,Int}(
    "p" => 1,
    "phase" => 1,
    "rx" => 1,
    "ry" => 1,
    "rz" => 1,
    "u1" => 1,
    "u2" => 1,
    "u3" => 1,
    "u" => 1,
    "gphase" => 0,
    "cp" => 2,
    "cphase" => 2,
    "crx" => 2,
    "cry" => 2,
    "crz" => 2,
    "cu" => 2,
)

# Number of numeric parameters inside the gate-call parentheses.
const QASM_PARAMETERIZED_GATE_PARAMETER_COUNTS = Dict{String,Int}(
    "p" => 1,
    "phase" => 1,
    "rx" => 1,
    "ry" => 1,
    "rz" => 1,
    "u1" => 1,
    "u2" => 2,
    "u3" => 3,
    "u" => 3,
    "gphase" => 1,
    "cp" => 1,
    "cphase" => 1,
    "crx" => 1,
    "cry" => 1,
    "crz" => 1,
    "cu" => 4,
)

const QASM_STDGATES_3_GATE_NAMES = Set([
    "p",
    "x",
    "y",
    "z",
    "h",
    "s",
    "sdg",
    "t",
    "tdg",
    "sx",
    "rx",
    "ry",
    "rz",
    "cx",
    "cy",
    "cz",
    "cp",
    "crx",
    "cry",
    "crz",
    "ch",
    "cu",
    "swap",
    "ccx",
    "cswap",
    "CX",
    "phase",
    "cphase",
    "id",
    "u1",
    "u2",
    "u3",
])

const QASM_BUILTIN_GATE_NAMES = Set(["U", "gphase"])

const QASM_NUMERIC_FUNCTIONS = Dict{String,Function}(
    "sin" => sin,
    "cos" => cos,
    "tan" => tan,
    "arcsin" => asin,
    "arccos" => acos,
    "arctan" => atan,
    "sqrt" => sqrt,
    "exp" => exp,
    "log" => log,
    "floor" => floor,
    "ceiling" => ceil,
)

const QASM_CONST_RE =
    r"^const\s+(?:(?:bit|int|uint|float|angle|bool)(?:\s*\[\s*[^]]+\s*\])?\s+)?([A-Za-z_]\w*)\s*=\s*(.+)$"
const QASM_QUBIT_DECL_RE = r"^qubit(?:\s*\[\s*(.+?)\s*\])?\s+([A-Za-z_]\w*)(?:\s*\[\s*(.+?)\s*\])?$"
const QASM_QREG_DECL_RE = r"^qreg\s+([A-Za-z_]\w*)(?:\s*\[\s*(.+?)\s*\])?$"
const QASM_INCLUDE_RE = r"^include\s+\"([^\"]+)\"$"
const QASM_QUBIT_REF_RE = r"^([A-Za-z_]\w*)(?:\[\s*(.+?)\s*\])?$"
const QASM_PARAM_GATE_RE = r"^([A-Za-z_]\w*)\s*\((.*)\)\s*(.*)$"
const QASM_GATE_RE = r"^([A-Za-z_]\w*)\s+(.+)$"

# OpenQASM spells the built-in universal gate `U`; table keys use lowercase names.
_qasm_gate_key(gate_name::AbstractString) = gate_name == "U" ? "u" : String(gate_name)

# ============================================================================ #
# Public API
# ============================================================================ #

"""
    from_qasm(qasm::String) -> GateCircuit

Parse a small OpenQASM 3 circuit into a [`GateCircuit`](@ref). Supported input
is the static unitary subset that Stretto can represent as a `GateCircuit`:
qubit declarations, `stdgates.inc`, fixed standard-library gates, constant
numeric parameters, register broadcasting, and barriers/no-ops. QASM qubit
references are converted from 0-based indices to Stretto's 1-based indices.

OpenQASM 3 features without a `GateCircuit` equivalent -- measurements,
resets, control flow, custom gate definitions, calibration/OpenPulse blocks,
timing, and dynamic classical computation -- throw `ArgumentError`.
"""
function from_qasm(qasm::String)
    source = _strip_qasm_comments(qasm)
    statements = split(source, ';'; keepempty = false)

    registers = Dict{String,Vector{Int}}()
    constants = Dict{String,Float64}()
    ops = GateOp[]
    n_qubits = 0

    for raw_statement in statements
        statement = strip(raw_statement)
        isempty(statement) && continue

        const_declaration = _parse_qasm_const_declaration(statement, constants)
        const_declaration !== nothing && continue

        declaration = _parse_qasm_qubit_declaration(statement, n_qubits, constants)
        if declaration !== nothing
            name, qubits = declaration
            haskey(registers, name) &&
                throw(ArgumentError("Duplicate qubit register `$name` in OpenQASM input"))
            registers[name] = qubits
            n_qubits += length(qubits)
            continue
        end

        _handle_qasm_include(statement) && continue
        _is_ignored_qasm_statement(statement) && continue
        _throw_for_unsupported_qasm_statement(statement)

        append!(ops, _parse_qasm_gate_statement(statement, registers, constants, n_qubits))
    end

    n_qubits > 0 || throw(ArgumentError("No qubit declarations found in OpenQASM input"))
    return GateCircuit(ops, n_qubits)
end

# ============================================================================ #
# Parser helpers
# ============================================================================ #

function _strip_qasm_comments(qasm::String)
    without_blocks = replace(qasm, r"/\*[\s\S]*?\*/" => " ")
    return join((_strip_qasm_line_comment(line) for line in split(without_blocks, '\n')), '\n')
end

function _strip_qasm_line_comment(line::AbstractString)
    comment_range = findfirst("//", line)
    comment_range === nothing && return String(line)
    comment_start = first(comment_range)
    comment_start == firstindex(line) && return ""
    return String(line[firstindex(line):prevind(line, comment_start)])
end

function _parse_qasm_const_declaration(statement::AbstractString, constants::Dict{String,Float64})
    m = match(QASM_CONST_RE, statement)
    m === nothing && return nothing

    name, value_text = m.captures
    constants[name] = _eval_qasm_numeric_expr(value_text, constants)
    return name
end

function _parse_qasm_qubit_declaration(
    statement::AbstractString,
    n_qubits::Int,
    constants::Dict{String,Float64},
)
    m = match(QASM_QUBIT_DECL_RE, statement)
    if m !== nothing
        prefix_size, name, suffix_size = m.captures
        prefix_size !== nothing &&
            suffix_size !== nothing &&
            throw(
                ArgumentError(
                    "Qubit register `$name` cannot use both `qubit[n] q` and `qubit q[n]` syntax",
                ),
            )
        size_text = prefix_size === nothing ? suffix_size : prefix_size
        return _qasm_register_qubits(name, size_text, n_qubits, constants)
    end

    m = match(QASM_QREG_DECL_RE, statement)
    m === nothing && return nothing

    name, size_text = m.captures
    return _qasm_register_qubits(name, size_text, n_qubits, constants)
end

function _qasm_register_qubits(
    name::AbstractString,
    size_text::Union{Nothing,AbstractString},
    n_qubits::Int,
    constants::Dict{String,Float64},
)
    size = size_text === nothing ? 1 : _eval_qasm_integer_expr(size_text, constants)
    size > 0 || throw(ArgumentError("Qubit register `$name` must have positive size"))

    first_qubit = n_qubits + 1
    return name => collect(first_qubit:(first_qubit+size-1))
end

function _handle_qasm_include(statement::AbstractString)
    m = match(QASM_INCLUDE_RE, statement)
    m === nothing && return false

    path = only(m.captures)
    path == "stdgates.inc" || throw(
        ArgumentError(
            "Only `include \"stdgates.inc\";` is supported; cannot resolve include `$path`",
        ),
    )
    return true
end

function _is_ignored_qasm_statement(statement::AbstractString)
    lowered = lowercase(statement)
    return startswith(lowered, "openqasm ") ||
           startswith(lowered, "pragma ") ||
           lowered == "barrier" ||
           startswith(lowered, "barrier ") ||
           lowered == "nop" ||
           occursin(r"^(bit|creg)\b", lowered)
end

function _throw_for_unsupported_qasm_statement(statement::AbstractString)
    lowered = lowercase(statement)
    occursin(r"\b(measure|reset)\b", lowered) &&
        throw(ArgumentError("Non-unitary OpenQASM statements are not supported: `$statement`"))
    startswith(lowered, "defcalgrammar ") &&
        throw(ArgumentError("OpenQASM calibration grammar declarations are not supported"))
    startswith(lowered, "defcal ") &&
        throw(ArgumentError("OpenQASM calibration definitions are not supported"))
    startswith(lowered, "cal ") &&
        throw(ArgumentError("OpenQASM calibration blocks are not supported"))
    startswith(lowered, "gate ") &&
        throw(ArgumentError("Custom OpenQASM gate definitions are not supported"))
    startswith(lowered, "def ") && throw(ArgumentError("OpenQASM subroutines are not supported"))
    startswith(lowered, "extern ") &&
        throw(ArgumentError("OpenQASM extern declarations are not supported"))
    occursin(r"^(if|for|while|switch)\b", lowered) &&
        throw(ArgumentError("OpenQASM control flow is not supported"))
    occursin(r"^(delay|box)\b", lowered) &&
        throw(ArgumentError("OpenQASM timing statements are not supported"))
    occursin("@", statement) &&
        throw(ArgumentError("OpenQASM gate modifiers are not supported: `$statement`"))
    occursin("{", statement) &&
        throw(ArgumentError("Scoped OpenQASM blocks are not supported: `$statement`"))
    return nothing
end

function _parse_qasm_gate_statement(
    statement::AbstractString,
    registers::Dict{String,Vector{Int}},
    constants::Dict{String,Float64},
    n_qubits::Int,
)
    param_match = match(QASM_PARAM_GATE_RE, statement)
    if param_match !== nothing
        gate_name, parameter_text, operand_text = param_match.captures
        gate_key, gate, expected_qubit_count =
            _resolve_qasm_parameterized_gate(gate_name, parameter_text, constants, n_qubits)
        if gate_key == "gphase"
            isempty(strip(operand_text)) || throw(
                ArgumentError("OpenQASM `gphase` does not accept qubit operands: `$statement`"),
            )
            return GateOp[GateOp(gate, Tuple(1:n_qubits))]
        end

        operands = expected_qubit_count == 0 ? String[] : _split_qasm_operands(operand_text)
        return _expand_qasm_gate_ops(
            gate_name,
            gate,
            expected_qubit_count,
            operands,
            registers,
            constants,
        )
    end

    m = match(QASM_GATE_RE, statement)
    m === nothing && throw(ArgumentError("Unsupported OpenQASM statement: `$statement`"))

    gate_name, operand_text = m.captures
    gate = get(QASM_FIXED_GATE_ALIASES, gate_name, nothing)
    gate === nothing && throw(ArgumentError("Unsupported OpenQASM gate `$gate_name`"))

    operands = _split_qasm_operands(operand_text)
    return _expand_qasm_gate_ops(
        gate_name,
        gate,
        QASM_FIXED_GATE_QUBIT_COUNTS[gate],
        operands,
        registers,
        constants,
    )
end

function _expand_qasm_gate_ops(
    gate_name::AbstractString,
    gate::Symbol,
    expected_qubit_count::Int,
    operands::Vector{String},
    registers::Dict{String,Vector{Int}},
    constants::Dict{String,Float64},
)
    any(isempty, operands) &&
        throw(ArgumentError("Invalid operands for OpenQASM gate `$gate_name`"))
    length(operands) == expected_qubit_count || throw(
        ArgumentError(
            "OpenQASM gate `$gate_name` expects $expected_qubit_count qubit operand(s), got $(length(operands))",
        ),
    )

    expected_qubit_count == 0 && return GateOp[GateOp(gate, ())]

    operand_qubits = [_parse_qasm_qubit_ref(operand, registers, constants) for operand in operands]
    broadcast_lengths = [length(qubits) for qubits in operand_qubits if length(qubits) > 1]
    broadcast_length = isempty(broadcast_lengths) ? 1 : first(broadcast_lengths)
    all(==(broadcast_length), broadcast_lengths) || throw(
        ArgumentError(
            "Broadcasted OpenQASM operands for gate `$gate_name` must have matching register sizes",
        ),
    )

    ops = GateOp[]
    for i = 1:broadcast_length
        qubits = Tuple(qs[length(qs) == 1 ? 1 : i] for qs in operand_qubits)
        push!(ops, GateOp(gate, qubits))
    end
    return ops
end

function _parse_qasm_qubit_ref(
    ref::AbstractString,
    registers::Dict{String,Vector{Int}},
    constants::Dict{String,Float64},
)
    m = match(QASM_QUBIT_REF_RE, ref)
    m === nothing && throw(ArgumentError("Invalid OpenQASM qubit operand `$ref`"))

    name, index_text = m.captures
    haskey(registers, name) ||
        throw(ArgumentError("OpenQASM qubit register `$name` has not been declared"))

    qubits = registers[name]
    if index_text === nothing
        return qubits
    end

    occursin(":", index_text) && throw(
        ArgumentError(
            "OpenQASM register slices are not supported; use whole-register broadcasting or scalar indices",
        ),
    )
    qasm_index = _eval_qasm_integer_expr(index_text, constants)
    0 <= qasm_index < length(qubits) || throw(
        ArgumentError(
            "OpenQASM qubit `$name[$qasm_index]` is out of range for register of size $(length(qubits))",
        ),
    )
    return [qubits[qasm_index+1]]
end

function _split_qasm_operands(text::AbstractString)
    stripped = strip(text)
    isempty(stripped) && return String[]
    return String.(strip.(_split_qasm_comma_list(stripped)))
end

function _split_qasm_parameters(text::AbstractString)
    stripped = strip(text)
    isempty(stripped) && return String[]
    return String.(strip.(_split_qasm_comma_list(stripped)))
end

function _split_qasm_comma_list(text::AbstractString)
    parts = String[]
    depth = 0
    start = firstindex(text)
    i = firstindex(text)
    while i <= lastindex(text)
        c = text[i]
        if c == '(' || c == '[' || c == '{'
            depth += 1
        elseif c == ')' || c == ']' || c == '}'
            depth -= 1
        elseif c == ',' && depth == 0
            push!(parts, String(text[start:prevind(text, i)]))
            start = nextind(text, i)
        end
        i = nextind(text, i)
    end
    push!(parts, String(text[start:lastindex(text)]))
    return parts
end

function _resolve_qasm_parameterized_gate(
    gate_name::AbstractString,
    parameter_text::AbstractString,
    constants::Dict{String,Float64},
    n_qubits::Int,
)
    gate_key = _qasm_gate_key(gate_name)
    expected_qubit_count = get(QASM_PARAMETERIZED_GATE_QUBIT_COUNTS, gate_key, nothing)
    expected_qubit_count === nothing &&
        throw(ArgumentError("Unsupported OpenQASM gate `$gate_name`"))

    parameters = [
        Float64(_eval_qasm_numeric_expr(parameter, constants)) for
        parameter in _split_qasm_parameters(parameter_text)
    ]
    matrix = _qasm_parameterized_gate_matrix(gate_key, parameters, n_qubits)
    gate = _register_qasm_generated_gate(gate_key, parameters, matrix)
    return gate_key, gate, expected_qubit_count
end

function _register_qasm_generated_gate(
    gate_name::AbstractString,
    parameters::Vector{Float64},
    matrix::AbstractMatrix,
)
    key = Symbol(
        "QASM_",
        uppercase(gate_name),
        "_",
        hash((gate_name, round.(parameters; digits = 14), size(matrix))),
    )
    EXTRA_GATES[key] = Matrix{ComplexF64}(matrix)
    return key
end

function _qasm_check_parameter_count(
    gate_name::AbstractString,
    parameters::Vector{Float64},
    expected::Int,
)
    length(parameters) == expected || throw(
        ArgumentError(
            "OpenQASM gate `$gate_name` expects $expected parameter(s), got $(length(parameters))",
        ),
    )
end

_qasm_matrix(entries::AbstractMatrix) = Matrix{ComplexF64}(entries)

function _qasm_phase(lambda)
    return _qasm_matrix([
        1 0
        0 exp(im * lambda)
    ])
end

function _qasm_rx(theta)
    return _qasm_matrix([
        cos(theta / 2) -im * sin(theta / 2)
        -im * sin(theta / 2) cos(theta / 2)
    ])
end

function _qasm_ry(theta)
    return _qasm_matrix([
        cos(theta / 2) -sin(theta / 2)
        sin(theta / 2) cos(theta / 2)
    ])
end

function _qasm_rz(theta)
    return _qasm_matrix([
        exp(-im * theta / 2) 0
        0 exp(im * theta / 2)
    ])
end

function _qasm_U(theta, phi, lambda)
    theta_phase = exp(im * theta)
    one_plus_theta_phase = 1 + theta_phase
    one_minus_theta_phase = 1 - theta_phase
    top_left = one_plus_theta_phase / 2
    top_right = -im * exp(im * lambda) * one_minus_theta_phase / 2
    bottom_left = im * exp(im * phi) * one_minus_theta_phase / 2
    bottom_right = exp(im * (phi + lambda)) * one_plus_theta_phase / 2

    return _qasm_matrix([
        top_left top_right
        bottom_left bottom_right
    ])
end

function _qasm_u3(theta, phi, lambda)
    return exp(-im * (theta + phi + lambda) / 2) * _qasm_U(theta, phi, lambda)
end

function _qasm_one_parameter_gate(builder)
    return (parameters, _) -> builder(parameters[1])
end

function _qasm_controlled_one_parameter_gate(builder)
    return (parameters, _) -> _qasm_controlled(builder(parameters[1]))
end

function _qasm_u2(parameters, _)
    return _qasm_u3(π / 2, parameters[1], parameters[2])
end

function _qasm_controlled_u(parameters, _)
    return _qasm_controlled(
        exp(im * parameters[4]) * _qasm_U(parameters[1], parameters[2], parameters[3]),
    )
end

function _qasm_global_phase_gate(parameters, n_qubits)
    return _qasm_global_phase(parameters[1], n_qubits)
end

function _qasm_u_gate(parameters, _)
    return _qasm_U(parameters[1], parameters[2], parameters[3])
end

function _qasm_u3_gate(parameters, _)
    return _qasm_u3(parameters[1], parameters[2], parameters[3])
end

const QASM_PARAMETERIZED_GATE_BUILDERS = Dict{String,Function}(
    "p" => _qasm_one_parameter_gate(_qasm_phase),
    "phase" => _qasm_one_parameter_gate(_qasm_phase),
    "rx" => _qasm_one_parameter_gate(_qasm_rx),
    "ry" => _qasm_one_parameter_gate(_qasm_ry),
    "rz" => _qasm_one_parameter_gate(_qasm_rz),
    "u1" => _qasm_one_parameter_gate(_qasm_phase),
    "u2" => _qasm_u2,
    "u3" => _qasm_u3_gate,
    "u" => _qasm_u_gate,
    "gphase" => _qasm_global_phase_gate,
    "cp" => _qasm_controlled_one_parameter_gate(_qasm_phase),
    "cphase" => _qasm_controlled_one_parameter_gate(_qasm_phase),
    "crx" => _qasm_controlled_one_parameter_gate(_qasm_rx),
    "cry" => _qasm_controlled_one_parameter_gate(_qasm_ry),
    "crz" => _qasm_controlled_one_parameter_gate(_qasm_rz),
    "cu" => _qasm_controlled_u,
)

function _qasm_parameterized_gate_matrix(
    gate_name::AbstractString,
    parameters::Vector{Float64},
    n_qubits::Int,
)
    parameter_count = get(QASM_PARAMETERIZED_GATE_PARAMETER_COUNTS, gate_name, nothing)
    parameter_count === nothing &&
        error("No parameter count registered for OpenQASM gate `$gate_name`")
    _qasm_check_parameter_count(gate_name, parameters, parameter_count)

    builder = get(QASM_PARAMETERIZED_GATE_BUILDERS, gate_name, nothing)
    builder === nothing && error("No matrix builder registered for OpenQASM gate `$gate_name`")
    return builder(parameters, n_qubits)
end

function _qasm_controlled(gate::AbstractMatrix)
    n = size(gate, 1)
    U = Matrix{ComplexF64}(I, 2n, 2n)
    U[(n+1):(2n), (n+1):(2n)] .= gate
    return U
end

function _qasm_global_phase(gamma, n_qubits::Int)
    n_qubits > 0 || throw(ArgumentError("`gphase` requires declared qubits"))
    return exp(im * gamma) * Matrix{ComplexF64}(I, 2^n_qubits, 2^n_qubits)
end

function _eval_qasm_integer_expr(text::AbstractString, constants::Dict{String,Float64})
    value = _eval_qasm_numeric_expr(text, constants)
    isapprox(value, round(value); atol = 1e-12) ||
        throw(ArgumentError("OpenQASM expression `$text` must evaluate to an integer"))
    return Int(round(value))
end

mutable struct _QASMExprParser
    text::String
    index::Int
    constants::Dict{String,Float64}
end

function _eval_qasm_numeric_expr(text::AbstractString, constants::Dict{String,Float64})
    parser = _QASMExprParser(String(text), 1, constants)
    value = _parse_qasm_expr_sum(parser)
    _skip_qasm_expr_space!(parser)
    parser.index > lastindex(parser.text) || throw(
        ArgumentError(
            "Unsupported OpenQASM expression syntax near `$(parser.text[parser.index:end])`",
        ),
    )
    return value
end

function _parse_qasm_expr_sum(parser::_QASMExprParser)
    value = _parse_qasm_expr_product(parser)
    while true
        _skip_qasm_expr_space!(parser)
        _qasm_expr_at_end(parser) && return value
        op = parser.text[parser.index]
        op == '+' || op == '-' || return value
        parser.index = nextind(parser.text, parser.index)
        rhs = _parse_qasm_expr_product(parser)
        value = op == '+' ? value + rhs : value - rhs
    end
end

function _parse_qasm_expr_product(parser::_QASMExprParser)
    value = _parse_qasm_expr_power(parser)
    while true
        _skip_qasm_expr_space!(parser)
        _qasm_expr_at_end(parser) && return value
        op = parser.text[parser.index]
        op == '*' || op == '/' || return value
        if op == '*' &&
           nextind(parser.text, parser.index) <= lastindex(parser.text) &&
           parser.text[nextind(parser.text, parser.index)] == '*'
            return value
        end
        parser.index = nextind(parser.text, parser.index)
        rhs = _parse_qasm_expr_power(parser)
        value = op == '*' ? value * rhs : value / rhs
    end
end

function _parse_qasm_expr_power(parser::_QASMExprParser)
    value = _parse_qasm_expr_unary(parser)
    _skip_qasm_expr_space!(parser)
    if !_qasm_expr_at_end(parser) && parser.text[parser.index] == '^'
        parser.index = nextind(parser.text, parser.index)
        value = value ^ _parse_qasm_expr_power(parser)
    elseif !_qasm_expr_at_end(parser) && parser.text[parser.index] == '*'
        next = nextind(parser.text, parser.index)
        if next <= lastindex(parser.text) && parser.text[next] == '*'
            parser.index = nextind(parser.text, next)
            value = value ^ _parse_qasm_expr_power(parser)
        end
    end
    return value
end

function _parse_qasm_expr_unary(parser::_QASMExprParser)
    _skip_qasm_expr_space!(parser)
    _qasm_expr_at_end(parser) && throw(ArgumentError("Unexpected end of OpenQASM expression"))
    op = parser.text[parser.index]
    if op == '+'
        parser.index = nextind(parser.text, parser.index)
        return _parse_qasm_expr_unary(parser)
    elseif op == '-'
        parser.index = nextind(parser.text, parser.index)
        return -_parse_qasm_expr_unary(parser)
    end
    return _parse_qasm_expr_primary(parser)
end

function _parse_qasm_expr_primary(parser::_QASMExprParser)
    _skip_qasm_expr_space!(parser)
    _qasm_expr_at_end(parser) && throw(ArgumentError("Unexpected end of OpenQASM expression"))

    if parser.text[parser.index] == '('
        parser.index = nextind(parser.text, parser.index)
        value = _parse_qasm_expr_sum(parser)
        _skip_qasm_expr_space!(parser)
        (!_qasm_expr_at_end(parser) && parser.text[parser.index] == ')') ||
            throw(ArgumentError("Missing `)` in OpenQASM expression"))
        parser.index = nextind(parser.text, parser.index)
        return value
    end

    if isdigit(parser.text[parser.index]) || parser.text[parser.index] == '.'
        return _parse_qasm_expr_number(parser)
    end

    name = _parse_qasm_expr_identifier(parser)
    lowered = lowercase(name)
    if lowered in ("pi", "π")
        return π
    elseif lowered == "tau"
        return 2π
    elseif lowered == "e"
        return ℯ
    elseif haskey(parser.constants, name)
        return parser.constants[name]
    elseif haskey(parser.constants, lowered)
        return parser.constants[lowered]
    end

    _skip_qasm_expr_space!(parser)
    if !_qasm_expr_at_end(parser) && parser.text[parser.index] == '('
        parser.index = nextind(parser.text, parser.index)
        arg = _parse_qasm_expr_sum(parser)
        _skip_qasm_expr_space!(parser)
        (!_qasm_expr_at_end(parser) && parser.text[parser.index] == ')') ||
            throw(ArgumentError("Missing `)` in OpenQASM function call `$name`"))
        parser.index = nextind(parser.text, parser.index)
        return _eval_qasm_numeric_function(lowered, arg)
    end

    throw(ArgumentError("Unknown OpenQASM numeric identifier `$name`"))
end

function _parse_qasm_expr_number(parser::_QASMExprParser)
    start = parser.index
    seen_exponent = false
    while parser.index <= lastindex(parser.text)
        c = parser.text[parser.index]
        if isdigit(c) || c == '.'
            parser.index = nextind(parser.text, parser.index)
        elseif (c == 'e' || c == 'E') && !seen_exponent
            seen_exponent = true
            parser.index = nextind(parser.text, parser.index)
            if parser.index <= lastindex(parser.text) &&
               (parser.text[parser.index] == '+' || parser.text[parser.index] == '-')
                parser.index = nextind(parser.text, parser.index)
            end
        else
            break
        end
    end
    return parse(Float64, parser.text[start:prevind(parser.text, parser.index)])
end

function _parse_qasm_expr_identifier(parser::_QASMExprParser)
    start = parser.index
    while parser.index <= lastindex(parser.text)
        c = parser.text[parser.index]
        if isletter(c) || isdigit(c) || c == '_' || c == 'π'
            parser.index = nextind(parser.text, parser.index)
        else
            break
        end
    end
    start == parser.index && throw(ArgumentError("Expected OpenQASM numeric expression"))
    return parser.text[start:prevind(parser.text, parser.index)]
end

function _eval_qasm_numeric_function(name::AbstractString, arg::Float64)
    f = get(QASM_NUMERIC_FUNCTIONS, String(name), nothing)
    f === nothing && throw(ArgumentError("Unsupported OpenQASM numeric function `$name`"))
    return Float64(f(arg))
end

function _skip_qasm_expr_space!(parser::_QASMExprParser)
    while parser.index <= lastindex(parser.text) && isspace(parser.text[parser.index])
        parser.index = nextind(parser.text, parser.index)
    end
end

_qasm_expr_at_end(parser::_QASMExprParser) = parser.index > lastindex(parser.text)

# ============================================================================ #
# TestItems
#
# This package already keeps lightweight tests next to the code via TestItems.jl.
# QASM tests are tagged with :qasm so they are easy to filter or move later.
# ============================================================================ #

@testitem "from_qasm — parses Bell circuit with and without stdgates include" tags = [:qasm] begin
    bare_qasm = """
    OPENQASM 3;
    qubit[2] q;
    h q[0];
    cx q[0], q[1];
    """

    stdgates_qasm = """
    OPENQASM 3;
    include "stdgates.inc";
    qubit[2] q;
    h q[0];
    cx q[0], q[1];
    """

    expected = GateCircuit([GateOp(:H, (1,)), GateOp(:CX, (1, 2))], 2)
    for qasm in (bare_qasm, stdgates_qasm)
        c = from_qasm(qasm)
        @test c isa GateCircuit
        @test c.n_qubits == 2
        @test [(op.gate, op.qubits) for op in c.ops] == [(:H, (1,)), (:CX, (1, 2))]
        @test circuit_unitary(c) ≈ circuit_unitary(expected) atol = 1e-12
    end
end

@testitem "from_qasm — supports comments, single-qubit declarations, and multiple registers" tags =
    [:qasm] begin
    qasm = """
    OPENQASM 3.0;
    /* exported by an external tool */
    qubit control;
    qubit[2] target;
    bit[2] c;
    x control; // single-qubit declaration may be referenced without [0]
    cz control, target[1];
    barrier control, target[0], target[1];
    """

    c = from_qasm(qasm)
    @test c.n_qubits == 3
    @test [(op.gate, op.qubits) for op in c.ops] == [(:X, (1,)), (:CZ, (1, 3))]
end

@testitem "from_qasm — supported stdgates list tracks OpenQASM 3.0 docs" tags = [:qasm] begin
    implemented_std = Set(keys(Stretto.QASM_FIXED_GATE_ALIASES))
    union!(implemented_std, keys(Stretto.QASM_PARAMETERIZED_GATE_QUBIT_COUNTS))
    setdiff!(implemented_std, ["cnot", "toffoli", "ccz", "u", "gphase"])
    @test implemented_std == Stretto.QASM_STDGATES_3_GATE_NAMES
    @test Stretto.QASM_BUILTIN_GATE_NAMES == Set(["U", "gphase"])

    parameterized = Set(keys(Stretto.QASM_PARAMETERIZED_GATE_QUBIT_COUNTS))
    @test Set(keys(Stretto.QASM_PARAMETERIZED_GATE_PARAMETER_COUNTS)) == parameterized
    @test Set(keys(Stretto.QASM_PARAMETERIZED_GATE_BUILDERS)) == parameterized
end

@testitem "from_qasm — parses fixed standard-library gates" tags = [:qasm] begin
    using LinearAlgebra

    qasm = """
    OPENQASM 3;
    include "stdgates.inc";
    qubit[3] q;
    id q[0];
    h q[0];
    x q[0];
    y q[0];
    z q[1];
    s q[2];
    sdg q[2];
    sx q[0];
    t q[1];
    tdg q[1];
    cx q[0], q[1];
    CX q[1], q[2];
    cy q[0], q[1];
    cz q[0], q[2];
    ch q[1], q[2];
    swap q[0], q[2];
    ccx q[0], q[1], q[2];
    cswap q[0], q[1], q[2];
    ccz q[0], q[1], q[2];
    """

    c = from_qasm(qasm)
    @test c.n_qubits == 3
    @test [(op.gate, op.qubits) for op in c.ops] == [
        (:ID, (1,)),
        (:H, (1,)),
        (:X, (1,)),
        (:Y, (1,)),
        (:Z, (2,)),
        (:S, (3,)),
        (:SDG, (3,)),
        (:SX, (1,)),
        (:T, (2,)),
        (:TDG, (2,)),
        (:CX, (1, 2)),
        (:CX, (2, 3)),
        (:CY, (1, 2)),
        (:CZ, (1, 3)),
        (:CH, (2, 3)),
        (:SWAP, (1, 3)),
        (:CCX, (1, 2, 3)),
        (:CSWAP, (1, 2, 3)),
        (:CCZ, (1, 2, 3)),
    ]
    @test circuit_unitary(c)' * circuit_unitary(c) ≈ I(8) atol = 1e-12
end

@testitem "from_qasm — parses constant-parameter standard-library gates" tags = [:qasm] begin
    using LinearAlgebra

    qasm = """
    OPENQASM 3;
    include "stdgates.inc";
    const int n = ceiling(1.2);
    const angle theta = 2 * arctan(1);
    const angle phi = log(exp(pi / 4));
    qubit[n] q;
    p(theta) q[0];
    phase(phi) q[0];
    rx(theta) q[0];
    ry(theta) q[0];
    rz(theta) q[0];
    u1(theta) q[0];
    u2(0, pi) q[0];
    u3(pi / 2, 0, pi) q[0];
    U(pi / 2, 0, pi) q[0];
    cp(theta) q[0], q[1];
    cphase(pi / 4) q[0], q[1];
    crx(theta) q[0], q[1];
    cry(theta) q[0], q[1];
    crz(theta) q[0], q[1];
    cu(pi / 2, 0, pi, pi / 4) q[0], q[1];
    gphase(pi / 8);
    """

    c = from_qasm(qasm)
    @test c.n_qubits == 2
    @test length(c.ops) == 16
    @test all(startswith(String(op.gate), "QASM_") for op in c.ops)
    U = circuit_unitary(c)
    @test U' * U ≈ I(4) atol = 1e-10
end

@testitem "from_qasm — expands register broadcasting and qreg declarations" tags = [:qasm] begin
    qasm = """
    OPENQASM 3;
    qreg q[2];
    qubit r[2];
    h q;
    cx q, r;
    """

    c = from_qasm(qasm)
    @test c.n_qubits == 4
    @test [(op.gate, op.qubits) for op in c.ops] == [(:H, (1,)), (:H, (2,)), (:CX, (1, 3)), (:CX, (2, 4))]
end

@testitem "from_qasm — rejects unsupported OpenQASM statements clearly" tags = [:qasm] begin
    @test_throws ArgumentError from_qasm("OPENQASM 3; qubit[1] q; ctrl @ x q[0], q[0];")
    @test_throws ArgumentError from_qasm("OPENQASM 3; qubit[1] q; measure q[0] -> c[0];")
    @test_throws ArgumentError from_qasm("OPENQASM 3; qubit[1] q; reset q[0];")
    @test_throws ArgumentError from_qasm("OPENQASM 3; qubit[1] q; gate custom a { x a; }")
    @test_throws ArgumentError from_qasm("OPENQASM 3; qubit[1] q; for int i in [0:1] { x q[0]; }")
    @test_throws ArgumentError from_qasm("OPENQASM 3; qubit[1] q; delay[10ns] q[0];")
    @test_throws ArgumentError from_qasm("OPENQASM 3; qubit[1] q; h q[1];")
    @test_throws ArgumentError from_qasm("OPENQASM 3; include \"custom.inc\"; qubit[1] q; h q[0];")
    @test_throws ArgumentError from_qasm("OPENQASM 3; qubit[2] q; h q[0:1];")
    @test_throws ArgumentError from_qasm("OPENQASM 3; qubit[1] q; gphase(pi) q[0];")
    @test_throws ArgumentError from_qasm("OPENQASM 3; qubit[1] q; rx(atan(1)) q[0];")
    @test_throws ArgumentError from_qasm("OPENQASM 3; qubit[1] q; rz(ln(1)) q[0];")
end
