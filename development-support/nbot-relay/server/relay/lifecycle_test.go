package relay

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

type delayedContext struct {
	context.Context
	delay atomic.Bool
}

func (c *delayedContext) Err() error {
	if c.delay.Load() {
		time.Sleep(10 * time.Millisecond)
	}
	return nil
}

func TestPollRechecksTimeDuringClaim(t *testing.T) {
	s, _ := fixture(t)
	b := s.Broker
	target := Target{ClusterID: "default", WorldID: "111"}
	ctx := &delayedContext{Context: context.Background()}
	task, _ := b.enqueue(ctx, target, "save", json.RawMessage(`{}`), time.Now().Add(5*time.Millisecond))
	ctx.delay.Store(true)
	r := b.poll(context.Background(), target, time.Now().Add(30*time.Millisecond))
	if r.Tasks == nil || len(*r.Tasks) != 0 {
		t.Fatal("expired task claimed", r)
	}
	if out := b.wait(context.Background(), task); out.Code != ResultTimeout {
		t.Fatal(out)
	}
}

func TestSubmitRechecksTimeAfterCancellationCheck(t *testing.T) {
	s, _ := fixture(t)
	b := s.Broker
	target := Target{ClusterID: "default", WorldID: "111"}
	ctx := &delayedContext{Context: context.Background()}
	task, _ := b.enqueue(ctx, target, "save", json.RawMessage(`{}`), time.Now().Add(time.Second))
	b.poll(context.Background(), target, time.Now().Add(time.Second))
	task.deadline = time.Now().Add(5 * time.Millisecond)
	ctx.delay.Store(true)
	r := b.submit(target, task.id, response(OK, "done"))
	if r.Accepted == nil || *r.Accepted {
		t.Fatal("late result accepted", r)
	}
	if out := b.wait(context.Background(), task); out.Code != ResultTimeout {
		t.Fatal(out)
	}
}

func TestConcurrentAdmissionBound(t *testing.T) {
	s, _ := fixture(t)
	b := s.Broker
	var wg sync.WaitGroup
	var accepted atomic.Int32
	for i := 0; i < MaxTasks+100; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			task, r := b.enqueue(context.Background(), Target{ClusterID: "default", WorldID: fmt.Sprint(i % 50)}, "world_info", json.RawMessage(`{}`), time.Now().Add(time.Minute))
			if task != nil {
				accepted.Add(1)
			} else if r.Code != GlobalTaskLimit {
				t.Errorf("unexpected failure: %+v", r)
			}
		}(i)
	}
	wg.Wait()
	if accepted.Load() != MaxTasks || b.Stats().Active != MaxTasks || b.Stats().PeakActive != MaxTasks {
		t.Fatal("global bound violated", b.Stats(), accepted.Load())
	}
}

func TestResultTimeoutRace(t *testing.T) {
	s, _ := fixture(t)
	b := s.Broker
	target := Target{ClusterID: "default", WorldID: "111"}
	for i := 0; i < 100; i++ {
		task := add(t, b, target, time.Millisecond)
		p := b.poll(context.Background(), target, time.Now().Add(time.Second))
		if len(*p.Tasks) != 1 {
			continue
		} // A scheduler stall can legitimately expire before claim.
		var wg sync.WaitGroup
		wg.Add(1)
		go func() {
			defer wg.Done()
			time.Sleep(time.Microsecond * 900)
			b.submit(target, task.id, response(OK, "done"))
		}()
		out := b.wait(context.Background(), task)
		wg.Wait()
		if out.Code != OK && out.Code != ResultTimeout {
			t.Fatal(out)
		}
		if len(task.done) != 0 || b.Stats().Active != 0 {
			t.Fatal("finished more than once or leaked")
		}
	}
}

func TestClientDisconnectRemovesClaimedTask(t *testing.T) {
	s, h := fixture(t)
	s.timeout = time.Second
	ctx, cancel := context.WithCancel(context.Background())
	req, _ := http.NewRequestWithContext(ctx, "POST", h.URL+"/execute", strings.NewReader(`{"token":"nbot-relay-default","target":{"world_id":"111"},"action":"world_info","args":{}}`))
	req.Header.Set("Content-Type", "application/json")
	done := make(chan struct{})
	go func() {
		defer close(done)
		r, _ := http.DefaultClient.Do(req)
		if r != nil {
			r.Body.Close()
		}
	}()
	eventually(t, func() bool { return s.Broker.Stats().Active == 1 })
	p, _ := post(t, h.URL+"/poll", request(Target{WorldID: "111"}))
	if len(*p.Tasks) != 1 {
		t.Fatal("not claimed")
	}
	cancel()
	<-done
	eventually(t, func() bool { return s.Broker.Stats().Active == 0 && s.Broker.Stats().Shards == 0 })
}

func TestCustomToken(t *testing.T) {
	c := DefaultConfig()
	c.Token = "custom"
	s, err := New(c)
	if err != nil {
		t.Fatal(err)
	}
	h := httptest.NewServer(s)
	defer h.Close()
	defer s.Broker.Stop()
	r, _ := post(t, h.URL+"/result", request(Target{WorldID: "111"}))
	if r.Code != InvalidToken {
		t.Fatal(r)
	}
	value := request(Target{WorldID: "111"})
	value["token"] = "custom"
	value["task_id"] = "expired"
	value["code"] = 0
	value["ok"] = true
	value["message"] = "done"
	r, _ = post(t, h.URL+"/result", value)
	if r.Code != OK || r.Accepted == nil || *r.Accepted {
		t.Fatal(r)
	}
}

func TestBodyReadBound(t *testing.T) {
	s, h := fixture(t)
	conn, err := net.Dial("tcp", h.Listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(time.Second))
	start := time.Now()
	fmt.Fprint(conn, "POST /execute HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: 100\r\n\r\n{")
	buf := make([]byte, 1024)
	n, err := conn.Read(buf)
	if err != nil || !strings.Contains(string(buf[:n]), "400 Bad Request") || time.Since(start) > time.Second {
		t.Fatalf("body deadline: %s %v", buf[:n], err)
	}
	if s.Broker.Stats().Active != 0 {
		t.Fatal("partial body created task")
	}
}
