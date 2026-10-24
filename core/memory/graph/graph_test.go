package graph

import (
	"database/sql"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/memory/store"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/protocol"
)

var now = time.Date(2026, 10, 24, 12, 0, 0, 0, time.UTC)

func newStore(t testing.TB) *store.Store {
	t.Helper()
	s, err := store.Open(filepath.Join(t.TempDir(), "m.db"), false)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	return s
}

type seedThread struct {
	bundle, name, key, title, url string
	ago                           []time.Duration // one version per entry, now minus ago
}

// seed stores the threads and returns their ids by key.
func seed(t *testing.T, s *store.Store, ts []seedThread) map[string]string {
	t.Helper()
	ids := map[string]string{}
	for _, st := range ts {
		th, err := s.UpsertThread(store.Thread{AppBundle: st.bundle, AppName: st.name, Key: st.key, Title: st.title, URL: st.url})
		if err != nil {
			t.Fatal(err)
		}
		ids[st.key] = th.ID
		for _, a := range st.ago {
			at := now.Add(-a)
			if _, err := s.PutVersion(store.Version{ThreadID: th.ID, HourBucket: at.Unix() / 3600, Content: st.key, CreatedAt: at}); err != nil {
				t.Fatal(err)
			}
		}
	}
	return ids
}

func addLoop(t *testing.T, s *store.Store, title, app, thread string, detected time.Time) {
	t.Helper()
	if _, err := s.ApplyLoops([]store.Loop{{Title: title, Kind: "task", SourceApp: app, SourceThread: thread, TitleHash: title, DetectedAt: detected}}, nil, now); err != nil {
		t.Fatal(err)
	}
}

func h(n int) time.Duration { return time.Duration(n) * time.Hour }

func ptr(t time.Time) *time.Time { return &t }

// render is a compact text form of a graph: sorted "kind:label=weight" lines
// for the nodes, then sorted "from>to kind=weight" lines for the edges, with
// ids (random for threads) replaced by labels.
func render(g protocol.MemoryGraph) string {
	label := map[string]string{}
	var nodes, edges []string
	for _, n := range g.Nodes {
		label[n.ID] = n.Kind + ":" + n.Label
		nodes = append(nodes, fmt.Sprintf("%s:%s=%g\n", n.Kind, n.Label, n.Weight))
	}
	for _, e := range g.Edges {
		edges = append(edges, fmt.Sprintf("%s>%s %s=%g\n", label[e.From], label[e.To], e.Kind, e.Weight))
	}
	slices.Sort(nodes)
	slices.Sort(edges)
	return strings.Join(nodes, "") + strings.Join(edges, "")
}

