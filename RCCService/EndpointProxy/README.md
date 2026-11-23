# Server-side endpoint routing

The endpoint proxy lets an operator move website handlers to a different origin
or path while keeping the public addresses that Player and Studio use. Deploy
it behind the public HTTP server for a hostname you operate when WEBSERVICE is
ready. Forward the original `Host` header and terminate public HTTPS at that
server. The proxy defaults to listening on `127.0.0.1:8080`.

Use Go 1.20 or later. Run the proxy from `RCCService/EndpointProxy` with a
server-owned JSON file stored outside the public website directory.

```text
go run . -config /path/to/private/endpoints.json
```

In each entry, `from` is the stable public URL and `to` is the backend service
address. Use the public URLs already used by the builds you want to support.
For example, a future site could implement these legacy public paths at `/v1`.

```json
{
  "routes": [
    {
      "from": "https://play.example.invalid/Game/GetCurrentUser.ashx",
      "to": "http://127.0.0.1:9000/v1/users/current"
    },
    {
      "from": "https://assets.example.invalid/asset/",
      "to": "http://127.0.0.1:9000/v1/assets/"
    }
  ]
}
```

The proxy matches the public host and path, including the port when present in
the `Host` header. Paths ending in `/` match a directory and preserve the path
after it. Other paths match exactly. The longest matching path wins. The
request method, query, and body pass through to the selected backend.
The site receives `X-Forwarded-Host` and `X-Forwarded-Proto` for generating
public redirects and cookies. HTTPS upstreams use normal TLS verification.

To move a handler, atomically replace the server config with a version that
updates its `to` URL. The proxy checks the file every second and switches the
entire table after validation. Bad edits leave the active routes serving
requests. Keep the previous file so a deployment can be rolled back by
restoring it. Deploy the new handler before changing the route and keep its
response format, authentication, and status codes compatible with callers.
