package relay

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

func fixture(t *testing.T) (*Server, *httptest.Server) {
	t.Helper()
	s, err := New(DefaultConfig())
	if err != nil {
		t.Fatal(err)
	}
	s.timeout = 200 * time.Millisecond
	h := httptest.NewServer(s)
	t.Cleanup(func() { s.Broker.Stop(); h.Close() })
	return s, h
}

func post(t *testing.T, url string, value any) (Response, int) {
	t.Helper()
	data, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	r, err := http.Post(url, "application/json", bytes.NewReader(data))
	if err != nil {
		t.Fatal(err)
	}
	defer r.Body.Close()
	var out Response
	if err := json.NewDecoder(r.Body).Decode(&out); err != nil {
		t.Fatal(err)
	}
	return out, r.StatusCode
}

func request(target Target) map[string]any {
	return map[string]any{"token": DefaultToken, "target": target}
}

func executeRequest(target Target) map[string]any {
	r := request(target)
	r["action"] = "world_info"
	r["args"] = map[string]any{}
	return r
}

func add(t *testing.T, b *Broker, target Target, duration time.Duration) *task {
	t.Helper()
	task, result := b.enqueue(context.Background(), target, "world_info", json.RawMessage(`{}`), time.Now().Add(duration))
	if task == nil {
		t.Fatalf("enqueue: %+v", result)
	}
	return task
}

func eventually(t *testing.T, f func() bool) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for !f() {
		if time.Now().After(deadline) {
			t.Fatal("condition not reached")
		}
		time.Sleep(time.Millisecond)
	}
}

func TestHTTPBatchRoundTrip(t *testing.T) {
	s, h := fixture(t)
	s.timeout = 2 * time.Second
	target := Target{WorldID: "111"}
	results := make(chan Response, 3)
	for i := 0; i < 3; i++ {
		go func() { r, _ := post(t, h.URL+"/execute", executeRequest(target)); results <- r }()
	}
	eventually(t, func() bool { return s.Broker.Stats().Active == 3 })
	p, status := post(t, h.URL+"/poll", request(Target{ClusterID: "default", WorldID: "111"}))
	if status != 200 || p.Tasks == nil || len(*p.Tasks) != 3 {
		t.Fatalf("batch: %+v %d", p, status)
	}
	if s.Broker.Stats().Active != 3 {
		t.Fatal("claim released capacity")
	}
	for i, c := range *p.Tasks {
		r := request(target)
		r["task_id"] = c.TaskID
		r["code"] = OK
		r["ok"] = true
		r["message"] = "done"
		r["result"] = i
		ack, _ := post(t, h.URL+"/result", r)
		if ack.Accepted == nil || !*ack.Accepted {
			t.Fatalf("ack: %+v", ack)
		}
		out := <-results
		if out.TaskID != c.TaskID || !out.OK || string(out.Result) != fmt.Sprint(i) {
			t.Fatalf("result: %+v", out)
		}
		ack, _ = post(t, h.URL+"/result", r)
		if ack.Accepted == nil || *ack.Accepted {
			t.Fatal("duplicate accepted")
		}
	}
	if stats := s.Broker.Stats(); stats.Active != 0 || stats.Shards != 0 {
		t.Fatalf("leak: %+v", stats)
	}
}

func TestPollWakeupAndEmptyTimeout(t *testing.T) {
	s, h := fixture(t)
	target := Target{ClusterID: "default", WorldID: "111"}
	done := make(chan Response, 1)
	go func() { r, _ := post(t, h.URL+"/poll", request(target)); done <- r }()
	eventually(t, func() bool { return s.Broker.Stats().Polls == 1 })
	add(t, s.Broker, target, time.Second)
	if r := <-done; r.Tasks == nil || len(*r.Tasks) != 1 {
		t.Fatalf("not woken: %+v", r)
	}
	start := time.Now()
	r, _ := post(t, h.URL+"/poll", request(target))
	if r.Code != OK || r.Tasks == nil || len(*r.Tasks) != 0 || time.Since(start) < 150*time.Millisecond {
		t.Fatalf("empty poll: %+v", r)
	}
}