func TestBuild(t *testing.T) {
	threads := []seedThread{
		// Safari: two pages on one site, switched between with Mail.
		{"com.apple.Safari", "Safari", "pr", "PR 12", "https://www.github.com/x/y/pull/12", []time.Duration{h(1), h(3)}},
		{"com.apple.Safari", "Safari", "issues", "Issues", "https://github.com/x/y/issues", []time.Duration{h(2)}},
		{"com.apple.mail", "Mail", "inbox", "Inbox", "", []time.Duration{h(1) + time.Minute, h(5), h(6)}},
		// Outside a 24 h window, inside the default 168 h one.
		{"com.apple.Notes", "Notes", "old", "Old note", "", []time.Duration{h(48)}},
	}
	type tc struct {
		name  string
		q     protocol.MemoryGraphQuery
		loops func(t *testing.T, s *store.Store, ids map[string]string)
		want  string
	}
	since := now.Add(-h(2) - time.Minute)
	cases := []tc{
		{name: "default window", q: protocol.MemoryGraphQuery{}, want: `app:Mail=3
app:Notes=1
app:Safari=3
site:github.com=3
thread:Inbox=3
thread:Issues=1
thread:Old note=1
thread:PR 12=2
app:Mail>thread:Inbox in=3
app:Notes>thread:Old note in=1
app:Safari>thread:Issues in=1
app:Safari>thread:PR 12 in=2
thread:Issues>site:github.com on=1
thread:PR 12>site:github.com on=2
`},
		{name: "24 hours", q: protocol.MemoryGraphQuery{Hours: 24}, want: `app:Mail=3
app:Safari=3
site:github.com=3
thread:Inbox=3
thread:Issues=1
thread:PR 12=2
app:Mail>thread:Inbox in=3
app:Safari>thread:Issues in=1
app:Safari>thread:PR 12 in=2
thread:Issues>site:github.com on=1
thread:PR 12>site:github.com on=2
`},
		{name: "app filter", q: protocol.MemoryGraphQuery{Hours: 24, App: "MAIL"}, want: `app:Mail=3
thread:Inbox=3
app:Mail>thread:Inbox in=3
`},
		{name: "since wins over hours", q: protocol.MemoryGraphQuery{Since: &since, Hours: 1}, want: `app:Mail=1
app:Safari=2
site:github.com=2
thread:Inbox=1
thread:Issues=1
thread:PR 12=1
app:Mail>thread:Inbox in=1
app:Safari>thread:Issues in=1
app:Safari>thread:PR 12 in=1
thread:Issues>site:github.com on=1
thread:PR 12>site:github.com on=1
`},
		{name: "cap keeps the heaviest and drops their edges", q: protocol.MemoryGraphQuery{Hours: 24, MaxNodes: 3}, want: `app:Mail=3
app:Safari=3
thread:Inbox=3
app:Mail>thread:Inbox in=3
`},
		{name: "loops: in window, dangling, other app", q: protocol.MemoryGraphQuery{Hours: 24},
			loops: func(t *testing.T, s *store.Store, ids map[string]string) {
				addLoop(t, s, "Reply to Sam", "Mail", ids["inbox"], now.Add(-h(30)))   // old, but its thread is active
				addLoop(t, s, "Send deck", "Mail", "purged-thread", now.Add(-h(1)))    // dangling: links to its app
				addLoop(t, s, "Call bank", "Phone", "gone", now.Add(-h(2)))            // dangling, unknown app: alone
				addLoop(t, s, "Old promise", "Mail", "purged-thread", now.Add(-h(40))) // dangling and old: left out
			},
			want: `app:Mail=3
app:Safari=3
loop:Call bank=0.5
loop:Reply to Sam=2
loop:Send deck=0.5
site:github.com=3
thread:Inbox=3
thread:Issues=1
thread:PR 12=2
app:Mail>thread:Inbox in=3
app:Safari>thread:Issues in=1
app:Safari>thread:PR 12 in=2
loop:Reply to Sam>thread:Inbox detected_in=2
loop:Send deck>app:Mail from_app=1
thread:Issues>site:github.com on=1
thread:PR 12>site:github.com on=2
`},
		{name: "loops with an app filter", q: protocol.MemoryGraphQuery{Hours: 24, App: "com.apple.Safari"},
			loops: func(t *testing.T, s *store.Store, ids map[string]string) {
				addLoop(t, s, "Review PR", "Safari", ids["pr"], now.Add(-h(1)))
				addLoop(t, s, "Send deck", "Mail", "purged-thread", now.Add(-h(1))) // another app: left out
				addLoop(t, s, "Read docs", "Safari", "gone", now.Add(-h(1)))        // dangling: to Safari
			},
			want: `app:Safari=3
loop:Read docs=0.5
loop:Review PR=1.5
site:github.com=3
thread:Issues=1
thread:PR 12=2
app:Safari>thread:Issues in=1
app:Safari>thread:PR 12 in=2
loop:Read docs>app:Safari from_app=1
loop:Review PR>thread:PR 12 detected_in=1.5
thread:Issues>site:github.com on=1
thread:PR 12>site:github.com on=2
`},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			s := newStore(t)
			ids := seed(t, s, threads)
			if c.loops != nil {
				c.loops(t, s, ids)
			}
			g, err := Build(s, c.q, now)
			if err != nil {
				t.Fatal(err)
			}
			got := withoutTogether(render(g))
			if got != c.want {
				t.Fatalf("graph\n%s\nwant\n%s", got, c.want)
			}
			for _, e := range g.Edges {
				if !has(g, e.From) || !has(g, e.To) {
					t.Fatalf("edge to a cut node: %+v", e)
				}
			}
		})
	}
}

