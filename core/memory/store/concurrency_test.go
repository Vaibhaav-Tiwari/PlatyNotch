package store

import (
	"fmt"
	"sync"
	"testing"
	"time"
)

// The capture path (PutVersion: read, then write) runs while the background
// worker writes on another pooled connection. A deferred transaction that
// upgrades from read to write fails at once with SQLITE_BUSY (busy_timeout does
// not apply), and the capture was dropped. Every write must wait its turn.
func TestConcurrentWritersNeverBusy(t *testing.T) {
	s, _ := open(t)
	th, ids := seed(t, s, "seed text", time.Unix(1_700_000_000, 0))
	var wg sync.WaitGroup
	errs := make(chan error, 400)
	for g := 0; g < 4; g++ {
		wg.Add(1)
		go func(g int) {
			defer wg.Done()
			for i := 0; i < 50; i++ {
				v := Version{ThreadID: th.ID, HourBucket: int64(g*1000 + i%3), Content: fmt.Sprint(g, i),
					ContentHash: fmt.Sprint(g, i), CreatedAt: time.Unix(1_700_000_000, 0)}
				if _, err := s.PutVersion(v); err != nil {
					errs <- err
				}
				if err := s.SetVector(ids[0], "m", []float32{1, 2}); err != nil {
					errs <- err
				}
			}
		}(g)
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		t.Fatal(err)
	}
}

// A write that waits on another in-process write longer than busy_timeout
// must still succeed. SQLite's busy handler polls with sleeps and gives up
// after busy_timeout, with no queue, so on a loaded machine a writer could be
// starved past it by the others and the capture was lost (CI: SQLITE_BUSY
// after 8s under -race). In-process writers queue in Go instead.
func TestWriterOutlastsBusyTimeout(t *testing.T) {
	old := busyTimeoutMs
	busyTimeoutMs = 50
	t.Cleanup(func() { busyTimeoutMs = old })
	s, _ := open(t)
	th, ids := seed(t, s, "seed text", time.Unix(1_700_000_000, 0))

	hold := 8 * time.Duration(busyTimeoutMs) * time.Millisecond // well past busy_timeout
	inTx := make(chan struct{})
	done := make(chan error, 1)
	go func() {
		_, err := s.SaveCapture(Version{ThreadID: th.ID, HourBucket: 7, Content: "new text", ContentHash: "n"},
			func(string) []string {
				close(inTx) // the write transaction is open and holds the lock
				time.Sleep(hold)
				return []string{"new text"}
			})
		done <- err
	}()
	<-inTx
	if err := s.SetVector(ids[0], "m", []float32{1, 2}); err != nil {
		t.Fatalf("SetVector while another write is open: %v", err)
	}
	if err := <-done; err != nil {
		t.Fatalf("SaveCapture: %v", err)
	}
}
