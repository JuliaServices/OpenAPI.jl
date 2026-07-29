# Lets OpenAPI.read fetch documents over HTTP (e.g. a running app's
# /openapi.json). Loads automatically when both OpenAPI and HTTP are loaded.
module OpenAPIHTTPExt

using OpenAPI, HTTP

OpenAPI.fetchurl(url::AbstractString) = String(HTTP.get(url).body)

end # module
