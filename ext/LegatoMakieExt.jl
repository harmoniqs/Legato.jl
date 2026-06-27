module LegatoMakieExt

using Legato
using Makie

using Piccolo: AbstractPulse

# Implementation of the stub in `src/post_process.jl` — extend the Legato
# function. Docstring lives on the stub.
function Legato.plot_pulse_spectrum(
    pulse::AbstractPulse;
    n_samples::Int = 1000,
    title = "Pulse power spectrum",
    kwargs...,
)
    freqs, power = pulse_spectrum(pulse; n_samples = n_samples)

    fig = Figure()
    ax = Axis(
        fig[1, 1];
        xlabel = "Frequency (GHz)",
        ylabel = "Power",
        yscale = log10,
        title = title,
        kwargs...,
    )

    # A log-scale axis cannot render exact zeros (e.g. an identically-zero
    # drive channel), so clamp to the smallest positive normal float.
    for k in axes(power, 1)
        lines!(ax, freqs, max.(power[k, :], floatmin(Float64)); label = "drive $k")
    end
    axislegend(ax)

    return fig
end

end # module
