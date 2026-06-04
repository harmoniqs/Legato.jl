
# API

## Devices

```@autodocs
Modules = [Stretto]
Order = [:type, :function]
Pages = ["devices.jl", "profiles.jl"]
```

## Circuits

### OpenQASM 3 Input

Stretto can import the static unitary subset of [OpenQASM 3](https://openqasm.com/versions/3.0/index.html) that maps cleanly to `GateCircuit`:

```julia
qasm = """
OPENQASM 3;
include "stdgates.inc";
qubit[2] q;
h q[0];
cx q[0], q[1];
"""

circuit = from_qasm(qasm)
```

Parsing and static OpenQASM evaluation are handled by [Quasar.jl](https://github.com/kshyatt-aws/Quasar.jl). Stretto then lowers the resulting unitary instructions into `GateOp`s. Supported input includes qubit and `qreg` declarations, the official `stdgates.inc` gate names, constant numeric gate parameters, whole-register broadcasting, register ranges, custom gate definitions, static loops and conditionals, barriers, no-ops, gate modifiers that resolve to finite unitary matrices, and 0-based QASM qubit indices converted to Stretto's 1-based indices.

The gate list and syntax boundaries are anchored to these OpenQASM sources:

- [OpenQASM standard library](https://openqasm.com/language/standard_library.html) and its [RST source](https://openqasm.com/_sources/language/standard_library.rst.txt): `stdgates.inc` gate names and mathematical definitions. The gates used here are marked as added in OpenQASM 3.0.
- [OpenQASM 3.0 gates](https://openqasm.com/versions/3.0/language/gates.html): built-in unitary instructions `U` and `gphase`, gate calls, custom gates, gate modifiers, and broadcasting.
- [OpenQASM 3.0 grammar](https://openqasm.com/versions/3.0/grammar/index.html): statement categories such as gate calls, declarations, measurement, reset, calibration, timing, and control flow.
- [OpenQASM 3.0 language specification](https://openqasm.com/versions/3.0/index.html): top-level language reference.

Supported gate coverage:

- Fixed `stdgates.inc` gates: `id`, `h`, `x`, `y`, `z`, `s`, `sdg`, `sx`, `t`, `tdg`, `cx`, `CX`, `cy`, `cz`, `ch`, `swap`, `ccx`, and `cswap`.
- Constant-parameter `stdgates.inc` gates: `p`, `phase`, `rx`, `ry`, `rz`, `u1`, `u2`, `u3`, `cp`, `cphase`, `crx`, `cry`, `crz`, and `cu`.
- OpenQASM 3 built-in unitary instructions: `U` and `gphase`.
- Stretto compatibility names accepted in addition to the standard list: `cnot`, `toffoli`, and `ccz`.

Unsupported OpenQASM features fail with `ArgumentError` when they do not have a `GateCircuit` equivalent or would lose semantics during lowering: measurements, resets, dynamic measurement-dependent classical behavior, calibration/OpenPulse blocks, timing and `box` constructs, arbitrary include files, and non-integer gate-power modifiers.

```@autodocs
Modules = [Stretto]
Order = [:type, :function]
Pages = ["circuits.jl", "qasm.jl", "library.jl"]
```

## Compilation

```@autodocs
Modules = [Stretto]
Order = [:type, :function]
Pages = ["compile.jl", "report.jl"]
```
