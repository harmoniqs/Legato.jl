# The canonical pulse catalog format (schema v3). Flat TOML keys per entry;
# a strict superset of the private tier's v2 — every pre-existing entry reads.
using Dates
using SHA
using JLD2

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
# System-hash integrity
# ============================================================================ #

"""
    SystemHashMismatchError(entry_hash, computed_hash)

The integrity failure the whole warm-start program keys off: an entry's
recorded system hash disagrees with the hash recomputed from the device it
claims to have been solved against. Either the device's parameters have
drifted since the entry was banked, or the entry misattributes its system —
either way the entry no longer describes the physics it was optimized for.
Refuse the warm-start or re-verify; `load_pulse(...; validate = false)` is
the explicit retargeting escape hatch.
"""
struct SystemHashMismatchError <: Exception
    entry_hash::String
    computed_hash::String
end

function Base.showerror(io::IO, err::SystemHashMismatchError)
    return print(
        io,
        "SystemHashMismatchError: entry recorded ",
        err.entry_hash,
        " but the device recomputes ",
        err.computed_hash,
        " — device drift or misattributed entry",
    )
end

# The hash serialization: versioned, canonical, and documented. The hash
# answers "was this pulse solved against THESE dynamics" — it covers exactly
# the parameters that change the optimized dynamics (frequencies,
# anharmonicities, levels, intra-subsystem couplings, drive bounds, subsystem
# identity) and deliberately NOT the performance metadata (T1/T2, published
# gate specs) that never enters the Hamiltonian. Subsystem order is
# canonicalized (sorted); Float64s serialize via `repr` (round-trip exact,
# locale-free); edges canonicalize to i < j, sorted. Non-transmon device types
# gain hashing when they land, by adding a `_serialize_system` method.
function _serialize_system(device::TransmonDevice, subsystem::AbstractVector{Int})
    sorted = sort(collect(Int, subsystem))
    sub = Set(sorted)
    io = IOBuffer()
    println(io, "legato-system-hash-v1")
    println(io, device.name)
    println(io, join(sorted, ","))
    for i in sorted
        q = device.qubits[i]
        println(io, repr(q.ω), ",", repr(q.δ), ",", q.n_levels)
    end
    edges = [
        (min(e.i, e.j), max(e.i, e.j), e.g) for
        e in device.edges if e.i in sub && e.j in sub
    ]
    sort!(edges)
    for (i, j, g) in edges
        println(io, i, "-", j, ",", repr(g))
    end
    println(io, repr(device.drive_max))
    return String(take!(io))
end

"""
    compute_system_hash(device, subsystem)

The `sha256:`-prefixed integrity hash for a (device, subsystem) pair — the
value a `CatalogEntry` records in its `system_hash` field. Stable under
recomputation and under subsystem reordering; sensitive to any change in the
parameters that alter the optimized dynamics. Serialization is versioned (the
version tag lives inside the hashed text), so a future format change produces
different hashes rather than silently invalidating every entry.
"""
compute_system_hash(device::AbstractDevice, subsystem::AbstractVector{Int}) =
    "sha256:" * bytes2hex(sha256(_serialize_system(device, subsystem)))

"""
    validate_hash!(entry, device, subsystem)

Recompute the system hash from `device`/`subsystem` and check it against the
entry's recorded `system_hash`. Throws `SystemHashMismatchError` (carrying
both hashes) on drift or misattribution; throws a named schema error if the
entry carries no hash to validate. Returns the entry on success.
"""
function validate_hash!(
    entry::CatalogEntry,
    device::AbstractDevice,
    subsystem::AbstractVector{Int},
)
    entry.system_hash !== nothing || throw(
        CatalogSchemaError(
            "system_hash",
            "entry carries no system hash — nothing to validate",
        ),
    )
    computed = compute_system_hash(device, subsystem)
    entry.system_hash == computed ||
        throw(SystemHashMismatchError(entry.system_hash, computed))
    return entry
end