func TestHTTPTimeoutAndLateResult(t *testing.T) {
	s, h := fixture(t)
	target := Target{WorldID: "111"}
	start := time.Now()
	r, status := post(t, h.URL+"/execute", executeRequest(target))
	if status != 504 || r.Code != ResultTimeout || r.TaskID == "" || time.Since(start) > time.Second {
		t.Fatalf("timeout: %+v %d", r, status)
	}
	late := request(target)
	late["task_id"] = r.TaskID
	late["code"] = 0
	late["ok"] = true
	late["message"] = "done"
	ack, _ := post(t, h.URL+"/result", late)
	if ack.Code != OK || ack.Accepted == nil || *ack.Accepted {
		t.Fatalf("late: %+v", ack)
	}
	if s.Broker.Stats().Active != 0 || s.Broker.Stats().Shards != 0 {
		t.Fatal("timeout leaked state")
	}
}

func TestHTTPValidation(t *testing.T) {
	_, h := fixture(t)
	cases := []struct {
		path, body string
		code       int
	}{
		{"/execute", `null`, InvalidJSON},
		{"/execute", `{} {}`, InvalidJSON},
		{"/execute", `{}`, InvalidToken},
		{"/poll", `{"token":null}`, InvalidToken},
		{"/poll", `{"token":"nbot-relay-default","target":{"world_id":"111","cluster_id":null}}`, InvalidTarget},
		{"/poll", `{"token":"nbot-relay-default","target":{"world_id":111}}`, InvalidTarget},
		{"/execute", `{"token":"nbot-relay-default","target":{"world_id":"111"},"action":"xxx","args":{}}`, UnsupportedAction},
		{"/execute", `{"token":"nbot-relay-default","target":{"world_id":"111"},"action":"world_info","args":null}`, InvalidArgs},
		{"/result", `{"token":"nbot-relay-default","target":{"world_id":"111"}}`, InvalidTaskID},
		{"/result", `{"token":"nbot-relay-default","target":{"world_id":"111"},"task_id":"x","ok":true}`, InvalidResult},
		{"/result", `{"token":"nbot-relay-default","target":{"world_id":"111"},"task_id":"x","code":4001,"ok":true,"message":"x"}`, InvalidResult},
		{"/result", `{"token":"nbot-relay-default","target":{"world_id":"111"},"task_id":"x","code":0,"ok":true,"message":"x","output":null}`, InvalidResult},
	}
	for _, c := range cases {
		t.Run(fmt.Sprint(c.code)+c.body, func(t *testing.T) {
			r, err := http.Post(h.URL+c.path, "application/json", strings.NewReader(c.body))
			if err != nil {
				t.Fatal(err)
			}
			defer r.Body.Close()
			var out Response
			_ = json.NewDecoder(r.Body).Decode(&out)
			if out.Code != c.code || out.OK || r.StatusCode != statusFor(c.code) {
				t.Fatalf("%+v status %d", out, r.StatusCode)
			}
		})
	}
	for _, c := range []struct {
		method, path, media string
		code                int
	}{
		{"GET", "/poll", "application/json", MethodNotAllowed},
		{"POST", "/missing", "application/json", RouteNotFound},
		{"POST", "/execute", "text/plain", UnsupportedMediaType},
		{"POST", "/execute", "", UnsupportedMediaType},
		{"POST", "/poll", "text/plain", InvalidToken},
		{"POST", "/poll", "", InvalidToken},
		{"POST", "/result", "application/x-www-form-urlencoded", InvalidToken},
		{"POST", "/result", "application/octet-stream", InvalidToken},
		{"POST", "/poll", "text/html", UnsupportedMediaType},
	} {
		r, _ := http.NewRequest(c.method, h.URL+c.path, strings.NewReader(`{}`))
		r.Header.Set("Content-Type", c.media)
		out, err := http.DefaultClient.Do(r)
		if err != nil {
			t.Fatal(err)
		}
		var value Response
		_ = json.NewDecoder(out.Body).Decode(&value)
		out.Body.Close()
		if value.Code != c.code {
			t.Fatal(value)
		}
		if c.code == MethodNotAllowed && out.Header.Get("Allow") != "POST" {
			t.Fatal("missing Allow")
		}
	}
}

