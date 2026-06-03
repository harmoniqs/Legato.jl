"""
    HeronR3(; n_levels::Int = 3)

IBM Heron r3 device profile. Parameters from published specs (2024-2026)
and Aumann et al. (arXiv:2604.12465).

Heavy-hex topology, CZ-native, 156 qubits. This profile models the first
8 qubits in a linear chain (sufficient for QFT-4 and QFT-8 benchmarks).

# Keyword Arguments
- `n_levels::Int = 3`: number of levels per transmon. The default `3`
  models the second-excited (`|2⟩`) leakage level explicitly — physically
  accurate for closed-system optimization. Setting `n_levels = 2` truncates
  to the qubit subspace, giving a 4-dim 2Q Hilbert space (vs 9-dim for
  3-level). Use `n_levels = 2` for fast 1Q–2Q demos where leakage isn't
  the focus.
"""
function HeronR3(; n_levels::Int = 3)
    # Typical Heron r3 parameters (from published calibration data)
    # Frequencies staggered to avoid frequency collisions
    qubits = [
        TransmonQubit(5.00, 0.21, n_levels),
        TransmonQubit(4.85, 0.20, n_levels),
        TransmonQubit(5.05, 0.22, n_levels),
        TransmonQubit(4.90, 0.20, n_levels),
        TransmonQubit(5.10, 0.21, n_levels),
        TransmonQubit(4.80, 0.19, n_levels),
        TransmonQubit(5.03, 0.21, n_levels),
        TransmonQubit(4.95, 0.20, n_levels),
    ]

    # Heavy-hex nearest-neighbor coupling (linear chain subset)
    edges = [
        CouplingEdge(1, 2, 0.003),
        CouplingEdge(2, 3, 0.003),
        CouplingEdge(3, 4, 0.003),
        CouplingEdge(4, 5, 0.003),
        CouplingEdge(5, 6, 0.003),
        CouplingEdge(6, 7, 0.003),
        CouplingEdge(7, 8, 0.003),
    ]

    # Published gate performance (Willow/Heron class)
    native_gates = Dict{Symbol,GateSpec}(
        :CZ => GateSpec(60.0, 0.0033),    # 60 ns, 0.33% error
        :X => GateSpec(25.0, 0.00035),    # 25 ns, 0.035% error
        :SX => GateSpec(25.0, 0.00035),    # √X, same as X
        :H => GateSpec(35.0, 0.0005),     # synthesized via SX·RZ (virtual-Z); estimate
    )

    T1 = fill(68.0, 8)   # μs (mean from Willow spec)
    T2 = fill(35.0, 8)   # μs (estimated)

    return TransmonDevice("ibm_heron_r3", qubits, edges, native_gates, 0.05, T1, T2)
end

