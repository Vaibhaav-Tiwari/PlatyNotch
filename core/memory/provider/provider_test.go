package provider

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/config"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/protocol"
)

func readJSON(t *testing.T, r *http.Request) map[string]any {
	t.Helper()
	var m map[string]any
	if err := json.NewDecoder(r.Body).Decode(&m); err != nil {
		t.Fatalf("decode: %v", err)
	}
	return m
}

func TestOllamaEmbed(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/embed" {
			t.Errorf("path %s", r.URL.Path)
		}
		m := readJSON(t, r)
		if m["model"] != "nomic-embed-text" {
			t.Errorf("model %v", m["model"])
		}
		in := m["input"].([]any)
		if len(in) != 2 || in[0] != "a" || in[1] != "b" {
			t.Errorf("input %v", in)
		}
		w.Write([]byte(`{"embeddings":[[1,2],[3,4]]}`))
	}))
	defer srv.Close()
	e, err := NewEmbedder(config.Provider{Name: "ollama", BaseURL: srv.URL})
	if err != nil {
		t.Fatal(err)
	}
	v, err := e.Embed(context.Background(), []string{"a", "b"})
	if err != nil || len(v) != 2 || v[1][1] != 4 {
		t.Fatalf("got %v %v", v, err)
	}
	if e.Name() != "ollama" || e.Model() != "nomic-embed-text" {
		t.Fatal(e.Name(), e.Model())
	}
}

func TestOpenAIEmbedOrdersByIndex(t *testing.T) {
	t.Setenv("TEST_KEY_X", "sk-secret")
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/embeddings" || r.Header.Get("Authorization") != "Bearer sk-secret" {
			t.Errorf("bad request %s %s", r.URL.Path, r.Header.Get("Authorization"))
		}
		w.Write([]byte(`{"data":[{"index":1,"embedding":[2]},{"index":0,"embedding":[1]}]}`))
	}))
	defer srv.Close()
	e, err := NewEmbedder(config.Provider{Name: "openai", Model: "m", BaseURL: srv.URL, APIKeyRef: "env:TEST_KEY_X"})
	if err != nil {
		t.Fatal(err)
	}
	v, err := e.Embed(context.Background(), []string{"a", "b"})
	if err != nil || v[0][0] != 1 || v[1][0] != 2 {
		t.Fatalf("got %v %v", v, err)
	}
}

func TestOpenAIBatches(t *testing.T) {
	var calls int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&calls, 1)
		in := readJSON(t, r)["input"].([]any)
		if len(in) > 64 {
			t.Errorf("batch %d", len(in))
		}
		var b strings.Builder
		b.WriteString(`{"data":[`)
		for i := range in {
			if i > 0 {
				b.WriteString(",")
			}
			b.WriteString(`{"index":` + itoa(i) + `,"embedding":[1]}`)
		}
		b.WriteString(`]}`)
		w.Write([]byte(b.String()))
	}))
	defer srv.Close()
	e, _ := NewEmbedder(config.Provider{Name: "openai", Model: "m", BaseURL: srv.URL})
	texts := make([]string, 130)
	v, err := e.Embed(context.Background(), texts)
	if err != nil || len(v) != 130 || calls != 3 {
		t.Fatalf("len %d calls %d err %v", len(v), calls, err)
	}
}

func itoa(i int) string { b, _ := json.Marshal(i); return string(b) }

const canned = "Sure!\n```json\n" + `{"loops":[{"title":"Send the deck","kind":"promise","quote":"I'll send the deck","due_at":"2026-10-25T10:00:00Z","details":"d"},{"title":"","kind":"task"}],"resolutions":[{"loop_id":"L1","evidence":"Sent it."}]}` + "\n```\nHope that helps"

