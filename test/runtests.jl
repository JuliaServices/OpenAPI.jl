using Test, OpenAPI, JSON, Dates
import HTTP, Servo

# ── domain types used across the tests ──────────────────────────────────────

struct TWidget
    id::Int
    tags::Vector{String}
end

struct TOrder
    widget::TWidget
    count::Int
    note::Union{Nothing, String}
    placed::Date
end

@enum TColor tred tgreen tblue

struct TNode
    value::Int
    next::Union{Nothing, TNode}
end

struct BearerAuth <: Servo.AuthScheme
    token::String
end
Servo.authenticate(a::BearerAuth, req::HTTP.Request) =
    HTTP.header(req, "Authorization", "") == "Bearer $(a.token)" ? "token-user" : nothing

# the end-to-end app: declared at top level, as a real app module would (locally
# declared endpoints capture boxed function bindings, defeating response-type
# inference — and real registration always happens at module load time anyway)
const ROUTER = Servo.Router()

Servo.@GET ROUTER "/api/widgets/{id}" public function getwidget(id::Int; tags::Vector{String}=String[])
    TWidget(id, tags)
end
Servo.@POST ROUTER "/api/orders" public function neworder(order::TOrder; dry::Bool=false)
    (; ok = !dry, count = order.count, note = order.note)
end
Servo.@DELETE ROUTER "/api/widgets/{id}" public function rmwidget(id::Int)
    nothing
end
Servo.@GET ROUTER "/api/secret" BearerAuth("sesame") function secret()
    (; principal = Servo.principal())
end
# named catch-all: documented as the `/api/docs/{page}` template
Servo.@GET ROUTER "/api/docs/{page...}" public function docpage(page::String)
    (; page)
end
# raw handler: documented with its captures, response unknown
Servo.register!(ROUTER, :GET, "/api/ping/{name}", req -> "pong:$(Servo.pathparams()[:name])";
                auth=Servo.Public(), name="ping")
# anonymous wildcards: real routes, but undescribable -> omitted from the document
Servo.register!(ROUTER, :GET, "/api/static/**", req -> Servo.Response(200, "blob");
                auth=Servo.Public(), name="static")
OpenAPI.register!(ROUTER; title="E2E API", version="0.0.1")

getschema(reg, T) = OpenAPI.schemaof(reg, T)

@testset "OpenAPI" begin

@testset "Julia types -> JSON Schema" begin
    reg = OpenAPI.SchemaRegistry()
    @test getschema(reg, Int)["type"] == "integer"
    @test getschema(reg, Int)["format"] == "int64"
    @test getschema(reg, Float64) == OpenAPI.obj("type" => "number", "format" => "double")
    @test getschema(reg, Bool)["type"] == "boolean"
    @test getschema(reg, String)["type"] == "string"
    @test getschema(reg, Symbol)["type"] == "string"
    @test getschema(reg, Date) == OpenAPI.obj("type" => "string", "format" => "date")
    @test getschema(reg, DateTime)["format"] == "date-time"
    @test getschema(reg, Any) == OpenAPI.obj()
    @test getschema(reg, Vector{Int}) ==
        OpenAPI.obj("type" => "array", "items" => OpenAPI.obj("type" => "integer", "format" => "int64"))
    @test getschema(reg, Dict{String, Bool})["additionalProperties"]["type"] == "boolean"
    @test getschema(reg, TColor)["enum"] == ["tred", "tgreen", "tblue"]

    nullable = getschema(reg, Union{Nothing, Int})
    @test haskey(nullable, "oneOf")
    @test OpenAPI.obj("type" => "null") in nullable["oneOf"]

    # named tuples become inline object schemas
    nt = getschema(reg, typeof((; ok = true, n = 1)))
    @test nt["type"] == "object"
    @test nt["required"] == ["ok", "n"]

    # structs register once and are referenced
    @test getschema(reg, TWidget) == OpenAPI.obj("\$ref" => "#/components/schemas/TWidget")
    @test getschema(reg, TWidget) == OpenAPI.obj("\$ref" => "#/components/schemas/TWidget")
    tw = reg.schemas["TWidget"]
    @test tw["properties"]["id"]["type"] == "integer"
    @test tw["properties"]["tags"]["type"] == "array"
    @test tw["required"] == ["id", "tags"]

    # nested refs, optional (Union{Nothing}) fields, date formats
    getschema(reg, TOrder)
    to = reg.schemas["TOrder"]
    @test to["properties"]["widget"]["\$ref"] == "#/components/schemas/TWidget"
    @test to["properties"]["placed"]["format"] == "date"
    @test to["required"] == ["widget", "count", "placed"]  # note is optional

    # self-referential types terminate
    getschema(reg, TNode)
    @test haskey(reg.schemas, "TNode")
