"""
    AutoBody(sdf,map=(x,t)->x; compose=true) <: AbstractBody

  - `sdf(x::AbstractVector,t::Real)::Real`: signed distance function
  - `map(x::AbstractVector,t::Real)::AbstractVector`: coordinate mapping function
  - `compose::Bool=true`: Flag for composing `sdf=sdf∘map`

Implicitly define a geometry by its `sdf` and optional coordinate `map`. Note: the `map`
is composed automatically if `compose=true`, i.e. `sdf(x,t) = sdf(map(x,t),t)`.
Both parameters remain independent otherwise. It can be particularly heplful to set
`compose=false` when adding mulitple bodies together to create a more complex one.
"""
struct AutoBody{F1<:Function,F2<:Function} <: AbstractBody
    sdf::F1
    map::F2
    function AutoBody(sdf, map=(x,t)->x; compose=true)
        comp(x,t) = compose ? sdf(map(x,t),t) : sdf(x,t)
        new{typeof(comp),typeof(map)}(comp, map)
    end
end

"""
    AutoBodies(bodies, ops::AbstractVector)

  - `bodies::Vector{AbstractBody}`: Vector of AbstractBody
  - `ops::Vector{Function}`: Vector of operators for the superposition of multiple AutoBody

Superposes multiple `body::AutoBody` objects together according to the operators `ops`.
While this can be manually performed by the operators implemented for `AutoBody`, adding too many
bodies can yield a recursion problem of the `sdf and `map` functions.
This type implements the superposition of bodies by iteration instead of recursion. The operators vector `ops`
specifies the specific operation to call between to consecutive bodies in the vector of `bodies`.
"""
struct AutoBodies{F1<:Function} <: AbstractBody
    bodies::Vector{AutoBody}
    ops::Vector{F1}
    function AutoBodies(bodies, ops::AbstractVector)
        !all(x -> x==Base.:+ || x==Base.:-, ops) && ArgumentError("Operations array not supported. Use only + or -")
        length(bodies) != length(ops)+1 && ArgumentError("length(bodies) != length(ops)+1")
        new{eltype(ops)}(bodies, ops)
    end
end
AutoBodies(bodies) = AutoBodies(bodies,repeat([+],length(bodies)-1))
AutoBodies(bodies, op::Function) = AutoBodies(bodies,repeat([op],length(bodies)-1))

function Base.:+(a::AutoBody, b::AutoBody)
    map(x,t) = ifelse(a.sdf(x,t)<b.sdf(x,t),a.map(x,t),b.map(x,t))
    sdf(x,t) = min(a.sdf(x,t),b.sdf(x,t))
    AutoBody(sdf,map,compose=false)
end
function Base.:∩(a::AutoBody, b::AutoBody)
    map(x,t) = ifelse(a.sdf(x,t)>b.sdf(x,t),a.map(x,t),b.map(x,t))
    sdf(x,t) = max(a.sdf(x,t),b.sdf(x,t))
    AutoBody(sdf,map,compose=false)
end
Base.:∪(x::AutoBody, y::AutoBody) = x+y
Base.:-(x::AutoBody) = AutoBody((d,t)->-x.sdf(d,t),x.map,compose=false)
Base.:-(x::AutoBody, y::AutoBody) = x ∩ -y

"""
    d = sdf(body::AutoBody,x,t) = body.sdf(x,t)
"""
sdf(body::AutoBody,x,t) = body.sdf(x,t)
"""
    sdf_map_d(ab::AutoBodies,x,t)

Returns the `sdf` and `map` functions, and the distance `d` (`d=sdf(x,t)`) for `::AutoBodies`.
"""
function sdf_map_d(ab::AutoBodies,x,t)
    sdf, map, d = ab.bodies[1].sdf, ab.bodies[1].map, ab.bodies[1].sdf(x,t)
    for (i,b) ∈ enumerate(ab.bodies[2:end])
        if Base.:+ == ab.ops[i] && b.sdf(x,t) < d
            sdf, map = b.sdf, b.map
            d = sdf(x,t)
        elseif Base.:- == ab.ops[i] && -b.sdf(x,t) > d
            sdf, map = (d,t)->-b.sdf(d,t), b.map
            d = sdf(x,t)
        end
    end
    return sdf, map, d
end
sdf(bodies::AutoBodies,x,t) = sdf_map_d(bodies,x,t)[end]

using ForwardDiff
"""
    d,n,V = measure(body::AutoBody,x,t)
    d,n,V = measure(body::AutoBodies,x,t)

Determine the implicit geometric properties from the `sdf` and `map`.
The gradient of `d=sdf(map(x,t))` is used to improve `d` for pseudo-sdfs.
The velocity is determined _solely_ from the optional `map` function.
"""
measure(body::AutoBody,x,t) = measure(body.sdf,body.map,x,t)
function measure(bodies::AutoBodies,x,t)
    sdf, map, _ = sdf_map_d(bodies,x,t)
    measure(sdf,map,x,t)
end
function measure(sdf,map,x,t)
    # eval d=f(x,t), and n̂ = ∇f
    d = sdf(x,t)
    n = ForwardDiff.gradient(x->sdf(x,t), x)
    any(isnan.(n)) && return (d,zero(x),zero(x))

    # correct general implicit fnc f(x₀)=0 to be a pseudo-sdf
    #   f(x) = f(x₀)+d|∇f|+O(d²) ∴  d ≈ f(x)/|∇f|
    m = √sum(abs2,n); d /= m; n /= m

    # The velocity depends on the material change of ξ=m(x,t):
    #   Dm/Dt=0 → ṁ + (dm/dx)ẋ = 0 ∴  ẋ =-(dm/dx)\ṁ
    J = ForwardDiff.jacobian(x->map(x,t), x)
    dot = ForwardDiff.derivative(t->map(x,t), t)
    return (d,n,-J\dot)
end

using LinearAlgebra: tr
"""
    curvature(A::AbstractMatrix)

Return `H,K` the mean and Gaussian curvature from `A=hessian(sdf)`.
`K=tr(minor(A))` in 3D and `K=0` in 2D.
"""
function curvature(A::AbstractMatrix)
    H,K = 0.5*tr(A),0
    if size(A)==(3,3)
        K = A[1,1]*A[2,2]+A[1,1]*A[3,3]+A[2,2]*A[3,3]-A[1,2]^2-A[1,3]^2-A[2,3]^2
    end
    H,K
end
