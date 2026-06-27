"""
    classify_problem(circuit, device) -> Symbol

Return a problem-class label for dispatch. Substrate: `:generic` for every input.
Strategies' `matches` functions may call this for dispatch shortcuts.

This is a codebase-wide free function (seam #5), not a per-strategy field —
one classifier per deployment. Richer classification is Strettissimo's concern.
"""
classify_problem(circuit, device) = _CLASSIFY_PROBLEM[](circuit, device)

_substrate_classify_problem(circuit, device) = :generic

const _CLASSIFY_PROBLEM = Ref{Any}(_substrate_classify_problem)

"""
    set_classify_problem!(f)

Install `f` as the classifier. `f` must have signature
`(circuit, device) -> Symbol`.
"""
set_classify_problem!(f) = (_CLASSIFY_PROBLEM[] = f)

@testitem "classify_problem — substrate returns :generic" begin
    using Legato

    device = HeronR3()
    circuit = GateCircuit([GateOp(:H, (1,))], 1)

    @test Legato.classify_problem(circuit, device) === :generic
end