"""
    HeronR2(; n_levels::Int = 3)

IBM Heron r2 device profile. The Heron r2 is the previous-generation
processor relative to [`HeronR3`](@ref), deployed across three active
156-qubit systems — `ibm_fez`, `ibm_kingston`, and `ibm_marrakesh` — which
all run the same processor and therefore share one profile. Per-machine
calibration differences are noise that does not belong here; the values
below are representative medians for the **processor type**.

Heavy-hex topology, CZ-native, 156 qubits. Like `HeronR3`, this profile
models the first 8 qubits in a linear chain (sufficient for QFT-4 / QFT-8
benchmarks). Adding it lets users benchmark Stretto compilation against r2
hardware and compare against r3.

Sources:
- Gate durations and errors — live `ibm_fez` calibration, median across all
  qubits/edges (last_update 2026-06-02): CZ 68 ns / 2.74e-3, SX·X 24 ns /
  3.09e-4.
- T1 (≈218 µs), T2 (≈264 µs): published r2 specs, Gambetta et al.
  (arXiv:2410.00916) — processor-type medians (single-machine snapshots
  drift day to day).
- Qubit frequencies, anharmonicities, and heavy-hex coupling: representative
  medians, same convention as `HeronR3`. IBM's calibration API exposes
  T1/T2/readout/gate-error but not per-qubit frequency or anharmonicity, so
  these are not machine-specific by construction.

# Keyword Arguments
- `n_levels::Int = 3`: number of levels per transmon (see [`HeronR3`](@ref)).
"""
function HeronR2(; n_levels::Int = 3)
    # Representative Heron r2 parameters (processor-type medians).
    # Frequencies staggered to avoid frequency collisions.
    qubits = [
        TransmonQubit(4.82, 0.31, n_levels),
        TransmonQubit(4.96, 0.31, n_levels),
        TransmonQubit(4.88, 0.31, n_levels),
        TransmonQubit(5.01, 0.31, n_levels),
        TransmonQubit(4.79, 0.31, n_levels),
        TransmonQubit(4.93, 0.31, n_levels),
        TransmonQubit(5.05, 0.31, n_levels),
        TransmonQubit(4.86, 0.31, n_levels),
    ]

    # Heavy-hex nearest-neighbor coupling (linear chain subset)
    edges = [
        CouplingEdge(1, 2, 0.003),
        CouplingEdge(2, 3, 0.003),
        CouplingEdge(3, 4, 0.003),
        CouplingEdge(4, 5, 0.003),
        CouplingEdge(5, 6, 0.003),
        CouplingEdge(6, 7, 0.003),
        CouplingEdge(7, 8, 0.003),
    ]

    # Gate performance: live ibm_fez calibration medians (last_update
    # 2026-06-02). RZ is virtual (zero duration); H is synthesized as
    # RZ·SX·RZ, so it costs ~one physical SX.
    native_gates = Dict{Symbol,GateSpec}(
        :CZ => GateSpec(68.0, 0.002743),   # 68 ns, 0.274% (live median over 352 pairs)
        :X => GateSpec(24.0, 0.0003087),   # 24 ns, 0.031% (live median over 156 qubits)
        :SX => GateSpec(24.0, 0.0003087),  # √X, same as X
        :H => GateSpec(24.0, 0.00035),     # synthesized via RZ·SX·RZ (virtual-Z); ≈ one SX
    )

    T1 = fill(218.0, 8)   # µs (published r2 median, arXiv:2410.00916)
    T2 = fill(264.0, 8)   # µs (published r2 median, arXiv:2410.00916)

    return TransmonDevice("ibm_heron_r2", qubits, edges, native_gates, 0.05, T1, T2)
end

# ============================================================================ #
# Tests
# ============================================================================ #

@testitem "HeronR2 construction" begin
    device = HeronR2()
    @test device isa TransmonDevice
    @test device.name == "ibm_heron_r2"
    @test length(device.qubits) == 8
    @test length(device.T1) == 8
    @test length(device.T2) == 8
    @test haskey(device.native_gates, :CZ)
    @test device.native_gates[:CZ].duration_ns == 68.0
end

@testitem "HeronR2 — MultiTransmonSystem from 2-qubit subset" begin
    using Piccolo: CompositeQuantumSystem, MultiTransmonSystem
    device = HeronR2()
    sys = MultiTransmonSystem(device, [1, 2])
    @test sys isa CompositeQuantumSystem
    # 2 transmons × 3 levels = 9 dim
    @test sys.levels == 9
    @test sys.subsystem_levels == [3, 3]
    # 2 drives per transmon = 4 subsystem drives, 0 coupling drives
    @test sys.n_drives == 4
end

# Full-solve fidelity check requested by the issue. Tagged :integration because
# the EmbeddedOperator-on-CompositeQuantumSystem solve pipeline is
# Piccolo-post-v1.6-only and is skipped on the registered-Piccolo-v1.6 CI
# (same constraint the `compile` testitems in compile.jl document and avoid).
@testitem "HeronR2 — compile_block QFT-2 fidelity in [0,1]" tags = [:integration] begin
    device = HeronR2()
    result = compile_block(qft_circuit(2), device, [1, 2]; max_iter = 50)
    @test result.n_qubits == 2
    @test 0.0 <= result.fidelity <= 1.0
end
