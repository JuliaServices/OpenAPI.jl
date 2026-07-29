# Generate a single-file Julia client module from an OpenAPI document.
# The generated module's only imports are HTTP and JSON (plus Dates when the
# API uses date/date-time fields).

isident(s::AbstractString) = Base.isidentifier(s) && !haskey(Base.Docs.keywords, Symbol(s))

function sanitizeident(s::AbstractString)
    isempty(s) && return "op"
    out = replace(String(s), r"[^A-Za-z0-9_]" => "_")
    isdigit(first(out)) && (out = "_" * out)
    isident(out) || (out = "_" * out)
    return out
end

_get(x, key, default=nothing) = x isa AbstractDict || x isa JSON.Object ? get(x, key, default) : default

# ── JSON Schema -> Julia type (as source text) ──────────────────────────────

function juliatype(schema, typemap::Dict{String, String}, usedates::Ref{Bool})
    (schema === nothing || schema === true) && return "Any"
    ref = _get(schema, "\$ref")
    if ref !== nothing
        return get(typemap, String(ref), "Any")
    end
    oneof = _get(schema, "oneOf")
    if oneof !== nothing
        nonnull = [s for s in oneof if _get(s, "type") != "null"]
        if length(nonnull) == 1 && length(oneof) == 2
            inner = juliatype(nonnull[1], typemap, usedates)
            return startswith(inner, "Union{Nothing") ? inner : "Union{Nothing, $inner}"
        end
        return "Any"
    end
    t = _get(schema, "type")
    if t isa AbstractVector  # 3.1-style type arrays, e.g. ["integer", "null"]
        nonnull = [x for x in t if x != "null"]
        length(nonnull) == 1 || return "Any"
        inner = juliatype(obj("type" => String(nonnull[1]), "format" => something(_get(schema, "format"), "")), typemap, usedates)
        return length(t) > length(nonnull) ? "Union{Nothing, $inner}" : inner
    end
    t == "integer" && return _get(schema, "format") == "int32" ? "Int32" : "Int64"
    t == "number" && return "Float64"
    t == "boolean" && return "Bool"
    if t == "string"
        f = _get(schema, "format")
        f == "date" && (usedates[] = true; return "Dates.Date")
        f == "date-time" && (usedates[] = true; return "Dates.DateTime")
        f == "time" && (usedates[] = true; return "Dates.Time")
        return "String"
    end
    t == "array" && return "Vector{$(juliatype(_get(schema, "items"), typemap, usedates))}"
    return "Any"
end

# ── components/schemas -> struct definitions ────────────────────────────────

structeligible(schema) =
    _get(schema, "type") == "object" && _get(schema, "properties") !== nothing &&
    all(isident, keys(_get(schema, "properties")))

schemarefs(schema) = begin
    refs = String[]
    _collectrefs!(refs, schema)
    refs
end
function _collectrefs!(refs, schema)
    (schema isa AbstractDict || schema isa JSON.Object) || return
    r = _get(schema, "\$ref")
    r !== nothing && push!(refs, String(r))
    for key in ("items", "additionalProperties")
        s = _get(schema, key)
        s === nothing || _collectrefs!(refs, s)
    end
    for key in ("oneOf", "anyOf", "allOf")
        for s in something(_get(schema, key), [])
            _collectrefs!(refs, s)
        end
    end
    props = _get(schema, "properties")
    if props !== nothing
        for (_, s) in pairs(props)
            _collectrefs!(refs, s)
        end
    end
    return
end

function genstructs(io::IO, components, typemap::Dict{String, String}, usedates::Ref{Bool})
    schemas = _get(components, "schemas")
    schemas === nothing && return
    done = Set{String}()
    inprogress = Set{String}()
    function emit(name::String)
        name in done && return
        schema = _get(schemas, name)
        (schema === nothing || !structeligible(schema)) && (push!(done, name); return)
        name in inprogress && return  # mutual cycle: later refs fall back to Any
        push!(inprogress, name)
        structname = sanitizeident(name)
        # self-references resolve to the struct's own name (legal in Julia)
        typemap["#/components/schemas/$name"] = structname
        for r in schemarefs(schema)
            rn = last(split(r, '/'))
            rn != name && emit(String(rn))
        end
        props = _get(schema, "properties")
        required = Set(String.(something(_get(schema, "required"), String[])))
        println(io, "struct ", structname)
        for (fname, fschema) in pairs(props)
            ftype = juliatype(fschema, typemap, usedates)
            if !(String(fname) in required) && !startswith(ftype, "Union{Nothing")
                ftype = "Union{Nothing, $ftype}"
            end
            println(io, "    ", fname, "::", ftype)
        end
        println(io, "end\n")
        delete!(inprogress, name)
        push!(done, name)
    end
    for name in keys(schemas)
        emit(String(name))
    end
    return
