// tonic with its defaults, raw bytes in and out through a codec of our own.
use bytes::{Buf, BufMut, Bytes};
use tonic::codec::{Codec, DecodeBuf, Decoder, EncodeBuf, Encoder};
use tonic::Status;

#[derive(Default, Clone)]
struct Raw;
struct E;
struct D;
impl Encoder for E {
    type Item = Bytes;
    type Error = Status;
    fn encode(&mut self, item: Bytes, dst: &mut EncodeBuf<'_>) -> Result<(), Status> {
        dst.put(item);
        Ok(())
    }
}
impl Decoder for D {
    type Item = Bytes;
    type Error = Status;
    fn decode(&mut self, src: &mut DecodeBuf<'_>) -> Result<Option<Bytes>, Status> {
        Ok(Some(src.copy_to_bytes(src.remaining())))
    }
}
impl Codec for Raw {
    type Encode = Bytes;
    type Decode = Bytes;
    type Encoder = E;
    type Decoder = D;
    fn encoder(&mut self) -> E { E }
    fn decoder(&mut self) -> D { D }
}

#[tokio::main]
async fn main() {
    let ch = tonic::transport::Endpoint::from_static("http://127.0.0.1:50051").connect().await.unwrap();
    let t = std::time::Instant::now();
    let path = http::uri::PathAndQuery::from_static("/opentelemetry.proto.collector.trace.v1.TraceService/Export");
    let n = 32;
    let mut set = tokio::task::JoinSet::new();
    let sem = std::sync::Arc::new(tokio::sync::Semaphore::new(16));
    for _ in 0..n {
        let mut g = tonic::client::Grpc::new(ch.clone());
        let p = path.clone();
        let s = sem.clone();
        set.spawn(async move {
            let _permit = s.acquire().await.unwrap();
            g.ready().await.unwrap();
            if let Err(e) = g.unary(tonic::Request::new(Bytes::from(vec![0u8; 200])), p, Raw).await { eprintln!("{e}"); }
        });
    }
    while set.join_next().await.is_some() {}
    eprintln!("tonic: {n} calls in {:?}", t.elapsed());
}
