// grpc-js with its defaults, raw Buffers in and out.
import grpc from '@grpc/grpc-js';
const [n, c] = [32, 16];
const client = new grpc.Client('127.0.0.1:50051', grpc.credentials.createInsecure());
const msg = Buffer.alloc(200);
const call = () => new Promise(res => client.makeUnaryRequest(
  '/opentelemetry.proto.collector.trace.v1.TraceService/Export', x => x, x => x, msg, (err) => { if (err) console.error(err.message); res(); }));
const t = Date.now(); let i = 0;
await Promise.all(Array.from({ length: c }, async () => { while (i < n) { i++; await call(); } }));
console.error(`grpc-js: ${n} calls in ${Date.now() - t}ms`); client.close();
