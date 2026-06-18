module Stretto

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
    duration,
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

"""
    default_integrator(qtraj, N)

Return the integrator used by `compile_block`. Default: Piccolo's `BilinearIntegrator`,
adequate for 1-2 qubit problems. When the private `Strettissimo` package is
loaded, its `__init__` installs a `SplineIntegrator` builder via
[`set_default_integrator!`](@ref), which scales to 3+ qubit compilation without
exhausting memory during evaluator construction.

Users who want a different integrator can either load Strettissimo or call
`set_default_integrator!` with a custom builder `(qtraj, N) -> integrator`.
"""
default_integrator(qtraj, N) = _DEFAULT_INTEGRATOR[](qtraj, N)

# Mutable default builder — swapped by Strettissimo's `__init__` at load time.
# We indirect through a Ref-held builder function so downstream packages can
# install overrides without redefining methods on types they don't own.
const _DEFAULT_INTEGRATOR = Ref{Any}((qtraj, N) -> BilinearIntegrator(qtraj, N))

"""
    set_default_integrator!(builder)

Install a new builder function for [`default_integrator`](@ref). `builder` must
accept `(qtraj, N)` and return an `AbstractIntegrator`. Intended primarily for
use by the private `Strettissimo` package, but callers can also use it to
plug in custom integrators without editing Stretto source.
"""
set_default_integrator!(builder) = (_DEFAULT_INTEGRATOR[] = builder; builder)

"""
    default_initial_pulse(circuit, device, times, n_drives)

Return the initial `AbstractPulse` that seeds optimization. Substrate: a random
Gaussian cold start (std = 0.02) on a `ZeroOrderPulse`, zero-clamped at the
first and last knots — pairs with the substrate `SmoothPulseProblem` template,
which adds derivative-of-control regularization for cold-start reliability.

Strettissimo overrides this with a catalog-retrieval warm-start keyed on the
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

Strettissimo overrides this with a parallel-multistart strategy that launches K
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
export build_problem, set_build_problem!
export CompilationStrategy
export register_strategy!, unregister_strategy!, strategies, select_strategy

function __init__()
    register_strategy!(DEFAULT_STRATEGY)
    return nothing
end

end # module
