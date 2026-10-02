# The canonical pulse catalog format (schema v3). Flat TOML keys per entry;
# a strict superset of the private tier's v2 — every pre-existing entry reads.
using Dates

"""
    CatalogSchemaError(field, reason)

Named validation failure for a catalog entry's metadata. `field` is the offending
flat TOML key; `reason` states what is wrong. Thrown by `read_entry` and
`write_entry` — never a bare `KeyError` or a stringly-typed complaint.
"""
struct CatalogSchemaError <: Exception
    field::String
    reason::String
end

function Base.showerror(io::IO, err::CatalogSchemaError)
    return print(io, "CatalogSchemaError: field '", err.field, "': ", err.reason)
end

"""
    VerificationRecord(rollout_fidelity, verifier, date)

The structural verification record of a catalog entry. `rollout_fidelity` is an
**independently re-rolled** fidelity — never the optimizer's claimed number.
An entry without a verification record is unverified, full stop; the optimizer
fidelity (`CatalogEntry.fidelity`) may be recorded for any entry but is never
presentable as verified.
"""
struct VerificationRecord
    rollout_fidelity::Float64
    verifier::String
    date::String
end

"""
    CatalogEntry

One entry of the canonical pulse catalog (schema v3) — the public format every
tier (bundled, curated) and every consumer (the private companion tier, the CLI,
the compiler's warm-start chain) reads and writes.

Fields group as:

- **Identity**: `id`, `platform`, `gate`, `version` (append-only: a new result
  supersedes by incrementing `version`, never overwrites).
- **Tier**: `tier` — `"bundled"` (public, in-repo) or `"curated"` (private bank);
  `nothing` means unset (a v2-era entry not yet migrated).
- **Device**: `device_id`, `subsystem`, `levels` (all optional; `subsystem` and
  `levels` must have equal length when both present).
- **Integrity**: `system_hash` — `sha256:`-prefixed digest over the device
  parameters the pulse was solved against; `nothing` for analytic seeds.
- **Pulse shape**: `pulse_type`, `N_knots`, `free_phase`, `duration_us`.
- **Fidelity**: `fidelity` (optimizer-claimed, recorded but never verified) and
  `verification` (the `VerificationRecord`, or `nothing`).
- **Lineage**: `warm_start` (the id of the entry this one was seeded from —
  not free text), `source_script`, `git_commit`, `date`.
- **Tags** and `path` (the entry's pulse binary path relative to its catalog
  root).

Reading a v2-era entry (no `tier`, no verification keys) succeeds and fills the
new fields with the documented defaults: `tier = nothing`, `verification = nothing`.
"""
struct CatalogEntry
    id::String
    platform::String
    gate::String
    version::Int
    tier::Union{String,Nothing}
    device_id::Union{String,Nothing}
    subsystem::Union{Vector{Int},Nothing}
    levels::Union{Vector{Int},Nothing}
    system_hash::Union{String,Nothing}
    pulse_type::String
    N_knots::Int
    free_phase::Bool
    duration_us::Float64
    fidelity::Float64
    verification::Union{VerificationRecord,Nothing}
    warm_start::Union{String,Nothing}
    source_script::Union{String,Nothing}
    git_commit::Union{String,Nothing}
    date::String
    tags::Vector{String}
    path::String
end

# Field-wise equality: the default `==` falls back to `===`, which compares
# the Vector fields by reference — two entries with identical metadata would
# compare unequal after a round-trip through disk.
function Base.:(==)(a::CatalogEntry, b::CatalogEntry)
    return all(getfield(a, k) == getfield(b, k) for k in fieldnames(CatalogEntry))
end

function Base.hash(a::CatalogEntry, h::UInt)
    return hash(ntuple(i -> getfield(a, i), fieldcount(CatalogEntry)), h)
end

# ============================================================================
# TOML coercion (flat keys; tolerant of TOML's native date/int literals)
# ============================================================================ #

_string(x::AbstractString) = String(x)
_string(x::Dates.Date) = string(x)
_string(x::Dates.DateTime) = string(x)

function _require(d, key)
    haskey(d, key) || throw(CatalogSchemaError(key, "required field missing"))
    return d[key]
end

function _string_field(d, key)
    v = _require(d, key)
    v isa Union{AbstractString,Dates.Date,Dates.DateTime} ||
        throw(CatalogSchemaError(key, "must be a string"))
    return _string(v)
end

function _int_field(d, key)
    v = _require(d, key)
    v isa Integer || throw(CatalogSchemaError(key, "must be an integer"))
    return Int(v)
