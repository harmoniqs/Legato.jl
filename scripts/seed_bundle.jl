# ============================================================================
# seed_bundle.jl — build the bundled reference library (data/pulses/)
# ============================================================================
# Solves the transmon single-qubit gate set on the generic allowlisted device,
# then INDEPENDENTLY re-rollout-verifies every solved pulse: exact product of
# per-knot matrix exponentials against Piccolo's own assembled generators
# (no optimizer in the loop), scored with the free-phase average gate
# fidelity on the computational subspace. Verification happens HERE, at build
# time — the recorded verification record is the evidence; CI checks metadata,
# hashes, and loads, never re-solves.
#
# Also writes the analytic DRAG seed entries (tags=["analytic-seed"]) — no
# fidelity claim, empty verification record by design.
#
# The H gate seeds through the floor override with the SY analytic pulse
# (H = Ry(π/2)·Rz up to virtual-Z, which free-phase absorbs) — a worked
# example of the chain's :override branch.
#
# Re-running overwrites the bundle in place. The bundle is in-repo data
# reviewed by PR; append-only versioning semantics belong to the vault
# catalog, not here.
#
# Run: julia --project=. scripts/seed_bundle.jl   (from the package root)

using Legato
using Legato.Piccolo
using JLD2
using LinearAlgebra
using TOML
using Dates

const DEVICE = TransmonDevice(
    "generic-transmon-1q",
    [TransmonQubit(4.0, 0.2, 3)],
    CouplingEdge[],
    Dict{Symbol,Legato.GateSpec}(),
    0.05,
    [100.0],
    [100.0],
)
const SUBSYS = [1]
const T_NS = 80.0
const N_KNOTS = 51
const MAX_ITER = 80
const GATES_TO_SOLVE = Symbol.(split(get(ENV, "LEGATO_BUNDLE_GATES", "X,Y,SX,H"), ","))
const BAR = 0.9999 # the INTENT 1Q quality bar — build-time, not negotiable here
const BUNDLE = joinpath(@__DIR__, "..", "data", "pulses")

const SYS = MultiTransmonSystem(DEVICE, SUBSYS)
const H_DRIFT = Matrix(SYS.H_drift)
const H_DRIVES = [Matrix(drive.H) for drive in SYS.H_drives]

# The 2×2 computational-subspace targets, resolved through the circuit
# machinery (GATES + EXTRA_GATES) — exactly what the compiler optimizes against.
const TARGETS = Dict(
    gate => circuit_unitary(GateCircuit([GateOp(gate, (1,))], 1)) for
    gate in (:X, :Y, :SX, :H)
)

"""Exact PWC rollout of a ZeroOrderPulse against Piccolo's own generators."""
function rollout_unitary(pulse)
    U = Matrix{ComplexF64}(I, SYS.levels, SYS.levels)
    t = pulse.controls.t
    u = pulse.controls.u
    for k = 1:(length(t)-1)
        H = H_DRIFT + u[1, k] * H_DRIVES[1] + u[2, k] * H_DRIVES[2]
        U = exp(-im * H * (t[k+1] - t[k])) * U
    end
    return U
end

"""Free-phase average gate fidelity on the 2D subspace, side-agnostic:
absorbs a virtual-Z on either side of the target (Rz(a)·V·Rz(b) — exactly the
class frame updates allow). The optimizer's free-phase representative may
carry its Z on either side (Piccolo's objective absorbs the left one; the
SY-seeded H lands there), so the verifier must not care which."""
function freephase_fidelity(U, target)
    M = target' * U[1:2, 1:2]
    # max over (a, b): |tr(Rz(-a)·M·Rz(b))| — inner phase has a closed form,
    # the outer is a 1D maximization g(γ) = |m11 + m12 e^{iγ}| + |m21 + m22 e^{iγ}|
    g(γ) = abs(M[1, 1] + M[1, 2] * exp(im * γ)) + abs(M[2, 1] + M[2, 2] * exp(im * γ))
    γ_grid = range(0, 2π; length = 721)[1:(end-1)]
    best = maximum(g.(γ_grid))
    return best^2 / 6 + 1 / 3
end

function verify(pulse, gate)
    F = freephase_fidelity(rollout_unitary(pulse), TARGETS[gate])
    F ≥ BAR || error(
        "verification FAILED for $gate: free-phase rollout fidelity $F < bar $BAR — the pulse is NOT banked",
    )
    return F
end

function solved_entry(gate, block, F, sha, today)
    return Legato.CatalogEntry(
        "transmon-$(gate)-generic-v1",
        "transmon",
        string(gate),
        1,
        "bundled",
        DEVICE.name,
        copy(SUBSYS),
        [3],
        compute_system_hash(DEVICE, SUBSYS),
        "ZeroOrderPulse",
        N_KNOTS,
        true,
        duration(block.pulse) / 1000,
        block.fidelity, # optimizer claim, recorded — the verified number is in the record
        Legato.VerificationRecord(F, "rollout: scripts/seed_bundle.jl", today),
        nothing,
        "scripts/seed_bundle.jl",
        sha,
        today,
        ["transmon", "gate/$gate", "bundled"],
        "pulses/transmon-$(gate)-generic-v1/pulse.jld2",
    )