end

ops = [
    OpenAPI.Operation(; id="getwidget", method=:GET, path="/w/{id}", summary="Get a widget",
        params=[OpenAPI.Param("id", :path, Int),
                OpenAPI.Param("owner", :query, String),
                OpenAPI.Param("verbose", :query, Bool; required=false)],
        responsetype=TWidget),
    OpenAPI.Operation(; id="neworder", method=:POST, path="/orders",
        bodytype=TOrder, responsetype=TOrder, secured=true),
    OpenAPI.Operation(; id="rmorder", method=:DELETE, path="/orders/{id}",
        params=[OpenAPI.Param("id", :path, Int)], responsetype=Nothing),
    OpenAPI.Operation(; id="getwidget", method=:GET, path="/w2/{id}",
        params=[OpenAPI.Param("id", :path, Int)]),
]
doc = OpenAPI.document(ops; title="Test API", version="1.2.3",
                       description="a test api", servers=["http://api.example"])

@testset "document generation" begin
    @test doc["openapi"] == "3.2.0"
    @test doc["info"]["title"] == "Test API"
    @test doc["info"]["version"] == "1.2.3"
    @test doc["servers"][1]["url"] == "http://api.example"

    get1 = doc["paths"]["/w/{id}"]["get"]
    @test get1["operationId"] == "getwidget"
    @test get1["summary"] == "Get a widget"
    p1, p2, p3 = get1["parameters"]
    @test p1["name"] == "id" && p1["in"] == "path" && p1["required"] === true
    @test p2["name"] == "owner" && p2["in"] == "query" && p2["required"] === true
    @test p3["name"] == "verbose" && p3["required"] === false
    @test get1["responses"]["200"]["content"]["application/json"]["schema"]["\$ref"] ==
        "#/components/schemas/TWidget"
    @test haskey(get1["responses"], "default")

    post = doc["paths"]["/orders"]["post"]
    @test post["requestBody"]["required"] === true
    @test post["requestBody"]["content"]["application/json"]["schema"]["\$ref"] ==
        "#/components/schemas/TOrder"
    @test post["security"] == [OpenAPI.obj("bearerAuth" => String[])]

    del = doc["paths"]["/orders/{id}"]["delete"]
    @test haskey(del["responses"], "204")
    @test !haskey(del["responses"], "200")

    # duplicate operationIds are deduped
    @test doc["paths"]["/w2/{id}"]["get"]["operationId"] == "getwidget_2"

    @test haskey(doc["components"]["schemas"], "TWidget")
    @test haskey(doc["components"]["schemas"], "TOrder")
    @test doc["components"]["securitySchemes"]["bearerAuth"]["scheme"] == "bearer"

    @test OpenAPI.validate(doc) === doc

    # invalid operations fail at construction
    @test_throws ArgumentError OpenAPI.Operation(; id="x", method=:FETCH, path="/x")
    @test_throws ArgumentError OpenAPI.Operation(; id="x", method=:GET, path="nope")
    @test_throws ArgumentError OpenAPI.Operation(; id="x", method=:GET, path="/a/{b}")
    @test_throws ArgumentError OpenAPI.Operation(; id="x", method=:GET, path="/a",
        params=[OpenAPI.Param("b", :path, Int)])
    @test_throws ArgumentError OpenAPI.Param("x", :header)
    @test_throws ArgumentError OpenAPI.Param("x", :path; required=false)
end

@testset "read & validate" begin
    # JSON string round trip
    doc2 = OpenAPI.read(JSON.json(doc))
    @test doc2["info"]["title"] == "Test API"
    @test doc2["paths"]["/w/{id}"]["get"]["operationId"] == "getwidget"

    # file round trip
    dir = mktempdir()
    file = joinpath(dir, "api.json")
    write(file, JSON.json(doc; pretty=2))
    @test OpenAPI.read(file)["info"]["version"] == "1.2.3"

    @test_throws ArgumentError OpenAPI.read("""{"openapi": "2.0", "info": {}}""")
    @test_throws ArgumentError OpenAPI.read("""{"openapi": "3.1.0"}""")
    @test_throws ArgumentError OpenAPI.read("definitely not a document")
    e = @test_throws ArgumentError OpenAPI.validate(
        OpenAPI.obj("openapi" => "3.2.0",
            "info" => OpenAPI.obj("title" => "t", "version" => "1"),
            "paths" => OpenAPI.obj("/x" => OpenAPI.obj("get" => OpenAPI.obj()))))
    @test occursin("responses", e.value.msg)
end

