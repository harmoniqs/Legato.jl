# ============================================================================ #
# OpenQASM 3 source-anchored gate tables and Quasar lowering
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
# Quasar handles OpenQASM parsing and static AST evaluation. Stretto owns the
# final lowering step into GateCircuit, so syntax that cannot become a static
# unitary still fails here with ArgumentError.
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

const QASM_INCLUDE_RE = r"(?i)\binclude\s+\"([^\"]+)\"\s*;"
const QASM_STDGATES_INCLUDE_RE = r"(?i)\binclude\s+\"stdgates\.inc\"\s*;"
const QASM_QREG_DECL_RE = r"(?m)\bqreg\s+([A-Za-z_]\w*)\s*\[\s*([^]]+)\s*\]\s*;"
const QASM_CREG_DECL_RE = r"(?m)\bcreg\s+([A-Za-z_]\w*)\s*\[\s*([^]]+)\s*\]\s*;"
const QASM_SUFFIX_QUBIT_DECL_RE = r"(?m)\bqubit\s+([A-Za-z_]\w*)\s*\[\s*([^]]+)\s*\]\s*;"
const QASM_GPHASE_WITH_OPERANDS_RE = r"(?m)\bgphase\s*\([^;]*\)\s+[^;\s]"
const QASM_VERSION_RE = r"(?im)^\s*OPENQASM\s+([0-9]+(?:\.[0-9]+)?)\s*;"
const QASM_NOP_RE = r"(?im)(^|[;{}])\s*nop\s*;"
const QASM_BARRIER_RE = r"(?im)(^|[;{}])\s*barrier\b[^;]*;"
const QASM_NON_UNITARY_RE = r"(?im)(^|[;{}])\s*(?:measure|reset)\b"
const QASM_DELAY_RE = r"(?im)(^|[;{}])\s*delay\b"
const QASM_BOX_RE = r"(?im)(^|[;{}])\s*box\b"
const QASM_CALIBRATION_RE = r"(?im)(^|[;{}])\s*(?:defcalgrammar|defcal|cal)\b"

const QASM_UNSUPPORTED_SOURCE_PATTERNS = (
    (QASM_GPHASE_WITH_OPERANDS_RE, "OpenQASM `gphase` does not accept qubit operands"),
    (QASM_NON_UNITARY_RE, "Non-unitary OpenQASM statements are not supported"),
    (QASM_DELAY_RE, "OpenQASM timing statements are not supported"),
    (QASM_BOX_RE, "OpenQASM box/timing constructs are not supported"),
    (QASM_CALIBRATION_RE, "OpenQASM calibration/OpenPulse constructs are not supported"),
)

# OpenQASM spells the built-in universal gate `U`; table keys use lowercase names.
_qasm_gate_key(gate_name::AbstractString) = gate_name == "U" ? "u" : String(gate_name)

# ============================================================================ #
# Public API
# ============================================================================ #

"""
    from_qasm(qasm::String) -> GateCircuit

Parse OpenQASM 3 into a [`GateCircuit`](@ref). Quasar.jl parses and statically
evaluates the program; Stretto lowers the resulting unitary instructions into
`GateOp`s. Supported input includes qubit and `qreg` declarations,
`stdgates.inc`, fixed and constant-parameter standard-library gates, `U`,
`gphase`, register broadcasting and ranges, custom gate definitions, static
loops and conditionals, barriers/no-ops, and gate modifiers that resolve to a
finite unitary matrix. QASM qubit references are converted from 0-based indices
to Stretto's 1-based indices.

OpenQASM 3 features without a `GateCircuit` equivalent -- measurements,
resets, dynamic classical behavior, calibration/OpenPulse blocks, timing/box
constructs, arbitrary include files, and non-integer gate powers -- throw
`ArgumentError`.
"""
function from_qasm(qasm::String)
    try
        source = _qasm_source_for_quasar(qasm)
        visitor = Quasar.QasmProgramVisitor()
        merge!(visitor.gate_defs, _qasm_quasar_gate_definitions())
        visitor(Quasar.parse_qasm(source))

        n_qubits = visitor.qubit_count
        n_qubits > 0 || throw(ArgumentError("No qubit declarations found in OpenQASM input"))

        ops = GateOp[]
        for instruction in visitor.instructions
            append!(ops, _lower_qasm_instruction(instruction, n_qubits))
        end
        return GateCircuit(ops, n_qubits)
    catch err
        err isa ArgumentError && rethrow()
        err isa Quasar.QasmParseError &&
            throw(ArgumentError("Invalid OpenQASM input: $(sprint(showerror, err))"))
        err isa Quasar.QasmVisitorError &&
            throw(ArgumentError("Unsupported OpenQASM input: $(sprint(showerror, err))"))
        rethrow()
    end