"""
    load_pulse(entry_dir; device = nothing, subsystem = nothing, validate = true)

Load an entry's pulse binary (`pulse.jld2`, under the established single
`"pulse"` key) together with its `CatalogEntry`: returns `(pulse, entry)`.

**Validation-on-load is the default**: when `device` (and `subsystem`) are
supplied, the entry's recorded hash is recomputed and checked first — a
mismatch refuses the load. `validate = false` is the explicit opt-out for
deliberate cross-device transfer (retargeting) workflows. Without a device
there is nothing to validate against; the pulse loads unverified.
"""
function load_pulse(
    entry_dir::AbstractString;
    device = nothing,
    subsystem = nothing,
    validate::Bool = true,
)
    entry = read_entry(entry_dir)
    if device !== nothing
        subsystem !== nothing || throw(ArgumentError("device given without subsystem"))
        validate && validate_hash!(entry, device, subsystem)
    end
    pulse = JLD2.load(joinpath(entry_dir, "pulse.jld2"))["pulse"]
    return pulse, entry
end

"""
    bundled_catalog()

The bundled reference library: the catalog partition shipped in this
repository (`data/pulses/` — solved + verified single-qubit gate pulses on
generic allowlisted devices, plus analytic seed entries). It is a standard
catalog partition: `find_pulses(bundled_catalog(); ...)` and the warm-start
chain's `:library` branch consume it directly via `set_default_catalog!`.

The bundle obeys the IP rule: every entry's device parameters match the
profiles in `data/pulses/allowlist.toml` (enforced by a lint test) —
partner-device parameters never enter the public repository.
"""
bundled_catalog() = joinpath(pkgdir(Legato), "data", "pulses")

# ============================================================================
# Query & ranking
# ============================================================================ #

"""
    rank_entries(entries; system_hash = nothing)

The **total ranking order** over catalog entries — the public contract every
consumer (the warm-start chain, the CLI, the private tier) shares, so none can
diverge. Descending by, in order:

1. **hash-exactness** — entries whose `system_hash` equals the query's come
   first (only when a query hash is given);
2. **verification** — verified entries rank strictly above unverified ones;
3. **fidelity** — recorded fidelity descending *within* the same
   hash/verification group;
4. ties break by shorter `duration_us`, then newer `date`, then id — the
   ordering is total, never unspecified.

The verified-above-unverified rule holds **at any recorded fidelity**: an
optimizer claiming 0.9999 never outranks a rollout-verified 0.999 — trust
ordering beats number envy.
"""
function rank_entries(entries::AbstractVector{CatalogEntry}; system_hash = nothing)
    # Tuple sort, rev: hash_exact desc, verified desc, fidelity desc,
    # duration asc (-duration under rev), date desc, id deterministic.
    return sort(
        entries;
        by = e -> (
            system_hash !== nothing && e.system_hash == system_hash,
            e.verification !== nothing,
            e.fidelity,
            -e.duration_us,
            e.date,
            e.id,
        ),
        rev = true,
    )
end

# Default results show one entry per line (platform, gate, device_id) **per
# trust class**: the verified incumbent chain keeps its max version, and the
# unverified candidate chain keeps its max version — both surface, and the
# ranking puts the incumbent above the candidate. Superseding by raw version
# across trust classes would let an unverified v3 hide a verified v2 incumbent,
# which is exactly what the verified-above-unverified rule forbids. Versioning
# is append-only, so supersession is a filter, never a mutation.
function _drop_superseded(entries::Vector{CatalogEntry})
    latest = Dict{Tuple{String,String,Union{String,Nothing},Bool},CatalogEntry}()
    for e in entries
        key = (e.platform, e.gate, e.device_id, e.verification !== nothing)
        if !haskey(latest, key) || e.version > latest[key].version
            latest[key] = e
        end
    end
    return collect(values(latest))
end