func withoutTogether(s string) string {
	var out []string
	for _, l := range strings.SplitAfter(s, "\n") {
		if !strings.Contains(l, " together=") {
			out = append(out, l)
		}
	}
	return strings.Join(out, "")
}

func has(g protocol.MemoryGraph, id string) bool {
	for _, n := range g.Nodes {
		if n.ID == id {
			return true
		}
	}
	return false
}

func m(n int) time.Duration { return time.Duration(n) * time.Minute }

// TestTogetherCountsWindowSwitches: consecutive versions of different threads
// at most TogetherGap apart link them, weighted by how often that happened.
func TestTogetherCountsWindowSwitches(t *testing.T) {
	s := newStore(t)
	ids := seed(t, s, []seedThread{
		{"a", "A", "a", "A1", "", []time.Duration{m(300), m(240), m(180)}},
		{"b", "B", "b", "B1", "", []time.Duration{m(270), m(210)}},
		{"c", "C", "c", "C1", "", []time.Duration{m(150)}},
		{"d", "D", "d", "D1", "", []time.Duration{m(60)}}, // 90 minutes after c: not together
	})
	g, err := Build(s, protocol.MemoryGraphQuery{Hours: 24}, now)
	if err != nil {
		t.Fatal(err)
	}
	got := map[[2]string]float64{}
	for _, e := range g.Edges {
		if e.Kind == protocol.EdgeTogether {
			got[[2]string{e.From, e.To}] = e.Weight
		}
	}
	// a b a b a c (30 minutes apart each), then d: a–b four times, a–c once.
	want := map[[2]string]float64{pair(ids["a"], ids["b"]): 4, pair(ids["a"], ids["c"]): 1}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("together = %v, want %v", got, want)
	}
}

// TestAppLabelIsTheNewestThreadsName: two names for one bundle (an app
// renamed, or localised) give the name on the most recently updated thread,
// in every fresh database; a loop's app name resolves the same way.
func TestAppLabelIsTheNewestThreadsName(t *testing.T) {
	for i := range 6 {
		s := newStore(t)
		old, newer := "Old Name", "New Name"
		if i%2 == 1 {
			old, newer = newer, old
		}
		seed(t, s, []seedThread{{"com.x.app", old, "k1", "First", "", []time.Duration{h(2)}}})
		time.Sleep(3 * time.Millisecond) // a later updated_at
		seed(t, s, []seedThread{{"com.x.app", newer, "k2", "Second", "", []time.Duration{h(1)}}})
		addLoop(t, s, "Loop", old, "gone", now.Add(-h(1)))
		g, err := Build(s, protocol.MemoryGraphQuery{Hours: 24}, now)
		if err != nil {
			t.Fatal(err)
		}
		var label string
		for _, n := range g.Nodes {
			if n.Kind == protocol.GraphApp {
				label = n.Label
			}
		}
		if label != newer {
			t.Fatalf("db %d: app label %q, want %q", i, label, newer)
		}
		if !strings.Contains(render(g), "loop:Loop>app:"+newer+" from_app=1") {
			t.Fatalf("db %d: loop not linked to its app by either name:\n%s", i, render(g))
		}
	}
}

