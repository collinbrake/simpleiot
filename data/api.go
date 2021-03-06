package data

// StandardResponse is the standard response to any request
type StandardResponse struct {
	Success bool   `json:"success"`
	Error   string `json:"error,omitempty"`
	ID      string `json:"id,omitempty"`
}
