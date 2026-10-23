package loops

import (
	"path/filepath"
	"testing"
	"time"

	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/memory/provider"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/memory/store"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/protocol"
)

func openStore(t *testing.T) *store.Store {
	t.Helper()
	s, err := store.Open(filepath.Join(t.TempDir(), "m.db"), false)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	return s
}

var t0 = time.Date(2026, 10, 23, 9, 0, 0, 0, time.UTC)

func newLoop(title string) protocol.Loop {
	return protocol.Loop{Title: title, Kind: "commitment", Status: "open", Quote: "q", DetectedAt: t0}
}

func mustList(t *testing.T, s *store.Store, status string) []protocol.Loop {
	t.Helper()
	ls, err := List(s, status)
	if err != nil {
		t.Fatal(err)
	}
	return ls
}

func TestTitleHashNormalizes(t *testing.T) {
	a := TitleHash("Send the proposal to Priya")
	b := TitleHash("  send   the proposal to priya. ")
	if a != b || len(a) != 64 {
		t.Fatalf("a=%s b=%s", a, b)
	}
	if a == TitleHash("Send the proposal to Sam") {
		t.Fatal("different titles share a hash")
	}
}

func TestDuplicateLoopTitlesMerge(t *testing.T) {
	s := openStore(t)
	changed, err := Apply(s, provider.ExtractResult{Loops: []protocol.Loop{newLoop("Send the proposal to Priya")}}, "Mail", "th1", t0)
	if err != nil || !changed {
		t.Fatalf("first apply changed=%v err=%v", changed, err)
	}
	changed, err = Apply(s, provider.ExtractResult{Loops: []protocol.Loop{newLoop("send the proposal to priya.")}}, "Slack", "th2", t0.Add(time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if changed {
		t.Fatal("duplicate title reported a change")
	}
	ls := mustList(t, s, "open")
	if len(ls) != 1 {
		t.Fatalf("got %d loops: %+v", len(ls), ls)
	}
	l := ls[0]
	if l.Title != "Send the proposal to Priya" || l.SourceApp != "Mail" || l.SourceThread != "th1" || l.Status != "open" || len(l.ID) != 32 || !l.DetectedAt.Equal(t0) {
		t.Fatalf("loop=%+v", l)
	}
	// Two duplicates inside one result also merge.
	if _, err := Apply(s, provider.ExtractResult{Loops: []protocol.Loop{newLoop("Book flights"), newLoop("book flights!")}}, "Mail", "th1", t0); err != nil {
		t.Fatal(err)
	}
	if n := len(mustList(t, s, "open")); n != 2 {
		t.Fatalf("open=%d want 2", n)
	}
}

func TestMergeFillsMissingDueDate(t *testing.T) {
	s := openStore(t)
	Apply(s, provider.ExtractResult{Loops: []protocol.Loop{newLoop("Pay rent")}}, "Mail", "th1", t0)
	due := t0.Add(48 * time.Hour)
	l := newLoop("pay rent")
	l.DueAt = &due
	changed, err := Apply(s, provider.ExtractResult{Loops: []protocol.Loop{l}}, "Mail", "th1", t0)
	if err != nil || !changed {
		t.Fatalf("changed=%v err=%v", changed, err)
	}
	got := mustList(t, s, "open")[0]
	if got.DueAt == nil || !got.DueAt.Equal(due) {
		t.Fatalf("due=%v", got.DueAt)
	}
}

func TestResolutionClosesLoop(t *testing.T) {
	s := openStore(t)
	Apply(s, provider.ExtractResult{Loops: []protocol.Loop{newLoop("Send the proposal to Priya"), newLoop("Call the bank")}}, "Mail", "th1", t0)
	open := mustList(t, s, "open")
	var id, other string
	for _, l := range open {
		if l.Title == "Call the bank" {
			other = l.ID
		} else {
			id = l.ID
		}
	}
	now := t0.Add(time.Hour)
	changed, err := Apply(s, provider.ExtractResult{Resolutions: []provider.Resolution{{LoopID: id, Evidence: "Sent it, thanks!"}}}, "Mail", "th1", now)
	if err != nil || !changed {
		t.Fatalf("changed=%v err=%v", changed, err)
	}
	res := mustList(t, s, "resolved")
	if len(res) != 1 || res[0].ID != id || res[0].Evidence != "Sent it, thanks!" || res[0].ResolvedAt == nil || !res[0].ResolvedAt.Equal(now) {
		t.Fatalf("resolved=%+v", res)
	}
	if o := mustList(t, s, "open"); len(o) != 1 || o[0].ID != other {
		t.Fatalf("open=%+v", o)
	}
	// A resolution only applies to open loops: a dismissed loop stays dismissed.
	if err := SetStatus(s, protocol.LoopSetStatus{ID: other, Status: "dismissed"}, now); err != nil {
		t.Fatal(err)
	}
	changed, err = Apply(s, provider.ExtractResult{Resolutions: []provider.Resolution{{LoopID: other, Evidence: "done"}}}, "Mail", "th1", now)
	if err != nil || changed {
		t.Fatalf("resolution of dismissed loop: changed=%v err=%v", changed, err)
	}
	if d := mustList(t, s, "dismissed"); len(d) != 1 || d[0].ResolvedAt != nil {
		t.Fatalf("dismissed=%+v", d)
	}
}

func TestSetStatus(t *testing.T) {
	s := openStore(t)
	Apply(s, provider.ExtractResult{Loops: []protocol.Loop{newLoop("Ship it")}}, "Mail", "th1", t0)
	id := mustList(t, s, "open")[0].ID
	now := t0.Add(time.Hour)
	if err := SetStatus(s, protocol.LoopSetStatus{ID: id, Status: "resolved", Evidence: "shipped"}, now); err != nil {
		t.Fatal(err)
	}
	r := mustList(t, s, "resolved")
	if len(r) != 1 || r[0].ResolvedAt == nil || !r[0].ResolvedAt.Equal(now) || r[0].Evidence != "shipped" {
		t.Fatalf("resolved=%+v", r)
	}
	if err := SetStatus(s, protocol.LoopSetStatus{ID: id, Status: "open"}, now); err != nil {
		t.Fatal(err)
	}
	if o := mustList(t, s, "open"); len(o) != 1 || o[0].ResolvedAt != nil {
		t.Fatalf("reopened=%+v", o)
	}
	if err := SetStatus(s, protocol.LoopSetStatus{ID: id, Status: "done"}, now); err == nil {
		t.Fatal("invalid status accepted")
	}
	if err := SetStatus(s, protocol.LoopSetStatus{ID: "nope", Status: "dismissed"}, now); err == nil {
		t.Fatal("unknown id accepted")
	}
	if all := mustList(t, s, ""); len(all) != 1 {
		t.Fatalf("all=%d", len(all))
	}
}

func TestArchiveStale(t *testing.T) {
	s := openStore(t)
	old := newLoop("Old thing")
	Apply(s, provider.ExtractResult{Loops: []protocol.Loop{old}}, "Mail", "th1", t0)
	fresh := newLoop("Fresh thing")
	fresh.DetectedAt = t0.Add(10 * 24 * time.Hour)
	Apply(s, provider.ExtractResult{Loops: []protocol.Loop{fresh}}, "Mail", "th1", fresh.DetectedAt)
	resolvedOld := newLoop("Resolved old thing")
	Apply(s, provider.ExtractResult{Loops: []protocol.Loop{resolvedOld}}, "Mail", "th1", t0)
	for _, l := range mustList(t, s, "open") {
		if l.Title == "Resolved old thing" {
			SetStatus(s, protocol.LoopSetStatus{ID: l.ID, Status: "resolved"}, t0)
		}
	}
	now := t0.Add(15 * 24 * time.Hour)
	n, err := ArchiveStale(s, 14*24*time.Hour, now)
	if err != nil || n != 1 {
		t.Fatalf("n=%d err=%v", n, err)
	}
	st := mustList(t, s, "stale")
	if len(st) != 1 || st[0].Title != "Old thing" {
		t.Fatalf("stale=%+v", st)
	}
	if o := mustList(t, s, "open"); len(o) != 1 || o[0].Title != "Fresh thing" {
		t.Fatalf("open=%+v", o)
	}
	if n, _ := ArchiveStale(s, 14*24*time.Hour, now); n != 0 {
		t.Fatalf("second archive n=%d", n)
	}
}