end

# ============================================================================ #
# Quasar integration helpers
# ============================================================================ #

function _qasm_source_for_quasar(qasm::String)
    _qasm_require_openqasm3(qasm)
    _qasm_reject_unsupported_source(qasm)

    # Quasar receives built-in gate definitions below, so the standard include
    # can be removed after recognizing it as an allowed source dependency.
    source = replace(qasm, QASM_STDGATES_INCLUDE_RE => "")

    # `GateCircuit` has no representation for visual separators or explicit
    # no-ops; they do not affect the unitary imported from the program.
    source = replace(source, QASM_NOP_RE => s"\1")
    source = replace(source, QASM_BARRIER_RE => s"\1")
    _qasm_reject_remaining_includes(source)

    # Normalize legacy/OpenQASM-2 style declarations and suffix-style qubit
    # declarations to the declaration form consumed by Quasar.
    source = replace(source, QASM_QREG_DECL_RE => s"qubit[\2] \1;")
    source = replace(source, QASM_CREG_DECL_RE => s"bit[\2] \1;")
    source = replace(source, QASM_SUFFIX_QUBIT_DECL_RE => s"qubit[\2] \1;")
    return source
end

function _qasm_reject_unsupported_source(qasm::AbstractString)
    for (pattern, message) in QASM_UNSUPPORTED_SOURCE_PATTERNS
        occursin(pattern, qasm) && throw(ArgumentError(message))
    end
    return nothing
end

function _qasm_reject_remaining_includes(source::AbstractString)
    for m in eachmatch(QASM_INCLUDE_RE, source)
        include_name = only(m.captures)
        throw(
            ArgumentError(
                "Unsupported OpenQASM include `$include_name`; only `stdgates.inc` is understood",
            ),
        )
    end
    return nothing
end

function _qasm_require_openqasm3(qasm::AbstractString)
    m = match(QASM_VERSION_RE, qasm)
    m === nothing && return nothing

    version = VersionNumber(only(m.captures))
    version.major == 3 ||
        throw(ArgumentError("Only OpenQASM 3 input is supported, got `OPENQASM $version`"))
    return nothing
end

function _qasm_quasar_gate_definitions()
    definitions = Dict{String,Quasar.AbstractGateDefinition}()

    # These lightweight definitions let Quasar expand broadcasting, ranges,
    # custom gates, and modifiers while preserving the gate call names for the
    # final Stretto-specific matrix lowering below.
    for (gate_name, gate) in QASM_FIXED_GATE_ALIASES
        definitions[gate_name] =
            _qasm_quasar_builtin_gate(gate_name, String[], QASM_FIXED_GATE_QUBIT_COUNTS[gate])
    end

    for (gate_name, n_qubits) in QASM_PARAMETERIZED_GATE_QUBIT_COUNTS
        gate_name == "gphase" && continue
        parameter_count = QASM_PARAMETERIZED_GATE_PARAMETER_COUNTS[gate_name]
        parameters = ["p$i" for i = 1:parameter_count]
        definitions[gate_name] = _qasm_quasar_builtin_gate(gate_name, parameters, n_qubits)
    end

    definitions["U"] = _qasm_quasar_builtin_gate("U", ["p1", "p2", "p3"], 1)
    return definitions
end

function _qasm_quasar_builtin_gate(
    gate_name::AbstractString,
    parameters::Vector{String},
    n_qubits::Int,
)
    targets = ["q$i" for i = 1:n_qubits]
    arguments = Quasar.InstructionArgument[Symbol(parameter) for parameter in parameters]
    body = (
        type = String(gate_name),
        arguments = arguments,
        targets = collect(0:(n_qubits-1)),
        controls = Pair{Int,Int}[],
        exponent = 1.0,
    )
    return Quasar.BuiltinGateDefinition(String(gate_name), parameters, targets, body)
