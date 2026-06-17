using TestItemRunner
using Test
using Stretto

@testitem "Pulse Spectrum FFT Analysis" begin
    using Stretto
    using Test
    import Piccolo
    
    # Define a mock pulse strictly for FFT isolation testing
    struct MockPulse end

    # Overload Piccolo.sample to generate a strict 5 GHz signal over 100ns
    function Piccolo.sample(::MockPulse; n_samples=1000)
        times = collect(range(0, 100, length=n_samples))
        controls = reshape(sin.(2π * 5.0 .* times), 1, n_samples)
        return controls, times
    end

    pulse = MockPulse()
    freq_GHz, power_matrix = pulse_spectrum(pulse; n_samples=1000)
    
    # Extract the frequency corresponding to the peak power density
    max_idx = argmax(power_matrix[1, :])
    peak_freq = freq_GHz[max_idx]
    
    # Assert the peak strictly aligns with the injected 5.0 GHz signal
    @test isapprox(peak_freq, 5.0, atol=0.1)
end

# External-cloner / Piccolo-only CI filter: skip tests that need Piccolissimo or
# that are slow (:integration). Full internal CI and `Pkg.test` with
# Piccolissimo loaded should override this by passing a broader filter.
const FULL_TESTS = get(ENV, "STRETTO_FULL_TESTS", "") == "1"

if FULL_TESTS
    @run_package_tests
else
    @run_package_tests filter =
        ti -> !(:piccolissimo in ti.tags) && !(:integration in ti.tags)
end