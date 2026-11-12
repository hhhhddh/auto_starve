package relay

import (
	"bytes"
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"io"
	"log"
	"mime"
	"net/http"
	"regexp"
	"strings"
	"time"
)

const DefaultMaxBodyBytes int64 = 64 * 1024
const DefaultMaxPolls = 2048

type Config struct {
	Listen       string `json:"listen"`
	Token        string `json:"token"`
	MaxBodyBytes int64  `json:"max_body_bytes"`
	MaxPolls     int    `json:"max_polls"`
}

func DefaultConfig() Config {
	return Config{Listen: "0.0.0.0:20502", Token: DefaultToken,
		MaxBodyBytes: DefaultMaxBodyBytes, MaxPolls: DefaultMaxPolls}
}

// LoadConfig applies defaults only to omitted fields, not null or empty values.
func LoadConfig(reader io.Reader) (Config, error) {
	c := DefaultConfig()
	data, err := io.ReadAll(io.LimitReader(reader, 1024*1024+1))
	if err != nil {
		return c, err
	}
	if len(data) > 1024*1024 {
		return c, errors.New("配置超过 1 MiB")
	}
	var fields map[string]json.RawMessage
	if err = json.Unmarshal(data, &fields); err != nil || fields == nil {
		return c, errors.New("配置必须为 JSON 对象")
	}
	for key, value := range fields {
		if bytes.Equal(bytes.TrimSpace(value), []byte("null")) {
			return c, errors.New("配置字段不能为 null")
		}
		switch key {
		case "listen":
			err = json.Unmarshal(value, &c.Listen)
		case "token":
			err = json.Unmarshal(value, &c.Token)
		case "max_body_bytes":
			err = json.Unmarshal(value, &c.MaxBodyBytes)
		case "max_polls":
			err = json.Unmarshal(value, &c.MaxPolls)
		default:
			return c, errors.New("配置包含未知字段")
		}
		if err != nil {
			return c, errors.New("配置字段类型错误")
		}
	}
	return c, c.validate()
}

func (c Config) validate() error {
	if strings.TrimSpace(c.Listen) == "" || c.Token == "" || c.MaxBodyBytes <= 0 || c.MaxPolls <= 0 {
		return errors.New("监听地址、token 和容量配置不能为空或非正数")
	}
	return nil
}

type Server struct {
	Broker *Broker
	config Config
	// Shortened only by in-package tests; production always uses RequestTimeout.
	timeout time.Duration
}

func New(config Config) (*Server, error) {
	if err := config.validate(); err != nil {
		return nil, err
	}
	b, err := newBroker(config.MaxPolls)
	if err != nil {
		return nil, err
	}
	return &Server{Broker: b, config: config, timeout: RequestTimeout}, nil
}

func (s *Server) HTTPServer() *http.Server {
	return &http.Server{Addr: s.config.Listen, Handler: s, ReadHeaderTimeout: RequestTimeout,
		IdleTimeout: 60 * time.Second, MaxHeaderBytes: 16 * 1024}
}

func writeResponse(w http.ResponseWriter, result Response) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(statusFor(result.Code))
	if err := json.NewEncoder(w).Encode(result); err != nil {
		log.Printf("response write failed code=%d", result.Code)
	}
}

func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	deadline := time.Now().Add(s.timeout)
	controller := http.NewResponseController(w)
	// Bound slow body reads as well as queue waits. Response transmission has a
	// separate one-second allowance and cannot hang forever on a slow reader.
	_ = controller.SetReadDeadline(deadline)
	_ = controller.SetWriteDeadline(deadline.Add(time.Second))
	defer func() {
		_ = controller.SetReadDeadline(time.Time{})
		// net/http flushes buffered output after ServeHTTP returns and then
		// clears its write deadline. Keep ours active through that final flush.
		if recover() != nil {
			log.Print("request panic")
			writeResponse(w, response(InternalError, "服务内部错误"))
		}
	}()
	ctx, cancel := context.WithDeadline(r.Context(), deadline)
	defer cancel()
	switch r.URL.Path {
	case "/execute", "/poll", "/result", "/worlds":
	default:
		writeResponse(w, response(RouteNotFound, "接口不存在"))
		return
	}
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		writeResponse(w, response(MethodNotAllowed, "仅支持 POST"))
		return
	}
	contentType := r.Header.Get("Content-Type")
	media, _, err := mime.ParseMediaType(contentType)
	// The game's QueryServer POST cannot set custom headers. Only Mod routes
	// accept its default media types; the body still must be a JSON object.
	modRoute := r.URL.Path == "/poll" || r.URL.Path == "/result"
	modMedia := contentType == "" || (err == nil && (media == "application/x-www-form-urlencoded" ||
		media == "text/plain" || media == "application/octet-stream"))
	if (err != nil || media != "application/json") && !(modRoute && modMedia) {
		writeResponse(w, response(UnsupportedMediaType, "请求体须为 application/json"))
		return
	}
	body := http.MaxBytesReader(w, r.Body, s.config.MaxBodyBytes)
	defer body.Close()
	data, err := io.ReadAll(body)
	if err != nil {
		var large *http.MaxBytesError
		if errors.As(err, &large) {
			writeResponse(w, response(BodyTooLarge, "请求体超过大小限制"))
		} else {
			writeResponse(w, response(InvalidJSON, "无法读取 JSON 请求体"))
		}
		return
	}
	// Reading is complete; don't time out keep-alive reads belonging to another request.
	_ = controller.SetReadDeadline(time.Time{})
	var fields map[string]json.RawMessage
	if json.Unmarshal(data, &fields) != nil || fields == nil {
		writeResponse(w, response(InvalidJSON, "请求体必须为单个 JSON 对象"))
		return
	}
	var token string
	if json.Unmarshal(fields["token"], &token) != nil || token == "" || subtle.ConstantTimeCompare([]byte(token), []byte(s.config.Token)) != 1 {
		writeResponse(w, response(InvalidToken, "token 无效"))
		return
	}
	if r.URL.Path == "/worlds" {
		cluster, valid := parseCluster(fields)
		if !valid {
			writeResponse(w, response(InvalidTarget, "集群标识无效"))
			return
		}
		writeResponse(w, s.Broker.worlds(cluster, time.Now()))
		return
	}
	target, valid := parseTarget(fields["target"])
	if !valid {
		writeResponse(w, response(InvalidTarget, "目标世界无效"))
		return
	}
	var result Response
	switch r.URL.Path {
	case "/execute":
		result = s.execute(ctx, fields, target, deadline)
	case "/poll":
		result = s.Broker.poll(ctx, target, deadline)
	case "/result":
		result = s.result(fields, target)
	}
	writeResponse(w, result)
}

