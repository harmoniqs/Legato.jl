#!/usr/bin/env julia
#
# Qiskit integration smoke test.
#
# Example setup with a local Python virtual environment:
#
#     python3 -m venv .venv-qiskit
#     .venv-qiskit/bin/python -m pip install qiskit
#     PYTHON=.venv-qiskit/bin/python julia --project=. scripts/qiskit_qasm_integration.jl
#
# Optional flags:
#
#     STRETTO_QISKIT_STRICT=1   # fail if Qiskit is missing instead of skipping
#     STRETTO_QISKIT_VERBOSE=1  # print the OpenQASM 3 emitted by Qiskit

using LinearAlgebra
using Test

const PYTHON = get(ENV, "PYTHON", "python3")
const STRICT = lowercase(get(ENV, "STRETTO_QISKIT_STRICT", "0")) in ("1", "true", "yes")
const STRETTO_MODULE = Ref{Module}()

const QISKIT_GENERATOR = raw"""
from math import pi
from pathlib import Path
import sys

try:
    from qiskit import QuantumCircuit, QuantumRegister, qasm3
except ModuleNotFoundError as exc:
    print(f"missing Python dependency: {exc}", file=sys.stderr)
    sys.exit(42)


def circuit(n_qubits):
    q = QuantumRegister(n_qubits, "q")
    return QuantumCircuit(q)


def dump(name, qc, out_dir):
    Path(out_dir, f"{name}.qasm").write_text(qasm3.dumps(qc), encoding="utf-8")


def main(out_dir):
    bell = circuit(2)
    bell.h(0)
    bell.cx(0, 1)
    dump("bell", bell, out_dir)

    fixed = circuit(3)
    fixed.id(0)
    fixed.h(0)
    fixed.x(0)
    fixed.y(0)
    fixed.z(1)
    fixed.s(2)
    fixed.sdg(2)
    fixed.sx(0)
    fixed.t(1)
    fixed.tdg(1)
    fixed.cx(0, 1)
    fixed.cy(0, 1)
    fixed.cz(0, 2)
    fixed.ch(1, 2)
    fixed.swap(0, 2)
    fixed.ccx(0, 1, 2)
    fixed.cswap(0, 1, 2)
    dump("fixed", fixed, out_dir)

    parameterized = circuit(2)
    parameterized.p(pi / 9, 0)
    parameterized.rx(pi / 2, 0)
    parameterized.ry(pi / 3, 0)
    parameterized.rz(pi / 4, 1)
    parameterized.u(pi / 2, 0, pi, 0)
    parameterized.cp(pi / 5, 0, 1)
    parameterized.crx(pi / 6, 0, 1)
    parameterized.cry(pi / 7, 0, 1)
    parameterized.crz(pi / 8, 0, 1)
    dump("parameterized", parameterized, out_dir)


if __name__ == "__main__":
    main(sys.argv[1])
"""

function run_qiskit_generator(out_dir::AbstractString)
    generator_path = joinpath(out_dir, "generate_qiskit_qasm.py")
    write(generator_path, QISKIT_GENERATOR)

    cmd = `$PYTHON $generator_path $out_dir`
    result = pipeline(cmd; stdout = stdout, stderr = stderr)
    try
        run(result)
    catch err
        if err isa ProcessFailedException && err.procs[1].exitcode == 42
            message = """
            Qiskit is not installed for `$PYTHON`, so the Qiskit -> OpenQASM 3 integration smoke test was skipped.

            Install it with:
                $PYTHON -m pip install qiskit

            To make a missing Qiskit dependency fail this script instead of skipping, run with:
                STRETTO_QISKIT_STRICT=1 julia --project=. scripts/qiskit_qasm_integration.jl
            """
            STRICT ? error(message) : (@warn message; return false)
        end
        rethrow()
    end

    return true
end

function read_qasm_case(out_dir::AbstractString, name::AbstractString)
    path = joinpath(out_dir, "$name.qasm")
    qasm = read(path, String)
    get(ENV, "STRETTO_QISKIT_VERBOSE", "0") == "1" && println("\n--- $name.qasm ---\n", qasm)
    return qasm
end

function load_stretto()
    if get(ENV, "STRETTO_QISKIT_INSTANTIATE", "1") == "1"
        @info "Instantiating Julia project dependencies before loading Stretto"
        @eval begin
            using Pkg
            Pkg.instantiate()
        end
    end

    try
        @eval using Stretto
        STRETTO_MODULE[] = @eval Stretto
    catch err
        error("""
        Could not load the local Stretto project.

        Instantiate the Julia project first, or leave automatic instantiation enabled:
            julia --project=. -e 'using Pkg; Pkg.instantiate()'

        Original error: $err
        """)
    end
end

op_signature(circuit) = [(op.gate, op.qubits) for op in circuit.ops]

function from_qasm_latest(qasm::AbstractString)
    return Base.invokelatest(getfield(STRETTO_MODULE[], :from_qasm), qasm)
end

function circuit_unitary_latest(circuit)
    return Base.invokelatest(getfield(STRETTO_MODULE[], :circuit_unitary), circuit)
end

function test_qiskit_qasm_cases(out_dir::AbstractString)
    @testset "Qiskit OpenQASM 3 export -> Stretto from_qasm" begin
        bell = from_qasm_latest(read_qasm_case(out_dir, "bell"))
        H = ComplexF64[1 1; 1 -1] / sqrt(2)
        CX = ComplexF64[
            1 0 0 0;
            0 1 0 0;
            0 0 0 1;
            0 0 1 0
        ]
        expected_bell = CX * kron(H, Matrix{ComplexF64}(I, 2, 2))
        @test bell.n_qubits == 2
        @test op_signature(bell) == [(:H, (1,)), (:CX, (1, 2))]
        @test circuit_unitary_latest(bell) ≈ expected_bell atol = 1e-12

        fixed = from_qasm_latest(read_qasm_case(out_dir, "fixed"))
        @test fixed.n_qubits == 3
        @test op_signature(fixed) == [
            (:ID, (1,)),
            (:H, (1,)),
            (:X, (1,)),
            (:Y, (1,)),
            (:Z, (2,)),
            (:S, (3,)),
            (:SDG, (3,)),
            (:SX, (1,)),
            (:T, (2,)),
            (:TDG, (2,)),
            (:CX, (1, 2)),
            (:CY, (1, 2)),
            (:CZ, (1, 3)),
            (:CH, (2, 3)),
            (:SWAP, (1, 3)),
            (:CCX, (1, 2, 3)),
            (:CSWAP, (1, 2, 3)),
        ]
        fixed_unitary = circuit_unitary_latest(fixed)
        @test fixed_unitary' * fixed_unitary ≈ I(8) atol = 1e-12

        parameterized = from_qasm_latest(read_qasm_case(out_dir, "parameterized"))
        @test parameterized.n_qubits == 2
        @test length(parameterized.ops) == 9
        @test all(startswith(String(op.gate), "QASM_") for op in parameterized.ops)
        @test [length(op.qubits) for op in parameterized.ops] == [1, 1, 1, 1, 1, 2, 2, 2, 2]
        parameterized_unitary = circuit_unitary_latest(parameterized)
        @test parameterized_unitary' * parameterized_unitary ≈ I(4) atol = 1e-10
    end
end

function main()
    mktempdir() do out_dir
        run_qiskit_generator(out_dir) || return 0
        load_stretto()
        test_qiskit_qasm_cases(out_dir)
    end
    return 0
end

exit(main())
