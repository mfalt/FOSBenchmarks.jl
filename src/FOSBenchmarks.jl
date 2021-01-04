module FOSBenchmarks

using Distributed
using FirstOrderSolvers, Convex, ProximalOperators, Random, Printf
# import FirstOrderSolvers: Feasibility

function solve1(prob::Feasibility, args...; kwargs...)
    sol, model = FirstOrderSolvers.solve!(prob, args...; kwargs...)
    return sol.status, model.enditr
end

function solve1(prob::Convex.Problem, args...; kwargs...)
    Convex.solve!(prob, args...; kwargs...)
    return prob.model.solve_stat, prob.model.enditr
end

function DR_solvers()
    [(DR,
        [(),]),
    ]
end

function GAP_solvers()
    [
    (GAP, 
        [
        #  (0.8, 1.8, 1.8),
        #  (0.8, 1.5, 1.5),
         (1.0, 1.0, 1.0)]), # AP
    (GAPA,
        [(1.0,0.0,0.0), # Standard
         (1.0,0.5,0.0), # Average with 2
        #  (1.0,0.0,0.8), # Damping
        #  (0.75,0.75,0.0), # Mostly DR
        #  (0.75,0.25,0.0), # Mostly GAPA
        #  (1.0,0.75,0.0), # Mostly DR
        #  (1.0,0.25,0.0), # Mostly GAPA
         (1.0,0.5,0.8),], # Damped average
     ) 
    ]
end

function prob1()
    Random.seed!(2)
    xsol1 = randn(100)
    A = randn(50,100)
    b = A*xsol1
    S1 = IndAffine(A,b)
    S2 = IndBox(0.0, Inf)
    Feasibility(S1, S2, 100)
end

# function include_everywhere(filepath)
#     fullpath = joinpath(@__DIR__, filepath)
#     @sync for p in procs()
#         @async remotecall_wait(include, p, fullpath)
#     end
# end


include("problems/youla.jl")
youla1(;N = 40, N_t = 300, N_f = 150, smax=1.6) = youlaProblem(problem=1, N = 40, N_t = 300, N_f = 150, smax=1.6)[1]
youla2(;N = 40, N_t = 300, N_f = 150, smax=1.6) = youlaProblem(problem=2, N = 40, N_t = 300, N_f = 150, smax=1.6)[1]
youla3(;N = 40, N_t = 300, N_f = 150, smax=1.6) = youlaProblem(problem=3, N = 40, N_t = 300, N_f = 150, smax=1.6)



function benchmarkProblem(prob)
    all_solvers = [DR_solvers()...,GAP_solvers()...]
    sols = []
    for (soli, solvers) in enumerate(all_solvers)
        sol_fun = solvers[1]
        sol_args = solvers[2]
        for (argi, args) in enumerate(sol_args)
            # If containt kwargs
            solver = if args isa Tuple{<:Tuple, Tuple{Vararg{<:Pair}}}
                sol_fun(args[1]...; args[2]..., eps=1e-3, direct=false, verbose=1, checki=10, max_iters=2000)
            else
                sol_fun(args..., eps=1e-3, direct=false, verbose=1, checki=10, max_iters=2000)
            end
            
            
            println("Solver:", solver)
            t0 = time_ns()
            status, iters = solve1(prob, solver)
            t = time_ns() - t0

            push!(sols, (soli, argi, t, status, iters))
        end
    end
    return sols
end

function benchmark()
    all_problems = [prob1,
                    youla1,youla2,youla3,
                    (;kwargs...) -> youla1(smax=2.0;kwargs...),
                    (;kwargs...) -> youla3(smax=2.0;kwargs...),
                    (;kwargs...) -> youla3(smax=2.0;kwargs...)]
    problems = [problem() for problem in all_problems]
    all_sols = []
    for prob in problems
        println("Problem:", prob)
        prb_sols = benchmarkProblem(prob)
        push!(all_sols, prb_sols)
    end
    all_sols
end

function performance_values(all_sols)
    n_probs = length(all_sols)
    n_algs = length(all_sols[1])

    # Get fastest of solutions
    t_mins = Array{Float64,1}(undef, n_probs)
    t_maxs = Array{Float64,1}(undef, n_probs)
    ratios = Array{Float64,2}(undef, n_probs, n_algs)
    for (pi,prob_sols) in enumerate(all_sols)
        ps_solved = filter(ps -> ps[4] == :Optimal,prob_sols)
        t_mins[pi] = minimum(getindex.(ps_solved, 3))
        t_maxs[pi] = maximum(getindex.(ps_solved, 3))
    end
    fail_mult = 10
    max_ratio = maximum(t_maxs./t_mins)
    for (pi,prob_sols) in enumerate(all_sols)
        for (ai, alg) in enumerate(prob_sols)
            if alg[4] == :Optimal
                ratios[pi,ai] = alg[3]/t_mins[pi]
            else
                ratios[pi,ai] = fail_mult*max_ratio
            end
        end
    end
    sorted_ratios = sort(ratios, dims=1)
    rat_x = 10 .^range(0, length=100, stop=log10(fail_mult*max_ratio)+eps())
    perf_values = Array{Float64,2}(undef, length(rat_x), n_algs)
    for ai in 1:n_algs
        for (ri,ratio) in enumerate(rat_x)
            perf_values[ri,ai] = count(ratios[:,ai] .<= ratio)/n_probs
        end
    end
    return rat_x, perf_values, ratios 
end

# function plot_perf_values(rat_x, perf_values)
#     rat_x_ticks = [rat_x[1:10:end-1]...;rat_x[end]]
#     xformatted = vcat([@sprintf("%.1F", x) for x in rat_x_ticks[1:end-1]]..., "Fail")
#     plot(rat_x, perf_values, xscale=:log10, xlims=(1,maximum(rat_x)), ylabel="Fraction of problems", xlabel="Time relative to best", xticks=(rat_x_ticks, xformatted))
# end

end # module
