package wire

import (
	"bytes"
	"io"
	"strings"
	"testing"

	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/protocol"
)

func TestReaderSkipsBlankLinesAndRejectsOversize(t *testing.T) {
	in := "\n" + `{"v":1,"type":"ping"}` + "\n\n"
	r := NewReader(strings.NewReader(in))
	env, err := r.Read()
	if err != nil || env.Type != protocol.TypePing {
		t.Fatalf("got %+v, %v", env, err)
	}
	if _, err := r.Read(); err != io.EOF {
		t.Fatalf("want EOF, got %v", err)
	}

	big := strings.Repeat("a", 5<<20) + "\n"
	if _, err := NewReader(strings.NewReader(big)).Read(); err == nil || err == io.EOF {
		t.Fatalf("want oversize error, got %v", err)
	}
}

func TestWriterSendRoundTrip(t *testing.T) {
	var buf bytes.Buffer
	w := NewWriter(&buf)
	if err := w.Send(protocol.TypeNotice, "7", protocol.Notice{Kind: "info", Title: "hi"}); err != nil {
		t.Fatal(err)
	}
	env, err := NewReader(&buf).Read()
	if err != nil {
		t.Fatal(err)
	}
	var n protocol.Notice
	if err := env.Decode(&n); err != nil || n.Title != "hi" || env.V != protocol.Version || env.ID != "7" {
		t.Fatalf("got %+v %+v %v", env, n, err)
	}
}
