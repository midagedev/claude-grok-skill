package cred

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"
)

// VerifyMain checks a key before it is stored, so a typo fails at setup instead
// of mid-round.
//
//	outsource verify-key <provider>     # the key arrives on stdin
//
// The key is read from stdin rather than an argument, because an argument shows
// up in a process listing. It exists in this process's memory and in the pipe
// from its parent, and nowhere else: no file, no log, no argv.
//
// Exit 0 accepted · 1 rejected (with the provider's own reason when it gave one)
// · 2 unverifiable (network) · 64 usage · 3 no free endpoint for this provider.
func VerifyMain(args []string, stdout, stderr io.Writer, stdin io.Reader) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, "usage: verify-key <zai|xai>   (key on stdin)")
		return ExitUsage
	}
	provider := args[0]
	if _, ok := providers[provider]; !ok {
		fmt.Fprintf(stderr, "verify-key: unknown provider '%s' (known: zai xai)\n", provider)
		return ExitUsage
	}
	raw, err := io.ReadAll(io.LimitReader(stdin, 1<<16))
	if err != nil {
		fmt.Fprintln(stderr, "verify-key: could not read the key from stdin")
		return ExitUsage
	}
	key := strings.TrimRight(string(raw), "\r\n")
	if key == "" {
		fmt.Fprintln(stderr, "verify-key: no key on stdin")
		return ExitUsage
	}

	if provider != "zai" {
		// Only zai has a free read-only endpoint to check against; xai's would
		// cost a real request, so a key for it is stored unverified and the
		// caller says so.
		fmt.Fprintf(stderr, "verify-key: '%s' has no free endpoint to verify against\n", provider)
		return 3
	}

	base := os.Getenv("ZAI_QUOTA_BASE")
	if base == "" {
		base = "https://api.z.ai"
	}
	req, err := http.NewRequest("GET", base+"/api/monitor/usage/quota/limit", nil)
	if err != nil {
		fmt.Fprintf(stderr, "verify-key: %v\n", err)
		return ExitUsage
	}
	req.Header.Set("Authorization", "Bearer "+key)
	req.Header.Set("Accept", "application/json")
	resp, err := (&http.Client{Timeout: 20 * time.Second}).Do(req)
	if err != nil {
		fmt.Fprintf(stderr, "verify-key: could not reach z.ai (%v)\n", err)
		return ExitEndpointUnreachable
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))

	// This endpoint answers a bad credential with HTTP 200 and success:false, so
	// the body decides, not the status line.
	var d map[string]any
	if json.Unmarshal(body, &d) != nil {
		fmt.Fprintln(stderr, "verify-key: z.ai returned a body this cannot read")
		return 1
	}
	ok, _ := d["success"].(bool)
	code, _ := d["code"].(float64)
	if ok && int(code) == 200 {
		return 0
	}
	if msg, ok := d["msg"].(string); ok && msg != "" {
		fmt.Fprintln(stdout, msg) // the provider's own reason, for the caller to quote
	}
	return 1
}

// ExitEndpointUnreachable separates "the network failed" from "the key is bad",
// so a caller offline does not get told their key was rejected.
const ExitEndpointUnreachable = 2