end

function _lower_qasm_instruction(instruction, n_qubits::Int)
    instruction.type == "barrier" && return GateOp[]

    if instruction.type in ("measure", "reset")
        throw(
            ArgumentError(
                "Non-unitary OpenQASM statements are not supported: `$(instruction.type)`",
            ),
        )
    elseif instruction.type == "delay"
        throw(ArgumentError("OpenQASM timing statements are not supported"))
    end

    op_qubits = _qasm_instruction_qubits(instruction)
    _qasm_validate_qubits(instruction.type, op_qubits, n_qubits)
    gate = _qasm_instruction_gate(instruction, op_qubits)
    return GateOp[GateOp(gate, Tuple(q + 1 for q in op_qubits))]
end

function _qasm_instruction_qubits(instruction)
    targets = Int.(instruction.targets)
    length(unique(targets)) == length(targets) ||
        throw(ArgumentError("OpenQASM gate `$(instruction.type)` uses duplicate qubits"))

    qubits = copy(targets)
    for control in instruction.controls
        control.first in qubits || pushfirst!(qubits, control.first)
    end
    return qubits
end

function _qasm_validate_qubits(gate_name::AbstractString, qubits::Vector{Int}, n_qubits::Int)
    isempty(qubits) && throw(ArgumentError("OpenQASM gate `$gate_name` has no qubit context"))
    all(q -> 0 <= q < n_qubits, qubits) ||
        throw(ArgumentError("OpenQASM gate `$gate_name` references an out-of-range qubit"))
    return nothing
end

function _qasm_instruction_gate(instruction, op_qubits::Vector{Int})
    controls = _qasm_instruction_controls(instruction)
    base_qubits = _qasm_base_qubits(instruction, controls)

    # Prefer Stretto's built-in symbols whenever the instruction is exactly a
    # supported fixed gate. Modified or parameterized gates are stored as
    # generated matrices in EXTRA_GATES.
    fixed_gate = get(QASM_FIXED_GATE_ALIASES, instruction.type, nothing)
    if _qasm_can_use_fixed_gate_symbol(instruction, fixed_gate, controls)
        _qasm_check_qubit_count(
            instruction.type,
            length(base_qubits),
            QASM_FIXED_GATE_QUBIT_COUNTS[fixed_gate],
        )
        return fixed_gate
    end

    gate_name, matrix = _qasm_instruction_matrix(instruction, length(base_qubits))
    matrix = _qasm_apply_exponent(matrix, instruction.exponent, instruction.type)
    if !isempty(controls)
        matrix = _qasm_apply_controls(
            matrix,
            _qasm_local_positions(base_qubits, op_qubits),
            length(op_qubits),
            _qasm_local_controls(controls, op_qubits),
        )
    end

    return _register_qasm_generated_gate(
        gate_name,
        _qasm_generated_gate_signature(instruction, controls, op_qubits),
        matrix,
    )
end

function _qasm_instruction_controls(instruction)
    return Pair{Int,Int}[control.first => control.second for control in instruction.controls]
end

function _qasm_base_qubits(instruction, controls::Vector{Pair{Int,Int}})
    control_qubits = first.(controls)
    return [q for q in Int.(instruction.targets) if q ∉ control_qubits]
end

function _qasm_can_use_fixed_gate_symbol(instruction, fixed_gate, controls::Vector{Pair{Int,Int}})
    return fixed_gate !== nothing &&
           isempty(instruction.arguments) &&
           isempty(controls) &&
           isapprox(instruction.exponent, 1.0; atol = 1e-12)
end

function _qasm_local_positions(qubits::Vector{Int}, op_qubits::Vector{Int})
    return [_qasm_local_position(q, op_qubits) for q in qubits]
end

function _qasm_local_controls(controls::Vector{Pair{Int,Int}}, op_qubits::Vector{Int})
    return [
        _qasm_local_position(control.first, op_qubits) => control.second for control in controls
    ]
end