// TestLoopAppNameSharedByTwoBundles: one app name on two bundles (two builds
// of an app) links a loop by that name to the bundle with the newest thread,
// in every fresh database.
func TestLoopAppNameSharedByTwoBundles(t *testing.T) {
	for i := range 6 {
		s := newStore(t)
		older, newer := "com.x.chat", "com.x.chat.beta"
		if i%2 == 1 {
			older, newer = newer, older
		}
		seed(t, s, []seedThread{{older, "Chat", "k1", "First", "", []time.Duration{h(2)}}})
		time.Sleep(3 * time.Millisecond) // a later updated_at
		seed(t, s, []seedThread{{newer, "Chat", "k2", "Second", "", []time.Duration{h(1)}}})
		addLoop(t, s, "Loop", "chat", "gone", now.Add(-h(1)))
		g, err := Build(s, protocol.MemoryGraphQuery{Hours: 24}, now)
		if err != nil {
			t.Fatal(err)
		}
		var to []string
		for _, e := range g.Edges {
			if e.Kind == protocol.EdgeFromApp {
				to = append(to, e.To)
			}
		}
		if len(to) != 1 || to[0] != "app:"+newer {
			t.Fatalf("db %d: loop linked to %v, want [app:%s]", i, to, newer)
		}
	}
}

// TestAppLabelSkipsAnEmptyName: when the newest thread of a bundle has no app
// name, the label is the newest non-empty one, not the bundle id.
func TestAppLabelSkipsAnEmptyName(t *testing.T) {
	s := newStore(t)
	seed(t, s, []seedThread{{"com.x.app", "Oldest", "k1", "A", "", []time.Duration{h(3)}}})
	time.Sleep(3 * time.Millisecond)
	seed(t, s, []seedThread{{"com.x.app", "Named", "k2", "B", "", []time.Duration{h(2)}}})
	time.Sleep(3 * time.Millisecond)
	seed(t, s, []seedThread{{"com.x.app", "", "k3", "C", "", []time.Duration{h(1)}}})
	seed(t, s, []seedThread{{"com.y.nameless", "", "k4", "D", "", []time.Duration{h(1)}}})
	g, err := Build(s, protocol.MemoryGraphQuery{Hours: 24}, now)
	if err != nil {
		t.Fatal(err)
	}
	labels := map[string]string{}
	for _, n := range g.Nodes {
		labels[n.ID] = n.Label
	}
	if labels["app:com.x.app"] != "Named" || labels["app:com.y.nameless"] != "com.y.nameless" {
		t.Fatalf("labels = %v", labels)
	}
}

// TestCapNeverOrphansALoop: under any cap, every kept loop has an edge
// whenever its app is kept, and no loop outranks its own thread.
func TestCapNeverOrphansALoop(t *testing.T) {
	s := newStore(t)
	var ts []seedThread
	for i := range 12 {
		var ago []time.Duration
		for j := range i%4 + 1 {
			ago = append(ago, h(j*3+i%3))
		}
		ts = append(ts, seedThread{fmt.Sprint("b", i%3), fmt.Sprint("App", i%3), fmt.Sprint(i), fmt.Sprint("T", i), "", ago})
	}
	ids := seed(t, s, ts)
	for i := range 12 {
		addLoop(t, s, fmt.Sprint("L", i), fmt.Sprint("App", i%3), ids[fmt.Sprint(i)], now.Add(-h(1)))
	}
	addLoop(t, s, "Dangling", "App1", "purged", now.Add(-h(1)))
	for cap := 1; cap <= 30; cap++ {
		g, err := Build(s, protocol.MemoryGraphQuery{Hours: 24, MaxNodes: cap}, now)
		if err != nil {
			t.Fatal(err)
		}
		weight := map[string]float64{}
		for _, n := range g.Nodes {
			weight[n.ID] = n.Weight
		}
		linked := map[string]bool{}
		for _, e := range g.Edges {
			linked[e.From] = true
		}
		for _, n := range g.Nodes {
			if n.Kind != protocol.GraphLoop {
				continue
			}
			app := "app:b1" // Dangling's
			if n.Label != "Dangling" {
				var i int
				fmt.Sscan(strings.TrimPrefix(n.Label, "L"), &i)
				app = fmt.Sprint("app:b", i%3)
				if tw, ok := weight[ids[fmt.Sprint(i)]]; ok && n.Weight > tw {
					t.Fatalf("cap %d: loop %s (%g) outweighs its thread (%g)", cap, n.Label, n.Weight, tw)
				}
			}
			if _, appKept := weight[app]; appKept && !linked[n.ID] {
				t.Fatalf("cap %d: loop %s kept with its app but no edge:\n%s", cap, n.Label, render(g))
			}
		}
	}
}