"""
    find_pulses(entries_dir; platform, gate, device_id, system_hash, exact_hash_only, include_superseded)

Scan a catalog partition (a directory of entry directories) for matching
entries, ranked by [`rank_entries`](@ref).

- `platform`, `gate`, `device_id` are exact-match filters (`nothing` = no
  filter); `device_id` matching narrows to one device's entries.
- `system_hash` does **not** filter by default — it *ranks*: hash-exact
  entries come first, the rest remain as fallbacks (the warm-start chain's
  resolution order). `exact_hash_only = true` makes it a strict filter.
- Superseded versions never appear in default results; `include_superseded = true`
  surfaces them. Supersession is per **trust class**: within one
  platform/gate/device line, the verified incumbent chain keeps its latest
  version and the unverified candidate chain keeps its latest — an unverified
  v3 can never hide a verified v2 incumbent from default results.
- An empty or missing directory returns an empty vector, never an error —
  callers fall through the warm-start chain on absence, not on exception.
- A malformed entry is skipped with a warning naming its path; one bad entry
  never poisons a catalog query.
"""
function find_pulses(
    entries_dir::AbstractString;
    platform = nothing,
    gate = nothing,
    device_id = nothing,
    system_hash = nothing,
    exact_hash_only::Bool = false,
    include_superseded::Bool = false,
)
    isdir(entries_dir) || return CatalogEntry[]
    entries = CatalogEntry[]
    for path in readdir(entries_dir; join = true)
        isdir(path) || continue
        isfile(joinpath(path, "metadata.toml")) || continue
        entry = try
            read_entry(path)
        catch err
            err isa CatalogSchemaError || rethrow()
            @warn "skipping malformed catalog entry" path error = err
            continue
        end
        (platform === nothing || entry.platform == platform) || continue
        (gate === nothing || entry.gate == gate) || continue
        (device_id === nothing || entry.device_id == device_id) || continue
        (system_hash === nothing || !exact_hash_only || entry.system_hash == system_hash) ||
            continue
        push!(entries, entry)
    end
    entries = include_superseded ? entries : _drop_superseded(entries)
    return rank_entries(entries; system_hash = system_hash)
end

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

# Rebuild a v3 entry with one field replaced (test scaffolding).
_break(key, value) = CatalogEntry(
    ntuple(
        i ->
            fieldnames(CatalogEntry)[i] === key ? value : getfield(_v3_full_entry(), i),
        fieldcount(CatalogEntry),
    )...,
)

# ============================================================================
# Tests
# ============================================================================ #

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

