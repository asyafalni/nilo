"""One line a connection from the probe's JSON, plus the header blocks that matter."""
import json
import sys

for line in open(sys.argv[1]):
    r = json.loads(line)
    blocks = r.pop("header_blocks")
    hdrs = r.pop("first_request_headers") or {}
    req = [b for b in blocks if not b.get("trailer")]
    print(f"  {hdrs.get('user-agent')}  settings={r['client_settings']}")
    print(f"  before our SETTINGS were acked: {r['frames_before_our_settings_acked']}")
    print(f"  calls={r['calls']} max_open={r['max_open_streams']} pings={r['pings']} "
          f"rst={r['rst_streams']} goaway={r.get('goaway')} ms={r['duration_ms']}")
    print(f"  grpc-encoding={hdrs.get('grpc-encoding')} grpc-timeout={hdrs.get('grpc-timeout')}")
    if req:
        print(f"  header block bytes: first {req[0]['bytes']}, second {req[1]['bytes'] if len(req) > 1 else '-'}, "
              f"last {req[-1]['bytes']}; insertions {sum(b['literal_incremental'] for b in req)} "
              f"({sum(b.get('inserted_bytes', 0) for b in req)} bytes offered); "
              f"size updates {[(b['stream'], b['size_updates']) for b in req if b.get('size_updates')]}")
    if r.get("decoder_error"):
        print(f"  decoder error: {r['decoder_error']}")