end

# ── operations -> client functions ──────────────────────────────────────────

function successresponse(op)
    responses = something(_get(op, "responses"), obj())
    for (status, resp) in pairs(responses)
        s = String(status)
        (s == "204") && continue
        (startswith(s, "2") && length(s) == 3) || continue
        return resp
    end
    return nothing
end

function genop(io::IO, pathstr::String, methodkey::String, op, pathitemparams,
               typemap::Dict{String, String}, usedates::Ref{Bool}, anysecured::Bool)
    method = uppercase(methodkey)
    id = something(_get(op, "operationId"), string(methodkey, "_", pathstr))
    fname = sanitizeident(String(id))

    # parameters: operation-level after path-item-level, keyed by (name, in)
    params = Any[]
    for p in [collect(something(pathitemparams, [])); collect(something(_get(op, "parameters"), []))]
        i = findfirst(q -> _get(q, "name") == _get(p, "name") && _get(q, "in") == _get(p, "in"), params)
        i === nothing ? push!(params, p) : (params[i] = p)
    end
    placeholders = pathplaceholders(pathstr)
    function paramfor(name)
        i = findfirst(p -> _get(p, "in") == "path" && String(_get(p, "name", "")) == name, params)
        return i === nothing ? nothing : params[i]
    end
    queryparams = [p for p in params if _get(p, "in") == "query"]

    # argument names (sanitized, deduped, avoiding our own locals)
    used = Set(["server", "body", "query", "headers", "resp", "url"])
    argname(n) = begin
        a = sanitizeident(n)
        while a in used
            a = a * "_"
        end
        push!(used, a)
        a
    end
    pathargs = [(ph, argname(ph),
                 juliatype(_get(something(paramfor(ph), obj()), "schema"), typemap, usedates))
                for ph in placeholders]

    requestbody = _get(op, "requestBody")
    bodytype = "Any"
    bodyct = "application/json"
    if requestbody !== nothing
        content = something(_get(requestbody, "content"), obj())
        for (ct, media) in pairs(content)
            bodyct = String(ct)
            bodytype = juliatype(_get(media, "schema"), typemap, usedates)
            break
        end
    end

    secured = anysecured && _get(op, "security") !== nothing

    # signature
    sig = String[]
    for (_, a, t) in pathargs
        push!(sig, t == "Any" ? a : "$a::$t")
    end
    requestbody === nothing || push!(sig, bodytype == "Any" ? "body" : "body::$bodytype")
    kwsig = String[]
    queryargs = Tuple{String, String, Bool}[]  # (wire name, arg name, required)
    for p in queryparams
        wire = String(_get(p, "name", ""))
        a = argname(wire)
        t = juliatype(_get(p, "schema"), typemap, usedates)
        required = _get(p, "required", false) == true
        if required
            push!(kwsig, t == "Any" ? a : "$a::$t")
        else
            topt = startswith(t, "Union{Nothing") || t == "Any" ? t : "Union{Nothing, $t}"
            push!(kwsig, "$a::$topt = nothing")
        end
        push!(queryargs, (wire, a, required))
    end
    push!(kwsig, "server::AbstractString = SERVER[]")

    summary = something(_get(op, "summary"), "")
    println(io, "\"\"\"")
    println(io, "    ", fname, "(...)")
    println(io, "")
    isempty(summary) || println(io, summary, "\n")
    println(io, "`", method, " ", pathstr, "`")
    println(io, "\"\"\"")
    println(io, "function ", fname, "(", join(sig, ", "), "; ", join(kwsig, ", "), ")")

    # url
    urlparts = String[]
    rest = pathstr
    for (ph, a, _) in pathargs
        pre, rest = split(rest, "{$ph}"; limit=2)
        isempty(pre) || push!(urlparts, repr(String(pre)))
        push!(urlparts, "HTTP.escapeuri(_str($a))")
    end
    isempty(rest) || push!(urlparts, repr(String(rest)))
    println(io, "    url = string(server, ", join(urlparts, ", "), ")")

    if !isempty(queryargs)
        println(io, "    query = Pair{String, String}[]")
        for (wire, a, required) in queryargs
            if required
                println(io, "    push!(query, ", repr(wire), " => _str(", a, "))")
            else
                println(io, "    ", a, " === nothing || push!(query, ", repr(wire), " => _str(", a, "))")
            end
        end
    end
    println(io, "    headers = Pair{String, String}[]")
    requestbody === nothing ||
        println(io, "    push!(headers, \"Content-Type\" => ", repr(bodyct), ")")
    secured &&
        println(io, "    TOKEN[] === nothing || push!(headers, \"Authorization\" => \"Bearer \" * something(TOKEN[]))")

    reqkw = String["status_exception = false"]
    isempty(queryargs) || pushfirst!(reqkw, "query = query")
    if requestbody !== nothing
        bodyexpr = startswith(bodyct, "application/json") ? "JSON.json(body)" : "string(body)"
        push!(reqkw, "body = $bodyexpr")
    end
    println(io, "    resp = HTTP.request(", repr(method), ", url, headers; ", join(reqkw, ", "), ")")
    println(io, "    resp.status >= 300 && throw(ApiError(resp.status, String(resp.body)))")
    println(io, "    resp.status == 204 && return nothing")

    success = successresponse(op)
    content = success === nothing ? nothing : _get(success, "content")
    if content === nothing
        println(io, "    return String(resp.body)")
    else
        ct, media = first(pairs(content))
        schema = _get(media, "schema")
        rt = juliatype(schema, typemap, usedates)
        if startswith(String(ct), "application/json")
            if rt in ("Any",)
                println(io, "    return JSON.parse(String(resp.body))")
            else
                println(io, "    return JSON.parse(String(resp.body), ", rt, ")")
            end
        else
            println(io, "    return String(resp.body)")
        end
    end
    println(io, "end\n")
    return
