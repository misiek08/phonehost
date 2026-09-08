// chargecap keeps the battery of the note9pro host inside a charge band.
//
// The pm6150_chg module exposes charge_behaviour on the qcom_qg power supply;
// "inhibit-charge" stops charging while the USB input keeps powering the phone,
// so holding the band costs nothing - the battery simply sits at 0 A instead of
// floating at 100 % / 4.44 V.
//
// Safety rules, in order of precedence:
//   - below the floor, charging is always restored, whatever the band says
//   - any unreadable sysfs file or a lost charge_behaviour restores charging
//   - a signal or a panic restores charging before exiting
//
// Metrics are exported for the local VictoriaMetrics to scrape.
package main

import (
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const listenRetry = 15 * time.Second

const (
	behaviourAuto      = "auto"
	behaviourInhibit   = "inhibit-charge"
	behaviourDischarge = "force-discharge"
)

type config struct {
	sysfs    string
	upper    int
	lower    int
	floor    int
	interval time.Duration
	listen   string
	descend  bool
}

type state struct {
	mu           sync.Mutex
	capacity     int
	voltage      float64
	current      float64
	behaviour    string
	chargerState string
	available    bool
	transitions  int
	writeErrors  int
	readErrors   int
	lastChange   time.Time
}

var (
	cfg config
	st  state
)

func envInt(name string, def int) int {
	v := os.Getenv(name)
	if v == "" {
		return def
	}
	n, err := strconv.Atoi(strings.TrimSpace(v))
	if err != nil {
		log.Printf("%s=%q is not a number, using %d", name, v, def)
		return def
	}
	return n
}

func envStr(name, def string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return def
}

func loadConfig() error {
	cfg = config{
		sysfs:    envStr("CHARGECAP_SYSFS", "/sys/class/power_supply/qcom_qg"),
		upper:    envInt("CHARGECAP_UPPER", 80),
		lower:    envInt("CHARGECAP_LOWER", 75),
		floor:    envInt("CHARGECAP_FLOOR", 60),
		interval: time.Duration(envInt("CHARGECAP_INTERVAL_SECONDS", 30)) * time.Second,
		listen:   envStr("CHARGECAP_LISTEN", "127.0.0.1:9110"),
		descend:  envStr("CHARGECAP_DESCEND", "yes") != "no",
	}

	switch {
	case cfg.upper < 1 || cfg.upper > 100:
		return fmt.Errorf("upper bound %d out of range", cfg.upper)
	case cfg.lower >= cfg.upper:
		return fmt.Errorf("lower bound %d must be below upper bound %d", cfg.lower, cfg.upper)
	case cfg.floor > cfg.lower:
		return fmt.Errorf("floor %d must not exceed lower bound %d", cfg.floor, cfg.lower)
	case cfg.interval < time.Second:
		return errors.New("interval must be at least 1s")
	}
	return nil
}

func readFile(name string) (string, error) {
	b, err := os.ReadFile(filepath.Join(cfg.sysfs, name))
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(b)), nil
}

func readInt(name string) (int, error) {
	s, err := readFile(name)
	if err != nil {
		return 0, err
	}
	return strconv.Atoi(s)
}

// charge_behaviour reads as e.g. "[auto] inhibit-charge force-discharge"
func readBehaviour() (string, error) {
	s, err := readFile("charge_behaviour")
	if err != nil {
		return "", err
	}
	for _, f := range strings.Fields(s) {
		if strings.HasPrefix(f, "[") {
			return strings.Trim(f, "[]"), nil
		}
	}
	return "", fmt.Errorf("no active behaviour in %q", s)
}

func writeBehaviour(b string) error {
	return os.WriteFile(filepath.Join(cfg.sysfs, "charge_behaviour"), []byte(b), 0o200)
}

// chargerState is informational only; the module exports it because qcom_qg
// hardcodes POWER_SUPPLY_PROP_STATUS to Unknown.
func chargerState() string {
	b, err := os.ReadFile("/sys/kernel/pm6150_chg/status")
	if err != nil {
		return "unknown"
	}
	return strings.TrimSpace(string(b))
}

// The control law has three levers, because inhibit-charge alone can only stop
// the level from rising: with the USB input still powering the phone the battery
// sits at 0 A, so a cell already above the band never comes down.
//
//	above the band  -> force-discharge, run off the battery until it reaches it
//	at the top      -> inhibit-charge, hold at 0 A (no cycling, no heat)
//	at the bottom   -> auto, refill
//	inside the band -> hold, but never keep discharging
func decide(capacity int, current string) string {
	switch {
	case capacity <= cfg.floor:
		return behaviourAuto
	case capacity > cfg.upper:
		if !cfg.descend {
			return behaviourInhibit
		}
		return behaviourDischarge
	case capacity == cfg.upper:
		return behaviourInhibit
	case capacity <= cfg.lower:
		return behaviourAuto
	case current == behaviourDischarge:
		// reached the band while discharging: stop draining and hold
		return behaviourInhibit
	default:
		return current
	}
}

