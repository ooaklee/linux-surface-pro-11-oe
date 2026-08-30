// Package bluetoothmgmt applies a private Bluetooth public address through the
// kernel HCI management control channel without invoking interactive tools.
package bluetoothmgmt

import (
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
	"time"
)

const (
	// defaultControllerWait bounds cold-boot HCI enumeration.
	defaultControllerWait = 2 * time.Minute
	// maximumControllerWait prevents configuration from creating an unbounded wait.
	maximumControllerWait = 5 * time.Minute
	// defaultPollInterval controls bounded controller-presence checks.
	defaultPollInterval = time.Second
	// defaultAttempts matches the established cold-boot retry envelope.
	defaultAttempts = 60
	// maximumAttempts prevents caller-controlled retry loops.
	maximumAttempts = 120
	// defaultRetryDelay spaces fresh management sockets between attempts.
	defaultRetryDelay = time.Second
	// defaultReadTimeout bounds management response reads.
	defaultReadTimeout = 5 * time.Second
	// maximumReadTimeout caps each management response deadline.
	maximumReadTimeout = 30 * time.Second
)

// Address is a private six-octet public controller address whose formatting is
// always redacted.
type Address [6]byte

// String prevents ordinary formatting from disclosing a private address.
func (Address) String() string {
	return "<redacted>"
}

// GoString prevents diagnostic formatting from disclosing a private address.
func (Address) GoString() string {
	return "bluetoothmgmt.Address(<redacted>)"
}

// Options controls bounded controller discovery and management retries.
type Options struct {
	// ControllerIndex selects one HCI management controller.
	ControllerIndex uint16
	// ControllerRoot overrides /sys/class/bluetooth for isolated tests.
	ControllerRoot string
	// ControllerWait bounds HCI enumeration.
	ControllerWait time.Duration
	// PollInterval controls cancellation-aware discovery polling.
	PollInterval time.Duration
	// Attempts bounds fresh management-socket attempts.
	Attempts int
	// RetryDelay spaces attempts without blocking cancellation.
	RetryDelay time.Duration
	// ReadTimeout bounds matching management-event reads per attempt.
	ReadTimeout time.Duration
}

// normalisedOptions contains validated non-zero runtime bounds.
type normalisedOptions struct {
	// ControllerIndex selects one HCI management controller.
	ControllerIndex uint16
	// ControllerRoot is the concrete sysfs inventory directory.
	ControllerRoot string
	// ControllerWait bounds HCI enumeration.
	ControllerWait time.Duration
	// PollInterval controls cancellation-aware discovery polling.
	PollInterval time.Duration
	// Attempts bounds fresh management-socket attempts.
	Attempts int
	// RetryDelay spaces attempts.
	RetryDelay time.Duration
	// ReadTimeout bounds matching event reads.
	ReadTimeout time.Duration
}

// ParseAddress validates canonical hexadecimal without including rejected input
// in errors or formatted values.
func ParseAddress(value string) (Address, error) {
	var address Address
	if len(value) != 17 || strings.ToUpper(value) != value {
		return address, errors.New("private Bluetooth address is not canonical uppercase colon-separated hexadecimal")
	}
	for index := 0; index < len(address); index++ {
		start := index * 3
		if index < len(address)-1 && value[start+2] != ':' {
			return Address{}, errors.New("private Bluetooth address is not canonical uppercase colon-separated hexadecimal")
		}
		decoded, err := hex.DecodeString(value[start : start+2])
		if err != nil || len(decoded) != 1 {
			return Address{}, errors.New("private Bluetooth address is not canonical uppercase colon-separated hexadecimal")
		}
		address[index] = decoded[0]
	}
	if placeholderAddress(address) || address[0]&0x01 != 0 {
		return Address{}, errors.New("private Bluetooth address is not an accepted unicast public address")
	}
	return address, nil
}

// placeholderAddress rejects established unusable or documentation values.
func placeholderAddress(address Address) bool {
	if address == (Address{0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA}) ||
		address == (Address{0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF}) ||
		address == (Address{0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF}) {
		return true
	}
	return address[0] == 0 && address[1] == 0 && address[2] == 0 && address[3] == 0
}

// normaliseOptions supplies defaults and rejects unsafe timing controls.
func normaliseOptions(options Options) (normalisedOptions, error) {
	normalised := normalisedOptions{
		ControllerIndex: options.ControllerIndex,
		ControllerRoot:  options.ControllerRoot,
		ControllerWait:  options.ControllerWait,
		PollInterval:    options.PollInterval,
		Attempts:        options.Attempts,
		RetryDelay:      options.RetryDelay,
		ReadTimeout:     options.ReadTimeout,
	}
	if normalised.ControllerRoot == "" {
		normalised.ControllerRoot = "/sys/class/bluetooth"
	}
	if normalised.ControllerWait == 0 {
		normalised.ControllerWait = defaultControllerWait
	}
	if normalised.PollInterval == 0 {
		normalised.PollInterval = defaultPollInterval
	}
	if normalised.Attempts == 0 {
		normalised.Attempts = defaultAttempts
	}
	if normalised.RetryDelay == 0 {
		normalised.RetryDelay = defaultRetryDelay
	}
	if normalised.ReadTimeout == 0 {
		normalised.ReadTimeout = defaultReadTimeout
	}
	if normalised.ControllerWait < 0 || normalised.ControllerWait > maximumControllerWait ||
		normalised.PollInterval <= 0 || normalised.PollInterval > normalised.ControllerWait ||
		normalised.Attempts < 1 || normalised.Attempts > maximumAttempts ||
		normalised.RetryDelay < 0 || normalised.RetryDelay > maximumReadTimeout ||
		normalised.ReadTimeout <= 0 || normalised.ReadTimeout > maximumReadTimeout {
		return normalisedOptions{}, fmt.Errorf("Bluetooth management timing options exceed their compiled bounds")
	}
	return normalised, nil
}
