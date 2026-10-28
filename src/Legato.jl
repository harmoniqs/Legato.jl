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
    AbstractSplinePulse,
    CubicSplinePulse,
    LinearSplinePulse,
    ZeroOrderPulse,
    n_drives,
    get_pulse,
    get_system,
    # Trajectories
    UnitaryTrajectory,
    # Integrators
    HermitianExponentialIntegrator,
    SplineIntegrator,
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
    default_integrator(qtraj, N; global_names = nothing)

Return the integrator used by `compile_block`. The substrate default is
**basis-aware**: the pulse's interpolation basis picks the integrator, so the
optimizer integrates exactly the waveform the pulse describes (Piccolo #375's
exact pairing — no approximation is declared anywhere on the compile path):

| pulse               | integrator                                           |
|:--------------------|:-----------------------------------------------------|
| `ZeroOrderPulse`    | `HermitianExponentialIntegrator` (exact PWC)         |
| `LinearSplinePulse` | `SplineIntegrator`, `spline_order = 1`               |
| `CubicSplinePulse`  | `SplineIntegrator`, `spline_order = 3` (reads `:du`) |

`global_names` are the problem trajectory's global variables (system
`global_params` plus the free-phase θ's the template adds — see
`_problem_global_names`). The exponential integrator must declare exactly
those; the spline integrator auto-detects the system's own globals and treats
the free-phase θ's as objective-only, so it ignores them.

Downstream tiers (Legatissimo) or callers install a different builder with
[`set_default_integrator!`](@ref).
"""
default_integrator(qtraj, N; global_names = nothing) =
    _call_integrator(_DEFAULT_INTEGRATOR[], qtraj, N; global_names = global_names)

# Builders are called with `global_names` when they accept it, otherwise with
# the legacy `(qtraj, N)` positional contract — so builders installed before
# the seam carried globals keep working unchanged.
function _call_integrator(builder, qtraj, N; global_names = nothing)
    hasmethod(builder, Tuple{typeof(qtraj),typeof(N)}, (:global_names,)) &&
        return builder(qtraj, N; global_names = global_names)
    return builder(qtraj, N)
end

_substrate_default_integrator(qtraj, N; global_names = nothing) =
    _basis_integrator(get_pulse(qtraj), qtraj, N, global_names)

_basis_integrator(::ZeroOrderPulse, qtraj, N, global_names) =
    HermitianExponentialIntegrator(
        _exponential_trajectory(get_system(qtraj), qtraj),
        N;
        global_names = global_names,
    )
_basis_integrator(::LinearSplinePulse, qtraj, N, global_names) =
    SplineIntegrator(qtraj, N; spline_order = 1)
_basis_integrator(::CubicSplinePulse, qtraj, N, global_names) =
    SplineIntegrator(qtraj, N; spline_order = 3)
_basis_integrator(pulse, qtraj, N, global_names) = throw(
    ArgumentError(
        "default_integrator: no exact integrator for a $(nameof(typeof(pulse))); " *
        "seed a ZeroOrderPulse, LinearSplinePulse or CubicSplinePulse, or install " *
        "a builder with `set_default_integrator!`.",
    ),
)

# `CompositeQuantumSystem`'s generator closures do not truncate the extended
# control vector `[u; globals]` the exponential integrator passes them (a plain
# `QuantumSystem`'s do), so a free-phase ZOH solve on a composite system fails
# with a DimensionMismatch. Integrate against the identical flat system. Only
# global-free systems are flattened: the flat copy carries no `global_params`.
_exponential_trajectory(sys, qtraj) = qtraj
function _exponential_trajectory(sys::CompositeQuantumSystem, qtraj::UnitaryTrajectory)
    isempty(sys.global_params) || return qtraj
    flat = QuantumSystem(
        Matrix(sys.H_drift),
        [Matrix(drive.H) for drive in sys.H_drives],
        sys.drive_bounds,
    )
    return UnitaryTrajectory(flat, get_pulse(qtraj), qtraj.goal)
end

"""
    _problem_global_names(qtraj; free_phase) -> Vector{Symbol}

The global variables a Piccolo problem template adds to the trajectory for
`qtraj`: the system's `global_params` plus, under `free_phase`, one phase per
subsystem of an `EmbeddedOperator` goal (`φ_1 … φ_n`, Piccolo's
`setup_free_phase_globals!` convention). Passed to the integrator seam so
globals-aware integrators declare exactly the trajectory's globals.
"""
function _problem_global_names(qtraj; free_phase::Bool)
    names = collect(Symbol, keys(get_system(qtraj).global_params))
    free_phase &&
        qtraj isa UnitaryTrajectory &&
        qtraj.goal isa EmbeddedOperator &&
        append!(names, [Symbol(:φ_, i) for i = 1:length(qtraj.goal.subsystem_levels)])
    return names
end

# Mutable default builder — downstream packages swap it via
# `set_default_integrator!`. We indirect through a Ref-held builder function so
# they can install overrides without redefining methods on types they don't own.
const _DEFAULT_INTEGRATOR = Ref{Any}(_substrate_default_integrator)

"""
    set_default_integrator!(builder)

Install a new builder function for [`default_integrator`](@ref). `builder`
accepts `(qtraj, N)` and returns an `AbstractIntegrator`; if it also accepts a
`global_names` keyword it receives the problem trajectory's globals (see
[`default_integrator`](@ref)). Intended primarily for the private `Legatissimo`
package, but callers can also use it to plug in custom integrators without
editing Legato source.
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
include("random_circuits.jl")
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
export random_circuit

function __init__()
    register_strategy!(DEFAULT_STRATEGY)
    return nothing
end

end # module
