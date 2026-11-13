//go:build linux && arm

// Apple USB NCM over usbfs. The head-unit kernels do not all carry cdc_ncm, and
// none binds it to a Mac, so the control requests and bulk transfers are made
// from user space on the claimed interfaces only.
package main

import (
	"encoding/hex"
	"errors"
	"fmt"
	"net"
	"os"
	"runtime"
	"syscall"
	"unsafe"
)

// A Mac attached to a USB host port presents this device (Apple, NCM networking).
const (
	appleVendor  = 0x05ac
	appleProduct = 0x1905
)

// USBDEVFS requests below have the ARM EABI pointer/size layout.
const (
	usbfsCtrl    = 0xc0105500
	usbfsBulk    = 0xc0105502
	usbfsAlt     = 0x80085504
	usbfsClaim   = 0x8004550f
	usbfsRelease = 0x80045510
)

type usbCtrl struct {
	Type, Request        uint8
	Value, Index, Length uint16
	Timeout              uint32
	Data                 unsafe.Pointer
}
type usbBulk struct {
	Endpoint, Length, Timeout uint32
	Data                      unsafe.Pointer
}
type ncmUSB struct {
	f                                *os.File
	ctrl, data                       uint32
	inEP, outEP                      byte
	ctrlClaim, dataClaim, changedAlt bool
	savedAlt                         uint32
	inMax                            int
	layout                           ntbLayout
	descriptorMAC                    net.HardwareAddr
	seq                              uint16
	pending                          [][]byte
}

func usbCall(f *os.File, request uintptr, data unsafe.Pointer) (int, error) {
	var n uintptr
	var errno syscall.Errno
	for {
		n, _, errno = syscall.Syscall(syscall.SYS_IOCTL, f.Fd(), request, uintptr(data))
		if errno != syscall.EINTR {
			break
		}
	}
	runtime.KeepAlive(f)
	runtime.KeepAlive(data)
	if errno != 0 {
		return 0, errno
	}
	return int(n), nil
}

func (u *ncmUSB) control(typ, req byte, val, idx uint16, buf []byte) (int, error) {
	t := usbCtrl{Type: typ, Request: req, Value: val, Index: idx, Length: uint16(len(buf)), Timeout: 1000}
	if len(buf) > 0 {
		t.Data = unsafe.Pointer(&buf[0])
	}
	n, err := usbCall(u.f, usbfsCtrl, unsafe.Pointer(&t))
	runtime.KeepAlive(buf)
	return n, err
}

func (u *ncmUSB) bulk(ep byte, buf []byte) (int, error) {
	t := usbBulk{Endpoint: uint32(ep), Length: uint32(len(buf)), Timeout: 600, Data: unsafe.Pointer(&buf[0])}
	n, err := usbCall(u.f, usbfsBulk, unsafe.Pointer(&t))
	runtime.KeepAlive(buf)
	return n, err
}

func (u *ncmUSB) alt(n uint32) error {
	args := [2]uint32{u.data, n}
	_, err := usbCall(u.f, usbfsAlt, unsafe.Pointer(&args))
	return err
}

