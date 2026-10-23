package provider

import (
	"context"
	"fmt"
	"net/http"
	"sort"
	"strings"

	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/config"
)

const openAIBase = "https://api.openai.com"

type openAI struct {
	base, model, key string
	c                *http.Client
}

type openAIEmbedder struct{ openAI }
type openAIExtractor struct{ openAI }

func newOpenAI(p config.Provider) (openAI, error) {
	if p.Model == "" {
		return openAI{}, fmt.Errorf("openai provider requires a model")
	}
	key, err := config.Secret(p.APIKeyRef)
	if err != nil {
		return openAI{}, fmt.Errorf("read API key: %w", err)
	}
	base := strings.TrimRight(p.BaseURL, "/")
	if base == "" {
		base = openAIBase
	}
	return openAI{base, p.Model, key, newClient()}, nil
}

func newOpenAIEmbedder(p config.Provider) (Embedder, error) {
	o, err := newOpenAI(p)
	if err != nil {
		return nil, err
	}
	return &openAIEmbedder{o}, nil
}

func newOpenAIExtractor(p config.Provider) (Extractor, error) {
	o, err := newOpenAI(p)
	if err != nil {
		return nil, err
	}
	return &openAIExtractor{o}, nil
}

func (o openAI) Name() string  { return "openai" }
func (o openAI) Model() string { return o.model }

func (o *openAIEmbedder) Embed(ctx context.Context, texts []string) ([][]float32, error) {
	return embedBatched(ctx, texts, func(b []string) ([][]float32, error) {
		var out struct {
			Data []struct {
				Index     int       `json:"index"`
				Embedding []float32 `json:"embedding"`
			} `json:"data"`
		}
		err := postJSON(ctx, o.c, o.base+"/v1/embeddings", o.key, map[string]any{"model": o.model, "input": b}, &out)
		if err != nil {
			return nil, err
		}
		sort.SliceStable(out.Data, func(i, j int) bool { return out.Data[i].Index < out.Data[j].Index })
		v := make([][]float32, len(out.Data))
		for i, d := range out.Data {
			v[i] = d.Embedding
		}
		return v, nil
	})
}

func (o *openAIExtractor) Extract(ctx context.Context, r ExtractRequest) (ExtractResult, error) {
	var out struct {
		Choices []struct {
			Message struct {
				Content string `json:"content"`
			} `json:"message"`
		} `json:"choices"`
	}
	err := postJSON(ctx, o.c, o.base+"/v1/chat/completions", o.key, map[string]any{
		"model":           o.model,
		"response_format": map[string]string{"type": "json_object"},
		"messages": []map[string]string{
			{"role": "system", "content": ExtractPrompt},
			{"role": "user", "content": userMessage(r)},
		},
	}, &out)
	if err != nil {
		return ExtractResult{}, err
	}
	if len(out.Choices) == 0 {
		return ExtractResult{}, fmt.Errorf("provider returned no choices")
	}
	return parseExtract(out.Choices[0].Message.Content, r.Now)
}