// TestDeterministic: the same data gives the same graph, order included.
func TestDeterministic(t *testing.T) {
	s := newStore(t)
	var ts []seedThread
	for i := range 30 {
		ts = append(ts, seedThread{fmt.Sprint("app", i%4), "", fmt.Sprint(i), fmt.Sprint("t", i), fmt.Sprintf("https://s%d.example/", i%5), []time.Duration{h(i % 7), h(i%11 + 7)}})
	}
	seed(t, s, ts)
	a, err := Build(s, protocol.MemoryGraphQuery{MaxNodes: 20}, now)
	if err != nil {
		t.Fatal(err)
	}
	for range 5 {
		b, err := Build(s, protocol.MemoryGraphQuery{MaxNodes: 20}, now)
		if err != nil {
			t.Fatal(err)
		}
		if fmt.Sprint(a) != fmt.Sprint(b) {
			t.Fatalf("graph changed between runs:\n%v\n%v", a, b)
		}
	}
}

func TestEmptyAndDefaults(t *testing.T) {
	s := newStore(t)
	g, err := Build(s, protocol.MemoryGraphQuery{}, now)
	if err != nil {
		t.Fatal(err)
	}
	if g.Nodes == nil || g.Edges == nil || len(g.Nodes) != 0 || len(g.Edges) != 0 {
		t.Fatalf("empty graph = %+v (want empty, non-nil slices)", g)
	}
	for _, c := range []struct {
		q    protocol.MemoryGraphQuery
		want time.Time
	}{
		{protocol.MemoryGraphQuery{}, now.Add(-h(168))},
		{protocol.MemoryGraphQuery{Hours: -3}, now.Add(-h(168))},
		{protocol.MemoryGraphQuery{Hours: 1 << 40}, now.Add(-h(MaxHours))},
		{protocol.MemoryGraphQuery{Since: ptr(now.Add(-h(5000)))}, now.Add(-h(MaxHours))},
		{protocol.MemoryGraphQuery{Since: ptr(now.Add(-h(3))), Hours: 1}, now.Add(-h(3))},
		{protocol.MemoryGraphQuery{Hours: 24}, now.Add(-h(24))},
	} {
		if got := Window(c.q, now); !got.Equal(c.want) {
			t.Errorf("Window(%+v) = %v, want %v", c.q, got, c.want)
		}
	}
}

func TestDefaultCapIs100(t *testing.T) {
	s := newStore(t)
	var ts []seedThread
	for i := range 120 {
		ts = append(ts, seedThread{"app", "App", fmt.Sprint(i), fmt.Sprint("t", i), "", []time.Duration{h(1)}})
	}
	seed(t, s, ts)
	g, err := Build(s, protocol.MemoryGraphQuery{}, now)
	if err != nil {
		t.Fatal(err)
	}
	if len(g.Nodes) != DefaultMaxNodes || g.Nodes[0].Kind != protocol.GraphApp {
		t.Fatalf("%d nodes, first %+v", len(g.Nodes), g.Nodes[0])
	}
	if g, _ := Build(s, protocol.MemoryGraphQuery{MaxNodes: 10_000}, now); len(g.Nodes) != 121 {
		t.Fatalf("max_nodes above the limit: %d nodes", len(g.Nodes))
	}
}

