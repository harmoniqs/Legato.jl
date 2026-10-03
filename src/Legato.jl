module Legato

using FFTW
using LinearAlgebra
using Printf
using TOML
using TestItems

using Piccolo
using Piccolo:
    # Systems
    AbstractQuantumSystem,
    QuantumSystem,
    MultiTransmonSystem,
    CompositeQuantumSystem,
    # Operators
    EmbeddedOperator,
    GATES,
    get_subspace_indices,
    # Pulses
    AbstractPulse,
    CubicSplinePulse,
    ZeroOrderPulse,
    n_drives,
    # Trajectories
    UnitaryTrajectory,
    # Integrators
    BilinearIntegrator,
    # Problems
    SmoothPulseProblem,
    SplinePulseProblem,
    PiccoloOptions,
    # Solving
    solve!,
    fidelity,
    get_trajectory,
    extract_pulse

# `duration` cannot come through the `Piccolo` re-export surface: NT >= 0.9.3
# exports TimeWarp's `duration`, which collides with Quantum.Pulses' in
# Piccolo's namespace (Piccolo#323), leaving the top-level binding ambiguous
# and undefined on import. Bind it from the declaring module instead.
using Piccolo.Quantum.Pulses: duration

"""
    default_integrator(qtraj, N)

Return the integrator used by `compile_block`. Default: Piccolo's `BilinearIntegrator`,
adequate for 1-2 qubit problems. When the private `Legatissimo` package is
loaded, its `__init__` installs a `SplineIntegrator` builder via
[`set_default_integrator!`](@ref), which scales to 3+ qubit compilation without
exhausting memory during evaluator construction.

Users who want a different integrator can either load Legatissimo or call
`set_default_integrator!` with a custom builder `(qtraj, N) -> integrator`.
"""
default_integrator(qtraj, N) = _DEFAULT_INTEGRATOR[](qtraj, N)

# Mutable default builder — swapped by Legatissimo's `__init__` at load time.
# We indirect through a Ref-held builder function so downstream packages can
# install overrides without redefining methods on types they don't own.
const _DEFAULT_INTEGRATOR = Ref{Any}((qtraj, N) -> BilinearIntegrator(qtraj, N))

"""
    set_default_integrator!(builder)

Install a new builder function for [`default_integrator`](@ref). `builder` must
accept `(qtraj, N)` and return an `AbstractIntegrator`. Intended primarily for
use by the private `Legatissimo` package, but callers can also use it to
plug in custom integrators without editing Legato source.
"""
set_default_integrator!(builder) = (_DEFAULT_INTEGRATOR[] = builder; builder)

# Warm-start chain configuration (additions — the four substrate seams above
# are untouched). The catalog is a catalog partition directory (entry dirs);
# nothing by default, which makes the chain's library/retarget branches no-ops
# and preserves pre-chain behavior exactly.
const _DEFAULT_CATALOG = Ref{Union{String,Nothing}}(nothing)

"""
    set_default_catalog!(dir)

Point the warm-start fallback chain at a catalog partition (a directory of
entry directories, as scanned by `find_pulses`). `nothing` disables the
library and retarget branches. Hash-exact entries load with
validation-on-load; a hash mismatch refuses the warm-start (drift is a
finding, not a fallback).
"""
set_default_catalog!(dir::Union{Nothing,AbstractString}) =
    (_DEFAULT_CATALOG[] = dir === nothing ? nothing : String(dir))

const _DEFAULT_RETARGET = Ref{Union{Function,Nothing}}(nothing)

"""
    set_default_retarget!(f)

Install the retarget override — the private tier's plug point for
cross-device transfer. `f` must have signature

`(entry, entry_dir, device, qubit_indices, times) -> Union{AbstractPulse, Nothing}`

and is applied to the best near-miss catalog entry (platform+gate match, no
hash-exact match). Returning `nothing` declines the retarget and the chain
falls through to analytic — never an error. `nothing` uninstalls.
"""
set_default_retarget!(f::Union{Nothing,Function}) = (_DEFAULT_RETARGET[] = f)

# Substrate dynamics are knot-only (PWC): the optimizer drives knot values,
# never a spline's derivative coefficients. Piccolo ≥ 2 requires that contract
# to be stated explicitly (`integrator_type = :pwc`) — composing a
# CubicSplinePulse with BilinearIntegrator is a hard error there, and a spline
# problem's default-integrator path rejects cubic pulses outright (Piccolo
# #275: the old silent :du drop became a loud guard). Piccolo 1.x predates the
# kwarg and pairs Bilinear with spline pulses directly — identical knot-only
# semantics. Both branches compute the same dynamics.
function _pwc_dynamics_kwargs()
    return pkgversion(Piccolo) >= v"2.0.0" ? (; integrator_type = :pwc) : (;)