// verifyEndpoints reads the device and active configuration descriptors and
// accepts only the expected Apple device with a CDC NCM control/data pair on the
// selected interfaces and endpoints.
func (u *ncmUSB) verifyEndpoints() error {
	d := make([]byte, 18)
	n, e := u.control(0x80, 6, 0x100, 0, d)
	if e != nil {
		return fmt.Errorf("read Apple device ID: %w", e)
	}
	if n != 18 || d[1] != 1 || usbLE.Uint16(d[8:]) != appleVendor || usbLE.Uint16(d[10:]) != appleProduct {
		return errors.New("expected Apple 05ac:1905")
	}
	var cfg [1]byte
	n, e = u.control(0x80, 8, 0, 0, cfg[:])
	if e != nil || n != 1 || cfg[0] == 0 {
		return fmt.Errorf("no active Apple USB configuration (n=%d, err=%v)", n, e)
	}
	for i := uint16(0); i < uint16(d[17]); i++ {
		h := make([]byte, 9)
		n, e = u.control(0x80, 6, 0x200+i, 0, h)
		if e != nil || n != 9 || h[1] != 2 || h[5] != cfg[0] {
			continue
		}
		size := int(usbLE.Uint16(h[2:]))
		if size < 9 || size > 4096 {
			return errors.New("invalid Apple configuration length")
		}
		raw := make([]byte, size)
		n, e = u.control(0x80, 6, 0x200+i, 0, raw)
		if e != nil || n != size {
			return fmt.Errorf("read configuration failed (n=%d err=%v)", n, e)
		}
		var ctl, data, matchedCtl, union, in, out bool
		var macIndex byte
		for pos := 0; pos < len(raw); {
			if pos+2 > len(raw) {
				return errors.New("short USB descriptor")
			}
			length := int(raw[pos])
			if length < 2 || pos+length > len(raw) {
				return errors.New("invalid USB descriptor")
			}
			field := raw[pos : pos+length]
			pos += length
			switch field[1] {
			case 4:
				if len(field) < 9 {
					return errors.New("short interface descriptor")
				}
				ctl = uint32(field[2]) == u.ctrl && field[3] == 0 && field[5] == 2 && field[6] == 13 && field[7] == 0
				data = uint32(field[2]) == u.data && field[3] == 1 && field[5] == 10
				matchedCtl = matchedCtl || ctl
			case 0x24:
				if ctl && len(field) >= 13 && field[2] == 0x0f {
					macIndex = field[3]
				}
				if ctl && len(field) >= 5 && field[2] == 6 && uint32(field[3]) == u.ctrl && uint32(field[4]) == u.data {
					union = true
				}
			case 5:
				if data && len(field) >= 7 && field[3]&3 == 2 {
					if field[2] == u.inEP {
						in = true
					}
					if field[2] == u.outEP {
						out = true
						u.layout.packet = int(usbLE.Uint16(field[4:]) & 0x7ff)
					}
				}
			}
		}
		if matchedCtl && union && in && out && u.layout.packet >= 8 {
			u.descriptorMAC = u.readDescriptorMAC(macIndex)
			if u.descriptorMAC != nil {
				fmt.Fprintf(os.Stderr, "Apple NCM descriptor iMACAddress %s (string %d)\n", u.descriptorMAC, macIndex)
			}
			return nil
		}
		break
	}
	return errors.New("selected Apple CDC control/data pair or endpoints did not match")
}

func (u *ncmUSB) readDescriptorMAC(i byte) net.HardwareAddr {
	if i == 0 {
		return nil
	}
	lang := make([]byte, 255)
	n, err := u.control(0x80, 6, 0x300, 0, lang)
	if err != nil || n < 4 || lang[1] != 3 {
		return nil
	}
	raw := make([]byte, 255)
	n, err = u.control(0x80, 6, 0x300|uint16(i), usbLE.Uint16(lang[2:]), raw)
	if err != nil || n < 26 || raw[1] != 3 || raw[0] != 26 {
		return nil
	}
	digits := make([]byte, 12)
	for j := range digits {
		if raw[3+2*j] != 0 {
			return nil
		}
		digits[j] = raw[2+2*j]
	}
	mac := make(net.HardwareAddr, 6)
	if _, e := hex.Decode(mac, digits); e != nil || !validUnicastMAC(mac) {
		return nil
	}
	return mac
}

