"""
    OpenAPI.read(source) -> JSON.Object

Read and structurally validate an OpenAPI document. `source` may be:

- a JSON string (starts with `{`),
- a path to a `.json` file,
- an `http(s)://` URL (requires the HTTP package to be loaded) — e.g. the
  `/openapi.json` endpoint a Servo app exposes via [`OpenAPI.register!`](@ref).
"""
function read(source::AbstractString)
    s = strip(source)
    if startswith(s, "{")
        return parse(s)
    elseif startswith(s, "http://") || startswith(s, "https://")
        Base.get_extension(@__MODULE__, :OpenAPIHTTPExt) === nothing &&
            throw(ArgumentError("reading a document from a URL requires the HTTP package: `using HTTP`"))
        return parse(fetchurl(String(s)))
    elseif isfile(s)
        return parse(Base.read(String(s), String))
    else
        throw(ArgumentError("`source` is not a JSON document, an existing file, or a URL: $(first(s, 100))"))
    end
end

parse(s::AbstractString) = validate(JSON.parse(s))

"""
    OpenAPI.validate(doc) -> doc

Structural validation of an OpenAPI document (works on both parsed and
freshly-built documents): spec version, required `info` fields, `paths` shape,
known methods, and that every operation has responses with descriptions.
Throws `ArgumentError` on the first problem; returns the document otherwise.
"""
function validate(doc)
    doc isa JSON.Object || doc isa AbstractDict ||
        throw(ArgumentError("expected a JSON object document, got $(typeof(doc))"))
    v = get(doc, "openapi", nothing)
    v isa AbstractString && startswith(v, "3.") ||
        throw(ArgumentError("not an OpenAPI 3.x document: `openapi` = $(repr(v))"))
    info = get(doc, "info", nothing)
    info !== nothing || throw(ArgumentError("missing required `info` object"))
    get(info, "title", nothing) isa AbstractString ||
        throw(ArgumentError("missing required `info.title`"))
    get(info, "version", nothing) isa AbstractString ||
        throw(ArgumentError("missing required `info.version`"))
    paths = get(doc, "paths", nothing)
    paths === nothing && return doc  # valid: a doc may have no paths
    methodnames = Set(lowercase(string(m)) for m in METHODS)
    for (path, item) in pairs(paths)
        startswith(String(path), "/") ||
            throw(ArgumentError("path `$path` must start with '/'"))
        for (key, op) in pairs(item)
            key in ("summary", "description", "parameters", "servers") && continue
            key in methodnames ||
                throw(ArgumentError("path `$path`: unknown operation method `$key`"))
            responses = get(op, "responses", nothing)
            responses !== nothing && !isempty(responses) ||
                throw(ArgumentError("operation `$key $path` has no responses"))
            for (status, resp) in pairs(responses)
                get(resp, "description", nothing) isa AbstractString ||
                    throw(ArgumentError("response `$status` of `$key $path` is missing its required description"))
            end
        end
    end
    return doc
end
