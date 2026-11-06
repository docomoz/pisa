import { createServer } from 'node:http';
import worker from '../dist/server/index.js';

const server = createServer(async (req, res) => {
  try {
    const response = await worker.fetch(new Request(`http://127.0.0.1:4173${req.url}`, { method: req.method }));
    res.writeHead(response.status, Object.fromEntries(response.headers));
    res.end(Buffer.from(await response.arrayBuffer()));
  } catch {
    res.writeHead(500).end();
  }
});
server.listen(4173, '127.0.0.1', () => console.log('Preview: http://127.0.0.1:4173/'));