@testset "client generation (static)" begin
    src = OpenAPI.client(doc; name="TestClient")
    @test occursin("module TestClient", src)
    host = Module(:TestClientHost)
    Base.include_string(host, src, "TestClient.jl")
    C = getfield(host, :TestClient)

    @test C.SERVER[] == "http://api.example"
    for f in (:getwidget, :neworder, :rmorder, :getwidget_2, :server!, :authorization!)
        @test isdefined(C, f)
    end
    # generated structs mirror the schemas
    @test fieldnames(C.TWidget) == (:id, :tags)
    @test fieldtype(C.TWidget, :id) == Int64
    @test fieldtype(C.TWidget, :tags) == Vector{String}
    @test fieldtype(C.TOrder, :note) == Union{Nothing, String}
    @test fieldtype(C.TOrder, :placed) == Dates.Date
    @test fieldtype(C.TOrder, :widget) == C.TWidget

    # required query params are required keywords; optional default to nothing
    m = only(methods(C.getwidget))
    @test Base.kwarg_decl(m) isa Vector
    @test :owner in Base.kwarg_decl(m)
end

@testset "Servo integration end-to-end" begin
    router = ROUTER

    # static: operations & document straight from the router
    sops = OpenAPI.operations(router)
    # openapi discovery endpoint + the anonymous-wildcard route are skipped
    @test length(sops) == 6
    byid = Dict(op.id => op for op in sops)
    @test byid["getwidget"].responsetype == TWidget
    @test byid["getwidget"].params[1].location == :path
    @test byid["neworder"].bodytype == TOrder
    @test byid["neworder"].responsetype <: NamedTuple
    @test byid["rmwidget"].responsetype === Nothing
    @test byid["secret"].secured
    # named catch-all: template rewritten, param typed as its String remainder
    @test byid["docpage"].path == "/api/docs/{page}"
    @test byid["docpage"].params[1].name == "page" && byid["docpage"].params[1].type === String
    # raw handler: captures documented, response unknown
    @test byid["ping"].path == "/api/ping/{name}"
    @test byid["ping"].params[1].location == :path
    @test byid["ping"].responsetype === nothing
    @test !haskey(byid, "static")

    sdoc = OpenAPI.document(router; title="E2E API", version="0.0.1")
    @test sdoc["paths"]["/api/widgets/{id}"]["get"]["responses"]["200"]["content"]["application/json"]["schema"]["\$ref"] ==
        "#/components/schemas/TWidget"
    @test haskey(sdoc["paths"]["/api/widgets/{id}"]["delete"]["responses"], "204")
    @test OpenAPI.validate(sdoc) === sdoc

    # discoverable from the running app
    server = Servo.serve!(router; host="127.0.0.1", port=0)
    try
        port = Servo.port(server)
        base = "http://127.0.0.1:$port"
        rdoc = OpenAPI.read("$base/openapi.json")
        @test rdoc["info"]["title"] == "E2E API"
        @test !haskey(rdoc["paths"], "/openapi.json")
        @test Set(keys(rdoc["paths"])) ==
            Set(["/api/widgets/{id}", "/api/orders", "/api/secret",
                 "/api/docs/{page}", "/api/ping/{name}"])

        # generate a client from the running app's document and call through it
        dir = mktempdir()
        src = OpenAPI.client(rdoc; name="E2EClient", path=joinpath(dir, "E2EClient.jl"))
        @test isfile(joinpath(dir, "E2EClient.jl"))
        host = Module(:E2EHost)
        Base.include_string(host, src, "E2EClient.jl")
        C = getfield(host, :E2EClient)
        # the client module was just defined, so its methods live in a newer
        # world than this top-level testset block: call via @invokelatest
        Base.@invokelatest C.server!(base)

        w = Base.@invokelatest C.getwidget(5; tags=["a", "b"])
        @test w isa C.TWidget
        @test w.id == 5 && w.tags == ["a", "b"]
        w = Base.@invokelatest C.getwidget(7)  # optional query param omitted -> server default
        @test w.id == 7 && isempty(w.tags)

        order = Base.@invokelatest C.TOrder(Base.@invokelatest(C.TWidget(1, ["x"])), 3, nothing, Date(2026, 1, 15))
        res = Base.@invokelatest C.neworder(order)
        @test res.ok == true && res.count == 3

        @test Base.@invokelatest(C.rmwidget(5)) === nothing

        # catch-all endpoint through the generated client (single-segment value;
        # multi-segment values don't survive the client's percent-encoding)
        @test Base.@invokelatest(C.docpage("intro")).page == "intro"

        # auth: 401 without a token, principal with one
        err = @test_throws C.ApiError Base.@invokelatest(C.secret())
        @test err.value.status == 401
        Base.@invokelatest C.authorization!("sesame")
        @test Base.@invokelatest(C.secret()).principal == "token-user"
        Base.@invokelatest C.authorization!(nothing)
    finally
        close(server)
    end
end

end # @testset "OpenAPI"
