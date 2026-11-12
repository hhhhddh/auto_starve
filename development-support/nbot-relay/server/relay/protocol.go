// Package relay implements the ephemeral HTTP bridge used by game shards.
package relay

import (
	"encoding/json"
	"net/http"
)

const (
	OK                   = 0
	InvalidJSON          = 1001
	InvalidTarget        = 1002
	UnsupportedAction    = 1003
	InvalidArgs          = 1004
	InvalidTaskID        = 1005
	InvalidResult        = 1006
	BodyTooLarge         = 1007
	MethodNotAllowed     = 1008
	RouteNotFound        = 1009
	UnsupportedMediaType = 1010
	InvalidToken         = 2001
	ResultTimeout        = 3001
	TaskTargetMismatch   = 3002
	TaskNotClaimed       = 3003
	ModExecutionFailed   = 4001
	GlobalTaskLimit      = 5001
	PollLimit            = 5002
	ServerStopping       = 5003
	InternalError        = 5004
)

const DefaultToken = "nbot-relay-default"

type Target struct {
	ClusterID string `json:"cluster_id,omitempty"`
	WorldID   string `json:"world_id"`
}

type Command struct {
	TaskID      string          `json:"task_id"`
	Action      string          `json:"action"`
	Args        json.RawMessage `json:"args"`
	RemainingMS int64           `json:"remaining_ms"`
}

type Response struct {
	Code          int             `json:"code"`
	Message       string          `json:"message"`
	OK            bool            `json:"ok"`
	TaskID        string          `json:"task_id,omitempty"`
	Result        json.RawMessage `json:"result,omitempty"`
	Output        string          `json:"output,omitempty"`
	Tasks         *[]Command      `json:"tasks,omitempty"`
	Accepted      *bool           `json:"accepted,omitempty"`
	ClusterID     string          `json:"cluster_id,omitempty"`
	WorldIDs      *[]string       `json:"world_ids,omitempty"`
	WindowSeconds int             `json:"window_seconds,omitempty"`
}

func response(code int, message string) Response {
	return Response{Code: code, Message: message, OK: code == OK}
}

func statusFor(code int) int {
	switch code {
	case OK, ModExecutionFailed:
		return http.StatusOK
	case InvalidToken:
		return http.StatusUnauthorized
	case TaskTargetMismatch, TaskNotClaimed:
		return http.StatusConflict
	case ResultTimeout:
		return http.StatusGatewayTimeout
	case BodyTooLarge:
		return http.StatusRequestEntityTooLarge
	case MethodNotAllowed:
		return http.StatusMethodNotAllowed
	case RouteNotFound:
		return http.StatusNotFound
	case UnsupportedMediaType:
		return http.StatusUnsupportedMediaType
	case GlobalTaskLimit, PollLimit, ServerStopping:
		return http.StatusServiceUnavailable
	case InternalError:
		return http.StatusInternalServerError
	default:
		return http.StatusBadRequest
	}
}
