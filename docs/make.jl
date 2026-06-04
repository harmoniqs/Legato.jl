using Pkg

Pkg.develop(PackageSpec(path = dirname(@__DIR__)))
Pkg.instantiate()

using Stretto
using PiccoloDocsTemplate

pages = ["Home" => "index.md", "Library" => "lib.md"]

generate_docs(
    @__DIR__,
    "Stretto",
    [Stretto],
    pages;
    make_literate = false,
    make_assets = false,
    format_kwargs = (canonical = "https://docs.harmoniqs.co/Stretto.jl",),
    versions = ["dev" => "dev", "stable" => "v^", "v#.#"],
)
