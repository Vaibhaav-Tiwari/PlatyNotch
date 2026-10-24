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
