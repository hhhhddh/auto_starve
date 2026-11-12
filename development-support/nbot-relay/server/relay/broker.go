package relay

import (
	"container/list"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"sort"
	"strconv"
	"sync"
	"sync/atomic"
	"time"
)

const MaxTasks = 5000
const RequestTimeout = 5 * time.Second
const DiscoveryWindow = 10 * time.Second

type task struct {
	id       string
	target   Target
	action   string
	args     json.RawMessage
	deadline time.Time
	ctx      context.Context
	claimed  bool
	element  *list.Element
	done     chan Response
}

type shard struct {
	pending list.List
	active  int
	waiters int
	notify  chan struct{}
}

// Stats is an in-process diagnostic snapshot, not another HTTP endpoint.
type Stats struct {
	Active     int `json:"active"`
	PeakActive int `json:"peak_active"`
	Polls      int `json:"polls"`
	PeakPolls  int `json:"peak_polls"`
	Shards     int `json:"shards"`
}

type Broker struct {
	mu            sync.Mutex
	tasks         map[string]*task
	shards        map[Target]*shard
	stopped       bool
	polls         int
	peakActive    int
	peakPolls     int
	maxPolls      int
	prefix        string
	sequence      atomic.Uint64
	seen          map[Target]time.Time
	lastSeenSweep time.Time
}

func newBroker(maxPolls int) (*Broker, error) {
	var prefix [16]byte
	if _, err := rand.Read(prefix[:]); err != nil {
		return nil, err
	}
	return &Broker{tasks: make(map[string]*task), shards: make(map[Target]*shard), seen: make(map[Target]time.Time),
		prefix: hex.EncodeToString(prefix[:]), maxPolls: maxPolls}, nil
}

func (b *Broker) getShard(target Target) *shard {
	s := b.shards[target]
	if s == nil {
		s = &shard{notify: make(chan struct{})}
		b.shards[target] = s
	}
	return s
}

func (b *Broker) prune(target Target) {
	if s := b.shards[target]; s != nil && s.active == 0 && s.waiters == 0 {
		delete(b.shards, target)
	}
}

// finish must hold mu. The buffered channel is sent exactly once, by the winner.
func (b *Broker) finish(t *task, result Response) {
	delete(b.tasks, t.id)
	s := b.shards[t.target]
	if t.element != nil {
		s.pending.Remove(t.element)
		t.element = nil
	}
	s.active--
	result.TaskID = t.id
	t.done <- result
	b.prune(t.target)
}

func timeoutResponse() Response {
	return response(ResultTimeout, "执行失败：等待结果超时，实际执行结果未知")
}

func (b *Broker) enqueue(ctx context.Context, target Target, action string, args json.RawMessage, deadline time.Time) (*task, Response) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.stopped {
		return nil, response(ServerStopping, "服务正在退出")
	}
	if !time.Now().Before(deadline) || ctx.Err() != nil {
		return nil, timeoutResponse()
	}
	if len(b.tasks) >= MaxTasks {
		// Reclaim expired/canceled requests even if their handlers have not run yet.
		for _, t := range b.tasks {
			if t.ctx.Err() != nil || !time.Now().Before(t.deadline) {
				b.finish(t, timeoutResponse())
			}
		}
	}
	if len(b.tasks) >= MaxTasks {
		return nil, response(GlobalTaskLimit, "活跃任务已达上限（5000）")
	}
	id := b.prefix + "-" + strconv.FormatUint(b.sequence.Add(1), 16)
	t := &task{id: id, target: target, action: action, args: args, deadline: deadline,
		ctx: ctx, done: make(chan Response, 1)}
	s := b.getShard(target)
	s.active++
	t.element = s.pending.PushBack(t)
	b.tasks[id] = t
	if len(b.tasks) > b.peakActive {
		b.peakActive = len(b.tasks)
	}
	close(s.notify)
	s.notify = make(chan struct{})
	return t, Response{}
}

func (b *Broker) wait(ctx context.Context, t *task) Response {
	timer := time.NewTimer(time.Until(t.deadline))
	defer timer.Stop()
	select {
	case result := <-t.done:
		return result
	case <-ctx.Done():
	case <-timer.C:
	}
	b.mu.Lock()
	if b.tasks[t.id] == t {
		b.finish(t, timeoutResponse())
	}
	b.mu.Unlock()
	// If a result won the race, return that result, not a second termination.
	return <-t.done
}

