// Standalone WASI CLI module (CGI / WAGI-shaped): the request comes in as
// environment variables, the response goes to stdout as CGI headers + body.
// Run: wasmtime run --env REQUEST_METHOD=GET --env PATH_INFO=/time main.wasm
package main

import (
	"fmt"
	"os"
	"time"
)

var moscow = time.FixedZone("MSK", 3*60*60)

// Same logic as wasm/moscow-time/main.go.
func moscowJSON(now time.Time) string {
	msk := now.In(moscow)
	return fmt.Sprintf(
		`{"unix":%d,"iso":%q,"hour_minute":%q,"timezone":%q,"utc_offset":%q,"utc":%q}`,
		now.Unix(),
		msk.Format(time.RFC3339),
		msk.Format("15:04"),
		"Europe/Moscow",
		"+03:00",
		now.UTC().Format(time.RFC3339),
	)
}

func main() {
	method, path := os.Getenv("REQUEST_METHOD"), os.Getenv("PATH_INFO")
	fmt.Print("Content-Type: application/json\n")
	switch {
	case path != "/time":
		fmt.Print("Status: 404 Not Found\n\n{\"error\":\"not found\"}\n")
	case method != "GET":
		fmt.Print("Status: 405 Method Not Allowed\n\n{\"error\":\"method not allowed\"}\n")
	default:
		fmt.Print("Status: 200 OK\n\n" + moscowJSON(time.Now()) + "\n")
	}
}
