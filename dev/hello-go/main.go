package main

import (
	"fmt"
	"os"
	"runtime"
	"strings"
)

func main() {
	fmt.Printf("go %s on %s/%s, %d cores\n", runtime.Version(), runtime.GOOS, runtime.GOARCH, runtime.NumCPU())
	if b, err := os.ReadFile("/sys/class/power_supply/qcom_qg/capacity"); err == nil {
		fmt.Printf("battery: %s%%\n", strings.TrimSpace(string(b)))
	}
}