func TestLimitsAndScope(t *testing.T) {
	s, _ := fixture(t)
	b := s.Broker
	target := Target{ClusterID: "default", WorldID: "111"}
	for i := 0; i < MaxTasks; i++ {
		add(t, b, target, time.Minute)
	}
	if _, r := b.enqueue(context.Background(), Target{ClusterID: "other", WorldID: "111"}, "save", json.RawMessage(`{}`), time.Now().Add(time.Minute)); r.Code != GlobalTaskLimit {
		t.Fatal(r)
	}
	other := b.poll(context.Background(), Target{ClusterID: "other", WorldID: "111"}, time.Now().Add(time.Millisecond))
	if len(*other.Tasks) != 0 {
		t.Fatal("cross-cluster claim")
	}
	p := b.poll(context.Background(), target, time.Now().Add(time.Second))
	if len(*p.Tasks) != 5000 || b.Stats().Active != 5000 {
		t.Fatal("batch/capacity")
	}
	id := (*p.Tasks)[0].TaskID
	if r := b.submit(Target{ClusterID: "other", WorldID: "111"}, id, response(OK, "done")); r.Code != TaskTargetMismatch {
		t.Fatal(r)
	}
	b.submit(target, id, response(OK, "done"))
	add(t, b, target, time.Minute)
	if b.Stats().Active != 5000 {
		t.Fatal("capacity not reused")
	}
}

func TestConcurrentClaimAndFinish(t *testing.T) {
	s, _ := fixture(t)
	b := s.Broker
	target := Target{ClusterID: "default", WorldID: "111"}
	for i := 0; i < 200; i++ {
		add(t, b, target, time.Second)
	}
	var wg sync.WaitGroup
	var mu sync.Mutex
	seen := map[string]bool{}
	for i := 0; i < 16; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			r := b.poll(context.Background(), target, time.Now().Add(5*time.Millisecond))
			for _, c := range *r.Tasks {
				mu.Lock()
				if seen[c.TaskID] {
					t.Error("duplicate claim")
				}
				seen[c.TaskID] = true
				mu.Unlock()
				b.submit(target, c.TaskID, response(OK, "done"))
			}
		}()
	}
	wg.Wait()
	if len(seen) != 200 || b.Stats().Active != 0 || b.Stats().Shards != 0 {
		t.Fatal("lost task or state leak")
	}
}

func TestUnclaimedAndExpiredResult(t *testing.T) {
	s, _ := fixture(t)
	b := s.Broker
	target := Target{ClusterID: "default", WorldID: "111"}
	task := add(t, b, target, 10*time.Millisecond)
	if r := b.submit(target, task.id, response(OK, "done")); r.Code != TaskNotClaimed {
		t.Fatal(r)
	}
	time.Sleep(15 * time.Millisecond)
	r := b.submit(Target{ClusterID: "other", WorldID: "111"}, task.id, response(OK, "done"))
	if r.Code != OK || *r.Accepted {
		t.Fatal(r)
	}
	if out := b.wait(context.Background(), task); out.Code != ResultTimeout {
		t.Fatal(out)
	}
}

