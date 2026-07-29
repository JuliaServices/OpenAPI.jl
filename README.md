# OpenAPI.jl

*Build OpenAPI documents from declared endpoints; generate single-file Julia
clients from OpenAPI documents.*

Two pieces:

## 1. Document generation

Describe endpoints as framework-neutral `OpenAPI.Operation`s and get a valid
[OpenAPI 3.2.0](https://spec.openapis.org/oas/v3.2.0.html) document, with Julia
types (including nested structs, `Union{Nothing, T}` optionals, `Vector`s,
enums, and `Dates` types) mapped to JSON Schema under `components/schemas`:

```julia
using OpenAPI, JSON

ops = [OpenAPI.Operation(; id="getwidget", method=:GET, path="/v1/widgets/{id}",
           params=[OpenAPI.Param("id", :path, Int),
                   OpenAPI.Param("verbose", :query, Bool; required=false)],
           responsetype=Widget)]
doc = OpenAPI.document(ops; title="Widgets", version="1.0.0")
JSON.json(doc; pretty=2)
```

With the Servo extension (`using Servo`), a router's introspectable route table
does all of that for you — statically:

```julia
doc = OpenAPI.document(router; title="Soleil", version="1.0.0")
```

or discoverably, from the running app:

```julia
OpenAPI.register!(router; title="Soleil", version="1.0.0")
# the app now serves GET /openapi.json (public), rebuilt per request
```

Path/query/body binding, content types, auth (`Public` vs. secured), and
response schemas (via return-type inference of each endpoint's typed binder)
are all derived from the endpoint declarations.

## 2. Client generation

`OpenAPI.client` turns any OpenAPI document — built in-process, read from a
file, or fetched from a running app — into a **single-file Julia client
module** whose only imports are HTTP and JSON (plus Dates when the API uses
date fields):

```julia
using OpenAPI, HTTP  # HTTP enables reading from a URL

doc = OpenAPI.read("http://localhost:8080/openapi.json")
OpenAPI.client(doc; name="SoleilClient", path="SoleilClient.jl")
```

```julia
include("SoleilClient.jl")
SoleilClient.server!("http://localhost:8080")
summary = SoleilClient.simulate(40.76, -111.89; system_capacity_kw=8.0)
```

The generated module defines one typed function per operation (path parameters
positional, request body last positional, query parameters as keywords — 
required ones without defaults, optional ones defaulting to `nothing` and
omitted from the request), a struct per object schema for typed responses,
`server!`/`authorization!` configuration, and an `ApiError` thrown for any
error status.

## Notes

- Documents are emitted as ordered `JSON.Object`s; serialize with
  `JSON.json(doc[; pretty=2])`.
- `OpenAPI.read`/`OpenAPI.validate` perform structural validation (spec
  version, info, path/operation/response shape).
- JSON documents only (the YAML flavor is out of scope for now).