func TestHost(t *testing.T) {
	for in, want := range map[string]string{
		"":                           "",
		"https://WWW.Example.com/a":  "example.com",
		"http://localhost:3000/x":    "localhost",
		"file:///Users/x/notes.txt":  "",
		"not a url\x7f":              "",
		"https://docs.google.com/d/": "docs.google.com",
	} {
		if got := host(in); got != want {
			t.Errorf("host(%q) = %q, want %q", in, got, want)
		}
	}
}

var (
	benchOnce sync.Once
	benchDir  string
	benchErr  error
)

func TestMain(m *testing.M) {
	code := m.Run()
	if benchDir != "" {
		os.RemoveAll(benchDir)
	}
	os.Exit(code)
}

// benchDB seeds, once, 30 days of 3000 threads in 40 apps over 300 sites,
// 36 000 versions in time order and 300 open loops (a third dangling).
func benchDB(b *testing.B) string {
	benchOnce.Do(func() {
		if benchDir, benchErr = os.MkdirTemp("", "graph-bench"); benchErr == nil {
			benchErr = seedBench(filepath.Join(benchDir, "m.db"))
		}
	})
	if benchErr != nil {
		b.Fatal(benchErr)
	}
	return filepath.Join(benchDir, "m.db")
}

func seedBench(path string) error {
	s, err := store.Open(path, false)
	if err != nil {
		return err
	}
	s.Close()
	db, err := sql.Open("sqlite", "file:"+path)
	if err != nil {
		return err
	}
	defer db.Close()
	tx, err := db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	const threads, versions = 3000, 36000
	start := now.Add(-30 * 24 * time.Hour).UnixMilli()
	for i := range threads {
		app := i % 40
		if _, err := tx.Exec(`INSERT INTO threads(id,app_bundle,app_name,key,title,url,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?)`,
			fmt.Sprintf("t%05d", i), fmt.Sprintf("com.example.app%d", app), fmt.Sprintf("App %d", app), fmt.Sprint(i),
			fmt.Sprintf("Thread %d", i), fmt.Sprintf("https://site%d.example.com/p/%d", i%300, i), start, start); err != nil {
			return err
		}
	}
	step := (now.UnixMilli() - start) / versions
	for v := range versions {
		// Mostly a working set of recent threads, with a long tail.
		th := (v*7919 + v/13) % threads
		if v%3 != 0 {
			th = (v / 5) % 200
		}
		at := start + int64(v)*step
		if _, err := tx.Exec(`INSERT OR IGNORE INTO versions(id,thread_id,hour_bucket,content,created_at) VALUES(?,?,?,?,?)`,
			fmt.Sprintf("v%06d", v), fmt.Sprintf("t%05d", th), at/3_600_000, "x", at); err != nil {
			return err
		}
	}
	for l := range 300 {
		src := fmt.Sprintf("t%05d", l*7)
		if l%3 == 0 {
			src = "purged"
		}
		if _, err := tx.Exec(`INSERT INTO loops(id,title,status,source_app,source_thread,detected_at,title_hash) VALUES(?,?,'open',?,?,?,?)`,
			fmt.Sprint("l", l), fmt.Sprint("Loop ", l), fmt.Sprintf("App %d", l%40), src, start+int64(l)*step*100, fmt.Sprint("h", l)); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// BenchmarkBuild30Days: the 30-day graph of benchDB, read-only like the MCP
// server and the core's socket handler. Target: under 50 ms.
func BenchmarkBuild30Days(b *testing.B) {
	path := benchDB(b)
	s, err := store.Open(path, true)
	if err != nil {
		b.Fatal(err)
	}
	defer s.Close()
	q := protocol.MemoryGraphQuery{Hours: 30 * 24}
	b.ResetTimer()
	for b.Loop() {
		g, err := Build(s, q, now)
		if err != nil {
			b.Fatal(err)
		}
		if len(g.Nodes) != DefaultMaxNodes {
			b.Fatalf("%d nodes", len(g.Nodes))
		}
	}
}
