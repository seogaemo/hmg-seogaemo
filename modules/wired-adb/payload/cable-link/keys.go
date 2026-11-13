package main

import (
	"bufio"
	"os"
	"strings"
)

// keyChars is the base64 length of adb's 524-byte RSA-2048 public key structure.
const keyChars = 700

func plausibleKey(field string) bool {
	if len(field) != keyChars {
		return false
	}
	for i := 0; i < len(field); i++ {
		c := field[i]
		if !(c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '+' || c == '/' || c == '=') {
			return false
		}
	}
	return true
}

// countKeys reports how many lines of an adb_keys file start with a plausible
// key. The cable adbd decodes and checks the keys itself; this only decides
// whether starting it is worthwhile.
func countKeys(path string) (int, error) {
	f, err := os.Open(path)
	if err != nil {
		return 0, err
	}
	defer f.Close()
	count := 0
	lines := bufio.NewScanner(f)
	for lines.Scan() {
		fields := strings.Fields(lines.Text())
		if len(fields) > 0 && plausibleKey(fields[0]) {
			count++
		}
	}
	return count, lines.Err()
}
