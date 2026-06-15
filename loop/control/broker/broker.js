// Secret broker — a credential-injecting reverse proxy (Node built-ins only; runs in the worker
// image via `--entrypoint node`). It HOLDS the dev API credentials and injects them into outbound
// requests, so the worker Claude can USE an API without ever READING its token.
//
// A worker calls:   $BROKER_URL/<alias>/<path...>     (NO credential in the request)
// The broker:        looks up <alias> -> { upstream, header }, forwards to upstream/<path...>,
//                    and injects the secret header. The raw token never leaves this process.
//
// Config via env BROKER_ROUTES (JSON), set by control/broker.sh from control/secret.broker.env:
//   { "github": { "upstream": "https://api.github.com", "header": "Authorization: Bearer ghp_…" },
//     "stripe": { "upstream": "https://api.stripe.com",  "header": "Authorization: Bearer sk_test_…" } }
'use strict';
const http = require('http');
const https = require('https');
const { URL } = require('url');

let routes = {};
try { routes = JSON.parse(process.env.BROKER_ROUTES || '{}'); }
catch (e) { console.error('broker: bad BROKER_ROUTES JSON:', e.message); process.exit(1); }
const port = parseInt(process.env.BROKER_PORT || '8080', 10);

const server = http.createServer((req, res) => {
  // /alias                      -> health/listing is not exposed; require an alias + path
  const m = req.url.match(/^\/([^/?]+)(\/[^?]*)?(\?.*)?$/);
  const alias = m && m[1];
  if (!alias || !routes[alias]) {
    res.writeHead(404, { 'content-type': 'text/plain' });
    return res.end(`broker: unknown alias '${alias || ''}'. Configure it in control/secret.broker.env.`);
  }
  const route = routes[alias];
  const rest = (m[2] || '/') + (m[3] || '');
  let target;
  try { target = new URL(rest.replace(/^\//, ''), route.upstream.replace(/\/?$/, '/')); }
  catch (e) { res.writeHead(400); return res.end('broker: bad target'); }

  const headers = Object.assign({}, req.headers, { host: target.host });
  delete headers['accept-encoding']; // avoid surprising the client with compressed bodies
  if (route.header) {
    const i = route.header.indexOf(':');
    if (i > 0) headers[route.header.slice(0, i).trim().toLowerCase()] = route.header.slice(i + 1).trim();
  }

  const lib = target.protocol === 'https:' ? https : http;
  const up = lib.request(target, { method: req.method, headers }, r => {
    res.writeHead(r.statusCode, r.headers);
    r.pipe(res);
  });
  up.on('error', e => { res.writeHead(502, { 'content-type': 'text/plain' }); res.end('broker upstream error: ' + e.message); });
  req.pipe(up);
});

server.listen(port, () => console.log(`broker: listening on :${port} for aliases [${Object.keys(routes).join(', ')}]`));
