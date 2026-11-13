// CDC NCM transfer blocks (NTB16), kept free of system calls so the framing is
// testable on any host.
package main

import (
	"encoding/binary"
	"errors"
	"fmt"
)

var usbLE = binary.LittleEndian

// ntbLayout is the transmit layout the USB device reports in GET_NTB_PARAMETERS.
type ntbLayout struct {
	outMax, divisor, remainder, alignment, packet int
}

func (l ntbLayout) valid() bool {
	return l.divisor >= 1 && l.divisor <= l.outMax && l.remainder < l.divisor &&
		l.alignment >= 4 && l.alignment <= l.outMax && l.alignment&(l.alignment-1) == 0 &&
		l.packet >= 8
}

// encode wraps one Ethernet frame in an NTB16 that carries a single NDP16.
func (l ntbLayout) encode(seq uint16, frame []byte) ([]byte, error) {
	if len(frame) < 14 {
		return nil, errors.New("short ethernet frame")
	}
	ndp := (12 + l.alignment - 1) / l.alignment * l.alignment
	start := ndp + 16
	start += (l.remainder - (start+14)%l.divisor + l.divisor) % l.divisor
	end := start + len(frame)
	// A transfer that is an exact multiple of the packet size would need a
	// zero-length packet; one pad byte ends it with a short packet instead.
	if end%l.packet == 0 && end < l.outMax {
		end++
	}
	if end > l.outMax {
		return nil, errors.New("ethernet frame exceeds negotiated NTB")
	}
	b := make([]byte, end)
	copy(b, "NCMH")
	usbLE.PutUint16(b[4:], 12)
	usbLE.PutUint16(b[6:], seq)
	usbLE.PutUint16(b[8:], uint16(end))
	usbLE.PutUint16(b[10:], uint16(ndp))
	copy(b[ndp:], "NCM0")
	usbLE.PutUint16(b[ndp+4:], 16)
	usbLE.PutUint16(b[ndp+8:], uint16(start))
	usbLE.PutUint16(b[ndp+10:], uint16(len(frame)))
	copy(b[start:], frame)
	return b, nil
}

// decodeNTB16 returns the Ethernet frames of one received NTB16. The frames
// alias b. Every signature, length and range is checked before use.
func decodeNTB16(b []byte) ([][]byte, error) {
	n := len(b)
	if n < 12 || string(b[:4]) != "NCMH" || usbLE.Uint16(b[4:]) != 12 {
		return nil, fmt.Errorf("invalid NTB16 header length=%d sig=%x", n, b[:min(n, 4)])
	}
	block := int(usbLE.Uint16(b[8:]))
	if block > n || block < 12 {
		return nil, fmt.Errorf("invalid NTB size %d/%d", block, n)
	}
	var frames [][]byte
	seen := map[int]bool{}
	for ndp := int(usbLE.Uint16(b[10:])); ndp != 0; {
		if seen[ndp] || ndp < 12 || ndp+8 > block || string(b[ndp:ndp+4]) != "NCM0" {
			return nil, errors.New("invalid NTB16 NDP")
		}
		seen[ndp] = true
		l := int(usbLE.Uint16(b[ndp+4:]))
		if l < 12 || l%4 != 0 || ndp+l > block {
			return nil, errors.New("invalid NDP length")
		}
		terminated := false
		for p := ndp + 8; p+4 <= ndp+l; p += 4 {
			off := int(usbLE.Uint16(b[p:]))
			size := int(usbLE.Uint16(b[p+2:]))
			if off == 0 && size == 0 {
				terminated = true
				break
			}
			if off < 12 || size < 14 || off+size > block {
				return nil, errors.New("invalid Ethernet datagram range")
			}
			frames = append(frames, b[off:off+size:off+size])
		}
		if !terminated {
			return nil, errors.New("unterminated NDP")
		}
		ndp = int(usbLE.Uint16(b[ndp+6:]))
	}
	return frames, nil
}