@testitem "find_pulses — deterministic ranking over a scenario catalog" begin
    using Legato
    using Legato: CatalogEntry, VerificationRecord, find_pulses, rank_entries, write_entry

    # Entry factory: one line (transmon, X, generic-2q), varying version,
    # fidelity, verification, hash.
    make(
        id,
        version,
        fidelity;
        verification = nothing,
        system_hash = nothing,
        duration = 0.04,
        date = "2026-10-01",
    ) = CatalogEntry(
        id,
        "transmon",
        "X",
        version,
        "bundled",
        "generic-2q",
        [1],
        [3],
        system_hash,
        "CubicSplinePulse",
        11,
        true,
        duration,
        fidelity,
        verification,
        nothing,
        nothing,
        nothing,
        date,
        String[],
        "pulses/$id/pulse.jld2",
    )
    verified(f) = VerificationRecord(f, "rollout: piccolo-2.1.0", "2026-10-01")

    # The scenario: a superseded verified v1, a hash-exact verified v2
    # incumbent, and a higher-fidelity but UNVERIFIED v3 — trust ordering
    # must beat number envy.
    scenario = [
        make("transmon-X-v1", 1, 0.90; verification = verified(0.90)),
        make(
            "transmon-X-v2",
            2,
            0.95;
            verification = verified(0.95),
            system_hash = "sha256:AAA",
        ),
        make("transmon-X-v3", 3, 0.9999),
        # Different gate, same platform — must not surface under gate=X
        CatalogEntry(
            "transmon-Y-v1",
            "transmon",
            "Y",
            1,
            "bundled",
            "generic-2q",
            [1],
            [3],
            nothing,
            "CubicSplinePulse",
            11,
            true,
            0.04,
            0.9,
            verified(0.9),
            nothing,
            nothing,
            nothing,
            "2026-10-01",
            String[],
            "pulses/transmon-Y-v1/pulse.jld2",
        ),
        # Different device — must not surface under device_id="other-dev"
        CatalogEntry(
            "transmon-X-other-v1",
            "transmon",
            "X",
            1,
            "bundled",
            "other-dev",
            [1],
            [3],
            nothing,
            "CubicSplinePulse",
            11,
            true,
            0.04,
            0.9,
            nothing,
            nothing,
            nothing,
            nothing,
            "2026-10-01",
            String[],
            "pulses/transmon-X-other-v1/pulse.jld2",
        ),
        # Different platform entirely
        CatalogEntry(
            "fluxonium-X-v1",
            "fluxonium",
            "X",
            1,
            "bundled",
            "generic-fl",
            [1],
            [5],
            nothing,
            "LinearSplinePulse",
            51,
            false,
            0.0255,
            0.9999,
            verified(0.9999),
            nothing,
            nothing,
            nothing,
            "2026-10-01",
            String[],
            "pulses/fluxonium-X-v1/pulse.jld2",
        ),
    ]
    mktempdir() do dir
        for e in scenario
            write_entry(joinpath(dir, e.id), e)
        end

        # platform+gate query with the query hash = the v2 incumbent's hash:
        # hash-exact verified v2 first, then unverified entries by recorded
        # fidelity (v3's higher claim notwithstanding). No device filter, so
        # the other-device candidate surfaces after v3; superseded v1 absent.
        hits =
            find_pulses(dir; platform = "transmon", gate = "X", system_hash = "sha256:AAA")
        @test [e.id for e in hits] == ["transmon-X-v2", "transmon-X-v3", "transmon-X-other-v1"]

        # include_superseded surfaces v1 — and verified v1 (0.90) ranks above
        # unverified v3 (0.9999) under the trust rule
        all_x = find_pulses(
            dir;
            platform = "transmon",
            gate = "X",
            system_hash = "sha256:AAA",
            include_superseded = true,
        )
        @test [e.id for e in all_x] == ["transmon-X-v2", "transmon-X-v1", "transmon-X-v3", "transmon-X-other-v1"]

        # Without a query hash, verified v2 still outranks unverified v3
        no_hash = find_pulses(dir; platform = "transmon", gate = "X")
        @test [e.id for e in no_hash] == ["transmon-X-v2", "transmon-X-v3", "transmon-X-other-v1"]

        # exact_hash_only narrows to the hash match alone
        strict = find_pulses(
            dir;
            platform = "transmon",
            gate = "X",
            system_hash = "sha256:AAA",
            exact_hash_only = true,
        )
        @test [e.id for e in strict] == ["transmon-X-v2"]

        # device_id filter excludes the other-device entry
        own = find_pulses(dir; platform = "transmon", gate = "X", device_id = "generic-2q")
        @test "transmon-X-other-v1" ∉ [e.id for e in own]

        # Empty library (and missing directory): empty result, never an error
        @test find_pulses(joinpath(dir, "nonexistent")) == CatalogEntry[]
    end
end

@testitem "rank_entries — total order: duration, date, id tie-breaks" begin
    using Legato
    using Legato: CatalogEntry, VerificationRecord, rank_entries

    make(id, fidelity, duration, date) = CatalogEntry(
        id,
        "transmon",
        "X",
        1,
        "bundled",
        nothing,
        nothing,
        nothing,
        nothing,
        "CubicSplinePulse",
        11,
        true,
        duration,
        fidelity,
        VerificationRecord(fidelity, "rollout", date),
        nothing,
        nothing,
        nothing,
        date,
        String[],
        "pulses/$id/pulse.jld2",
    )

    # Same fidelity: shorter duration first
    a = make("transmon-X-a", 0.99, 0.030, "2026-09-01")
    b = make("transmon-X-b", 0.99, 0.040, "2026-09-02")
    @test [e.id for e in rank_entries([b, a])] == ["transmon-X-a", "transmon-X-b"]

    # Same fidelity and duration: newer date first
    c = make("transmon-X-c", 0.99, 0.030, "2026-10-01")
    @test [e.id for e in rank_entries([a, c])] == ["transmon-X-c", "transmon-X-a"]

    # Fully tied apart from id: still total (id-terminated)
    d = make("transmon-X-d", 0.99, 0.030, "2026-10-01")
    @test length(rank_entries([c, d])) == 2  # deterministic, no throw

    # Verified strictly above unverified at ANY recorded fidelity
    unverified = CatalogEntry(
        "transmon-X-hi",
        "transmon",
        "X",
        1,
        "bundled",
        nothing,
        nothing,
        nothing,
        nothing,
        "CubicSplinePulse",
        11,
        true,
        0.04,
        0.99999,
        nothing,
        nothing,
        nothing,
        nothing,
        "2026-10-02",
        String[],
        "pulses/h/pulse.jld2",
    )
    @test [e.id for e in rank_entries([unverified, c])] == ["transmon-X-c", "transmon-X-hi"]
