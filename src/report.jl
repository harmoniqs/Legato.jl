"""
Gate-level baseline computed from device specs (no optimization).
"""
struct GateLevelBaseline
    total_duration_ns::Float64
    total_error::Float64
    n_gates::Int
end

"""
    gate_level_baseline(circuit, device)

Compute gate-level performance from published error rates.
Duration = sum of gate durations (serial, no parallelism in v0.1).
Error ≈ 1 - product of gate fidelities.
"""
function gate_level_baseline(circuit::GateCircuit, device::TransmonDevice)
    total_dur = 0.0
    total_fid = 1.0

    for op in circuit.ops
        gate = op.gate
        # Look up native gate spec, or estimate
        if haskey(device.native_gates, gate)
            spec = device.native_gates[gate]
            total_dur += spec.duration_ns
            total_fid *= (1.0 - spec.error_rate)
        elseif gate == :H
            # H ≈ 2 single-qubit gates cost
            sx = get(device.native_gates, :SX, GateSpec(25.0, 0.00035))
            total_dur += 2 * sx.duration_ns
            total_fid *= (1.0 - sx.error_rate)^2
        elseif haskey(EXTRA_GATES, gate) || haskey(GATE_ALIASES, gate)
            # Controlled-phase, Toffoli-class, or alias — decomposition estimate
            cz = get(device.native_gates, :CZ, GateSpec(60.0, 0.0033))
            sx = get(device.native_gates, :SX, GateSpec(25.0, 0.00035))
            if length(op.qubits) == 2
                # ~1 CZ + 2 single-qubit
                total_dur += cz.duration_ns + 2 * sx.duration_ns
                total_fid *= (1.0 - cz.error_rate) * (1.0 - sx.error_rate)^2
            elseif length(op.qubits) == 3
                # Toffoli-class: standard decomposition ~6 CX + 10 single-qubit
                total_dur += 6 * cz.duration_ns + 10 * sx.duration_ns
                total_fid *= (1.0 - cz.error_rate)^6 * (1.0 - sx.error_rate)^10
            else
                total_dur += sx.duration_ns
                total_fid *= (1.0 - sx.error_rate)
            end
        else
            # Unknown gate — use single-qubit estimate
            sx = get(device.native_gates, :SX, GateSpec(25.0, 0.00035))
            total_dur += sx.duration_ns
            total_fid *= (1.0 - sx.error_rate)
        end
    end

    total_error = 1.0 - total_fid
    return GateLevelBaseline(total_dur, total_error, length(circuit.ops))
end

"""
Full compilation report: gate-level baseline vs pulse-level result.
"""
struct CompilationReport
    circuit_name::String
    device_name::String
    n_qubits::Int

    # Gate-level baseline
    gate_duration_ns::Float64
    gate_error::Float64
    gate_n_gates::Int

    # Pulse-level result
    pulse_fidelity::Float64
    pulse_duration_ns::Float64
    pulse_error::Float64
end

function CompilationReport(
    circuit::AbstractCircuit,
    device::AbstractDevice,
    block::BlockResult,
    baseline::GateLevelBaseline,
)
    name = "$(circuit.n_qubits)Q circuit ($(length(circuit)) gates)"
    return CompilationReport(
        name,
        device.name,
        circuit.n_qubits,
        baseline.total_duration_ns,
        baseline.total_error,
        baseline.n_gates,
        block.fidelity,
        duration(block.pulse),
        1.0 - block.fidelity,
    )
end

function Base.show(io::IO, r::CompilationReport)
    dur_ratio = r.gate_duration_ns / max(r.pulse_duration_ns, 1e-10)
    err_ratio = r.gate_error / max(r.pulse_error, 1e-15)
    println(io, "")
    println(io, "Legato Compilation Report")
    println(io, "Circuit: $(r.circuit_name) ($(r.n_qubits)Q)  │  Target: $(r.device_name)")
    println(io, "─" ^ 58)
    println(io, "                  Gate-Level     Pulse-Level    Improvement")
    @printf(
        io,
        "Duration         %8.1f ns    %8.1f ns       %4.1f×\n",
        r.gate_duration_ns,
        r.pulse_duration_ns,
        dur_ratio
    )
    @printf(
        io,
        "Fidelity          %8.4f%%     %8.4f%%       %4.1f× error\n",
        (1-r.gate_error)*100,
        r.pulse_fidelity*100,
        err_ratio
    )
    @printf(io, "Gates                  %3d        — (1 pulse)\n", r.gate_n_gates)
    println(io, "─" ^ 58)
end

# ============================================================================ #
# Tests
# ============================================================================ #

@testitem "gate_level_baseline — H→CZ on HeronR3" begin
    device = HeronR3()
    circuit = GateCircuit([GateOp(:H, (1,)), GateOp(:CZ, (1, 2))], 2)
    baseline = gate_level_baseline(circuit, device)

    @test baseline.total_duration_ns > 0.0
    @test 0.0 < baseline.total_error < 1.0
    @test baseline.n_gates == 2
end

@testitem "CompilationReport display" begin
    # Construct a report directly (no compile) to keep the test fast.
    report = Legato.CompilationReport(
        "2Q circuit (2 gates)",  # circuit_name
        "ibm_heron_r3",            # device_name
        2,                          # n_qubits
        110.0,                      # gate_duration_ns
        0.004,                      # gate_error
        2,                          # gate_n_gates
        0.95,                       # pulse_fidelity
        200.0,                      # pulse_duration_ns
        0.05,                       # pulse_error
    )

    buf = IOBuffer()
    show(buf, report)
    output = String(take!(buf))
    @test occursin("Legato", output)
    @test occursin("Duration", output)
end
