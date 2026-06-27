using Legato
using PiccoloDocsTemplate

pages = ["Home" => "index.md", "Library" => "lib.md"]

generate_docs(
    @__DIR__,
    "Legato",
    [Legato],
    pages;
    make_literate = false,
    make_assets = false,
    format_kwargs = (canonical = "https://docs.harmoniqs.co/Legato.jl",),
    versions = ["dev" => "dev", "stable" => "v^", "v#.#"],
)
