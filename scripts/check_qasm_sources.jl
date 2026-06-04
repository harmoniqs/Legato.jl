#!/usr/bin/env julia

using Downloads

# This is a source-table check, not a semantic/unitary equivalence test.
# It downloads the official OpenQASM docs, reads `src/qasm.jl` as text, and
# compares the gate names declared there with the gate names in the sources.
# Matrix definitions and parser behavior are covered by the Julia/Qiskit tests.

const REPO_ROOT = normpath(joinpath(@__DIR__, ".."))
const QASM_SOURCE_PATH = joinpath(REPO_ROOT, "src", "qasm.jl")
const TARGET_OPENQASM_VERSION = VersionNumber(get(ENV, "OPENQASM_VERSION", "3.0"))
const STDGATES_SOURCE_URL = "https://openqasm.com/_sources/language/standard_library.rst.txt"
const GATES_3_SOURCE_URL = "https://openqasm.com/versions/3.0/_sources/language/gates.rst.txt"
const RST_HEADING_MARKERS =
    Set(['=', '-', '~', '`', ':', '\'', '"', '^', '_', '*', '+', '#', '<', '>'])

# Stretto accepts a few compatibility aliases that are useful locally but are
# not official `stdgates.inc` names, so they are excluded from source matching.
const STRETTO_COMPAT_GATE_NAMES = Set(["cnot", "toffoli", "ccz"])

# `U` and `gphase` are documented by OpenQASM, but as language built-ins in the
# gates spec rather than as entries in the `stdgates.inc` standard library. The
# script parses them from `GATES_3_SOURCE_URL`; the only local convention here is
# that `src/qasm.jl` stores the official gate name `U` under the table key `u`.
qasm_parser_table_key(source_name::AbstractString) = source_name == "U" ? "u" : source_name

function fetch_text(url::AbstractString)
    path = Downloads.download(url)
    return read(path, String)
end

function parse_version(text::AbstractString)
    return VersionNumber(strip(text))
end

function parse_stdgate_names(text::AbstractString, target_version::VersionNumber)
    matches = collect(eachmatch(r"\.\.\s+gate::\s+([A-Za-z][A-Za-z0-9_]*)\b", text))
    isempty(matches) && error("No `.. gate::` directives found in $STDGATES_SOURCE_URL")

    names = Set{String}()
    missing_version = String[]
    for (i, m) in enumerate(matches)
        block_start = m.offset
        block_stop = i == length(matches) ? lastindex(text) : prevind(text, matches[i+1].offset)
        block = text[block_start:block_stop]
        name = String(only(m.captures))

        added_match = match(r"\.\.\s+versionadded::\s+([0-9.]+)", block)
        if added_match === nothing
            push!(missing_version, name)
            continue
        end

        added = parse_version(only(added_match.captures))
        removed_match = match(r"\.\.\s+versionremoved::\s+([0-9.]+)", block)
        removed = removed_match === nothing ? nothing : parse_version(only(removed_match.captures))
        if added <= target_version && (removed === nothing || target_version < removed)
            push!(names, name)
        end
    end

    isempty(missing_version) ||
        error("Gate directive(s) without `versionadded`: $(join(sort(missing_version), ", "))")
    return names
end

function is_rst_underline(line::AbstractString)
    stripped = strip(line)
    isempty(stripped) && return false

    marker = first(stripped)
    marker in RST_HEADING_MARKERS || return false
    return length(stripped) >= 3 && all(==(marker), stripped)
end

function rst_heading_level!(marker_order::Vector{Char}, marker::Char)
    index = findfirst(==(marker), marker_order)
    index !== nothing && return index

    push!(marker_order, marker)
    return length(marker_order)
end

function parse_rst_headings(lines::AbstractVector{<:AbstractString})
    headings = NamedTuple{(:title, :line, :level),Tuple{String,Int,Int}}[]
    marker_order = Char[]

    for i = 1:(length(lines)-1)
        title = strip(lines[i])
        isempty(title) && continue

        underline = strip(lines[i+1])
        is_rst_underline(underline) || continue

        marker = first(underline)
        level = rst_heading_level!(marker_order, marker)
        push!(headings, (title = title, line = i, level = level))
    end

    return headings
end

function rst_section_body(text::AbstractString, title::AbstractString, source_url::AbstractString)
    lines = split(String(text), '\n'; keepempty = true)
    headings = parse_rst_headings(lines)
    target_index = findfirst(heading -> heading.title == title, headings)
    target_index !== nothing || error("Could not find RST section `$title` in $source_url")

    target = headings[target_index]
    body_start = target.line + 2
    body_stop = length(lines)
    for heading in headings[(target_index+1):end]
        if heading.level <= target.level
            body_stop = heading.line - 1
            break
        end
    end

    return join(lines[body_start:body_stop], "\n")
end

function parse_builtin_gate_names(text::AbstractString)
    section = rst_section_body(text, "Built-in gates", GATES_3_SOURCE_URL)
    headings = parse_rst_headings(split(section, '\n'; keepempty = true))
    names = Set{String}()
    for heading in headings
        m = match(r"``([A-Za-z][A-Za-z0-9_]*)``", heading.title)
        m === nothing && continue
        push!(names, String(only(m.captures)))
    end
    isempty(names) && error("No gate headings found below `Built-in gates` in $GATES_3_SOURCE_URL")
    return names
end

