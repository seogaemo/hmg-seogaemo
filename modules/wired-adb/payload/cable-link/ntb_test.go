package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func frame(n int) []byte {
	b := make([]byte, n)
	for i := range b {
		b[i] = byte(i*7 + 3)
	}
	return b
}

func TestNTBRoundTrip(t *testing.T) {
	layouts := []ntbLayout{
		{outMax: 16384, divisor: 4, remainder: 0, alignment: 4, packet: 512},
		{outMax: 65535, divisor: 8, remainder: 2, alignment: 8, packet: 1024},
		{outMax: 2048, divisor: 1, remainder: 0, alignment: 4, packet: 64},
	}
	for _, l := range layouts {
		if !l.valid() {
			t.Fatalf("layout %+v must be valid", l)
		}
		for _, size := range []int{14, 60, 61, 482, 484, 1514} {
			in := frame(size)
			b, err := l.encode(9, in)
			if err != nil {
				t.Fatalf("%+v size %d: %v", l, size, err)
			}
			if len(b)%l.packet == 0 && len(b) < l.outMax {
				t.Fatalf("%+v size %d: transfer of %d bytes needs a zero-length packet", l, size, len(b))
			}
			ndp := int(usbLE.Uint16(b[10:]))
			start := int(usbLE.Uint16(b[ndp+8:]))
			if ndp%l.alignment != 0 || (start+14)%l.divisor != l.remainder {
				t.Fatalf("%+v size %d: ndp=%d start=%d misaligned", l, size, ndp, start)
			}
			out, err := decodeNTB16(b)
			if err != nil || len(out) != 1 || !bytes.Equal(out[0], in) {
				t.Fatalf("%+v size %d: decode gave %d frames, err %v", l, size, len(out), err)
			}
		}
	}
}

func TestNTBLimits(t *testing.T) {
	l := ntbLayout{outMax: 2048, divisor: 4, remainder: 0, alignment: 4, packet: 512}
	if _, err := l.encode(0, frame(13)); err == nil {
		t.Fatal("a 13-byte frame is not Ethernet")
	}
	if _, err := l.encode(0, frame(2040)); err == nil {
		t.Fatal("a frame beyond the negotiated NTB must be refused")
	}
	for _, bad := range []ntbLayout{{outMax: 2048, divisor: 0, alignment: 4, packet: 512},
		{outMax: 2048, divisor: 4, remainder: 4, alignment: 4, packet: 512},
		{outMax: 2048, divisor: 4, alignment: 6, packet: 512},
		{outMax: 2048, divisor: 4, alignment: 4, packet: 0}} {
		if bad.valid() {
			t.Fatalf("layout %+v must be invalid", bad)
		}
	}
}

func TestNTBRejectsMalformed(t *testing.T) {
	l := ntbLayout{outMax: 16384, divisor: 4, remainder: 0, alignment: 4, packet: 512}
	good, _ := l.encode(1, frame(60))
	corrupt := func(change func(b []byte)) []byte {
		b := append([]byte(nil), good...)
		change(b)
		return b
	}
	cases := map[string][]byte{
		"short":            good[:8],
		"signature":        corrupt(func(b []byte) { b[0] = 'X' }),
		"block beyond":     corrupt(func(b []byte) { usbLE.PutUint16(b[8:], uint16(len(b)+4)) }),
		"ndp signature":    corrupt(func(b []byte) { b[12] = 'X' }),
		"ndp loop":         corrupt(func(b []byte) { usbLE.PutUint16(b[12+6:], 12) }),
		"datagram beyond":  corrupt(func(b []byte) { usbLE.PutUint16(b[12+10:], 9000) }),
		"datagram tiny":    corrupt(func(b []byte) { usbLE.PutUint16(b[12+10:], 6) }),
		"not terminated":   corrupt(func(b []byte) { usbLE.PutUint16(b[12+4:], 12) }),
		"ndp length odd":   corrupt(func(b []byte) { usbLE.PutUint16(b[12+4:], 18) }),
		"ndp out of block": corrupt(func(b []byte) { usbLE.PutUint16(b[10:], uint16(len(b)-4)) }),
	}
	for name, b := range cases {
		if _, err := decodeNTB16(b); err == nil {
			t.Fatalf("%s: malformed NTB accepted", name)
		}
	}
	// An NTB whose NDP lists no datagram is valid and carries nothing.
	empty := corrupt(func(b []byte) { usbLE.PutUint16(b[12+8:], 0); usbLE.PutUint16(b[12+10:], 0) })
	if frames, err := decodeNTB16(empty); err != nil || len(frames) != 0 {
		t.Fatalf("empty NTB: %d frames, err %v", len(frames), err)
	}
}

func TestCountKeys(t *testing.T) {
	key := strings.Repeat("A", keyChars-1) + "="
	file := filepath.Join(t.TempDir(), "adb_keys")
	content := key + " dev@laptop\n" + "\n" + key[:keyChars-1] + "\n" + strings.Repeat("*", keyChars) + "\n" + key + "\r\n"
	if err := os.WriteFile(file, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	if n, err := countKeys(file); err != nil || n != 2 {
		t.Fatalf("countKeys = %d, %v; want 2", n, err)
	}
	if _, err := countKeys(file + ".absent"); err == nil {
		t.Fatal("a missing key file must be an error")
	}
}
