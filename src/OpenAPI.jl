"""
OpenAPI.jl: build OpenAPI documents from declared endpoints, and generate Julia
clients from OpenAPI documents.

Two pieces:

1. **Document generation** — describe endpoints as [`OpenAPI.Operation`](@ref)s
   (or hand a `Servo.Router` straight to [`OpenAPI.document`](@ref) with the
   Servo extension loaded) and get a valid OpenAPI 3.2.0 document.
   `OpenAPI.register!(router)` exposes it from the running app at
   `/openapi.json`, making the endpoints discoverable.
2. **Client generation** — [`OpenAPI.client`](@ref) turns an OpenAPI document
   (built in-process, read from a file, or fetched from a running app) into a
   single-file Julia client module whose only imports are HTTP and JSON (plus
   Dates when the API uses date fields).
"""
module OpenAPI

using Dates, JSON

const OPENAPI_VERSION = "3.2.0"

include("schemas.jl")
include("document.jl")
include("read.jl")
include("client.jl")

# ── extension seams ─────────────────────────────────────────────────────────

"""
    OpenAPI.register!(router; path="/openapi.json", title=..., version=..., kw...)

Register a public endpoint on a `Servo.Router` that serves the app's OpenAPI
document — the "discoverable from the running app" mechanism. The document is
built per request, so it always reflects the currently-registered endpoints
(minus the discovery endpoint itself). Requires the Servo package to be loaded.
"""
function register! end

# implemented by OpenAPIServoExt: describe a Servo.Router as Vector{Operation}
function operations end

# implemented by OpenAPIHTTPExt (loaded with the HTTP package)
function fetchurl end

end # module