end

"""
    default_initial_pulse(circuit, device, times, n_drives)

Return the initial `AbstractPulse` that seeds optimization. Substrate: a random
Gaussian cold start (std = 0.02) on a `ZeroOrderPulse`, zero-clamped at the
first and last knots — pairs with the substrate `SmoothPulseProblem` template,
which adds derivative-of-control regularization for cold-start reliability.

Legatissimo overrides this with a catalog-retrieval warm-start keyed on the
(circuit fingerprint, device profile) pair, falling back to the substrate on
catalog miss.
"""
default_initial_pulse(circuit, device, times, n_drives) =
    _DEFAULT_INITIAL_PULSE[](circuit, device, times, n_drives)

function _substrate_default_initial_pulse(circuit, device, times, n_drives)
    N = length(times)
    u_init = 0.02 * randn(n_drives, N)
    u_init[:, 1] .= 0.0
    u_init[:, end] .= 0.0
    return ZeroOrderPulse(
        u_init,
        times;
        initial_value = zeros(n_drives),
        final_value = zeros(n_drives),
    )
end

const _DEFAULT_INITIAL_PULSE = Ref{Any}(_substrate_default_initial_pulse)

"""
    set_default_initial_pulse!(f)

Install `f` as the initial-pulse builder. `f` must have signature
`(circuit, device, times, n_drives) -> AbstractPulse`. Whatever pulse
type is returned must be compatible with the problem template installed
via `set_build_problem!` (substrate: `ZeroOrderPulse` paired with
`SmoothPulseProblem`).
"""
set_default_initial_pulse!(f) = (_DEFAULT_INITIAL_PULSE[] = f)

"""
    default_solver_strategy(problem, qtraj; max_iter)

Execute the solve and return `(pulse, fidelity)`. Substrate: one `solve!` call
with the given `max_iter`, then `extract_pulse` + `fidelity`. This is the single
cold-start path.

Legatissimo overrides this with a parallel-multistart strategy that launches K
cold starts, solves each, and returns the best-fidelity pair.
"""
default_solver_strategy(problem, qtraj; max_iter) =
    _DEFAULT_SOLVER_STRATEGY[](problem, qtraj; max_iter)

function _substrate_default_solver_strategy(problem, qtraj; max_iter)
    solve!(problem; max_iter = max_iter)
    traj = get_trajectory(problem)
    pulse = extract_pulse(qtraj, traj)
    fid = fidelity(problem)
    return (pulse, fid)
end

const _DEFAULT_SOLVER_STRATEGY = Ref{Any}(_substrate_default_solver_strategy)

"""
    set_default_solver_strategy!(f)

Install `f` as the solver strategy. `f` must have signature
`(problem, qtraj; max_iter) -> (pulse, fidelity)`.
"""
set_default_solver_strategy!(f) = (_DEFAULT_SOLVER_STRATEGY[] = f)

include("devices.jl")
include("profiles.jl")
include("circuits.jl")
include("qasm.jl")
include("transpile.jl")
include("partitioning.jl")
include("library.jl")
include("classify.jl")
include("build_problem.jl")
include("pulse_library.jl")
include("analytic_seeds.jl")
include("post_process.jl")
include("strategy.jl")
include("compile.jl")
include("report.jl")

export AbstractDevice, TransmonDevice, TransmonQubit, CouplingEdge
export HeronR3, HeronR2, IQMEmerald
export AbstractCircuit, GateOp, GateCircuit, circuit_unitary
export from_qasm
export to_native, native_gate_set
export qft_circuit, bell_circuit, toffoli_circuit, ccz_circuit
export compile, compile_block
export CompilationReport, gate_level_baseline
export default_integrator, set_default_integrator!
export default_initial_pulse, set_default_initial_pulse!
export BlockSpec, default_partitioner, set_default_partitioner!
export default_solver_strategy, set_default_solver_strategy!
export classify_problem, set_classify_problem!
export PostProcessContext, default_post_process, set_default_post_process!
export pulse_spectrum, plot_pulse_spectrum
export build_problem, set_build_problem!
export CompilationStrategy
export register_strategy!, unregister_strategy!, strategies, select_strategy
export CatalogSchemaError, VerificationRecord, CatalogEntry
export validate_entry, read_entry, write_entry
export find_pulses, rank_entries
export SystemHashMismatchError, compute_system_hash, validate_hash!, load_pulse
export rectangular_seed, drag_seed
export SeedProvenance, resolve_seed
export set_default_catalog!, set_default_retarget!
export bundled_catalog
export rollout_pwc, freephase_gate_fidelity

function __init__()
    register_strategy!(DEFAULT_STRATEGY)
    return nothing
end

end # module
