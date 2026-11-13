import { createServer } from 'node:http';
import worker from '../dist/server/index.js';

// Caddy is the public entry point; this process only accepts local connections.
const host = '127.0.0.1';
const port = 4174;
const server = createServer(async (req, res) => {
  try {
    if (!req.url?.startsWith('/') || req.url.startsWith('//')) {
      res.writeHead(400).end('Bad request');
      return;
    }
    const request = new Request(`http://${host}:${port}${req.url}`, { method: req.method });
    const response = await worker.fetch(request);
    res.writeHead(response.status, Object.fromEntries(response.headers));
    res.end(Buffer.from(await response.arrayBuffer()));
  } catch (error) {
    console.error('Request failed:', error);
    if (!res.headersSent) res.writeHead(500);
    res.end();
  }
});

server.listen(port, host, () => console.log(`Pisa site listening on ${host}:${port}`));
for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, () => server.close(() => process.exit(0)));
}
