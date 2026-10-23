// Package wire reads and writes protocol envelopes as newline-delimited JSON.
package wire

import (
	"bufio"
	"encoding/json"
	"io"
	"sync"

	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/protocol"
)

// MaxLine bounds one message (hook payloads can carry large tool inputs).
const MaxLine = 4 << 20

// Reader decodes one envelope per line.
type Reader struct{ sc *bufio.Scanner }

func NewReader(r io.Reader) *Reader {
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 64<<10), MaxLine)
	return &Reader{sc: sc}
}

// Read returns the next envelope, skipping blank lines. io.EOF at end.
func (r *Reader) Read() (protocol.Envelope, error) {
	for r.sc.Scan() {
		line := r.sc.Bytes()
		if len(line) == 0 {
			continue
		}
		var env protocol.Envelope
		if err := json.Unmarshal(line, &env); err != nil {
			return env, err
		}
		return env, nil
	}
	if err := r.sc.Err(); err != nil {
		return protocol.Envelope{}, err
	}
	return protocol.Envelope{}, io.EOF
}

// Writer encodes envelopes, one per line; safe for concurrent use.
type Writer struct {
	mu sync.Mutex
	w  io.Writer
}

func NewWriter(w io.Writer) *Writer { return &Writer{w: w} }

func (w *Writer) Write(env protocol.Envelope) error {
	if env.V == 0 {
		env.V = protocol.Version
	}
	b, err := json.Marshal(env)
	if err != nil {
		return err
	}
	b = append(b, '\n')
	w.mu.Lock()
	defer w.mu.Unlock()
	_, err = w.w.Write(b)
	return err
}

// Send marshals data into an envelope and writes it.
func (w *Writer) Send(typ, id string, data any) error {
	env, err := protocol.New(typ, id, data)
	if err != nil {
		return err
	}
	return w.Write(env)
}