func (b *Broker) poll(ctx context.Context, target Target, deadline time.Time) Response {
	b.mu.Lock()
	if b.stopped {
		b.mu.Unlock()
		return response(ServerStopping, "服务正在退出")
	}
	b.touchLocked(target, time.Now())
	if b.polls >= b.maxPolls {
		b.mu.Unlock()
		return response(PollLimit, "轮询连接已达上限")
	}
	s := b.getShard(target)
	s.waiters++
	b.polls++
	if b.polls > b.peakPolls {
		b.peakPolls = b.polls
	}
	b.mu.Unlock()
	defer func() {
		b.mu.Lock()
		defer b.mu.Unlock()
		s.waiters--
		b.polls--
		b.prune(target)
	}()
	timer := time.NewTimer(time.Until(deadline))
	defer timer.Stop()
	empty := func() Response { tasks := []Command{}; r := response(OK, "成功"); r.Tasks = &tasks; return r }
	for {
		b.mu.Lock()
		if b.stopped {
			b.mu.Unlock()
			return response(ServerStopping, "服务正在退出")
		}
		now := time.Now()
		if ctx.Err() != nil || !now.Before(deadline) {
			b.mu.Unlock()
			return empty()
		}
		commands := []Command{}
		for e := s.pending.Front(); e != nil; {
			next := e.Next()
			t := e.Value.(*task)
			if t.ctx.Err() != nil || !time.Now().Before(t.deadline) {
				b.finish(t, timeoutResponse())
			} else {
				s.pending.Remove(e)
				t.element = nil
				t.claimed = true
				commands = append(commands, Command{TaskID: t.id, Action: t.action, Args: t.args,
					RemainingMS: max(0, time.Until(t.deadline).Milliseconds())})
			}
			e = next
		}
		notify := s.notify
		b.mu.Unlock()
		if len(commands) > 0 {
			r := response(OK, "成功")
			r.Tasks = &commands
			return r
		}
		select {
		case <-notify:
		case <-timer.C:
			return empty()
		case <-ctx.Done():
			return empty()
		}
	}
}

func (b *Broker) submit(target Target, id string, result Response) Response {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.stopped {
		return response(ServerStopping, "服务正在退出")
	}
	accepted := false
	t := b.tasks[id]
	if t != nil && (t.ctx.Err() != nil || !time.Now().Before(t.deadline)) {
		b.finish(t, timeoutResponse())
		t = nil
	}
	if t != nil {
		if t.target != target {
			return response(TaskTargetMismatch, "任务目标不匹配")
		}
		if !t.claimed {
			return response(TaskNotClaimed, "任务尚未领取")
		}
	}
	b.touchLocked(target, time.Now())
	if t != nil {
		b.finish(t, result)
		accepted = true
	}
	r := response(OK, "结果已丢弃")
	if accepted {
		r.Message = "结果已接收"
	}
	r.Accepted = &accepted
	return r
}

func (b *Broker) Stop() {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.stopped {
		return
	}
	b.stopped = true
	clear(b.seen)
	for _, t := range b.tasks {
		b.finish(t, response(ServerStopping, "服务正在退出，实际执行结果未知"))
	}
	for target, s := range b.shards {
		close(s.notify)
		b.prune(target)
	}
}

func (b *Broker) expireSeenLocked(now time.Time) {
	cutoff := now.Add(-DiscoveryWindow)
	for target, seen := range b.seen {
		if !seen.After(cutoff) {
			delete(b.seen, target)
		}
	}
	b.lastSeenSweep = now
}

func (b *Broker) touchLocked(target Target, now time.Time) {
	if now.Sub(b.lastSeenSweep) >= time.Second {
		b.expireSeenLocked(now)
	}
	b.seen[target] = now
}

func (b *Broker) worlds(cluster string, now time.Time) Response {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.stopped {
		return response(ServerStopping, "服务正在退出")
	}
	b.expireSeenLocked(now)
	ids := []string{}
	for target := range b.seen {
		if target.ClusterID == cluster {
			ids = append(ids, target.WorldID)
		}
	}
	sort.Strings(ids)
	r := response(OK, "成功")
	r.ClusterID = cluster
	r.WorldIDs = &ids
	r.WindowSeconds = int(DiscoveryWindow / time.Second)
	return r
}

func (b *Broker) Stats() Stats {
	b.mu.Lock()
	defer b.mu.Unlock()
	return Stats{Active: len(b.tasks), PeakActive: b.peakActive, Polls: b.polls,
		PeakPolls: b.peakPolls, Shards: len(b.shards)}
}
