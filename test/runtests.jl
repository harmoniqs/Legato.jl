using TestItemRunner

# External-cloner / Piccolo-only CI filter: skip tests that need Piccolissimo or
# that are slow (:integration). Full internal CI and `Pkg.test` with
# Piccolissimo loaded should override this by passing a broader filter.
const FULL_TESTS = get(ENV, "LEGATO_FULL_TESTS", "") == "1"

if FULL_TESTS
    @run_package_tests
else
    @run_package_tests filter =
        ti -> !(:piccolissimo in ti.tags) && !(:integration in ti.tags)
end
