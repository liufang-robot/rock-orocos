# HTTP REST Reference

The component-owned `http` service exposes explicitly published RTT application
components to browsers and Electron applications. It runs alongside OPC UA in
one Deployer process. `deployer-opcua` retains its existing behavior; the ordinary
deployer can load both service plugins.

## Deployment

Load application components, ordinary typekits, and any separate HTTP/OPC UA
type-support plugins before starting either service. With `arm` already loaded:

```text
import("rtt_http")
import("ocl")
loadService("Deployer", "opcua")
loadService("Deployer", "http")
opcua.start()
http.start()
opcua.publishComponent("arm")
http.publishComponent("arm")
```

Each service starts with an empty publication set. HTTP records the component's
current interface; its values remain live. Repeated publication succeeds without
rescanning. Later interface additions remain absent. There is no refresh or
unpublish API. Deployer, managed remote proxies, global `require("http")`, ordinary
component owners, and duplicate service loads are unsupported.

## Local Controls

The local service provides `start()`, `stop()`, `isRunning()`, `state()`,
`endpointUrl()`, `lastError()`, `publishComponent(name)`,
`publicationDiagnostics(name)`, and `pendingOperationCount()`. Its own controls
are absent from REST. Listener states are Stopped, Starting, Running, and Stopping.

Configuration properties can be written only while Stopped:

| Property | Default |
|---|---|
| `bindAddress`, `port` | `127.0.0.1`, `8080` |
| `tlsEnabled`, `certificateFile`, `privateKeyFile` | `false`, empty, empty |
| `workerThreads`, `maxQueuedConnections`, `maxPendingOperations` | `4`, `64`, `32` |
| `operationTimeoutMs` | `5000` |
| `maxRequestBodyBytes`, `maxResponseBodyBytes`, `maxJsonDepth` | `1048576`, `8388608`, `64` |
| `socketReadTimeoutMs`, `socketWriteTimeoutMs`, `keepAliveTimeoutMs` | `5000` each |
| `keepAliveMaxRequests`, `shutdownGraceMs` | `100`, `10000` |

Capacities and timeouts must be positive. The port must be 1–65535. Keep-alive
timeouts must be whole seconds expressed in milliseconds. Startup checks TLS
certificate/key pairing. HTTPS encrypts the connection; authentication is deferred.

## Discovery And Requests

`GET /api/v1/components` returns `{"items":[],"types":{}}`. Published component
summaries contain `name`, `description`, and an encoded `href`. Follow these links
to component and nested-service descriptions. Descriptions list immediate
services, properties, attributes, operations, ports, and canonical type schemas.

| Resource | Request | Successful response |
|---|---|---|
| Property or attribute | GET its `href` | `200 {"value":V}` |
| Writable value | PUT `{"value":V}` to its `href` | `204`, no body |
| Operation | POST `{"arguments":[...]}` to its `href` | `200 {"result":R,"outputs":[...]}` |
| Output port | GET its `latestHref` | `200 {"hasSample":true,"value":V}` |
| Input port | POST `{"value":V}` to its `samplesHref` | `204` when the transport stages the sample |

Every output has a latest route backed by its committed snapshot. Before the
first committed sample, latest returns
`{"hasSample":false,"value":null}`. Reads do not consume another reader's data.
Changes to the component's output working image become visible after a successful
cyclic commit. HTTP input writes use independent RTT staging connections; the
component acquires a staged sample at its next input boundary. An HTTP success
does not mean the component has processed the sample, and a request arriving
during its hook does not modify the current input image. See
[Automatic cyclic data ports](automatic-cyclic-io.md) for the execution contract.

Constants and other nonassignable values are read-only. Writes
replace whole values after complete validation. Operation arguments follow
declaration order; non-const references also appear in `outputs`. A false result
is still HTTP success, and a void result is null.

Use exact JSON envelopes and `Content-Type: application/json`. Unknown/duplicate
fields, invalid types, and wrong argument counts are rejected. Compression is
unsupported. Types without codecs remain visible with `jsonSupported=false`;
access requiring their codec returns 501. HEAD mirrors GET without a body;
OPTIONS returns Allow. Neither invokes operations. Unsupported methods and
immutable writes return 405; unpublished resources return 404.

## JSON And Browser Routing

64-bit integers use exact decimal strings. Enums use underlying integers;
non-finite floats use `"NaN"`, `"Infinity"`, and `"-Infinity"`. Strings are strict
UTF-8. Structures require every declared field, and sequences replace the whole
array. The response's `types` dictionary supplies transitive schema references.

Each RTT name occupies one encoded segment: `motion/raw` becomes `motion%2Fraw`,
while literal `motion%2Fraw` becomes `motion%252Fraw`. Empty names and `.`/`..`
reject publication. Follow discovery links without normalizing the whole path.

Browsers need a same-origin frontend arrangement; this version does not enable
permissive CORS. The Nginx integration test verifies this configuration:

```nginx
location /api/ {
    proxy_pass http://127.0.0.1:8080$request_uri;
    proxy_http_version 1.1;
    proxy_set_header Connection "";
}
```

`$request_uri` preserves the original encoded URI. Normalized `$uri` and rewrite
rules require a new routing check. Multiple clients can send independent REST
requests and poll values. WebSocket/SSE subscriptions are deferred.

## Operations And Shutdown

OwnThread operations run on the component engine; ClientThread operations run
on a bounded HTTP executor outside network workers. Capacity covers queued and
executing calls. A response timeout returns 504 without cancellation or replay.
The invocation retains storage, component lifetime, and capacity until it finishes.
Clients must not automatically repeat commands after timeout.

Ordinary stop closes admission, disposes queued connections, interrupts owned
network I/O after the grace period, and joins network workers. Publication,
bridges, and unfinished calls survive restart. Executor width cannot change while
calls remain; pending capacity cannot fall below the retained count. Bind/TLS
failure remains local to HTTP.

Final deployment shutdown closes every service's admission before draining work,
with component engines and storage alive. Published components cannot be unloaded
individually. A nonreturning operation can prevent final shutdown; threads are
never forcibly terminated. The application must ensure safe concurrent property
and attribute access.

Errors use `application/problem+json` with `type`, `title`, numeric `status`, and
a bounded request-path `instance` when available. Types use
`urn:rtt-http:error:<reason>`; client diagnostics contain no application exception
text. Authentication, service unloading, generic jobs, and streaming are later work.

## Custom Types

Ordinary typekits and components depend only on RTT. A separate HTTP companion
links `rtt_http::rtt_http` and registers codecs in project-local protocol slot 1043.
The selected source set uses slots 1 for CORBA, 2 for mqueue, 42 for Typelib,
and 1042 for OPC UA. HTTP registration rejects an incompatible occupant of 1043.
Reflection supplies whole-value conversion where metadata is complete; a typed
companion supplies retained port reads. Import the ordinary typekit first.

Prepare reflection outside RTT's `registerTransport()` callback, which holds the
RTT type repository lock. Metadata getters must not register codecs. Retain a
plugin once it installs callbacks, even if another mapping fails. HTTP and OPC UA
registries freeze independently before their first listener bind attempts.

See the [HTTP SDK](https://github.com/liufang-robot/rtt_http) and the
[external custom-type fixture](https://github.com/liufang-robot/rock-orocos/tree/main/tests/http-custom-datatypes).
