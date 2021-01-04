
# Script for starting remote workers, run before running the larger examples to
# initialize a large enough work pool

using Pkg
using Printf
using Distributed

# Where to find local dev packages
dev_dir = "/local/home/mattiasf/.julia/dev/"
# -------------------- SETUP OF MACHINES ---------------------------------
base_path = "/var/tmp/julia-mattiasf/"
depot_path = joinpath(base_path, ".julia")
project_path = joinpath(base_path, "project")
package_path = joinpath(base_path, "packages")
packages = ["Pkg", "Random", "LinearAlgebra", "JLD", "FirstOrderSolvers", "Convex", "ProximalOperators"]

local_LOAD_PATH = copy(LOAD_PATH)
# Need SSH key login with gitlab
local_packages = []#[("EventBasedParticleFiltering", "git@gitlab.control.lth.se:mattiasf/eventbasedparticlefiltering.git", "master")]
local_packages_spec = [PackageSpec(path=joinpath(package_path,p[1]),rev=p[3]) for p in local_packages]

dev_packages = ["FOSBenchmarks"]
dev_packages_spec = [PackageSpec(path=joinpath(package_path,p)) for p in dev_packages]
#machines = [("cloud-01", 24), ("cloud-02", 24), ("cloud-03", 24), ("cloud-04", 24)]
machines = [(@sprintf("cloud-%2.2d", i), 3) for i in 1:3]
#machines = vcat(machines, [(@sprintf("ktesibios-%2.2d", i), 7) for i in 1:12])
#machines = vcat(machines, [(@sprintf("ktesibios-%2.2d", i), 3) for i in 1:12])
#machines = [(@sprintf("philon-%2.2d", i), 4) for i in 1:12]
#machines = vcat(machines, [(@sprintf("ktesibios-%2.2d", i), 3) for i in 1:12])
#machines = [(@sprintf("cloud-%2.2d", i), 24) for i in 1:7]
#machines = [(@sprintf("cloud-%2.2d.control.lth.se", i), 24) for i in 1:7]

#machines = [("philon-01", 3)]

# Dirty-hack solution for spontanous errors that might occur when loading all
# those workers at the same time
tries = 5

remove_old_project_path = false
reset_local_project = true

## First check if anyone else is using the machines, and remove ones not connectable

calc_cpu = "awk '{u=\$2+\$4; t=\$2+\$4+\$5; if (NR==1){u1=u; t1=t;} else print (\$2+\$4-u1) * 100 / (t-t1) \"%\"; }' <(grep 'cpu ' /proc/stat) <(sleep 1;grep 'cpu ' /proc/stat)"

connection_error = []
for m in machines
    global connection_error
    printstyled("Checking machine $(m[1]):\n",bold=true,color=:magenta)
    try
        run(`ssh -q -t $(m[1]) who \&\& $calc_cpu \&\& nproc`)
    catch
        connection_error = vcat(connection_error, m[1])
    end
end

for m in connection_error
    global machines
    filter!(x -> x[1] != m, machines)
end

if !isempty(connection_error)
    println("Failed to conenct to the follwing machines:")
    for m in connection_error
        println("\t $(m)")
    end
end

## Instatiate the remote workers