end

function _float_field(d, key)
    v = _require(d, key)
    v isa Real || throw(CatalogSchemaError(key, "must be a number"))
    return Float64(v)
end

function _bool_field(d, key)
    v = _require(d, key)
    v isa Bool || throw(CatalogSchemaError(key, "must be a boolean"))
    return v
end

function _optional_string(d, key)
    haskey(d, key) || return nothing
    d[key] isa Union{AbstractString,Dates.Date,Dates.DateTime} ||
        throw(CatalogSchemaError(key, "must be a string"))
    return _string(d[key])
end

function _optional_intvec(d, key)
    haskey(d, key) || return nothing
    v = d[key]
    (v isa AbstractVector && all(x -> x isa Integer, v)) ||
        throw(CatalogSchemaError(key, "must be an array of integers"))
    return Int[v...]
end

function _optional_stringvec(d, key)
    haskey(d, key) || return nothing
    v = d[key]
    (v isa AbstractVector && all(x -> x isa AbstractString, v)) ||
        throw(CatalogSchemaError(key, "must be an array of strings"))
    return String[v...]
end

# ============================================================================
# Validation
# ============================================================================ #

"""
    validate_entry(entry)

Validate a `CatalogEntry` against the v3 invariants, throwing
`CatalogSchemaError` with the offending field named. Called by `read_entry` and
`write_entry`; public so curation tooling can pre-validate.
"""
function validate_entry(entry::CatalogEntry)
    for key in (:id, :platform, :gate)
        getfield(entry, key) |> isempty &&
            throw(CatalogSchemaError(String(key), "must be non-empty"))
    end
    entry.version >= 1 || throw(CatalogSchemaError("version", "must be ≥ 1"))
    entry.N_knots >= 2 || throw(CatalogSchemaError("N_knots", "must be ≥ 2"))
    0 <= entry.fidelity <= 1 || throw(CatalogSchemaError("fidelity", "must lie in [0, 1]"))
    if entry.verification !== nothing
        0 <= entry.verification.rollout_fidelity <= 1 ||
            throw(CatalogSchemaError("rollout_fidelity", "must lie in [0, 1]"))
    end
    if entry.subsystem !== nothing && entry.levels !== nothing
        length(entry.subsystem) == length(entry.levels) ||
            throw(CatalogSchemaError("levels", "must have the same length as subsystem"))
    end
    if entry.system_hash !== nothing
        startswith(entry.system_hash, "sha256:") ||
            throw(CatalogSchemaError("system_hash", "must be sha256:-prefixed"))
    end
    if entry.tier !== nothing
        entry.tier in ("bundled", "curated") ||
            throw(CatalogSchemaError("tier", "must be \"bundled\" or \"curated\""))
    end
    if entry.warm_start !== nothing
        (isempty(entry.warm_start) || occursin(r"\s", entry.warm_start)) &&
            throw(CatalogSchemaError("warm_start", "must be a catalog entry id"))
    end
    return entry
end

# ============================================================================
# Read / write
# ============================================================================ #

"""
    read_entry(dir_or_metadata_path)

Read one catalog entry: given the entry directory (reads `metadata.toml` inside)
or the metadata file path directly. Validates on read — malformed metadata
throws `CatalogSchemaError` naming the offending field. v2-era entries (no
`tier`, no verification keys) read with documented defaults: tier unset,
verification `nothing` (unverified).
"""
function read_entry(path::AbstractString)
    metadata_path = isdir(path) ? joinpath(path, "metadata.toml") : String(path)
    d = TOML.parsefile(metadata_path)
    verification = if haskey(d, "rollout_fidelity")
        haskey(d, "verifier") && haskey(d, "verified_date") || throw(
            CatalogSchemaError(
                "verification",
                "rollout_fidelity requires verifier and verified_date",
            ),
        )
        VerificationRecord(
            _float_field(d, "rollout_fidelity"),
            _string_field(d, "verifier"),
            _string_field(d, "verified_date"),
        )
    else
        nothing
    end
    tags = _optional_stringvec(d, "tags")
    entry = CatalogEntry(
        _string_field(d, "id"),
        _string_field(d, "platform"),
        _string_field(d, "gate"),
        _int_field(d, "version"),
        _optional_string(d, "tier"),
        _optional_string(d, "device_id"),
        _optional_intvec(d, "subsystem"),
        _optional_intvec(d, "levels"),
        _optional_string(d, "system_hash"),
        _string_field(d, "pulse_type"),
        _int_field(d, "N_knots"),
        _bool_field(d, "free_phase"),
        _float_field(d, "duration_us"),
        _float_field(d, "fidelity"),
        verification,
        _optional_string(d, "warm_start"),
        _optional_string(d, "source_script"),
        _optional_string(d, "git_commit"),
        haskey(d, "date") ? _string_field(d, "date") : "",
        tags === nothing ? String[] : tags,
        _string_field(d, "path"),
    )
    return validate_entry(entry)