end

# ── entry point ─────────────────────────────────────────────────────────────

"""
    OpenAPI.client(doc; name="ApiClient", path=nothing) -> String

Generate a self-contained, single-file Julia client module for an OpenAPI
document (anything [`OpenAPI.read`](@ref) accepts, or a document built by
[`OpenAPI.document`](@ref)). The generated module imports only HTTP and JSON
(plus Dates when the API uses date fields) and defines:

- one function per operation, named after its `operationId`: path parameters as
  typed positional arguments, the request body (if any) as the final positional
  argument, query parameters as keyword arguments (required ones have no
  default; optional ones default to `nothing` and are omitted from the request);
- a struct per object schema in `components/schemas`, used to materialize typed
  responses via `JSON.parse(body, T)`;
- `server!(url)` to set the default base URL (initialized from the document's
  first server, else `"http://127.0.0.1:8080"`); every function also accepts a
  `server` keyword;
- `authorization!(token)` (when the API declares security) to send
  `Authorization: Bearer <token>`;
- `ApiError(status, body)`, thrown for any ≥300 response.

Pass `path` to also write the module to a file.
"""
function client(doc; name::AbstractString="ApiClient", path::Union{Nothing, AbstractString}=nothing)
    doc isa AbstractString && (doc = read(doc))
    validate(doc)
    modname = sanitizeident(name)
    io = IOBuffer()
    body = IOBuffer()
    typemap = Dict{String, String}()
    usedates = Ref(false)
    info = doc["info"]

    components = something(_get(doc, "components"), obj())
    anysecured = _get(components, "securitySchemes") !== nothing
    genstructs(body, components, typemap, usedates)
    paths = something(_get(doc, "paths"), obj())
    methodnames = Set(lowercase(string(m)) for m in METHODS)
    for (pathstr, item) in pairs(paths)
        for (key, op) in pairs(item)
            String(key) in methodnames || continue
            genop(body, String(pathstr), String(key), op, _get(item, "parameters"),
                  typemap, usedates, anysecured)
        end
    end

    servers = something(_get(doc, "servers"), [])
    defaultserver = isempty(servers) ? "http://127.0.0.1:8080" :
        String(rstrip(String(_get(servers[1], "url", "http://127.0.0.1:8080")), '/'))

    println(io, "# Generated by OpenAPI.jl from \"", _get(info, "title", "API"),
            "\" version ", _get(info, "version", "?"), " — do not edit.")
    println(io, "module ", modname, "\n")
    print(io, "using HTTP, JSON\n")
    usedates[] && print(io, "using Dates\n")
    println(io, "")
    println(io, "\"base URL used when `server` is not passed per call\"")
    println(io, "const SERVER = Ref{String}(", repr(defaultserver), ")")
    println(io, "server!(url::AbstractString) = (SERVER[] = String(rstrip(url, '/')); nothing)\n")
    if anysecured
        println(io, "const TOKEN = Ref{Union{Nothing, String}}(nothing)")
        println(io, "\"set the bearer token sent as `Authorization: Bearer <token>`\"")
        println(io, "authorization!(token::Union{Nothing, AbstractString}) = (TOKEN[] = token === nothing ? nothing : String(token); nothing)\n")
    end
    println(io, "struct ApiError <: Exception")
    println(io, "    status::Int")
    println(io, "    body::String")
    println(io, "end")
    println(io, "Base.showerror(io::IO, e::ApiError) = print(io, \"ApiError(\", e.status, \"): \", e.body)\n")
    println(io, "_str(x::AbstractVector) = join(map(string, x), \",\")")
    println(io, "_str(x) = string(x)\n")
    write(io, take!(body))
    println(io, "end # module ", modname)

    out = String(take!(io))
    path === nothing || write(path, out)
    return out
end