function extract_string_literals(body::AbstractString)
    return Set(String(only(match.captures)) for match in eachmatch(r"\"([^\"]+)\"", body))
end

# Extract string keys from simple `const NAME = Dict{...}(... )` declarations.
# The script scans source text on purpose: it checks the parser tables directly
# without loading Stretto or relying on runtime state such as generated gates.
function extract_dict_keys(text::AbstractString, name::AbstractString)
    pattern = Regex("(?s)const\\s+$name\\s*=\\s*Dict\\{[^}]+\\}\\((.*?)\\n\\)")
    m = match(pattern, text)
    m === nothing && error("Could not find constant `$name` in $QASM_SOURCE_PATH")
    return extract_string_literals(only(m.captures))
end

function extract_set_items(text::AbstractString, name::AbstractString)
    pattern = Regex("(?s)const\\s+$name\\s*=\\s*Set\\(\\[(.*?)\\]\\)")
    m = match(pattern, text)
    m === nothing && error("Could not find constant `$name` in $QASM_SOURCE_PATH")
    return extract_string_literals(only(m.captures))
end

function implemented_stdgate_names(qasm_text::AbstractString, source_builtins::Set{String})
    implemented = union(
        extract_dict_keys(qasm_text, "QASM_FIXED_GATE_ALIASES"),
        extract_dict_keys(qasm_text, "QASM_PARAMETERIZED_GATE_QUBIT_COUNTS"),
    )
    setdiff!(implemented, STRETTO_COMPAT_GATE_NAMES)
    setdiff!(implemented, qasm_parser_table_key.(source_builtins))
    return implemented
end

function implemented_builtin_gate_names(qasm_text::AbstractString, source_builtins::Set{String})
    names = Set{String}()
    parameterized = extract_dict_keys(qasm_text, "QASM_PARAMETERIZED_GATE_QUBIT_COUNTS")
    for source_name in source_builtins
        table_key = qasm_parser_table_key(source_name)
        table_key in parameterized && push!(names, source_name)
    end
    return names
end

function implemented_parameterized_gate_names(qasm_text::AbstractString)
    return extract_dict_keys(qasm_text, "QASM_PARAMETERIZED_GATE_QUBIT_COUNTS")
end

function format_names(names)
    isempty(names) && return "(none)"
    return join(sort(collect(names)), ", ")
end

function check_exact(label::AbstractString, expected::Set{String}, actual::Set{String})
    missing = setdiff(expected, actual)
    extra = setdiff(actual, expected)
    isempty(missing) && isempty(extra) && return true

    println("Mismatch: $label")
    println("  Missing from Stretto: ", format_names(missing))
    println("  Extra in Stretto:     ", format_names(extra))
    return false
end

function main()
    println("Fetching OpenQASM source files...")
    stdgates_text = fetch_text(STDGATES_SOURCE_URL)
    gates_text = fetch_text(GATES_3_SOURCE_URL)
    qasm_text = read(QASM_SOURCE_PATH, String)

    source_stdgates = parse_stdgate_names(stdgates_text, TARGET_OPENQASM_VERSION)
    source_builtins = parse_builtin_gate_names(gates_text)

    declared_stdgates = extract_set_items(qasm_text, "QASM_STDGATES_3_GATE_NAMES")
    declared_builtins = extract_set_items(qasm_text, "QASM_BUILTIN_GATE_NAMES")
    implemented_stdgates = implemented_stdgate_names(qasm_text, source_builtins)
    implemented_builtins = implemented_builtin_gate_names(qasm_text, source_builtins)
    parameterized_names = implemented_parameterized_gate_names(qasm_text)
    parameter_count_names = extract_dict_keys(qasm_text, "QASM_PARAMETERIZED_GATE_PARAMETER_COUNTS")
    parameter_builder_names = extract_dict_keys(qasm_text, "QASM_PARAMETERIZED_GATE_BUILDERS")

    checks = Bool[
        check_exact(
            "QASM_STDGATES_3_GATE_NAMES vs OpenQASM stdgates source",
            source_stdgates,
            declared_stdgates,
        ),
        check_exact(
            "parser stdgate tables vs OpenQASM stdgates source",
            source_stdgates,
            implemented_stdgates,
        ),
        check_exact(
            "QASM_BUILTIN_GATE_NAMES vs OpenQASM gates source",
            source_builtins,
            declared_builtins,
        ),
        check_exact(
            "parser built-in table entries vs OpenQASM gates source",
            source_builtins,
            implemented_builtins,
        ),
        check_exact(
            "parameter-count table vs parameterized gate qubit table",
            parameterized_names,
            parameter_count_names,
        ),
        check_exact(
            "matrix-builder table vs parameterized gate qubit table",
            parameterized_names,
            parameter_builder_names,
        ),
    ]

    if all(checks)
        println("OpenQASM source check passed.")
        println("  Target OpenQASM version: ", TARGET_OPENQASM_VERSION)
        println("  stdgates.inc gates:      ", format_names(source_stdgates))
        println("  built-in gates:          ", format_names(source_builtins))
        println("  Stretto aliases allowed: ", format_names(STRETTO_COMPAT_GATE_NAMES))
        return 0
    end

    println()
    println("OpenQASM source check failed.")
    println("Sources:")
    println("  ", STDGATES_SOURCE_URL)
    println("  ", GATES_3_SOURCE_URL)
    return 1
end

exit(main())