end

@testitem "find_pulses — malformed entry is skipped, not fatal" begin
    using Legato
    using TOML
    using Legato: find_pulses, write_entry

    mktempdir() do dir
        good = Legato._v3_full_entry()
        write_entry(joinpath(dir, good.id), good)
        # A malformed sibling: identity missing entirely
        mkpath(joinpath(dir, "bad-entry"))
        open(joinpath(dir, "bad-entry", "metadata.toml"), "w") do io
            return TOML.print(io, Dict{String,Any}("platform" => "transmon"))
        end
        hits = find_pulses(dir; platform = "transmon", gate = "X")
        @test [e.id for e in hits] == [good.id]
    end
end

# A minimal generic transmon device for hashing tests (the generic builder
# path, not a published profile).
_test_device(;
    ωs = [4.0, 4.1],
    δs = [-0.2, -0.22],
    levels = [3, 3],
    g = 0.003,
    drive_max = 0.05,
) = TransmonDevice(
    "generic-hash-test",
    TransmonQubit.(ωs, δs, levels),
    [CouplingEdge(1, 2, g)],
    Dict{Symbol,GateSpec}(),
    drive_max,
    fill(68.0, 2),
    fill(80.0, 2),
)

@testitem "compute_system_hash — stable, sensitive, canonical" begin
    using Legato
    using Legato: compute_system_hash, GateSpec

    # Stability: recomputation does not move the hash
    d = Legato._test_device()
    @test compute_system_hash(d, [1, 2]) == compute_system_hash(d, [1, 2])

    # Subsystem reordering canonicalizes to the same set
    @test compute_system_hash(d, [1, 2]) == compute_system_hash(d, [2, 1])

    # Subsystem identity matters
    @test compute_system_hash(d, [1, 2]) != compute_system_hash(d, [1])

    # Sensitivity: every dynamics-relevant parameter perturbation moves the hash
    for perturbed in (
        Legato._test_device(ωs = [4.0, 4.100000001]),   # a frequency
        Legato._test_device(δs = [-0.2, -0.220000001]), # an anharmonicity
        Legato._test_device(levels = [3, 4]),           # a level count
        Legato._test_device(g = 0.003000001),          # a coupling
        Legato._test_device(drive_max = 0.050000001),   # the drive bound
    )
        @test compute_system_hash(perturbed, [1, 2]) != compute_system_hash(d, [1, 2])
    end

    # Deliberately EXCLUDED from the hash: performance metadata that never
    # enters the Hamiltonian (T1/T2, published gate specs).
    same_dynamics = TransmonDevice(
        d.name,
        d.qubits,
        d.edges,
        Dict(:X => GateSpec(20.0, 1e-4)), # native_gates added
        d.drive_max,
        fill(999.0, 2),                   # T1 changed
        fill(999.0, 2),                   # T2 changed
    )
    @test compute_system_hash(same_dynamics, [1, 2]) == compute_system_hash(d, [1, 2])

    # Versioned: the serialization tag lives inside the hashed text
    @test startswith(compute_system_hash(d, [1, 2]), "sha256:")
end

