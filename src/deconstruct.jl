using MacroTools, MonteCarloMeasurements
using MonteCarloMeasurements: ∓, ±

unsafe_comparisons()
# P = tf(1 ∓ 0.1, [1, 1∓0.1])


function has_particles(P)
    P isa AbstractParticles && (return true)
    P isa AbstractArray && (return has_particles(P[1]))
    any(fieldnames(typeof(P))) do n
        fp = getfield(P,n)
        if fp isa Union{AbstractArray, Tuple}
            return has_particles(fp[1]) # Specials can occur inside arrays or tuples
        else
            return has_particles(fp)
        end
    end
end

nakedtypeof(x::Type) = x.name.wrapper
nakedtypeof(x) = nakedtypeof(typeof(x))
build_mutable_container(P) = replace_particles(P, P->P isa AbstractParticles,result = P->Particles(Vector(P.particles)))
build_container(P) = replace_particles(P,P->P isa AbstractParticles,P->P[1])

function replace_particles(P,condition=P->P isa AbstractParticles,result = P->P[1])
    # @show typeof(P)
    condition(P) && (return result(P)) # This replaces a Special with a float
    has_particles(P) || (return P) # No need to carry on
    P isa Number && (return P)
    if P isa AbstractArray # Special handling for arrays
        return map(P->replace_particles(P,condition,result), P)
    end
    fields = map(fieldnames(typeof(P))) do n
        f = getfield(P,n)
        has_particles(f) || (return f)
        # @show typeof(f), n
        replace_particles(f,condition,result)
    end
    T = nakedtypeof(P)

    try
        return T(fields...)
    catch e
        @error("Failed to create a `$T` by calling it with its fields in order. For this to work, `$T` must have a constructor that accepts all fields in the order they appear in the struct and accept that the fields that contained particles are replaced by 0. Try defining a meaningful constructor that accepts arguments with the type signature \n`$(T)$(typeof.(fields))`\nThe error thrown by `$T` was ")
        rethrow(e)
    end

end

particletype(p::AbstractParticles{T,N}) where {T,N} = (T,N)
particletype(::Type{<:AbstractParticles{T,N}}) where {T,N} = (T,N)

function particle_paths(P, allpaths=[], path=[])
    T = typeof(P)
    if T <: AbstractParticles
        push!(allpaths, (path,particletype(T)...))
        return
    end
    for n in fieldnames(T)
        fp = getfield(P,n)
        FT = typeof(fp)
        if FT <: Union{AbstractArray, Tuple}
            particle_paths(fp[1], allpaths, [path; (n, FT, size(fp))])
        else
            particle_paths(fp, allpaths, [path; (n, FT, ())])
        end
    end
    ntuple(i->allpaths[i], length(allpaths))
end

function vecpartind2vec!(v, pv, j)
    for i in eachindex(v)
        v[i] = pv[i][j]
    end
end

function get_setter_funs(paths)
    exprs = map(paths) do p # for each encountered particle
        get1expr = :(P)
        set1expr = :(P2)
        for (i,(fn,ft,fs)) in enumerate(p[1][1:end-1]) # p[1] is a tuple vector where the first element in each tuple is the fieldname
            if ft <: AbstractArray
                # Here we should recursively branch down into all the elements, but this seems very complicated so we'll just access element 1 for now
                get1expr = :($(get1expr).$(fn)[1])
                set1expr = :($(set1expr).$(fn)[1])
            else # It was no array, regular field
                get1expr = :($(get1expr).$(fn))
                set1expr = :($(set1expr).$(fn))
            end
        end
        (fn,ft,fs) = p[1][end] # The last element, we've reached the particles
        if ft <: AbstractArray
            set1expr = :(vecpartind2vec!($(set1expr).$(fn), $(get1expr).$(fn), partind))
            # get1expr = :(getindex.($(get1expr).$(fn), partind))

        else # It was no array, regular field
            get1expr = :($(get1expr).$(fn)[partind])
            set1expr = :($(get1expr).$(fn)[partind] = $get1expr)
        end
        get1expr, set1expr
    end
    get1expr, set1expr = getindex.(exprs, 1), getindex.(exprs, 2)
    set1expr = Expr(:block, set1expr...)
    get1expr = Expr(:block, get1expr...)
    # get2expr = MacroTools.postwalk(get1expr) do x
    #     x == :P && (return :P2)
    #     x == :P2 && (return :P)
    #     x
    # end
    set2expr = MacroTools.postwalk(set1expr) do x
        x == :P && (return :P2res)
        x == :P2 && (return :Pres)
        @capture(x, vecpartind2vec!(y_,z_, partind)) && (return :(setindex!.($(y), $(z), partind)))
        x
    end
    # display(set1expr)
    # display(set2expr)

    @eval set1fun = (P,P2,partind)-> $set1expr
    @eval set2fun = (Pres,P2res,partind)-> $set2expr
    sleep(0.01)
    set1fun, set2fun