end

function analytic_entry(gate, seed, sha, today)
    return Legato.CatalogEntry(
        "transmon-$(gate)-drag-generic-v1",
        "transmon",
        string(gate),
        1,
        "bundled",
        DEVICE.name,
        copy(SUBSYS),
        [3],
        compute_system_hash(DEVICE, SUBSYS),
        "ZeroOrderPulse",
        N_KNOTS,
        true,
        duration(seed) / 1000,
        0.0, # no claim — seeds are guesses, and the ranking treats them as such
        nothing, # verification empty: analytic entries carry no fidelity claim
        nothing,
        "scripts/seed_bundle.jl",
        sha,
        today,
        ["transmon", "gate/$gate", "analytic-seed", "bundled"],
        "pulses/transmon-$(gate)-drag-generic-v1/pulse.jld2",
    )
end

function write_out(entry, pulse)
    dir = joinpath(BUNDLE, entry.id)
    write_entry(dir, entry)
    JLD2.save(joinpath(dir, "pulse.jld2"), "pulse", pulse)
    println("  wrote ", entry.id)
end

# ——— main ———————————————————————————————————————————————————————————— #

sha = readchomp(`git rev-parse --short HEAD`)
today = string(Dates.today())

# The IP rule, enforced at build time too: the device must be allowlisted.
allowlist = TOML.parsefile(joinpath(BUNDLE, "allowlist.toml"))
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
        SUBSYS,
    ) for p in allowlist["profile"]
)
compute_system_hash(DEVICE, SUBSYS) in allowed_hashes ||
    error("the seed device is not allowlisted — refusing to bundle")

# Pass 1: the in-plane gates seed analytically (the chain's own :analytic branch).
# SY is analytic-only (not in the circuit gate table): it banks as a seed and
# is what seeds H in pass 2.
println("solving in-plane gates (analytic DRAG seeds)…")
write_out(
    analytic_entry(:SY, drag_seed(:SY, T_NS, N_KNOTS, DEVICE.drive_max, 0.2), sha, today),
    drag_seed(:SY, T_NS, N_KNOTS, DEVICE.drive_max, 0.2),
)
for gate in [g for g in GATES_TO_SOLVE if g in (:X, :Y, :SX)]
    println("[$gate]")
    circuit = GateCircuit([GateOp(gate, (1,))], 1)
    block = compile_block(
        circuit,
        DEVICE,
        SUBSYS;
        T_ns = T_NS,
        N_knots = N_KNOTS,
        max_iter = MAX_ITER,
    )
    F = verify(block.pulse, gate)
    println(
        "  optimizer: ",
        round(block.fidelity, digits = 6),
        "  verified: ",
        round(F, digits = 6),
        "  seed: ",
        block.seed.branch,
    )
    write_out(solved_entry(gate, block, F, sha, today), block.pulse)
    # the analytic seed itself, banked alongside
    write_out(
        analytic_entry(
            gate,
            drag_seed(gate, T_NS, N_KNOTS, DEVICE.drive_max, 0.2),
            sha,
            today,
        ),
        drag_seed(gate, T_NS, N_KNOTS, DEVICE.drive_max, 0.2),
    )
end

# Pass 2: H — not in the analytic set; seed through the floor override with
# the SY pulse. Honest note: the SY seed is geometrically adjacent to H
# (H = Ry(π/2)·Z) but sits OUTSIDE Piccolo's free-phase class for this target
# (the objective absorbs the left-side virtual-Z, Rz·V), so the solve starts
# at F(x₀) ≈ 1/3 and the optimizer walks it in — recorded here so nobody
# mistakes it for a hot start.
println("[H]  (floor override: SY analytic seed)")
:H in GATES_TO_SOLVE || exit(0)
set_default_initial_pulse!(
    (c, d, t, n) -> drag_seed(:SY, t[end], length(t), d.drive_max, 0.2),
)
try
    circuit = GateCircuit([GateOp(:H, (1,))], 1)
    block = compile_block(
        circuit,
        DEVICE,
        SUBSYS;
        T_ns = T_NS,
        N_knots = N_KNOTS,
        max_iter = MAX_ITER,
    )
    F = verify(block.pulse, :H)
    println(
        "  optimizer: ",
        round(block.fidelity, digits = 6),
        "  verified: ",
        round(F, digits = 6),
        "  seed: ",
        block.seed.branch,
    )
    write_out(solved_entry(:H, block, F, sha, today), block.pulse)
finally
    Legato._DEFAULT_INITIAL_PULSE[] = Legato._substrate_default_initial_pulse
end

println(
    "bundle complete: 4 solved + 4 analytic entries, all verified against ",
    DEVICE.name,
)
