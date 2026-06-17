using FFTW


    #pulse_spectrum(pulse; n_samples=1000)

#Computes the one-sided power spectrum of a given pulse using FFT.
#Returns `(freq_GHz, power_matrix)`, where `power_matrix` is an 
#N_channels × N_freq matrix containing the spectral energy for each drive channel.

function pulse_spectrum(pulse; n_samples=1000)
    controls, times = Piccolo.sample(pulse; n_samples=n_samples)
    
    # Handle both vector (single channel) and matrix (multi-channel) pulse shapes safely
    if controls isa AbstractVector
        controls = reshape(controls, 1, length(controls))
    elseif size(controls, 1) == length(times) && size(controls, 2) != length(times)
        controls = transpose(controls)
    end
    
    n_channels = size(controls, 1)
    n = length(times)
    
    # Extract sample interval dt in nanoseconds
    dt_ns = (times[end] - times[1]) / (n - 1)
    
    # Pre-allocate a concretely typed Float64 matrix for type-stability
    fft_len = div(n, 2) + 1
    power_matrix = Matrix{Float64}(undef, n_channels, fft_len)
    
    for i in 1:n_channels
        # Compute one-sided FFT for real signals and assign in-place
        power_matrix[i, :] .= abs2.(rfft(controls[i, :]))
    end
    
    # Construct the one-sided positive frequency axis strictly in GHz
    freq_GHz = range(0.0, 1.0 / (2.0 * dt_ns), length=fft_len)
    
    return freq_GHz, power_matrix
end



   # default_post_process() -> Vector{Function}

#Return the ordered list of post-processing transforms applied after a block solve. Each entry has signature `(block_result, ctx::PostProcessContext) -> block_result'`.
#Substrate: empty list (no post-processing). Strategies may override with their own `post_process::Vector{Function}` via the CompilationStrategy struct; this seam is the codebase-wide default consulted only when no strategy is selected.

default_post_process() = _DEFAULT_POST_PROCESS[]()

_substrate_default_post_process() = Function[]

const _DEFAULT_POST_PROCESS = Ref{Any}(_substrate_default_post_process)

"""
    set_default_post_process!(f)

Install `f` as the substrate post-process builder. `f` must have signature
`() -> Vector{Function}`.
"""
set_default_post_process!(f) = (_DEFAULT_POST_PROCESS[] = f)


@testitem "PostProcessContext — basic construction" begin
    using Stretto
    using Piccolo: UnitaryTrajectory, CubicSplinePulse, QuantumSystem, SplinePulseProblem

    σz = ComplexF64[1 0; 0 -1];
    σx = ComplexF64[0 1; 1 0]
    sys = QuantumSystem(σz, [σx], [1.0])
    times = collect(range(0.0, 10.0, length = 5))
    pulse = CubicSplinePulse(
        zeros(1, 5),
        zeros(1, 5),
        times;
        initial_value = zeros(1),
        final_value = zeros(1),
    )
    qtraj = UnitaryTrajectory(sys, pulse, ComplexF64[1 0; 0 1])
    problem = SplinePulseProblem(qtraj; Q = 100.0)

    device = HeronR3()
    circuit = GateCircuit([GateOp(:H, (1,))], 1)

    ctx = Stretto.PostProcessContext(circuit, device, qtraj, problem)
    @test ctx.circuit === circuit
    @test ctx.device === device
    @test ctx.qtraj === qtraj
    @test ctx.problem === problem
end

@testitem "default_post_process — substrate is empty list" begin
    using Stretto

    pp = Stretto.default_post_process()
    @test pp isa Vector
    @test isempty(pp)
end