func step() {
	capacity, err := readInt("capacity")
	if err != nil {
		st.mu.Lock()
		st.readErrors++
		st.mu.Unlock()
		log.Printf("cannot read capacity: %v - restoring charging", err)
		if err := writeBehaviour(behaviourAuto); err != nil {
			log.Printf("restoring charging failed: %v", err)
		}
		return
	}

	behaviour, err := readBehaviour()
	if err != nil {
		st.mu.Lock()
		st.available = false
		st.readErrors++
		st.capacity = capacity
		st.mu.Unlock()
		log.Printf("charge_behaviour unavailable (%v) - is pm6150_chg loaded?", err)
		return
	}

	want := decide(capacity, behaviour)
	if want != behaviour {
		if err := writeBehaviour(want); err != nil {
			st.mu.Lock()
			st.writeErrors++
			st.mu.Unlock()
			log.Printf("cannot set %s at %d%%: %v", want, capacity, err)
		} else {
			st.mu.Lock()
			st.transitions++
			st.lastChange = time.Now()
			st.mu.Unlock()
			log.Printf("%d%% -> %s", capacity, want)
			behaviour = want
		}
	}

	uv, _ := readInt("voltage_now")
	ua, _ := readInt("current_now")

	st.mu.Lock()
	st.capacity = capacity
	st.voltage = float64(uv) / 1e6
	st.current = float64(ua) / 1e6
	st.behaviour = behaviour
	st.chargerState = chargerState()
	st.available = true
	st.mu.Unlock()
}

func metrics(w http.ResponseWriter, _ *http.Request) {
	st.mu.Lock()
	defer st.mu.Unlock()

	inhibited := 0
	if st.behaviour == behaviourInhibit {
		inhibited = 1
	}
	available := 0
	if st.available {
		available = 1
	}

	w.Header().Set("Content-Type", "text/plain; version=0.0.4")
	fmt.Fprintf(w, "# HELP chargecap_up chargecap is running.\n# TYPE chargecap_up gauge\nchargecap_up 1\n")
	fmt.Fprintf(w, "# HELP chargecap_available The pm6150_chg charge_behaviour control is present.\n# TYPE chargecap_available gauge\nchargecap_available %d\n", available)
	fmt.Fprintf(w, "# HELP chargecap_inhibited Charging is currently inhibited.\n# TYPE chargecap_inhibited gauge\nchargecap_inhibited %d\n", inhibited)
	fmt.Fprintf(w, "# HELP chargecap_capacity_percent Battery charge level.\n# TYPE chargecap_capacity_percent gauge\nchargecap_capacity_percent %d\n", st.capacity)
	fmt.Fprintf(w, "# HELP chargecap_voltage_volts Battery voltage.\n# TYPE chargecap_voltage_volts gauge\nchargecap_voltage_volts %.6f\n", st.voltage)
	fmt.Fprintf(w, "# HELP chargecap_current_amperes Battery current, positive while discharging.\n# TYPE chargecap_current_amperes gauge\nchargecap_current_amperes %.6f\n", st.current)
	fmt.Fprintf(w, "# HELP chargecap_band_percent Configured charge band.\n# TYPE chargecap_band_percent gauge\nchargecap_band_percent{bound=\"upper\"} %d\nchargecap_band_percent{bound=\"lower\"} %d\nchargecap_band_percent{bound=\"floor\"} %d\n", cfg.upper, cfg.lower, cfg.floor)
	fmt.Fprintf(w, "# HELP chargecap_transitions_total Charge behaviour changes since start.\n# TYPE chargecap_transitions_total counter\nchargecap_transitions_total %d\n", st.transitions)
	fmt.Fprintf(w, "# HELP chargecap_write_errors_total Failed charge_behaviour writes.\n# TYPE chargecap_write_errors_total counter\nchargecap_write_errors_total %d\n", st.writeErrors)
	fmt.Fprintf(w, "# HELP chargecap_read_errors_total Failed sysfs reads.\n# TYPE chargecap_read_errors_total counter\nchargecap_read_errors_total %d\n", st.readErrors)
	fmt.Fprintf(w, "# HELP chargecap_charger_state Charger state reported by pm6150_chg.\n# TYPE chargecap_charger_state gauge\nchargecap_charger_state{state=\"%s\"} 1\n", st.chargerState)
	fmt.Fprintf(w, "# HELP chargecap_behaviour The charge behaviour currently applied.\n# TYPE chargecap_behaviour gauge\n")
	for _, mode := range []string{behaviourAuto, behaviourInhibit, behaviourDischarge} {
		v := 0
		if st.behaviour == mode {
			v = 1
		}
		fmt.Fprintf(w, "chargecap_behaviour{mode=\"%s\"} %d\n", mode, v)
	}
}

func main() {
	log.SetFlags(0)
	if err := loadConfig(); err != nil {
		log.Fatalf("configuration: %v", err)
	}
	log.Printf("band %d-%d%%, floor %d%%, descend=%t, every %s, metrics on %s",
		cfg.lower, cfg.upper, cfg.floor, cfg.descend, cfg.interval, cfg.listen)

	// Whatever happens next, the phone must be left able to charge.
	defer func() {
		if err := writeBehaviour(behaviourAuto); err != nil {
			log.Printf("could not restore charging on exit: %v", err)
		} else {
			log.Print("charging restored on exit")
		}
	}()

	// At boot this daemon can start before loopback is configured, so binding
	// has to be retried - and it must never take the control loop down with it.
	mux := http.NewServeMux()
	mux.HandleFunc("/metrics", metrics)
	go func() {
		logged := false
		for {
			ln, err := net.Listen("tcp", cfg.listen)
			if err != nil {
				if !logged {
					log.Printf("metrics server: %v - retrying every %s", err, listenRetry)
					logged = true
				}
				time.Sleep(listenRetry)
				continue
			}
			log.Printf("metrics server listening on %s", cfg.listen)
			logged = false
			if err := (&http.Server{Handler: mux}).Serve(ln); err != nil &&
				!errors.Is(err, http.ErrServerClosed) {
				log.Printf("metrics server: %v - restarting", err)
			}
			time.Sleep(listenRetry)
		}
	}()

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)

	ticker := time.NewTicker(cfg.interval)
	defer ticker.Stop()

	step()
	for {
		select {
		case s := <-sig:
			log.Printf("got %s, shutting down", s)
			return
		case <-ticker.C:
			step()
		}
	}
}
