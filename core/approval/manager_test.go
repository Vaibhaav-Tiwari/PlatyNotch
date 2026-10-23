package approval

import (
	"regexp"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/platynotch/platynotch/core/protocol"
)

func newM() (*Manager, *time.Time) {
	t := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	return NewManager(func() time.Time { return t }), &t
}

func TestOpenAssigns(t *testing.T) {
	m, now := newM()
	a, _ := m.Open(protocol.Approval{Tool: "Bash"})
	if !regexp.MustCompile(`^apr_[0-9a-f]{16}$`).MatchString(a.ID) {
		t.Fatal(a.ID)
	}
	if !a.CreatedAt.Equal(*now) || !a.ExpiresAt.Equal(now.Add(100*time.Second)) {
		t.Fatalf("%+v", a)
	}
	custom := now.Add(5 * time.Second)
	b, _ := m.Open(protocol.Approval{ExpiresAt: custom})
	if !b.ExpiresAt.Equal(custom) {
		t.Fatal("custom expiry ignored")
	}
	if len(m.Pending()) != 2 {
		t.Fatal("pending")
	}
}

func TestDecideOnce(t *testing.T) {
	m, _ := newM()
	a, ch := m.Open(protocol.Approval{})
	if err := m.Decide(protocol.ApprovalDecide{ID: a.ID, Behavior: protocol.BehaviorAllow, Source: "notch"}); err != nil {
		t.Fatal(err)
	}
	d := <-ch
	if d.Behavior != protocol.BehaviorAllow || d.Source != "notch" {
		t.Fatalf("%+v", d)
	}
	if err := m.Decide(protocol.ApprovalDecide{ID: a.ID, Behavior: protocol.BehaviorDeny}); err != ErrResolved {
		t.Fatal(err)
	}
	if err := m.Decide(protocol.ApprovalDecide{ID: "apr_nope"}); err != ErrUnknown {
		t.Fatal(err)
	}
	if len(m.Pending()) != 0 {
		t.Fatal("still pending")
	}
}

func TestConcurrentDecide(t *testing.T) {
	m, _ := newM()
	a, _ := m.Open(protocol.Approval{})
	var ok int32
	var wg sync.WaitGroup
	for i := 0; i < 50; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if m.Decide(protocol.ApprovalDecide{ID: a.ID, Behavior: protocol.BehaviorAllow}) == nil {
				atomic.AddInt32(&ok, 1)
			}
		}()
	}
	wg.Wait()
	if ok != 1 {
		t.Fatal(ok)
	}
}

func TestExpireDeliversNone(t *testing.T) {
	m, _ := newM()
	a, ch := m.Open(protocol.Approval{})
	if !m.Expire(a.ID) {
		t.Fatal("expire false")
	}
	if d := <-ch; d.Behavior != protocol.BehaviorNone {
		t.Fatalf("%+v", d)
	}
	if m.Expire(a.ID) || m.Expire("apr_nope") {
		t.Fatal("second expire should be false")
	}
	if err := m.Decide(protocol.ApprovalDecide{ID: a.ID}); err != ErrResolved {
		t.Fatal(err)
	}
}