var identifier = regexp.MustCompile(`^[A-Za-z0-9_-]{1,128}$`)

func parseCluster(fields map[string]json.RawMessage) (string, bool) {
	cluster := "default"
	if raw, present := fields["cluster_id"]; present {
		if bytes.Equal(bytes.TrimSpace(raw), []byte("null")) || json.Unmarshal(raw, &cluster) != nil || !identifier.MatchString(cluster) {
			return "", false
		}
	}
	return cluster, true
}

func parseTarget(raw json.RawMessage) (Target, bool) {
	var fields map[string]json.RawMessage
	if json.Unmarshal(raw, &fields) != nil || fields == nil {
		return Target{}, false
	}
	cluster, valid := parseCluster(fields)
	if !valid {
		return Target{}, false
	}
	t := Target{ClusterID: cluster}
	if json.Unmarshal(fields["world_id"], &t.WorldID) != nil || !identifier.MatchString(t.WorldID) {
		return t, false
	}
	return t, true
}

func validateArgs(action string, raw json.RawMessage) bool {
	var args map[string]json.RawMessage
	if json.Unmarshal(raw, &args) != nil || args == nil {
		return false
	}
	key := ""
	switch action {
	case "world_info", "players", "save":
		return len(args) == 0
	case "announce":
		key = "message"
	case "rollback":
		var count int
		return len(args) == 1 && json.Unmarshal(args["count"], &count) == nil && count > 0
	case "lua":
		key = "code"
	}
	var value string
	if len(args) != 1 || json.Unmarshal(args[key], &value) != nil || strings.TrimSpace(value) == "" {
		return false
	}
	return true
}

func (s *Server) execute(ctx context.Context, fields map[string]json.RawMessage, target Target, deadline time.Time) Response {
	var action string
	if json.Unmarshal(fields["action"], &action) != nil {
		return response(UnsupportedAction, "操作名称无效")
	}
	switch action {
	case "world_info", "players", "announce", "save", "rollback", "lua":
	default:
		return response(UnsupportedAction, "不支持的操作")
	}
	if !validateArgs(action, fields["args"]) {
		return response(InvalidArgs, "操作参数无效")
	}
	t, failure := s.Broker.enqueue(ctx, target, action, fields["args"], deadline)
	if t == nil {
		return failure
	}
	return s.Broker.wait(ctx, t)
}

func (s *Server) result(fields map[string]json.RawMessage, target Target) Response {
	var id string
	if json.Unmarshal(fields["task_id"], &id) != nil || strings.TrimSpace(id) == "" || len(id) > 128 {
		return response(InvalidTaskID, "任务编号无效")
	}
	// Pointers distinguish a missing/null field from a valid zero/false value.
	var code *int
	var ok *bool
	var message *string
	var output string
	invalid := json.Unmarshal(fields["code"], &code) != nil || code == nil ||
		json.Unmarshal(fields["ok"], &ok) != nil || ok == nil ||
		json.Unmarshal(fields["message"], &message) != nil || message == nil
	if raw, present := fields["output"]; present {
		invalid = invalid || bytes.Equal(bytes.TrimSpace(raw), []byte("null")) || json.Unmarshal(raw, &output) != nil
	}
	if invalid || (*code != OK && *code != ModExecutionFailed) || *ok != (*code == OK) {
		return response(InvalidResult, "结果格式无效")
	}
	result := response(*code, *message)
	result.Result = fields["result"]
	result.Output = output
	return s.Broker.submit(target, id, result)
}