function _qasm_generated_gate_signature(
    instruction,
    controls::Vector{Pair{Int,Int}},
    op_qubits::Vector{Int},
)
    return (
        arguments = _qasm_signature_arguments(instruction),
        controls = sort(collect(controls); by = first),
        exponent = round(Float64(instruction.exponent); digits = 14),
        qubits = op_qubits,
    )
end

function _qasm_signature_arguments(instruction)
    return round.(Float64.([arg for arg in instruction.arguments if arg isa Real]); digits = 14)
end

function _qasm_instruction_matrix(instruction, base_qubit_count::Int)
    fixed_gate = get(QASM_FIXED_GATE_ALIASES, instruction.type, nothing)
    if fixed_gate !== nothing
        _qasm_check_qubit_count(
            instruction.type,
            base_qubit_count,
            QASM_FIXED_GATE_QUBIT_COUNTS[fixed_gate],
        )
        isempty(instruction.arguments) ||
            throw(ArgumentError("OpenQASM gate `$(instruction.type)` does not accept parameters"))
        return String(instruction.type), resolve_gate(fixed_gate)
    end

    gate_name = _qasm_gate_key(instruction.type)
    haskey(QASM_PARAMETERIZED_GATE_QUBIT_COUNTS, gate_name) ||
        throw(ArgumentError("Unsupported OpenQASM gate `$(instruction.type)`"))

    if gate_name != "gphase"
        expected = QASM_PARAMETERIZED_GATE_QUBIT_COUNTS[gate_name]
        _qasm_check_qubit_count(instruction.type, base_qubit_count, expected)
    end

    parameters = _qasm_instruction_parameters(instruction)
    matrix = _qasm_parameterized_gate_matrix(gate_name, parameters, max(base_qubit_count, 1))
    return gate_name, matrix
end

function _qasm_instruction_parameters(instruction)
    parameters = Float64[]
    for argument in instruction.arguments
        argument isa Real || throw(
            ArgumentError(
                "OpenQASM gate `$(instruction.type)` has non-numeric parameter `$argument`",
            ),
        )
        push!(parameters, Float64(argument))
    end
    return parameters
end

function _qasm_check_qubit_count(gate_name::AbstractString, actual::Int, expected::Int)
    actual == expected || throw(
        ArgumentError("OpenQASM gate `$gate_name` expects $expected qubit operand(s), got $actual"),
    )
end

function _qasm_local_position(qubit::Int, op_qubits::Vector{Int})
    position = findfirst(==(qubit), op_qubits)
    position === nothing && throw(ArgumentError("Internal OpenQASM lowering error"))
    return position
end

function _qasm_apply_exponent(matrix::AbstractMatrix, exponent::Real, gate_name::AbstractString)
    isapprox(exponent, 1.0; atol = 1e-12) && return Matrix{ComplexF64}(matrix)
    isapprox(exponent, round(exponent); atol = 1e-12) || throw(
        ArgumentError(
            "OpenQASM gate modifiers with non-integer exponent `$exponent` are not supported for `$gate_name`",
        ),
    )
    return Matrix{ComplexF64}(matrix) ^ Int(round(exponent))
end

function _qasm_apply_controls(
    matrix::AbstractMatrix,
    target_positions::Vector{Int},
    n_qubits::Int,
    control_positions::Vector{Pair{Int,Int}},
)
    isempty(target_positions) &&
        throw(ArgumentError("Controlled OpenQASM gates require at least one target qubit"))
    all(control -> control.second in (0, 1), control_positions) ||
        throw(ArgumentError("OpenQASM controls must target classical bit values 0 or 1"))

    D = 2^n_qubits
    controlled = zeros(ComplexF64, D, D)
    for col = 0:(D-1)
        # Each matrix column is one input computational-basis state.
        bits = _qasm_basis_bits(col, n_qubits)
        if all(bits[control.first] == control.second for control in control_positions)
            # Controls matched, so project the full basis state onto the target
            # qubits and look up how the unmodified gate transforms them.
            gate_bits = [bits[position] for position in target_positions]
            gate_index = _qasm_bits_to_index(gate_bits)
            for out_gate_index = 0:(2^length(target_positions)-1)
                amplitude = matrix[out_gate_index+1, gate_index+1]
                iszero(amplitude) && continue
                # Reinsert the transformed target bits into the full basis
                # state while leaving controls and untouched qubits fixed.
                out_bits = copy(bits)
                out_gate_bits = _qasm_basis_bits(out_gate_index, length(target_positions))
                for (k, position) in enumerate(target_positions)
                    out_bits[position] = out_gate_bits[k]
                end
                out_col = _qasm_bits_to_index(out_bits)
                controlled[out_col+1, col+1] += amplitude
            end
        else
            # Controls did not match, so this basis state passes through unchanged.
            controlled[col+1, col+1] = 1
        end
    end
    return controlled
