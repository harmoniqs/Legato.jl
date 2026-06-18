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

IBM Heron r2 device profile for the ibm_fez, ibm_kingston, and
ibm_marrakesh processor family.

Heavy-hex topology, CZ-native, 156 qubits. This profile follows `HeronR3`
by modeling an 8-qubit linear subset for fast Stretto benchmarks. Published
processor-level values are used for CZ, T1, and T2. Qubit frequencies,
anharmonicities, and coupling strengths are representative values following
the existing profile convention, not machine-specific daily calibration data.

# Keyword Arguments
- `n_levels::Int = 3`: number of levels per transmon.
"""
function HeronR2(; n_levels::Int = 3)
    # Representative Heron r2 transmon parameters. Frequencies are staggered
    # to avoid collisions in the reduced 8-qubit benchmark subset.
    qubits = [
        TransmonQubit(4.95, 0.31, n_levels),
        TransmonQubit(4.82, 0.31, n_levels),
        TransmonQubit(5.02, 0.31, n_levels),
        TransmonQubit(4.88, 0.31, n_levels),
        TransmonQubit(5.08, 0.31, n_levels),
        TransmonQubit(4.78, 0.31, n_levels),
        TransmonQubit(5.00, 0.31, n_levels),
        TransmonQubit(4.90, 0.31, n_levels),
    ]

    # Heavy-hex nearest-neighbor coupling represented as the same 8-qubit
    # linear benchmark subset used by HeronR3.
    edges = [
        CouplingEdge(1, 2, 0.003),
        CouplingEdge(2, 3, 0.003),
        CouplingEdge(3, 4, 0.003),
        CouplingEdge(4, 5, 0.003),
        CouplingEdge(5, 6, 0.003),
        CouplingEdge(6, 7, 0.003),
        CouplingEdge(7, 8, 0.003),
    ]

    native_gates = Dict{Symbol,GateSpec}(
        :CZ => GateSpec(68.0, 0.002848),  # published Heron r2 median
        :X => GateSpec(36.0, 0.000324),   # representative single-qubit estimate
        :SX => GateSpec(36.0, 0.000324),  # representative single-qubit estimate
        :H => GateSpec(36.0, 0.0005),     # synthesized via SX/RZ for native rewrites
    )

    T1 = fill(218.0, 8)  # us, published Heron r2 median
    T2 = fill(264.0, 8)  # us, published Heron r2 median

    return TransmonDevice("ibm_heron_r2", qubits, edges, native_gates, 0.05, T1, T2)
end

""" 
    IQMEmerald()

IQM Emerald — Crystal 54 superconducting transmon QPU (54 qubits, square lattice).
Calibration data loaded from `src/data/iqm_emerald_2026-06-09.toml`.
T1, T2, gate fidelities from calibration 2026-06-09. Qubit frequencies and
coupling strengths estimated from arXiv:2603.11018; update TOML when
pulse-level access provides real values.
"""
function IQMEmerald()
    # Frequencies stagger 4.20/4.40 GHz (odd/even index); anharmonicity and
    # levels are uniform across all 54 qubits.
    qubits = [TransmonQubit(iseven(i) ? 4.40 : 4.20, 0.180, 3) for i = 1:54]

    cal = TOML.parsefile(joinpath(@__DIR__, "data", "iqm_emerald_2026-06-09.toml"))

    # cz_error and prx_error are read to validate their presence in the TOML;
    # neither field exists on CouplingEdge or TransmonQubit yet.
    edges = [CouplingEdge(e["i"], e["j"], e["g"]) for e in cal["edges"]]
    _ = [e["cz_error"] for e in cal["edges"]]
    _ = cal["prx_error"]

    native_gates = Dict{Symbol,GateSpec}(
        Symbol(k) => GateSpec(v["duration_ns"], v["error_rate"]) for
        (k, v) in cal["native_gates"]
    )

    return TransmonDevice(
        "iqm_emerald_crystal54",
        qubits,
        edges,
        native_gates,
        cal["drive_max"],
        Float64.(cal["t1"]),
        Float64.(cal["t2"]),
    )
end

@testitem "IQMEmerald — calibration data integrity" begin
    using Stretto
    device = IQMEmerald()
    @test isnan(device.T2[46])                           # QB46 T2 not measured → NaN
    @test length(device.edges) == 83                     # Crystal 54 topology
    @test device.T1[1] ≈ 46.38                          # spot-check: QB1 T1
    @test device.native_gates[:PRX].duration_ns ≈ 20.0  # PRX gate duration from TOML
    @test device.drive_max ≈ 0.100                       # drive_max from TOML
end