end

##
# We create a two-stage process with the outer function `withbuffer` and an inner macro with the same name. The reason is that the function generates an expression at *runtime* and this should ideally be compiled into the body of the function without a runtime call to eval. The macro allows us to do this


macro withbuffer(f,P,P2,setters,setters2,N)
    quote
        $(esc(:(partind = 1))) # Because we need the actual name partind
        $(esc(setters))($(esc(P)),$(esc(P2)), $(esc(:partind)))
        $(esc(:P2res)) = $(esc(f))($(esc(P2))) # We first to index 1 to peek at the result
        Pres = @unsafe f(P) # Heuristic, see what the result is if called with particles and unsafe_comparisons
        $(esc(setters2))(Pres,$(esc(:P2res)), $(esc(:partind)))
        for $(esc(:partind)) = 2:$(esc(N))
            $(esc(setters))($(esc(P)),$(esc(P2)), $(esc(:partind)))
            $(esc(:P2res)) = $(esc(f))($(esc(P2)))
            $(esc(setters2))(Pres,$(esc(:P2res)), $(esc(:partind)))
        end
        Pres
    end
end

@generated function withbufferg(f,P,P2,N,setters,setters2)
    ex = Expr(:block)
    push!(ex.args, quote
        partind = 1 # Because we need the actual name partind
    end)
    push!(ex.args, :(setters(P,P2,partind)))
    push!(ex.args, quote
        P2res = f(P2) # We first to index 1 to peek at the result
        Pres = @unsafe f(P)
    end) #build_result_container(paths, results[1])
    push!(ex.args, :(setters2(Pres,P2res,partind)))
    loopex = Expr(:block, :(setters(P,P2,partind)))
    push!(loopex.args, :(P2res = f(P2)))
    push!(loopex.args, :(setters2(Pres,P2res,partind)))
    push!(ex.args, quote
        for partind = 2:N
            $loopex
        end
    end)
    push!(ex.args, :Pres)
    ex

end



struct Workspace{T1,T2,T3,T4}
    P::T1
    P2::T2
    setters::T3
    setters2::T4
    N::Int
end
function Workspace(P)
    paths = particle_paths(P)
    P2 = build_container(P)
    setters, setters2 = get_setter_funs(paths)
    @assert all(n == paths[1][3] for n in getindex.(paths,3))
    N = paths[1][3]
    Workspace(P,P2,Pres,setters,setters2,N)
end


function (w::Workspace)(f)
    P,P2,setters,setters2,N = w.P,w.P2,w.setters,w.setters2,w.N
    @withbuffer(f,P,P2,setters,setters2,N)
    # withbufferg(f,P,P2,N,setters,setters2)
    # ex = @macroexpand @withbuffer(f,P,P2,setters,setters2,N)
    # display(prettify(ex))
end


##


##


@time eval(code)
@btime c2d($(tf(1,[1,1])),0.1)





##

function makeexpr(a)
    return :($a+1)
end

macro useexpr(ex)
    # :($(esc(ex)))
    Expr(:quote, :($(Expr(:$, :ex))))
    # :($(esc(QuoteNode(ex))))
    # :($(QuoteNode(ex)))
    # :($(QuoteNode(esc(ex))))
    # Expr(:$, :ex)
end

function runit(a)
    ex = makeexpr(a)
    @useexpr ex
end

runit(2)


function makefun(a)
    return @eval () -> $a+1
end

macro usefun(ex)
    :($(esc(ex))())
end

function runitfun(a)
    ex = makefun(a)
    @usefun ex
end

runitfun(2)