end

_qasm_basis_bits(index::Int, n_bits::Int) = reverse(digits(index; base = 2, pad = n_bits))

function _qasm_bits_to_index(bits::AbstractVector{<:Integer})
    n_bits = length(bits)
    return sum(bits[k] * 2^(n_bits - k) for k = 1:n_bits)
end

function _register_qasm_generated_gate(gate_name::AbstractString, signature, matrix::AbstractMatrix)
    # Generated gates cover parameterized gates, custom definitions, and gate
    # modifiers. The signature keeps distinct matrices from sharing a symbol.
    key = Symbol("QASM_", uppercase(gate_name), "_", hash((gate_name, signature, size(matrix))))
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

function _qasm_phase_matrix(lambda)
    return _qasm_matrix([
        1 0
        0 exp(im * lambda)
    ])
end

function _qasm_rx_matrix(theta)
    return _qasm_matrix([
        cos(theta / 2) -im * sin(theta / 2)
        -im * sin(theta / 2) cos(theta / 2)
    ])
end

function _qasm_ry_matrix(theta)
    return _qasm_matrix([
        cos(theta / 2) -sin(theta / 2)
        sin(theta / 2) cos(theta / 2)
    ])
end

function _qasm_rz_matrix(theta)
    return _qasm_matrix([
        exp(-im * theta / 2) 0
        0 exp(im * theta / 2)
    ])
end

function _qasm_builtin_u_matrix(theta, phi, lambda)
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

function _qasm_u3_matrix(theta, phi, lambda)
    return exp(-im * (theta + phi + lambda) / 2) * _qasm_builtin_u_matrix(theta, phi, lambda)
end

function _qasm_one_parameter_gate(matrix_builder)
    return (parameters, _n_qubits) -> matrix_builder(parameters[1])
end

function _qasm_controlled_one_parameter_gate(matrix_builder)
    return (parameters, _n_qubits) -> _qasm_controlled(matrix_builder(parameters[1]))
end

function _qasm_u2_gate(parameters, _n_qubits)
    return _qasm_u3_matrix(π / 2, parameters[1], parameters[2])
end

function _qasm_controlled_u_gate(parameters, _n_qubits)
    return _qasm_controlled(
        exp(im * parameters[4]) *
        _qasm_builtin_u_matrix(parameters[1], parameters[2], parameters[3]),
    )
end

function _qasm_global_phase_gate(parameters, n_qubits)
    return _qasm_global_phase(parameters[1], n_qubits)
end

function _qasm_u_gate(parameters, _n_qubits)
    return _qasm_builtin_u_matrix(parameters[1], parameters[2], parameters[3])
end

function _qasm_u3_gate(parameters, _n_qubits)
    return _qasm_u3_matrix(parameters[1], parameters[2], parameters[3])
end

