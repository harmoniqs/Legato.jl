"""
A qubit on a transmon device with its physical parameters.
"""
struct TransmonQubit
    ω::Float64    # frequency (GHz)
    δ::Float64    # anharmonicity (GHz), positive convention (Piccolo subtracts)
    n_levels::Int # number of levels (typically 3)
end

"""
A coupling edge between two qubits on a transmon device.
"""
struct CouplingEdge
    i::Int         # qubit index (1-based)
    j::Int         # qubit index (1-based)
    g::Float64     # coupling strength (GHz)
end

"""
Published performance data for a native gate on the device.
"""
struct GateSpec
    duration_ns::Float64
    error_rate::Float64
end

"""
    AbstractDevice

Base type for all hardware device profiles. Subtypes carry the physical
parameters needed to build a Piccolo quantum system for any qubit subset.
"""
abstract type AbstractDevice end

"""
    TransmonDevice <: AbstractDevice

A superconducting transmon device profile. Holds the device-level
information (qubit frequencies, couplings, published gate specs, T1/T2)
that doesn't belong in a Piccolo `QuantumSystem` itself but is needed to
build one for any subset of qubits.
"""
struct TransmonDevice <: AbstractDevice
    name::String
    qubits::Vector{TransmonQubit}
    edges::Vector{CouplingEdge}
    native_gates::Dict{Symbol,GateSpec}
    drive_max::Float64                   # max drive amplitude (GHz)
    T1::Vector{Float64}                  # T1 per qubit (μs)
    T2::Vector{Float64}                  # T2 per qubit (μs)
end

"""Return subsystem levels for a qubit subset of a device."""
subsystem_levels(device::TransmonDevice, qubit_indices) =
    [device.qubits[i].n_levels for i in qubit_indices]

"""
    MultiTransmonSystem(device::TransmonDevice, qubit_indices::AbstractVector{Int}; kwargs...)

Build Piccolo's `MultiTransmonSystem` (a `CompositeQuantumSystem`) for a
subset of qubits on a transmon device. Wraps Piccolo's native constructor
with device-level plumbing: pulls frequencies/anharmonicities from the
selected qubits, builds a symmetric coupling matrix from `device.edges`,
and uses Piccolo's `subsystems` keyword for the qubit slice.

The returned composite preserves subsystem structure (`subsystem_levels`,
`subsystems`), so downstream code can use `EmbeddedOperator(U, composite)`
without re-deriving the level layout.
"""
function Piccolo.MultiTransmonSystem(
    device::TransmonDevice,
    qubit_indices::AbstractVector{Int};
    lab_frame::Bool = false,
    kwargs...,
)
    N = length(device.qubits)
    ωs = Float64[q.ω for q in device.qubits]
    δs = Float64[q.δ for q in device.qubits]

    # Full N×N symmetric coupling matrix
    gs = zeros(Float64, N, N)
    for edge in device.edges
        gs[edge.i, edge.j] = edge.g
        gs[edge.j, edge.i] = edge.g
    end

    # Assume uniform levels (enforced by typical device profiles)
    levels = device.qubits[first(qubit_indices)].n_levels

    return MultiTransmonSystem(
        ωs,
        δs,
        gs;
        drive_bounds = device.drive_max,
        levels_per_transmon = levels,
        subsystems = collect(qubit_indices),
        subsystem_drive_indices = collect(qubit_indices),
        lab_frame = lab_frame,
        kwargs...,
    )
end

# ============================================================================ #
# Tests
# ============================================================================ #

@testitem "HeronR3 construction" begin
    device = HeronR3()
    @test device isa TransmonDevice
    @test device.name == "ibm_heron_r3"
    @test length(device.qubits) >= 4
end

@testitem "HeronR2 construction" begin
    device = HeronR2()
    @test device isa TransmonDevice
    @test device.name == "ibm_heron_r2"
    @test length(device.qubits) == 8
    @test length(device.edges) == 7
    @test length(device.T1) == 8
    @test length(device.T2) == 8
    @test all(q.n_levels == 3 for q in device.qubits)
    @test device.T1 == fill(218.0, 8)
    @test device.T2 == fill(264.0, 8)
    @test device.native_gates[:CZ].duration_ns == 68.0
    @test device.native_gates[:CZ].error_rate == 0.002848
    @test Set(keys(device.native_gates)) == Set([:CZ, :X, :SX, :H])
end

@testitem "HeronR2 n_levels keyword" begin
    device = HeronR2(n_levels = 2)
    @test all(q.n_levels == 2 for q in device.qubits)
    @test Legato.subsystem_levels(device, [1, 2]) == [2, 2]
end

@testitem "HeronR2 compiles a 2-qubit block" tags = [:integration] begin
    using Legato
    device = HeronR2(n_levels = 2)
    result = compile_block(
        qft_circuit(2),
        device,
        [1, 2];
        max_iter = 2,
        T_ns = 20.0,
        N_knots = 5,
    )
    @test result isa Legato.BlockResult
    @test result.n_qubits == 2
    @test 0.0 <= result.fidelity <= 1.0
end

@testitem "MultiTransmonSystem from 2-qubit subset" begin
    using Piccolo: CompositeQuantumSystem, MultiTransmonSystem
    device = HeronR3()
    sys = MultiTransmonSystem(device, [1, 2])
    @test sys isa CompositeQuantumSystem
    # 2 transmons × 3 levels = 9 dim
    @test sys.levels == 9
    @test sys.subsystem_levels == [3, 3]
    # 2 drives per transmon = 4 subsystem drives, 0 coupling drives
    @test sys.n_drives == 4
end

@testitem "subsystem_levels accessor" begin
    device = HeronR3()
    @test Legato.subsystem_levels(device, [1, 2]) == [3, 3]
end
