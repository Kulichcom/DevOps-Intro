// Prints p50/p95/mean (ms) for each command in a hyperfine --export-json file.
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"sort"
)

func main() {
	var f struct {
		Results []struct {
			Command string    `json:"command"`
			Mean    float64   `json:"mean"`
			Times   []float64 `json:"times"`
		} `json:"results"`
	}
	b, _ := os.ReadFile(os.Args[1])
	if err := json.Unmarshal(b, &f); err != nil {
		panic(err)
	}
	for _, r := range f.Results {
		t := append([]float64(nil), r.Times...)
		sort.Float64s(t)
		pct := func(p float64) float64 { return t[int(p*float64(len(t)-1)+0.5)] * 1000 }
		fmt.Printf("%-75s n=%d p50=%.2fms p95=%.2fms mean=%.2fms\n", r.Command, len(t), pct(0.50), pct(0.95), r.Mean*1000)
	}
}
