package relay

import (
	"context"
	"reflect"
	"testing"
	"time"
)

func TestDiscoveryTracksModContactsOnly(t *testing.T) {
	s, h := fixture(t)
	defaultTarget := Target{ClusterID: "default", WorldID: "111"}
	queued := add(t, s.Broker, defaultTarget, time.Second)
	list, status := post(t, h.URL+"/worlds", map[string]any{"token": DefaultToken})
	if status != 200 || list.WorldIDs == nil || len(*list.WorldIDs) != 0 {
		t.Fatalf("execute appeared in discovery: %+v", list)
	}
	poll, _ := post(t, h.URL+"/poll", request(defaultTarget))
	if poll.Tasks == nil || len(*poll.Tasks) != 1 || (*poll.Tasks)[0].TaskID != queued.id {
		t.Fatal(poll)
	}
	for _, target := range []Target{{WorldID: "-1"}, {WorldID: "-1"}, {ClusterID: "other", WorldID: "222"}} {
		value := request(target)
		value["task_id"] = "late"
		value["code"] = 0
		value["ok"] = true
		value["message"] = "done"
		ack, _ := post(t, h.URL+"/result", value)
		if ack.Code != 0 || ack.Accepted == nil || *ack.Accepted {
			t.Fatal(ack)
		}
	}
	list, status = post(t, h.URL+"/worlds", map[string]any{"token": DefaultToken})
	if status != 200 || list.ClusterID != "default" || list.WindowSeconds != 10 || list.WorldIDs == nil || !reflect.DeepEqual(*list.WorldIDs, []string{"-1", "111"}) {
		t.Fatal(list)
	}
	other, _ := post(t, h.URL+"/worlds", map[string]any{"token": DefaultToken, "cluster_id": "other"})
	if other.WorldIDs == nil || !reflect.DeepEqual(*other.WorldIDs, []string{"222"}) {
		t.Fatal(other)
	}
}

func TestDiscoveryWindowAndRefresh(t *testing.T) {
	s, _ := fixture(t)
	b := s.Broker
	now := time.Now()
	target := Target{ClusterID: "default", WorldID: "111"}
	b.seen[target] = now.Add(-9 * time.Second)
	b.seen[Target{ClusterID: "default", WorldID: "expired"}] = now.Add(-11 * time.Second)
	b.seen[Target{ClusterID: "default", WorldID: "boundary"}] = now.Add(-10 * time.Second)
	r := b.worlds("default", now)
	if !reflect.DeepEqual(*r.WorldIDs, []string{"111"}) || len(b.seen) != 1 {
		t.Fatal(r)
	}
	b.mu.Lock()
	b.touchLocked(target, now)
	b.mu.Unlock()
	r = b.worlds("default", now.Add(9*time.Second))
	if len(*r.WorldIDs) != 1 {
		t.Fatal("refresh not retained")
	}
	r = b.worlds("default", now.Add(10*time.Second))
	if len(*r.WorldIDs) != 0 {
		t.Fatal("expired retained")
	}
	b.Stop()
	if b.worlds("default", now).Code != ServerStopping || len(b.seen) != 0 {
		t.Fatal("stop retained discovery")
	}
}

func TestDiscoveryRejectsMalformedAndUnauthenticated(t *testing.T) {
	s, h := fixture(t)
	for _, value := range []map[string]any{{}, {"token": "wrong"}} {
		r, status := post(t, h.URL+"/worlds", value)
		if status != 401 || r.Code != InvalidToken {
			t.Fatal(r)
		}
	}
	for _, cluster := range []any{nil, "", 123, "bad/name"} {
		r, status := post(t, h.URL+"/worlds", map[string]any{"token": DefaultToken, "cluster_id": cluster})
		if status != 400 || r.Code != InvalidTarget {
			t.Fatal(r)
		}
	}
	r, _ := post(t, h.URL+"/result", map[string]any{"token": DefaultToken, "target": Target{WorldID: "222"}, "task_id": "bad"})
	if r.Code != InvalidResult {
		t.Fatal(r)
	}
	r, _ = post(t, h.URL+"/poll", map[string]any{"token": "wrong", "target": Target{WorldID: "333"}})
	if r.Code != InvalidToken {
		t.Fatal(r)
	}
	r, _ = post(t, h.URL+"/worlds", map[string]any{"token": DefaultToken})
	if r.WorldIDs == nil || len(*r.WorldIDs) != 0 {
		t.Fatal("invalid contacts registered", r)
	}
	// Listing does not refresh contact timestamps.
	if len(s.Broker.seen) != 0 {
		t.Fatal("listing registered world")
	}
}

func TestDiscoveryDoesNotBlockOrClaimTasks(t *testing.T) {
	s, h := fixture(t)
	target := Target{ClusterID: "default", WorldID: "111"}
	task := add(t, s.Broker, target, time.Second)
	start := time.Now()
	r, _ := post(t, h.URL+"/worlds", map[string]any{"token": DefaultToken})
	if r.Code != 0 || time.Since(start) > time.Second || s.Broker.Stats().Active != 1 {
		t.Fatal(r)
	}
	if ack := s.Broker.submit(target, task.id, response(OK, "done")); ack.Code != TaskNotClaimed {
		t.Fatal("discovery claimed task")
	}
	s.Broker.Stop()
	s.Broker.wait(context.Background(), task)
}
