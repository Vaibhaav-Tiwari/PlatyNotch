// Package graph builds the free memory graph: the apps, threads, sites and
// open loops active in a time window, and how they link. It is derived on the
// fly from threads, versions and loops (no edges table), which stays in tens
// of milliseconds for a 7–30 day window; a year view would want precomputed
// edges. AI-built links (topics, resolution links) are not built here.
package graph

import (
	"cmp"
	"net/url"
	"slices"
	"strings"
	"time"

	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/memory/store"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/protocol"
)

const (
	DefaultHours    = 168
	MaxHours        = 24 * 365
	DefaultMaxNodes = 100
	MaxMaxNodes     = 500
)

// Window returns the query's start: Since, else now minus Hours (default
// DefaultHours, at most MaxHours).
func Window(q protocol.MemoryGraphQuery, now time.Time) time.Time {
	if q.Since != nil {
		return *q.Since
	}
	h := q.Hours
	if h <= 0 {
		h = DefaultHours
	}
	return now.Add(-time.Duration(min(h, MaxHours)) * time.Hour)
}

// Build returns the graph for q. Weights: a thread's is its active hours in
// the window (versions); an app's or site's is the sum of its threads'; a
// loop's is 1 plus its source thread's. Edge weights are the thread's weight
// (in, on, detected_in), 1 (from_app) or the number of window switches
// between two threads (together). Only the MaxNodes heaviest nodes are kept
// (ties: kind, then id) with the edges between them. A loop whose
// source_thread is gone or outside the window links to its app instead.
func Build(s *store.Store, q protocol.MemoryGraphQuery, now time.Time) (protocol.MemoryGraph, error) {
	since := Window(q, now)
	f := store.Filter{Since: since, App: q.App}
	maxNodes := q.MaxNodes
	if maxNodes <= 0 {
		maxNodes = DefaultMaxNodes
	}
	maxNodes = min(maxNodes, MaxMaxNodes)

	g := newBuilder()
	// Active hours per thread and window switches, in one pass over versions.
	hours := map[string]float64{}
	switches := map[[2]string]float64{}
	prev := ""
	if err := s.VisitVersionTimes(f, func(id string) {
		hours[id]++
		if prev != "" && prev != id {
			switches[pair(prev, id)]++
		}
		prev = id
	}); err != nil {
		return protocol.MemoryGraph{}, err
	}
	threads, err := s.ThreadsWithVersions(f)
	if err != nil {
		return protocol.MemoryGraph{}, err
	}
	apps := map[string]string{} // lower-cased app name and bundle → app node id
	for _, t := range threads {
		w := hours[t.ID]
		g.add(t.ID, protocol.GraphThread, t.Title, w)
		app := "app:" + t.AppBundle
		g.add(app, protocol.GraphApp, cmp.Or(t.AppName, t.AppBundle), w)
		g.edge(app, t.ID, protocol.EdgeIn, w)
		apps[strings.ToLower(t.AppBundle)] = app
		if t.AppName != "" {
			apps[strings.ToLower(t.AppName)] = app
		}
		if h := host(t.URL); h != "" {
			site := "site:" + h
			g.add(site, protocol.GraphSite, h, w)
			g.edge(t.ID, site, protocol.EdgeOn, w)
		}
	}
	for p, n := range switches {
		g.edge(p[0], p[1], protocol.EdgeTogether, n)
	}

	open, err := s.ListLoops("open", 0)
	if err != nil {
		return protocol.MemoryGraph{}, err
	}
	for _, l := range open {
		tw, inGraph := hours[l.SourceThread]
		inGraph = inGraph && l.SourceThread != ""
		fromApp := q.App == "" || apps[strings.ToLower(l.SourceApp)] != ""
		if !inGraph && (l.DetectedAt.Before(since) || !fromApp) {
			continue
		}
		id := "loop:" + l.ID
		g.add(id, protocol.GraphLoop, l.Title, 1+tw)
		if inGraph {
			g.edge(id, l.SourceThread, protocol.EdgeDetectedIn, 1+tw)
		} else if app := apps[strings.ToLower(l.SourceApp)]; app != "" {
			g.edge(id, app, protocol.EdgeFromApp, 1)
		}
	}
	return g.capped(maxNodes), nil
}

// host is the URL's host without "www.", lower-cased; "" when there is none.
func host(raw string) string {
	if raw == "" {
		return ""
	}
	u, err := url.Parse(raw)
	if err != nil {
		return ""
	}
	return strings.TrimPrefix(strings.ToLower(u.Hostname()), "www.")
}

func pair(a, b string) [2]string {
	if b < a {
		a, b = b, a
	}
	return [2]string{a, b}
}

type builder struct {
	nodes map[string]*protocol.GraphNode
	edges map[[3]string]*protocol.GraphEdge
}

func newBuilder() *builder {
	return &builder{nodes: map[string]*protocol.GraphNode{}, edges: map[[3]string]*protocol.GraphEdge{}}
}

// add creates the node or adds w to its weight.
func (b *builder) add(id, kind, label string, w float64) {
	if n := b.nodes[id]; n != nil {
		n.Weight += w
		return
	}
	b.nodes[id] = &protocol.GraphNode{ID: id, Kind: kind, Label: label, Weight: w}
}

func (b *builder) edge(from, to, kind string, w float64) {
	k := [3]string{from, to, kind}
	if e := b.edges[k]; e != nil {
		e.Weight += w
		return
	}
	b.edges[k] = &protocol.GraphEdge{From: from, To: to, Kind: kind, Weight: w}
}

var kindRank = map[string]int{protocol.GraphApp: 0, protocol.GraphLoop: 1, protocol.GraphThread: 2, protocol.GraphSite: 3, protocol.GraphTopic: 4}

// capped keeps the n heaviest nodes and the edges whose ends both survive,
// sorted so the same data always gives the same graph.
func (b *builder) capped(n int) protocol.MemoryGraph {
	nodes := make([]protocol.GraphNode, 0, len(b.nodes))
	for _, v := range b.nodes {
		nodes = append(nodes, *v)
	}
	slices.SortFunc(nodes, func(x, y protocol.GraphNode) int {
		return cmp.Or(cmp.Compare(y.Weight, x.Weight), cmp.Compare(kindRank[x.Kind], kindRank[y.Kind]), cmp.Compare(x.ID, y.ID))
	})
	if len(nodes) > n {
		nodes = nodes[:n]
	}
	kept := make(map[string]bool, len(nodes))
	for _, v := range nodes {
		kept[v.ID] = true
	}
	edges := []protocol.GraphEdge{}
	for _, e := range b.edges {
		if kept[e.From] && kept[e.To] {
			edges = append(edges, *e)
		}
	}
	slices.SortFunc(edges, func(x, y protocol.GraphEdge) int {
		return cmp.Or(cmp.Compare(x.From, y.From), cmp.Compare(x.To, y.To), cmp.Compare(x.Kind, y.Kind))
	})
	return protocol.MemoryGraph{Nodes: nodes, Edges: edges}
}