end

"""
    write_entry(dir, entry)

Write `entry` as `dir/metadata.toml` (flat keys, unset fields omitted),
validating first. The binary pulse itself is written by the curation tooling —
this function owns only the metadata half of the format.
"""
function write_entry(dir::AbstractString, entry::CatalogEntry)
    validate_entry(entry)
    d = Dict{String,Any}(
        "id" => entry.id,
        "platform" => entry.platform,
        "gate" => entry.gate,
        "version" => entry.version,
        "pulse_type" => entry.pulse_type,
        "N_knots" => entry.N_knots,
        "free_phase" => entry.free_phase,
        "duration_us" => entry.duration_us,
        "fidelity" => entry.fidelity,
        "path" => entry.path,
    )
    entry.tier !== nothing && (d["tier"] = entry.tier)
    entry.device_id !== nothing && (d["device_id"] = entry.device_id)
    entry.subsystem !== nothing && (d["subsystem"] = entry.subsystem)
    entry.levels !== nothing && (d["levels"] = entry.levels)
    entry.system_hash !== nothing && (d["system_hash"] = entry.system_hash)
    entry.warm_start !== nothing && (d["warm_start"] = entry.warm_start)
    entry.source_script !== nothing && (d["source_script"] = entry.source_script)
    entry.git_commit !== nothing && (d["git_commit"] = entry.git_commit)
    isempty(entry.date) || (d["date"] = entry.date)
    isempty(entry.tags) || (d["tags"] = entry.tags)
    if entry.verification !== nothing
        d["rollout_fidelity"] = entry.verification.rollout_fidelity
        d["verifier"] = entry.verification.verifier
        d["verified_date"] = entry.verification.date
    end
    mkpath(dir)
    open(joinpath(dir, "metadata.toml"), "w") do io
        return TOML.print(io, d)
    end
    return joinpath(dir, "metadata.toml")
end

# ============================================================================
# Tests
# ============================================================================ #

_v3_full_entry() = CatalogEntry(
    "transmon-X-v1",
    "transmon",
    "X",
    1,
    "bundled",
    "generic-2q",
    [1, 2],
    [3, 3],
    "sha256:0f3e8a9c2d1b4e6f8a7c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1",
    "CubicSplinePulse",
    11,
    true,
    0.03778913896658561,
    0.9999999770894263,
    VerificationRecord(0.999999977, "rollout: piccolo-2.1.0", "2026-10-01"),
    nothing,
    "scripts/x_heronr3_2level.jl",
    "cebc791",
    "2026-10-01",
    ["transmon", "gate/X"],
    "pulses/transmon-X-v1/pulse.jld2",
)

@testitem "CatalogEntry — v3 round-trips losslessly" begin
    using Legato
    using Legato: CatalogEntry, VerificationRecord, read_entry, write_entry

    mktempdir() do dir
        entry = Legato._v3_full_entry()
        write_entry(dir, entry)
        @test read_entry(dir) == entry
    end
end

@testitem "read_entry — v2-era metadata fills documented defaults" begin
    using Legato
    using Legato: read_entry, CatalogSchemaError

    # A v2-era entry: no tier, no verification keys, no hash. The schema's
    # compatibility floor — every pre-existing private-tier entry reads.
    v2_toml = """
    id = "transmon-H-ibm_heron_r3-v1"
    platform = "transmon"
    gate = "H"
    version = 1
    device_id = "ibm_heron_r3"
    subsystem = [1]
    levels = [3]
    pulse_type = "CubicSplinePulse"
    N_knots = 11
    free_phase = true
    duration_us = 0.0421
    fidelity = 0.9999998
    date = 2026-03-24
    path = "pulses/transmon-H-ibm_heron_r3-v1/pulse.jld2"
    """
    mktempdir() do dir
        open(joinpath(dir, "metadata.toml"), "w") do io
            return write(io, v2_toml)
        end
        entry = read_entry(dir)
        @test entry.id == "transmon-H-ibm_heron_r3-v1"
        @test entry.gate == "H"
        @test entry.date == "2026-03-24"  # TOML native date coerced to ISO string
        @test entry.tier === nothing           # documented default: unset
        @test entry.verification === nothing   # documented default: unverified
        @test entry.system_hash === nothing
        @test entry.tags == []
    end
