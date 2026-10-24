// Package graph builds the free memory graph: the apps, threads, sites and
// open loops active in a time window, and how they link. It is derived on the
// fly from threads, versions and loops (no edges table), which stays in tens
// of milliseconds for a 7–30 day window. Windows are capped at 90 days (the
// default retention); longer ones would want edges precomputed at ingest
// (a thread_edges table, a follow-up). AI-built links (topics, resolution
// links) are not built here.
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
	MaxHours        = 2160 // 90 days, the default retention
	DefaultMaxNodes = 100
	MaxMaxNodes     = 500
	// TogetherGap is the longest gap between two consecutive versions that
	// still links their threads as active one after another.
	TogetherGap = 45 * time.Minute
)

// Window returns the query's start: Since, else now minus Hours (default
// DefaultHours); never earlier than now minus MaxHours.
func Window(q protocol.MemoryGraphQuery, now time.Time) time.Time {
	earliest := now.Add(-MaxHours * time.Hour)
	if q.Since != nil {
		if q.Since.Before(earliest) {
			return earliest
		}
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
// loop's is 0.5 plus half its source thread's (0.5 when the thread is not in
// the window), so a loop never outranks its own thread. Edge weights are the
// thread's weight (in, on), the loop's (detected_in), 1 (from_app) or how
// often two threads were active one after another, at most TogetherGap apart
// (together). Only the MaxNodes heaviest nodes are kept (ties: kind, then id)
// with the edges between them. A loop whose source_thread is gone, outside
// the window or cut links to its app instead, when the app is kept. An app's
// label is the newest non-empty name among its threads (else its bundle id).
func Build(s *store.Store, q protocol.MemoryGraphQuery, now time.Time) (protocol.MemoryGraph, error) {
	since := Window(q, now)
	f := store.Filter{Since: since, App: q.App}
	maxNodes := q.MaxNodes
	if maxNodes <= 0 {
		maxNodes = DefaultMaxNodes
	}
	maxNodes = min(maxNodes, MaxMaxNodes)

	visits, threads, err := s.GraphWindow(f)
	if err != nil {
		return protocol.MemoryGraph{}, err
	}
	g := newBuilder()
	// Active hours per thread, and threads active one after another.
	hours := map[string]float64{}
	switches := map[[2]string]float64{}
	var prev store.VersionVisit
	for _, v := range visits {
		hours[v.ThreadID]++
		if prev.ThreadID != "" && prev.ThreadID != v.ThreadID && v.At.Sub(prev.At) <= TogetherGap {
			switches[pair(prev.ThreadID, v.ThreadID)]++
		}
		prev = v
	}
	// Threads come newest first: the first name seen for a bundle (and the
	// first bundle seen for a name, so a loop's app is the newest bundle with
	// that name) wins.
	apps := map[string]string{} // lower-cased app name and bundle → app node id
	for _, t := range threads {
		w := hours[t.ID]
		g.add(t.ID, protocol.GraphThread, t.Title, w)
		app := "app:" + t.AppBundle
		g.add(app, protocol.GraphApp, cmp.Or(t.AppName, t.AppBundle), w)
		if n := g.nodes[app]; n.Label == t.AppBundle && t.AppName != "" {
			n.Label = t.AppName // the newest non-empty name beats the bundle id
		}
		g.edge(app, t.ID, protocol.EdgeIn, w)
		for _, k := range []string{t.AppBundle, t.AppName} {
			if k := strings.ToLower(k); k != "" && apps[k] == "" {
				apps[k] = app
			}
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
		app := apps[strings.ToLower(l.SourceApp)]
		if !inGraph && (l.DetectedAt.Before(since) || (q.App != "" && app == "")) {
			continue
		}
		id := "loop:" + l.ID
		w := 0.5 + tw/2
		g.add(id, protocol.GraphLoop, l.Title, w)
		if app != "" {
			g.fallback[id] = app
		}
		if inGraph {
			g.edge(id, l.SourceThread, protocol.EdgeDetectedIn, w)
		} else if app != "" {
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
	nodes    map[string]*protocol.GraphNode
	edges    map[[3]string]*protocol.GraphEdge
	fallback map[string]string // loop node id → its app node id
}

func newBuilder() *builder {
	return &builder{nodes: map[string]*protocol.GraphNode{}, edges: map[[3]string]*protocol.GraphEdge{}, fallback: map[string]string{}}
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

var kindRank = map[string]int{protocol.GraphApp: 0, protocol.GraphThread: 1, protocol.GraphSite: 2, protocol.GraphLoop: 3, protocol.GraphTopic: 4}

// capped keeps the n heaviest nodes and the edges whose ends both survive,
// links a kept loop that lost its thread to its app (when kept), and sorts
// everything so the same data always gives the same graph.
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
	linked := map[string]bool{}
	for _, e := range b.edges {
		if kept[e.From] && kept[e.To] {
			edges = append(edges, *e)
			linked[e.From] = true
		}
	}
	for _, v := range nodes {
		if app := b.fallback[v.ID]; v.Kind == protocol.GraphLoop && !linked[v.ID] && kept[app] {
			edges = append(edges, protocol.GraphEdge{From: v.ID, To: app, Kind: protocol.EdgeFromApp, Weight: 1})
		}
	}
	slices.SortFunc(edges, func(x, y protocol.GraphEdge) int {
		return cmp.Or(cmp.Compare(x.From, y.From), cmp.Compare(x.To, y.To), cmp.Compare(x.Kind, y.Kind))
	})
	return protocol.MemoryGraph{Nodes: nodes, Edges: edges}
}