const QASM_PARAMETERIZED_GATE_BUILDERS = Dict{String,Function}(
    # Builder functions receive already-evaluated numeric parameters and the
    # qubit count used by global-phase matrices.
    "p" => _qasm_one_parameter_gate(_qasm_phase_matrix),
    "phase" => _qasm_one_parameter_gate(_qasm_phase_matrix),
    "rx" => _qasm_one_parameter_gate(_qasm_rx_matrix),
    "ry" => _qasm_one_parameter_gate(_qasm_ry_matrix),
    "rz" => _qasm_one_parameter_gate(_qasm_rz_matrix),
    "u1" => _qasm_one_parameter_gate(_qasm_phase_matrix),
    "u2" => _qasm_u2_gate,
    "u3" => _qasm_u3_gate,
    "u" => _qasm_u_gate,
    "gphase" => _qasm_global_phase_gate,
    "cp" => _qasm_controlled_one_parameter_gate(_qasm_phase_matrix),
    "cphase" => _qasm_controlled_one_parameter_gate(_qasm_phase_matrix),
    "crx" => _qasm_controlled_one_parameter_gate(_qasm_rx_matrix),
    "cry" => _qasm_controlled_one_parameter_gate(_qasm_ry_matrix),
    "crz" => _qasm_controlled_one_parameter_gate(_qasm_rz_matrix),
    "cu" => _qasm_controlled_u_gate,
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
    controlled = Matrix{ComplexF64}(I, 2n, 2n)
    controlled[(n+1):(2n), (n+1):(2n)] .= gate
    return controlled
end

function _qasm_global_phase(gamma, n_qubits::Int)
    n_qubits > 0 || throw(ArgumentError("`gphase` requires declared qubits"))
    return exp(im * gamma) * Matrix{ComplexF64}(I, 2^n_qubits, 2^n_qubits)
end

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
    const int n = int(ceiling(1.2));
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

@testitem "from_qasm — supports static Quasar-expanded OpenQASM structure" tags = [:qasm] begin
    using LinearAlgebra

    qasm = """
    OPENQASM 3;
    qubit[2] q;

    gate x_alias a {
        x a;
    }

    gate custom_cx c, t {
        ctrl @ x_alias c, t;
    }

    for int i in [0:1] {
        h q[i];
    }

    z q[0:1];
    inv @ s q[0];
    custom_cx q[0], q[1];
    """

    c = from_qasm(qasm)
    @test c.n_qubits == 2
    @test [(op.gate, op.qubits) for op in c.ops[1:4]] == [(:H, (1,)), (:H, (2,)), (:Z, (1,)), (:Z, (2,))]
    @test c.ops[5].qubits == (1,)
    @test startswith(String(c.ops[5].gate), "QASM_S_")
    @test c.ops[6].qubits == (1, 2)
    @test startswith(String(c.ops[6].gate), "QASM_X_")

    generated_sdg = GateCircuit([c.ops[5]], 1)
    expected_sdg = GateCircuit([GateOp(:SDG, (1,))], 1)
    @test circuit_unitary(generated_sdg) ≈ circuit_unitary(expected_sdg) atol = 1e-12

    generated_cx = GateCircuit([c.ops[6]], 2)
    expected_cx = GateCircuit([GateOp(:CX, (1, 2))], 2)
    @test circuit_unitary(generated_cx) ≈ circuit_unitary(expected_cx) atol = 1e-12

    U = circuit_unitary(c)
    @test U' * U ≈ I(4) atol = 1e-12
end

@testitem "from_qasm — rejects unsupported OpenQASM statements clearly" tags = [:qasm] begin
    @test_throws ArgumentError from_qasm("OPENQASM 3; qubit[1] q; ctrl @ x q[0], q[0];")
    @test_throws ArgumentError from_qasm("OPENQASM 3; qubit[1] q; measure q[0] -> c[0];")
    @test_throws ArgumentError from_qasm("OPENQASM 3; qubit[1] q; reset q[0];")
    @test_throws ArgumentError from_qasm("OPENQASM 3; qubit[1] q; delay[10ns] q[0];")
    @test_throws ArgumentError from_qasm("OPENQASM 3; qubit[1] q; box { h q[0]; }")
    @test_throws ArgumentError from_qasm("OPENQASM 3; defcalgrammar \"openpulse\"; qubit[1] q;")
    @test_throws ArgumentError from_qasm("OPENQASM 3; qubit[1] q; h q[1];")
    @test_throws ArgumentError from_qasm("OPENQASM 2.0; qreg q[1]; h q[0];")
    @test_throws ArgumentError from_qasm("OPENQASM 3; include \"custom.inc\"; qubit[1] q; h q[0];")
    @test_throws ArgumentError from_qasm("OPENQASM 3; qubit[1] q; gphase(pi) q[0];")
    @test_throws ArgumentError from_qasm("OPENQASM 3; qubit[1] q; pow(0.5) @ x q[0];")
    @test_throws ArgumentError from_qasm("OPENQASM 3; qubit[1] q; rx(atan(1)) q[0];")
    @test_throws ArgumentError from_qasm("OPENQASM 3; qubit[1] q; rz(ln(1)) q[0];")
end
