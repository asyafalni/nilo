// probe is a gRPC server written at the frame level, so that what a real
// client puts on the wire can be read rather than assumed. It answers every
// unary call with an empty message and grpc-status 0, after a fixed delay so
// concurrent calls overlap, and prints one JSON report per connection when the
// connection closes.
package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"sync"
	"sync/atomic"
	"time"

	"golang.org/x/net/http2"
	"golang.org/x/net/http2/hpack"
)

var (
	addr      = flag.String("addr", "127.0.0.1:50051", "listen address")
	maxStr    = flag.Uint("max-streams", 100, "SETTINGS_MAX_CONCURRENT_STREAMS")
	tableSize = flag.Uint("table", 0, "SETTINGS_HEADER_TABLE_SIZE we advertise (decoder side)")
	delay     = flag.Duration("delay", 20*time.Millisecond, "how long each call takes")
	out       = flag.String("out", "", "file the per-connection reports are appended to")
)

var connSeq atomic.Int64

type block struct {
	Stream     uint32   `json:"stream"`
	Bytes      int      `json:"bytes"`
	Indexed    int      `json:"indexed"`
	IncIndex   int      `json:"literal_incremental"`
	NoIndex    int      `json:"literal_no_index"`
	Never      int      `json:"literal_never"`
	SizeUpdate []uint64 `json:"size_updates,omitempty"`
	Trailer    bool     `json:"trailer,omitempty"`
	Names      []string `json:"names,omitempty"`
	Kinds      []byte   `json:"-"`
	Inserted   int      `json:"inserted_bytes"`
}

type report struct {
	Conn              int64             `json:"conn"`
	ClientSettings    map[string]uint32 `json:"client_settings"`
	SentBeforeOurs    []string          `json:"frames_before_our_settings_acked"`
	FirstWindowUpdate uint32            `json:"conn_window_update"`
	Blocks            []block           `json:"header_blocks"`
	Calls             int               `json:"calls"`
	MaxOpen           int               `json:"max_open_streams"`
	RequestHeaders    map[string]string `json:"first_request_headers"`
	DataFrames        int               `json:"data_frames"`
	DataBytes         int               `json:"data_bytes"`
	Pings             int               `json:"pings"`
	RstStreams        int               `json:"rst_streams"`
	Goaway            string            `json:"goaway,omitempty"`
	DurationMs        int64             `json:"duration_ms"`
	DecoderError      string            `json:"decoder_error,omitempty"`
}

// scan walks one header block's representations without decoding strings, so
// what the client *chose* (index, insert, literal, size update) is counted.
func scan(b []byte, blk *block) {
	i := 0
	readInt := func(prefix uint) uint64 {
		mask := byte(1<<prefix - 1)
		v := uint64(b[i] & mask)
		i++
		if v < uint64(mask) {
			return v
		}
		m := uint(0)
		for i < len(b) {
			c := b[i]
			i++
			v += uint64(c&0x7f) << m
			m += 7
			if c&0x80 == 0 {
				break
			}
		}
		return v
	}
	skipString := func() {
		n := readInt(7)
		i += int(n)
	}
	for i < len(b) {
		c := b[i]
		switch {
		case c&0x80 != 0:
			readInt(7)
			blk.Indexed++
			blk.Kinds = append(blk.Kinds, 'i')
		case c&0xc0 == 0x40:
			if readInt(6) == 0 {
				skipString()
			}
			skipString()
			blk.IncIndex++
			blk.Kinds = append(blk.Kinds, '+')
		case c&0xe0 == 0x20:
			blk.SizeUpdate = append(blk.SizeUpdate, readInt(5))
		case c&0xf0 == 0x10:
			if readInt(4) == 0 {
				skipString()
			}
			skipString()
			blk.Never++
			blk.Kinds = append(blk.Kinds, 'n')
		default:
			if readInt(4) == 0 {
				skipString()
			}
			skipString()
			blk.NoIndex++
			blk.Kinds = append(blk.Kinds, 'l')
		}
	}
}

func settingName(id http2.SettingID) string { return id.String() }

