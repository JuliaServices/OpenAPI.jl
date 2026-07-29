# Describes a Servo.Router's endpoints as OpenAPI: `OpenAPI.document(router)`
# builds the document statically, and `OpenAPI.register!(router)` additionally
# serves it from the running app at /openapi.json (making the endpoints
# discoverable by clients and by OpenAPI.read). Loads automatically when both
# OpenAPI and Servo are loaded.
module OpenAPIServoExt

using OpenAPI, Servo

# "application/json; charset=utf-8" -> "application/json" (media type keys in
# OpenAPI content maps are written without parameters)
basemime(fmt::Servo.Format) = String(strip(first(split(Servo.mime(fmt), ';'))))

# Best-effort response type: infer the return type of the endpoint's generated
# binder (which carries the full typed call, including keyword arguments),
# against a concrete do-nothing transport so inference is precise and does not
# depend on which real transports happen to be loaded. Reflectively-bound
# endpoints (GenericBinder) and abstract inference results report "unknown"
# rather than guessing.
struct InferenceRequest end
Servo.rawquery(::InferenceRequest) = Pair{String, String}[]
Servo.rawbody(::InferenceRequest) = UInt8[]

function inferresponse(ep::Servo.Endpoint)
    ep.binder isa Servo.GenericBinder && return nothing
    ts = try
        Base.return_types(ep.binder, Tuple{typeof(ep.format), Dict{Symbol, String}, InferenceRequest})
    catch
        return nothing
    end
    length(ts) == 1 || return nothing
    t = ts[1]
    (t === Union{} || t === Any || t <: Servo.Response) && return nothing
    return t
end

"""
    OpenAPI.operations(router::Servo.Router; skip=("openapi",)) -> Vector{OpenAPI.Operation}

Describe a router's endpoints as framework-neutral [`OpenAPI.Operation`](@ref)s:
path/query/body binding comes from each endpoint's `params`, the content type
from its `format`, the security flag from its auth scheme (`Public` or not), and
the response schema from best-effort return-type inference of its binder.
Endpoints whose name is in `skip` are omitted (by default the `/openapi.json`
discovery endpoint itself).
"""
function OpenAPI.operations(router::Servo.Router; skip=("openapi",))
    ops = OpenAPI.Operation[]
    for ep in router.endpoints
        ep.name in skip && continue
        params = OpenAPI.Param[]
        bodytype = nothing
        for p in ep.params
            if p.source == :path
                push!(params, OpenAPI.Param(string(p.name), :path, p.type))
            elseif p.source == :query
                push!(params, OpenAPI.Param(string(p.name), :query, p.type; required=p.required))
            else
                bodytype = p.type
            end
        end
        push!(ops, OpenAPI.Operation(;
            id=ep.name, method=ep.method, path=ep.path, params, bodytype,
            responsetype=inferresponse(ep), contenttype=basemime(ep.format),
            secured=!(ep.auth isa Servo.Public)))
    end
    return ops
end

OpenAPI.document(router::Servo.Router; skip=("openapi",), kw...) =
    OpenAPI.document(OpenAPI.operations(router; skip); kw...)

function OpenAPI.register!(router::Servo.Router; path::AbstractString="/openapi.json", kw...)
    # the document is built per request so it reflects the current route table
    target = () -> Servo.Response(200, OpenAPI.JSON.json(OpenAPI.document(router; kw...));
                                  headers=["Content-Type" => "application/json"])
    return Servo.register!(router, Servo.Endpoint(;
        name="openapi", method=:GET, path, target,
        auth=Servo.Public(), format=Servo.TextFormat()))
end

end # module
