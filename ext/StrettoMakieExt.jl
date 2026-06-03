module StrettoMakieExt

using Makie
using Stretto

function Stretto.plot_pulse_spectrum(
    pulse;
    n_samples::Integer = 1000,
    log_power::Bool = true,
    figure_kwargs = (;),
    axis_kwargs = (;),
    labels = nothing,
    kwargs...,
)
    freqs_GHz, power = Stretto.pulse_spectrum(pulse; n_samples)

    fig = Figure(; figure_kwargs...)
    ylabel = log_power ? "Power (log scale)" : "Power"
    yscale = log_power ? log10 : identity
    ax = Axis(fig[1, 1]; xlabel = "Frequency (GHz)", ylabel, yscale, axis_kwargs...)

    for drive in axes(power, 1)
        label = labels === nothing ? "drive $drive" : labels[drive]
        y = log_power ? max.(power[drive, :], eps(Float64)) : power[drive, :]
        lines!(ax, freqs_GHz, y; label, kwargs...)
    end

    if size(power, 1) > 1 || labels !== nothing
        axislegend(ax)
    end

    return fig
end

end