@testitem "compute_system_hash — covers profiles and the generic builder" begin
    using Legato
    using Legato: compute_system_hash

    hashes = [
        compute_system_hash(HeronR3(), [1, 2]),
        compute_system_hash(HeronR2(), [1, 2]),
        compute_system_hash(IQMEmerald(), [1, 2]),
        compute_system_hash(Legato._test_device(), [1, 2]),
    ]
    # Distinct devices hash distinctly; every hash is well-formed
    @test length(unique(hashes)) == 4
    @test all(startswith.(hashes, "sha256:"))
end

@testitem "validate_hash! — drift and misattribution are named, both hashes carried" begin
    using Legato
    using Legato:
        CatalogSchemaError, SystemHashMismatchError, compute_system_hash, validate_hash!

    d = Legato._test_device()
    h = compute_system_hash(d, [1, 2])

    # A no-hash entry cannot be validated — named schema error
    no_hash = Legato._break(:system_hash, nothing)
    err = try
        validate_hash!(no_hash, d, [1, 2])
        nothing
    catch e
        e
    end
    @test err isa CatalogSchemaError
    @test err.field == "system_hash"

    # A hash-bearing entry validates clean on its own device
    entry = Legato._break(:system_hash, h)
    @test validate_hash!(entry, d, [1, 2]) == entry

    # Device drift → mismatch error carrying BOTH hashes
    drifted = Legato._test_device(ωs = [4.0, 4.11])
    err = try
        validate_hash!(entry, drifted, [1, 2])
        nothing
    catch e
        e
    end
    @test err isa SystemHashMismatchError
    @test err.entry_hash == h
    @test err.computed_hash == compute_system_hash(drifted, [1, 2])
    @test occursin(h, sprint(showerror, err))
    @test occursin(err.computed_hash, sprint(showerror, err))
end

@testitem "load_pulse — validation-on-load default, explicit retargeting opt-out" begin
    using Legato
    using JLD2
    using Legato: SystemHashMismatchError, compute_system_hash, write_entry, load_pulse
    using Piccolo: ZeroOrderPulse

    d = Legato._test_device()
    h = compute_system_hash(d, [1, 2])
    times = collect(range(0.0, 10.0, length = 5))
    pulse =
        ZeroOrderPulse(zeros(2, 5), times; initial_value = zeros(2), final_value = zeros(2))

    mktempdir() do dir
        entry_dir = joinpath(dir, "transmon-X-hash-v1")
        entry = Legato.CatalogEntry(
            "transmon-X-hash-v1",
            "transmon",
            "X",
            1,
            "curated",
            "generic-hash-test",
            [1, 2],
            [3, 3],
            h,
            "ZeroOrderPulse",
            5,
            true,
            0.01,
            0.99,
            Legato.VerificationRecord(0.99, "rollout: test", "2026-10-02"),
            nothing,
            nothing,
            nothing,
            "2026-10-02",
            String[],
            "pulses/transmon-X-hash-v1/pulse.jld2",
        )
        write_entry(entry_dir, entry)
        JLD2.save(joinpath(entry_dir, "pulse.jld2"), "pulse", pulse)

        # Validation-on-load (default): matching device loads clean
        loaded, meta = load_pulse(entry_dir; device = d, subsystem = [1, 2])
        @test loaded isa ZeroOrderPulse
        @test meta.id == "transmon-X-hash-v1"

        # Drifted device → refusal by default
        drifted = Legato._test_device(ωs = [4.0, 4.11])
        err = try
            load_pulse(entry_dir; device = drifted, subsystem = [1, 2])
            nothing
        catch e
            e
        end
        @test err isa SystemHashMismatchError

        # The explicit retargeting opt-out loads anyway
        retargeted, _ =
            load_pulse(entry_dir; device = drifted, subsystem = [1, 2], validate = false)
        @test retargeted isa ZeroOrderPulse

        # Without a device, loading is unverified but works (integrity is the
        # caller's contract to request)
        bare, meta2 = load_pulse(entry_dir)
        @test bare isa ZeroOrderPulse
        @test meta2.id == meta.id
    end
end