func serve(c net.Conn) {
	defer c.Close()
	start := time.Now()
	r := report{Conn: connSeq.Add(1), ClientSettings: map[string]uint32{}}
	br := bufio.NewReader(c)
	preface := make([]byte, len(http2.ClientPreface))
	if _, err := io.ReadFull(br, preface); err != nil || string(preface) != http2.ClientPreface {
		log.Printf("conn %d: bad preface %q", r.Conn, preface)
		return
	}
	var wmu sync.Mutex
	fr := http2.NewFramer(c, br)
	fr.SetMaxReadFrameSize(1 << 24)

	var encBuf bytes.Buffer
	enc := hpack.NewEncoder(&encBuf)
	enc.SetMaxDynamicTableSizeLimit(0)

	wmu.Lock()
	fr.WriteSettings(
		http2.Setting{ID: http2.SettingHeaderTableSize, Val: uint32(*tableSize)},
		http2.Setting{ID: http2.SettingMaxConcurrentStreams, Val: uint32(*maxStr)},
	)
	wmu.Unlock()

	dec := hpack.NewDecoder(4096, nil)
	oursAcked := false
	open := map[uint32]bool{}
	var mu sync.Mutex
	var cur *block
	var raw []byte
	var wg sync.WaitGroup

	finishBlock := func() {
		scan(raw, cur)
		fields, err := dec.DecodeFull(raw)
		if err != nil && r.DecoderError == "" {
			r.DecoderError = err.Error()
		}
		for k, f := range fields {
			cur.Names = append(cur.Names, f.Name)
			if k < len(cur.Kinds) && cur.Kinds[k] == '+' {
				cur.Inserted += len(f.Name) + len(f.Value) + 32
			}
		}
		if r.RequestHeaders == nil && !cur.Trailer {
			r.RequestHeaders = map[string]string{}
			for _, f := range fields {
				v := f.Value
				if len(v) > 80 {
					v = v[:80] + "…"
				}
				r.RequestHeaders[f.Name] = v
			}
		}
		r.Blocks = append(r.Blocks, *cur)
		cur = nil
		raw = nil
	}

	respond := func(id uint32) {
		defer wg.Done()
		time.Sleep(*delay)
		wmu.Lock()
		defer wmu.Unlock()
		encBuf.Reset()
		enc.WriteField(hpack.HeaderField{Name: ":status", Value: "200"})
		enc.WriteField(hpack.HeaderField{Name: "content-type", Value: "application/grpc"})
		fr.WriteHeaders(http2.HeadersFrameParam{StreamID: id, BlockFragment: append([]byte(nil), encBuf.Bytes()...), EndHeaders: true})
		fr.WriteData(id, false, []byte{0, 0, 0, 0, 0})
		encBuf.Reset()
		enc.WriteField(hpack.HeaderField{Name: "grpc-status", Value: "0"})
		fr.WriteHeaders(http2.HeadersFrameParam{StreamID: id, BlockFragment: append([]byte(nil), encBuf.Bytes()...), EndHeaders: true, EndStream: true})
		mu.Lock()
		delete(open, id)
		mu.Unlock()
	}

	for {
		f, err := fr.ReadFrame()
		if err != nil {
			break
		}
		if !oursAcked {
			r.SentBeforeOurs = append(r.SentBeforeOurs, f.Header().Type.String())
		}
		switch f := f.(type) {
		case *http2.SettingsFrame:
			if f.IsAck() {
				oursAcked = true
				dec.SetAllowedMaxDynamicTableSize(uint32(*tableSize))
				continue
			}
			f.ForeachSetting(func(s http2.Setting) error {
				r.ClientSettings[settingName(s.ID)] = s.Val
				return nil
			})
			wmu.Lock()
			fr.WriteSettingsAck()
			wmu.Unlock()
		case *http2.WindowUpdateFrame:
			if f.StreamID == 0 && r.FirstWindowUpdate == 0 {
				r.FirstWindowUpdate = f.Increment
			}
		case *http2.HeadersFrame:
			mu.Lock()
			trailer := open[f.StreamID]
			if !trailer {
				open[f.StreamID] = true
				r.Calls++
				if len(open) > r.MaxOpen {
					r.MaxOpen = len(open)
				}
			}
			mu.Unlock()
			cur = &block{Stream: f.StreamID, Trailer: trailer}
			raw = append(raw[:0], f.HeaderBlockFragment()...)
			cur.Bytes = len(f.HeaderBlockFragment())
			if f.HeadersEnded() {
				finishBlock()
			}
			if f.StreamEnded() {
				wg.Add(1)
				go respond(f.StreamID)
			}
		case *http2.ContinuationFrame:
			raw = append(raw, f.HeaderBlockFragment()...)
			cur.Bytes += len(f.HeaderBlockFragment())
			if f.HeadersEnded() {
				finishBlock()
			}
		case *http2.DataFrame:
			r.DataFrames++
			r.DataBytes += len(f.Data())
			if n := len(f.Data()); n > 0 {
				wmu.Lock()
				fr.WriteWindowUpdate(0, uint32(n))
				wmu.Unlock()
			}
			if f.StreamEnded() {
				wg.Add(1)
				go respond(f.StreamID)
			}
		case *http2.PingFrame:
			r.Pings++
			if !f.IsAck() {
				wmu.Lock()
				fr.WritePing(true, f.Data)
				wmu.Unlock()
			}
		case *http2.RSTStreamFrame:
			r.RstStreams++
		case *http2.GoAwayFrame:
			r.Goaway = f.ErrCode.String()
		}
	}
	wg.Wait()
	r.DurationMs = time.Since(start).Milliseconds()
	js, _ := json.Marshal(r)
	if *out != "" {
		fh, err := os.OpenFile(*out, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
		if err == nil {
			fh.Write(append(js, '\n'))
			fh.Close()
		}
	}
	fmt.Println(string(js))
}

func main() {
	flag.Parse()
	ln, err := net.Listen("tcp", *addr)
	if err != nil {
		log.Fatal(err)
	}
	log.Printf("probe on %s, max-streams=%d table=%d delay=%s", *addr, *maxStr, *tableSize, *delay)
	for {
		c, err := ln.Accept()
		if err != nil {
			log.Fatal(err)
		}
		go serve(c)
	}
}
