module StrettoMakieExt

using Stretto
using Makie

function Stretto.plot_pulse_spectrum(pulse; n_samples=1000, kwargs...)
    freq_GHz, power_matrix = Stretto.pulse_spectrum(pulse; n_samples=n_samples)
    
    fig = Figure()
    ax = Axis(fig[1, 1], xlabel="Frequency (GHz)", ylabel="Power", yscale=log10)
    
    n_channels = size(power_matrix, 1)
    for i in 1:n_channels
        # Offset zero values by 1e-12 to prevent log10 domain mathematical errors
        lines!(ax, freq_GHz, max.(power_matrix[i, :], 1e-12); label="Channel $i", kwargs...)
    end
    
    if n_channels > 1
        axislegend(ax)
    end
    
    return fig
end

end