@testitem "bundled library — completeness and schema" begin
    using Legato
    using Legato: bundled_catalog, find_pulses, read_entry

    partition = bundled_catalog()
    isdir(partition) || error("bundled catalog partition missing")

    # The solved set (verification-recorded) and the analytic seed set
    solved = ["transmon-$g-generic-v1" for g in (:X, :Y, :SX, :H)]
    analytic = ["transmon-$g-drag-generic-v1" for g in (:X, :Y, :SX, :SY)]
    for id in vcat(solved, analytic)
        entry = read_entry(joinpath(partition, id))
        @test entry.tier == "bundled"
        @test entry.device_id == "generic-transmon-1q"
        @test entry.platform == "transmon"
        isfile(joinpath(partition, id, "pulse.jld2")) ||
            error("$id missing its pulse binary")
    end
    for id in solved
        entry = read_entry(joinpath(partition, id))
        @test entry.verification !== nothing
        # The INTENT 1Q quality bar, recorded at build time
        @test entry.verification.rollout_fidelity ≥ 0.9999
    end
    for id in analytic
        entry = read_entry(joinpath(partition, id))
        # Analytic seeds carry NO fidelity claim — empty verification is the
        # distinction, and the ranking treats them accordingly
        @test entry.verification === nothing
        @test "analytic-seed" in entry.tags
    end

    # It is a standard partition: queryable
    hits = find_pulses(partition; platform = "transmon", gate = "X")
    @test "transmon-X-generic-v1" in [e.id for e in hits]
end

@testitem "bundled library — IP lint (allowlist enforcement)" begin
    using Legato
    using TOML
    using Legato: bundled_catalog, read_entry, compute_system_hash

    # The allowlist: device parameterizations cleared for public bundling.
    # Adding a profile is a deliberate, human-reviewed PR action; the lint
    # fails if any bundled entry's hash matches no allowlisted profile.
    allowlist = TOML.parsefile(joinpath(bundled_catalog(), "allowlist.toml"))
    @test !isempty(allowlist["profile"])
    for p in allowlist["profile"]
        # human-auditable: every profile states its provenance
        @test p["provenance"] isa AbstractString && !isempty(p["provenance"])
    end
    allowed_hashes = Set(
        compute_system_hash(
            TransmonDevice(
                p["name"],
                TransmonQubit.(p["omega"], p["delta"], p["levels"]),
                [CouplingEdge(c...) for c in p["couplings"]],
                Dict{Symbol,Legato.GateSpec}(),
                p["drive_max"],
                [1.0],
                [1.0],
            ),
            [1],
        ) for p in allowlist["profile"]
    )

    for entry_dir in readdir(bundled_catalog(); join = true)
        isdir(entry_dir) || continue
        entry = read_entry(entry_dir)
        entry.system_hash in allowed_hashes || error(
            "IP LINT FAILURE: $(entry.id) references device parameters that " *
            "match no allowlisted profile — partner-device parameters never " *
            "enter the public bundle",
        )
    end
end

@testitem "bundled library — loads with validation-on-load" begin
    using Legato
    using TOML
    using Legato: bundled_catalog, load_pulse, compute_system_hash, validate_hash!

    # The allowlisted generic device, reconstructed from the allowlist itself
    allowlist = TOML.parsefile(joinpath(bundled_catalog(), "allowlist.toml"))
    p = only(allowlist["profile"])
    device = TransmonDevice(
        p["name"],
        TransmonQubit.(p["omega"], p["delta"], p["levels"]),
        [CouplingEdge(c...) for c in p["couplings"]],
        Dict{Symbol,Legato.GateSpec}(),
        p["drive_max"],
        [1.0],
        [1.0],
    )
    # Every solved entry loads against its own device, hash-validated
    for g in (:X, :Y, :SX, :H)
        pulse, entry = load_pulse(
            joinpath(bundled_catalog(), "transmon-$g-generic-v1");
            device = device,
            subsystem = [1],
        )
        @test pulse isa Legato.Piccolo.AbstractPulse
        @test entry.verification.rollout_fidelity ≥ 0.9999
    end
end