end

@testitem "validate_entry — malformed metadata fails with the field named" begin
    using Legato
    using TOML
    using Legato: CatalogSchemaError, read_entry

    # Case 1: well-typed metadata but empty identity → validate_entry names id
    empty_id = Dict{String,Any}(
        "id" => "",
        "platform" => "transmon",
        "gate" => "X",
        "version" => 1,
        "pulse_type" => "CubicSplinePulse",
        "N_knots" => 11,
        "free_phase" => true,
        "duration_us" => 0.03,
        "fidelity" => 0.99,
        "path" => "pulses/x/pulse.jld2",
    )
    mktempdir() do dir
        open(joinpath(dir, "metadata.toml"), "w") do io
            return TOML.print(io, empty_id)
        end
        err = try
            read_entry(dir)
            nothing
        catch e
            e
        end
        @test err isa CatalogSchemaError
        @test err.field == "id"

        # Case 2: missing required key entirely → the key is named at read
        delete!(empty_id, "id")
        open(joinpath(dir, "metadata.toml"), "w") do io
            return TOML.print(io, empty_id)
        end
        err = try
            read_entry(dir)
            nothing
        catch e
            e
        end
        @test err isa CatalogSchemaError
        @test err.field == "id"

        # Case 3: wrong type → the field is named at read
        empty_id["id"] = "transmon-X-v1"
        empty_id["version"] = "1"  # string, not int
        open(joinpath(dir, "metadata.toml"), "w") do io
            return TOML.print(io, empty_id)
        end
        err = try
            read_entry(dir)
            nothing
        catch e
            e
        end
        @test err isa CatalogSchemaError
        @test err.field == "version"
    end

    # Structural invariants (readable metadata, invalid values) — each failure
    # names its field. _break rebuilds the struct with one field replaced.
    base = Legato._v3_full_entry()
    _break(key, value) = CatalogEntry(
        ntuple(
            i -> fieldnames(CatalogEntry)[i] === key ? value : getfield(base, i),
            fieldcount(CatalogEntry),
        )...,
    )
    for (key, bad_value) in
        ((:version, 0), (:N_knots, 1), (:fidelity, 1.2), (:warm_start, "has space"))
        err = try
            Legato.validate_entry(_break(key, bad_value))
            nothing
        catch e
            e
        end
        @test err isa Legato.CatalogSchemaError
        @test err.field == string(key)
    end

    # levels/subsystem length mismatch is named too
    err = try
        Legato.validate_entry(_break(:levels, [3, 3, 3]))
        nothing
    catch e
        e
    end
    @test err isa Legato.CatalogSchemaError
    @test err.field == "levels"

    # A verification record with an out-of-range rollout fidelity is rejected
    err = try
        Legato.validate_entry(
            _break(
                :verification,
                Legato.VerificationRecord(1.5, "rollout: piccolo-2.1.0", "2026-10-01"),
            ),
        )
        nothing
    catch e
        e
    end
    @test err isa Legato.CatalogSchemaError
    @test err.field == "rollout_fidelity"

    # tier is closed vocabulary
    err = try
        Legato.validate_entry(_break(:tier, "secret-third-tier"))
        nothing
    catch e
        e
    end
    @test err isa Legato.CatalogSchemaError
    @test err.field == "tier"
end

@testitem "read_entry — verification record must be complete or absent" begin
    using Legato
    using TOML
    using Legato: CatalogSchemaError, read_entry

    partial = Dict{String,Any}(
        "id" => "transmon-X-v1",
        "platform" => "transmon",
        "gate" => "X",
        "version" => 1,
        "pulse_type" => "CubicSplinePulse",
        "N_knots" => 11,
        "free_phase" => true,
        "duration_us" => 0.037,
        "fidelity" => 0.99,
        "path" => "pulses/transmon-X-v1/pulse.jld2",
        "rollout_fidelity" => 0.99,  # verifier + verified_date missing
    )
    mktempdir() do dir
        open(joinpath(dir, "metadata.toml"), "w") do io
            return TOML.print(io, partial)
        end
        err = try
            read_entry(dir)
            nothing
        catch e
            e
        end
        @test err isa CatalogSchemaError
        @test err.field == "verification"
    end
end