func openUSB(path string, ctrl int, inEP, outEP byte) (*ncmUSB, error) {
	if (ctrl != 0 && ctrl != 2) || inEP&0x80 == 0 || outEP&0x80 != 0 {
		return nil, errors.New("invalid NCM endpoint selection")
	}
	f, err := os.OpenFile(path, os.O_RDWR, 0)
	if err != nil {
		return nil, err
	}
	u := &ncmUSB{f: f, ctrl: uint32(ctrl), data: uint32(ctrl + 1), inEP: inEP, outEP: outEP}
	success := false
	defer func() {
		if !success {
			u.Close()
		}
	}()
	if err = u.verifyEndpoints(); err != nil {
		return nil, err
	}
	if _, err = usbCall(f, usbfsClaim, unsafe.Pointer(&u.ctrl)); err != nil {
		return nil, fmt.Errorf("claim control: %w", err)
	}
	u.ctrlClaim = true
	if _, err = usbCall(f, usbfsClaim, unsafe.Pointer(&u.data)); err != nil {
		return nil, fmt.Errorf("claim data: %w", err)
	}
	u.dataClaim = true
	var saved [1]byte
	n, e := u.control(0x81, 10, 0, uint16(u.data), saved[:])
	if e != nil || n != 1 {
		return nil, fmt.Errorf("GET_INTERFACE: n=%d err=%v", n, e)
	}
	u.savedAlt = uint32(saved[0])
	if u.savedAlt != 0 {
		return nil, fmt.Errorf("selected data interface already active (alt=%d)", u.savedAlt)
	}
	params := make([]byte, 28)
	n, e = u.control(0xa1, 0x80, 0, uint16(ctrl), params)
	if e != nil || n < 26 || int(usbLE.Uint16(params)) > n || int(usbLE.Uint16(params)) < 26 {
		return nil, fmt.Errorf("GET_NTB_PARAMETERS: n=%d err=%v", n, e)
	}
	formats := usbLE.Uint16(params[2:])
	if formats&1 == 0 {
		return nil, errors.New("NTB16 unsupported")
	}
	// NCM starts in NTB16 mode. Request that format explicitly while data is
	// at alt zero. As in Linux 3.18 cdc_ncm_init, devices may stall the
	// optional format setter. ReadFrame still verifies every NTB signature.
	if formats&2 != 0 {
		_, e = u.control(0x21, 0x84, 0, uint16(ctrl), nil)
		if e != nil && e != syscall.EPIPE {
			return nil, fmt.Errorf("SET_NTB_FORMAT(16): %w", e)
		}
		if e != nil {
			fmt.Fprintln(os.Stderr, "Apple NCM SET_NTB_FORMAT stalled; using default NTB16, verifying received signature")
		}
	}
	maxIn := usbLE.Uint32(params[4:])
	maxOut := usbLE.Uint32(params[16:])
	if maxIn < 2048 || maxOut < 2048 {
		return nil, fmt.Errorf("invalid NTB sizes in/out=%d/%d", maxIn, maxOut)
	}
	// Ask for the 16 KiB default only when the peer advertises more.
	// On stall, leave the peer's value intact and use the larger RX buffer.
	u.inMax = int(min(maxIn, 65535))
	if maxIn > 16384 {
		var inputSize [4]byte
		usbLE.PutUint32(inputSize[:], 16384)
		n, e = u.control(0x21, 0x86, 0, uint16(ctrl), inputSize[:])
		if e == nil && n == 4 {
			u.inMax = 16384
		} else if e != syscall.EPIPE {
			return nil, fmt.Errorf("SET_NTB_INPUT_SIZE: n=%d err=%v", n, e)
		}
	}
	u.layout.outMax = int(min(maxOut, 65535))
	u.layout.divisor = int(usbLE.Uint16(params[20:]))
	u.layout.remainder = int(usbLE.Uint16(params[22:]))
	u.layout.alignment = int(usbLE.Uint16(params[24:]))
	if !u.layout.valid() {
		return nil, fmt.Errorf("invalid NTB layout %+v", u.layout)
	}
	if err = u.alt(1); err != nil {
		return nil, fmt.Errorf("set data alt 1: %w", err)
	}
	u.changedAlt = true
	// Standard directed, broadcast and multicast ingress. Some NCM functions
	// have a fixed filter and stall the optional class request.
	_, err = u.control(0x21, 0x43, 0x1c, uint16(ctrl), nil)
	if err != nil && err != syscall.EPIPE {
		return nil, fmt.Errorf("set packet filter: %w", err)
	}
	fmt.Fprintf(os.Stderr, "Apple NCM control=%d data=%d NTB16 max-in=%d layout=%+v\n", ctrl, u.data, u.inMax, u.layout)
	success = true
	return u, nil
}

func (u *ncmUSB) WriteFrame(frame []byte) error {
	b, err := u.layout.encode(u.seq, frame)
	if err != nil {
		return err
	}
	u.seq++
	n, e := u.bulk(u.outEP, b)
	if e != nil {
		return e
	}
	if n != len(b) {
		return fmt.Errorf("short NCM write %d/%d", n, len(b))
	}
	return nil
}

func (u *ncmUSB) ReadFrame() ([]byte, error) {
	if len(u.pending) > 0 {
		f := u.pending[0]
		u.pending = u.pending[1:]
		return f, nil
	}
	b := make([]byte, u.inMax)
	n, e := u.bulk(u.inEP, b)
	if e != nil {
		return nil, e
	}
	frames, err := decodeNTB16(b[:n])
	if err != nil {
		return nil, err
	}
	if len(frames) == 0 {
		return nil, syscall.EAGAIN
	}
	u.pending = frames[1:]
	return frames[0], nil
}

func (u *ncmUSB) Close() {
	if u.f == nil {
		return
	}
	if u.changedAlt {
		u.alt(u.savedAlt)
	}
	if u.dataClaim {
		usbCall(u.f, usbfsRelease, unsafe.Pointer(&u.data))
	}
	if u.ctrlClaim {
		usbCall(u.f, usbfsRelease, unsafe.Pointer(&u.ctrl))
	}
	u.f.Close()
}
