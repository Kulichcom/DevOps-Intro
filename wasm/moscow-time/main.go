package main

import (
	"fmt"
	"net/http"
	"time"

	spinhttp "github.com/spinframework/spin-go-sdk/v2/http"
)

// Moscow is UTC+3 all year (no DST since 2014). A fixed zone avoids
// time.LoadLocation, which needs tzdata that TinyGo/WASI doesn't ship.
var moscow = time.FixedZone("MSK", 3*60*60)

// moscowJSON builds the body with fmt + %q instead of encoding/json:
// TinyGo's reflection support makes json of map[string]any unreliable.
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

func init() {
	spinhttp.Handle(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.Method != http.MethodGet {
			w.WriteHeader(http.StatusMethodNotAllowed)
			fmt.Fprint(w, `{"error":"method not allowed"}`)
			return
		}
		fmt.Fprintln(w, moscowJSON(time.Now()))
	})
}