func TestCancellationAndStop(t *testing.T) {
	s, _ := fixture(t)
	b := s.Broker
	target := Target{ClusterID: "default", WorldID: "111"}
	ctx, cancel := context.WithCancel(context.Background())
	task, _ := b.enqueue(ctx, target, "save", json.RawMessage(`{}`), time.Now().Add(time.Second))
	cancel()
	b.wait(ctx, task)
	if b.Stats().Active != 0 {
		t.Fatal("canceled task retained")
	}
	task = add(t, b, target, time.Minute)
	done := make(chan Response, 1)
	go func() {
		done <- b.poll(context.Background(), Target{ClusterID: "default", WorldID: "other"}, time.Now().Add(time.Second))
	}()
	eventually(t, func() bool { return b.Stats().Polls == 1 })
	b.Stop()
	b.Stop()
	if (<-done).Code != ServerStopping || b.wait(context.Background(), task).Code != ServerStopping {
		t.Fatal("stop not delivered")
	}
	if st := b.Stats(); st.Active != 0 || st.Polls != 0 || st.Shards != 0 {
		t.Fatal(st)
	}
}

func TestPollAndBodyLimit(t *testing.T) {
	c := DefaultConfig()
	c.MaxPolls = 1
	c.MaxBodyBytes = 128
	s, err := New(c)
	if err != nil {
		t.Fatal(err)
	}
	s.timeout = time.Second
	h := httptest.NewServer(s)
	defer h.Close()
	defer s.Broker.Stop()
	done := make(chan Response, 1)
	go func() { r, _ := post(t, h.URL+"/poll", request(Target{WorldID: "111"})); done <- r }()
	eventually(t, func() bool { return s.Broker.Stats().Polls == 1 })
	r, status := post(t, h.URL+"/poll", request(Target{WorldID: "222"}))
	if r.Code != PollLimit || status != 503 {
		t.Fatal(r)
	}
	raw, err := http.Post(h.URL+"/execute", "application/json", strings.NewReader(strings.Repeat("x", 129)))
	if err != nil {
		t.Fatal(err)
	}
	var out Response
	json.NewDecoder(raw.Body).Decode(&out)
	raw.Body.Close()
	if out.Code != BodyTooLarge {
		t.Fatal(out)
	}
	s.Broker.Stop()
	<-done
}

func TestModFailureRoundTrip(t *testing.T) {
	s, h := fixture(t)
	target := Target{WorldID: "111"}
	done := make(chan Response, 1)
	go func() { r, _ := post(t, h.URL+"/execute", executeRequest(target)); done <- r }()
	eventually(t, func() bool { return s.Broker.Stats().Active == 1 })
	p, _ := post(t, h.URL+"/poll", request(target))
	id := (*p.Tasks)[0].TaskID
	r := request(target)
	r["task_id"] = id
	r["code"] = 4001
	r["ok"] = false
	r["message"] = "未找到玩家"
	ack, status := post(t, h.URL+"/result", r)
	if status != 200 || ack.Code != OK || !*ack.Accepted {
		t.Fatal(ack)
	}
	if out := <-done; out.Code != 4001 || out.OK || out.Message != "未找到玩家" {
		t.Fatal(out)
	}
}

func TestConfigAndActions(t *testing.T) {
	c, err := LoadConfig(strings.NewReader(`{}`))
	if err != nil || c.Token != DefaultToken {
		t.Fatal(c, err)
	}
	for _, raw := range []string{`null`, `{"token":null}`, `{"token":""}`, `{"max_polls":0}`, `{"unknown":1}`, `{} {}`} {
		if _, err := LoadConfig(strings.NewReader(raw)); err == nil {
			t.Fatalf("accepted %s", raw)
		}
	}
	for action, args := range map[string]string{"world_info": "{}", "players": "{}", "save": "{}", "announce": `{"message":"hi"}`, "rollback": `{"count":1}`, "lua": `{"code":"return 1"}`} {
		if !validateArgs(action, json.RawMessage(args)) {
			t.Fatal(action)
		}
	}
	for _, item := range []struct{ a, b string }{{"rollback", `{"count":0}`}, {"announce", `{"message":""}`}, {"save", `{"extra":1}`}, {"lua", `{"code":1}`}} {
		if validateArgs(item.a, json.RawMessage(item.b)) {
			t.Fatal(item)
		}
	}
}