func TestExtractParsesJSON(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/chat" {
			t.Errorf("path %s", r.URL.Path)
		}
		m := readJSON(t, r)
		if m["format"] != "json" || m["stream"] != false {
			t.Errorf("body %v", m)
		}
		msgs := m["messages"].([]any)
		u := msgs[1].(map[string]any)["content"].(string)
		if !strings.Contains(u, "L1: Reply to Bob") {
			t.Errorf("user msg %q", u)
		}
		out, _ := json.Marshal(map[string]any{"message": map[string]any{"content": canned}})
		w.Write(out)
	}))
	defer srv.Close()
	x, err := NewExtractor(config.Provider{Name: "ollama", Model: "llama", BaseURL: srv.URL})
	if err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 10, 23, 0, 0, 0, 0, time.UTC)
	res, err := x.Extract(context.Background(), ExtractRequest{App: "Slack", Thread: "t", Text: "x",
		OpenLoops: []protocol.Loop{{ID: "L1", Title: "Reply to Bob"}}, Now: now})
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Loops) != 1 || len(res.Resolutions) != 1 {
		t.Fatalf("%+v", res)
	}
	l := res.Loops[0]
	if l.Kind != "task" || l.Status != "open" || !l.DetectedAt.Equal(now) || l.DueAt == nil {
		t.Fatalf("%+v", l)
	}
}

func TestExtractOpenAI(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		m := readJSON(t, r)
		if r.URL.Path != "/v1/chat/completions" || m["response_format"].(map[string]any)["type"] != "json_object" {
			t.Errorf("bad %s %v", r.URL.Path, m)
		}
		w.Write([]byte(`{"choices":[{"message":{"content":"{\"loops\":[{\"title\":\"` + strings.Repeat("é", 100) + `\",\"kind\":\"request\"}],\"resolutions\":[]}"}}]}`))
	}))
	defer srv.Close()
	x, _ := NewExtractor(config.Provider{Name: "openai", Model: "m", BaseURL: srv.URL})
	res, err := x.Extract(context.Background(), ExtractRequest{Text: "x"})
	if err != nil || len(res.Loops) != 1 || len([]rune(res.Loops[0].Title)) != 80 {
		t.Fatalf("%+v %v", res, err)
	}
}

func TestExtractMalformedJSON(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"message":{"content":"not json at all"}}`))
	}))
	defer srv.Close()
	x, _ := NewExtractor(config.Provider{Name: "ollama", Model: "m", BaseURL: srv.URL})
	if _, err := x.Extract(context.Background(), ExtractRequest{Text: "x"}); err == nil {
		t.Fatal("want error")
	}
}

func TestHTTPErrorTruncatedNoKey(t *testing.T) {
	t.Setenv("TEST_KEY_Y", "sk-topsecret")
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(401)
		w.Write([]byte(strings.Repeat("x", 1000)))
	}))
	defer srv.Close()
	e, _ := NewEmbedder(config.Provider{Name: "openai", Model: "m", BaseURL: srv.URL, APIKeyRef: "env:TEST_KEY_Y"})
	_, err := e.Embed(context.Background(), []string{"a"})
	if err == nil || !strings.Contains(err.Error(), "401") || len(err.Error()) > 400 || strings.Contains(err.Error(), "topsecret") {
		t.Fatalf("err %v", err)
	}
}

func TestMissingModels(t *testing.T) {
	if _, err := NewExtractor(config.Provider{Name: "ollama"}); err == nil {
		t.Fatal("ollama extractor needs model")
	}
	if _, err := NewEmbedder(config.Provider{Name: "openai"}); err == nil {
		t.Fatal("openai embedder needs model")
	}
}

func TestNoneReturnsNil(t *testing.T) {
	e, err := NewEmbedder(config.Provider{Name: "none"})
	if e != nil || err != nil {
		t.Fatal(e, err)
	}
	x, err := NewExtractor(config.Provider{})
	if x != nil || err != nil {
		t.Fatal(x, err)
	}
	if _, err := NewEmbedder(config.Provider{Name: "bogus"}); err == nil {
		t.Fatal("unknown should error")
	}
}

type fakeEmb struct{}

func (fakeEmb) Name() string  { return "fake" }
func (fakeEmb) Model() string { return "f" }
func (fakeEmb) Embed(context.Context, []string) ([][]float32, error) {
	return nil, nil
}

func TestRegisterCustom(t *testing.T) {
	RegisterEmbedder("fake", func(config.Provider) (Embedder, error) { return fakeEmb{}, nil })
	e, err := NewEmbedder(config.Provider{Name: "fake"})
	if err != nil || e.Name() != "fake" {
		t.Fatal(e, err)
	}
}
