# grpcio (the C-core client) with its defaults, raw bytes in and out.
import grpc, time
from concurrent.futures import ThreadPoolExecutor
ch = grpc.insecure_channel('127.0.0.1:50051')
f = ch.unary_unary('/opentelemetry.proto.collector.trace.v1.TraceService/Export')
t = time.time()
with ThreadPoolExecutor(16) as ex: list(ex.map(lambda _: f(b'\0'*200), range(32)))
print(f'grpcio: 32 calls in {int((time.time()-t)*1000)}ms'); ch.close()
