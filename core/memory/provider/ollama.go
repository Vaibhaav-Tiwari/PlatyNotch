package provider

import (
	"context"
	"fmt"
	"net/http"
	"strings"

	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/config"
)

const (
	ollamaBase       = "http://127.0.0.1:11434"
	ollamaEmbedModel = "nomic-embed-text"
)

type ollama struct {
	base, model string
	c           *http.Client
}

func ollamaBaseURL(p config.Provider) string {
	if p.BaseURL == "" {
		return ollamaBase
	}
	return strings.TrimRight(p.BaseURL, "/")
}

type ollamaEmbedder struct{ ollama }
type ollamaExtractor struct{ ollama }

func newOllamaEmbedder(p config.Provider) Embedder {
	m := p.Model
	if m == "" {
		m = ollamaEmbedModel
	}
	return &ollamaEmbedder{ollama{ollamaBaseURL(p), m, newClient()}}
}

func newOllamaExtractor(p config.Provider) (Extractor, error) {
	if p.Model == "" {
		return nil, fmt.Errorf("ollama extractor requires a model")
	}
	return &ollamaExtractor{ollama{ollamaBaseURL(p), p.Model, newClient()}}, nil
}

func (o ollama) Name() string  { return "ollama" }
func (o ollama) Model() string { return o.model }

func (o *ollamaEmbedder) Embed(ctx context.Context, texts []string) ([][]float32, error) {
	return embedBatched(ctx, texts, func(b []string) ([][]float32, error) {
		var out struct {
			Embeddings [][]float32 `json:"embeddings"`
		}
		err := postJSON(ctx, o.c, o.base+"/api/embed", "", map[string]any{"model": o.model, "input": b}, &out)
		return out.Embeddings, err
	})
}

func (o *ollamaExtractor) Extract(ctx context.Context, r ExtractRequest) (ExtractResult, error) {
	var out struct {
		Message struct {
			Content string `json:"content"`
		} `json:"message"`
	}
	err := postJSON(ctx, o.c, o.base+"/api/chat", "", map[string]any{
		"model": o.model, "format": "json", "stream": false,
		"messages": []map[string]string{
			{"role": "system", "content": ExtractPrompt},
			{"role": "user", "content": userMessage(r)},
		},
	}, &out)
	if err != nil {
		return ExtractResult{}, err
	}
	return parseExtract(out.Message.Content, r)
}
