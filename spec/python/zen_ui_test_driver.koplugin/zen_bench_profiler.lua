-- Opt-in sampling profiler (jit.profile, 1 ms) collecting folded stacks.
-- Also installed as an early userpatch so ZEN_UI_BENCH_JITP=startup covers plugin loading.
-- The sampling timer only runs between start/stop: forked children (CoverBrowser) must not inherit it.
local P = rawget(_G, "__ZEN_BENCH_PROFILER")
if P then return P end
local profile = require("jit.profile")
P = { counts = {}, running = false }

function P.start()
    if P.running then return end
    P.running = true
    profile.start("i1", function(thread, samples)
        local stack = profile.dumpstack(thread, "pl;", -40)
        P.counts[stack] = (P.counts[stack] or 0) + samples
    end)
end

function P.stop()
    if not P.running then return end
    P.running = false
    profile.stop()
end

function P.write(path)
    local file = assert(io.open(path, "w"))
    for stack, samples in pairs(P.counts) do
        file:write((stack:gsub(";$", "")), " ", samples, "\n")
    end
    file:close()
end

rawset(_G, "__ZEN_BENCH_PROFILER", P)
if os.getenv("ZEN_UI_BENCH_JITP") == "startup" then P.start() end
return P
