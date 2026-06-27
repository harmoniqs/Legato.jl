# QFT-4 on IBM Heron r3 — DEFERRED past v0.1.
#
# Compile QFT-4 as a single optimized pulse on a 4-qubit HeronR3 model
# (3^4 = 81-dim Hilbert space, 8 drives, 31 knots, 4 free phases). Uses
# Piccolissimo's SplineIntegrator so evaluator construction stays in RAM
# (~4GB observed, vs. 57GB OOM with Piccolo's BilinearIntegrator).
#
# Status: the pipeline wires up and evaluator construction succeeds on
# this workstation, but even one Ipopt iteration on a 393k-constraint
# problem is prohibitively slow for an interactive run. Keeping the
# script as a reference target — revisit when we have:
#   - a partitioning pass (compile per-block, not whole-circuit),
#   - a warm-start catalog (start near a good pulse, not cold),
#   - or a stronger solver (AL / GPU — see Altissimo).
#
# To run:
#   OPENBLAS_NUM_THREADS=1 julia --project=. -t auto scripts/qft4_heronr3.jl

using Legato
using Piccolo: duration

device = HeronR3()
circuit = qft_circuit(4)

println("\nQFT-4 circuit: $(length(circuit)) gates on $(circuit.n_qubits) qubits")
println("Hilbert space: 3^4 = 81 dim, 8 drives")
println("Compiling with 500 iterations...")

report = compile(
    circuit,
    device;
    max_iter = 500,
    T_ns = 400.0,    # generous initial duration for 4Q
    N_knots = 31,       # more knots for 4Q
    Q = 200.0,
)

println(report)
println("\nv0.1 milestone: QFT-4 on HeronR3 compiled successfully.")
println("Pulse fidelity: $(round(report.pulse_fidelity * 100, digits=2))%")
println("Pulse duration: $(round(report.pulse_duration_ns, digits=1)) ns")
println("Gate baseline:  $(round(report.gate_duration_ns, digits=1)) ns")

# Sanity assertions (script-style — assertion errors halt the run)
@assert report.pulse_duration_ns > 0.0
@assert report.gate_duration_ns > 0.0
@assert report.pulse_fidelity > 0.1   # better than 1/16 random