if nprocs() == 1

    # Create a new package path to store packages
    empty!(DEPOT_PATH)
    push!(DEPOT_PATH, depot_path)

    ENV["PYTHON"] = "python"

    # Copying local dev packages
    printstyled("resetting dev packages:\n",bold=true,color=:magenta)
    for package in dev_packages
        run(`rm -rf $(package_path)/$(package)`) #overwrite
        run(`cp -r $(joinpath(dev_dir,package)) $(package_path)/$(package)`)
    end

    printstyled("Setting up local dev dirs:\n",bold=true,color=:magenta)
    for package in local_packages
        Pkg.add(PackageSpec(path=joinpath(package_path,package[1]),
            rev=package[3]))
    end

    printstyled("Downloading local packages:\n",bold=true,color=:magenta)
    for package in local_packages
        run(`rm -rf $(package_path)/$(package[1])`) #overwrite
        run(`git clone $(package[2]) $(package_path)/$(package[1]) --branch $(package[3])`)
    end

    # Reset local project
    if reset_local_project
        run(`rm -f $(joinpath(project_path,"Manifest.toml"))`)
        run(`rm -f $(joinpath(project_path,"Project.toml"))`)
    end

    # Setup local project
    printstyled("Setting up local project:\n",bold=true,color=:magenta)
    Pkg.activate(project_path)
    Pkg.add(packages)
    length(local_packages_spec) > 0 && Pkg.add(local_packages_spec)
    length(dev_packages_spec) > 0 && Pkg.add(dev_packages_spec)


    # Transfer the necessary scripts
    for m in machines
        printstyled("Copying project to $(m[1]):\n",bold=true,color=:magenta)
        if remove_old_project_path
            run(`ssh -q -t $(m[1]) rm -rf $project_path`)
        end
        run(`ssh -q -t $(m[1]) mkdir -p $project_path`)
        run(`ssh -q -t $(m[1]) rm -rf $package_path`) # Overwrite
        run(`scp $project_path/Manifest.toml $(m[1]):$project_path`)
        run(`scp $project_path/Project.toml $(m[1]):$project_path`)
        println("Transferring local packages")
        run(`scp -q -r $package_path $(m[1]):$package_path`)
    end

    # hacky solution to precompilation issues
    machines_pcmp = [(m[1], 1) for m in machines]
    machines_rest = [(m[1], m[2]-1) for m in machines]

    # Setup workers
    printstyled("Starting precompilation workers on each designated machine:\n"
            ,bold=true,color=:magenta)

    addprocs(machines_pcmp,topology=:master_worker,tunnel=true,
        dir=project_path, exename="/usr/bin/julia",
        max_parallel=24*length(machines))

    # Download, precompile and import required packages on cloud machines
    printstyled("Downloading and compiling required packages to worker sessions:\n"
        ,bold=true,color=:magenta)

    @everywhere empty!(DEPOT_PATH)
    @everywhere push!(DEPOT_PATH, $depot_path)

    @everywhere ENV["PYTHON"] = "python"

    count = 0
    while count < tries
        try
            @everywhere begin
                using Pkg
                Pkg.activate($project_path) #TODO Change this so that this operation is NOT done by every worker. Only needs to be done once on each machine!
                Pkg.instantiate()
                ps = vcat($packages, [p[1] for p in $local_packages], [p for p in $dev_packages])
                for i in ps
                    expr = :(using $(Symbol(i)))
                    eval(expr)
                end
            end
            break
        catch
            global count
            count += 1
            printstyled("Error occured, trying $(count) / $(tries)\n"
                ,bold=true,color=:red)
        end
    end

    printstyled("Starting rest of workers on each designated machine:\n"
            ,bold=true,color=:magenta)

    addprocs(machines_rest,topology=:master_worker,tunnel=true,
        dir=project_path, exename="/usr/bin/julia",
        max_parallel=12*length(machines))

    # Download, precompile and import required packages on cloud machines
    printstyled("Importing required packages to worker sessions:\n"
        ,bold=true,color=:magenta)

    # Set the DEPOT_PATH
    @everywhere empty!(DEPOT_PATH)
    @everywhere push!(DEPOT_PATH, $depot_path)

    # Use same LOAD_PATH as locally
    @everywhere empty!(LOAD_PATH)
    @everywhere append!(LOAD_PATH, $local_LOAD_PATH)

    @everywhere eval(:(using Pkg))
    @everywhere Pkg.offline(false)

    @everywhere ENV["PYTHON"] = "python"

    count = 0
    while count < tries
        try
            @everywhere begin
                using Pkg
                Pkg.activate($project_path) #TODO Change this so that this operation is NOT done by every worker. Only needs to be done once on each machine!
                Pkg.instantiate()
                ps = vcat($packages, [p[1] for p in $local_packages], [p for p in $dev_packages])
                for i in ps
                    expr = :(using $(Symbol(i)))
                    eval(expr)
                end
            end
            break
        catch
            global count
            count += 1
            printstyled("Error occured, trying $(count) / $(tries)\n"
                ,bold=true,color=:red)
        end
    end

    printstyled("Setup of workers on machines done!\n"
        ,bold=true,color=:magenta)

end
