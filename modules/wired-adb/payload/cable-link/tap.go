//go:build linux && arm

// The cable network lives on a private, non-persistent TAP device. Its address
// disappears with the device when the link closes; no address, route or
// property is written on any other interface.
package main

import (
	"encoding/binary"
	"errors"
	"fmt"
	"net"
	"os"
	"strconv"
	"strings"
	"syscall"
	"unsafe"
)

type ifreq struct {
	Name  [16]byte
	Value [24]byte
}

func ioctl(fd uintptr, request uintptr, arg *ifreq) error {
	_, _, err := syscall.Syscall(syscall.SYS_IOCTL, fd, request, uintptr(unsafe.Pointer(arg)))
	if err != 0 {
		return err
	}
	return nil
}

func newReq() ifreq {
	var req ifreq
	copy(req.Name[:], tapName)
	return req
}

func openTap() (*os.File, error) {
	for _, path := range []string{"/dev/net/tun", "/dev/tun"} {
		tap, err := os.OpenFile(path, os.O_RDWR|syscall.O_NONBLOCK, 0)
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return nil, err
		}
		req := newReq()
		// IFF_TAP | IFF_NO_PI | IFF_TUN_EXCL. Refuse attachment to an
		// existing device even if another process creates it during preflight.
		binary.LittleEndian.PutUint16(req.Value[:], 0x0002|0x1000|0x8000)
		if err := ioctl(tap.Fd(), 0x400454ca, &req); err != nil {
			tap.Close()
			return nil, fmt.Errorf("TUNSETIFF %s: %w", path, err)
		}
		return tap, nil
	}
	return nil, fmt.Errorf("both /dev/net/tun and /dev/tun absent")
}

func configureTap(ip net.IP, mask net.IPMask, mac net.HardwareAddr) error {
	s, err := syscall.Socket(syscall.AF_INET, syscall.SOCK_DGRAM|syscall.SOCK_CLOEXEC, 0)
	if err != nil {
		return err
	}
	defer syscall.Close(s)
	req := newReq()
	binary.LittleEndian.PutUint16(req.Value[:], 1) // ARPHRD_ETHER
	copy(req.Value[2:], mac)
	if err := ioctl(uintptr(s), syscall.SIOCSIFHWADDR, &req); err != nil {
		return fmt.Errorf("TAP MAC: %w", err)
	}
	var addresses [][]byte
	if ip != nil {
		addresses = [][]byte{ip.To4(), []byte(mask)}
	}
	for i, addr := range addresses {
		req = newReq()
		binary.LittleEndian.PutUint16(req.Value[:], syscall.AF_INET)
		copy(req.Value[4:8], addr)
		op := uintptr(syscall.SIOCSIFADDR)
		if i == 1 {
			op = syscall.SIOCSIFNETMASK
		}
		if err := ioctl(uintptr(s), op, &req); err != nil {
			return fmt.Errorf("TAP IPv4 ioctl 0x%x: %w", op, err)
		}
	}
	req = newReq()
	if err := ioctl(uintptr(s), syscall.SIOCGIFFLAGS, &req); err != nil {
		return err
	}
	flags := binary.LittleEndian.Uint16(req.Value[:])
	binary.LittleEndian.PutUint16(req.Value[:], flags|syscall.IFF_UP)
	return ioctl(uintptr(s), syscall.SIOCSIFFLAGS, &req)
}

// addCableIPv6 gives the TAP a fixed link-local address. It stays usable when
// Internet Sharing on the Mac uses another IPv4 subnet.
func addCableIPv6() error {
	nic, err := net.InterfaceByName(tapName)
	if err != nil {
		return err
	}
	fd, err := syscall.Socket(syscall.AF_INET6, syscall.SOCK_DGRAM|syscall.SOCK_CLOEXEC, 0)
	if err != nil {
		return err
	}
	defer syscall.Close(fd)
	req := struct {
		Address [16]byte
		Prefix  uint32
		Index   int32
	}{Prefix: 64, Index: int32(nic.Index)}
	copy(req.Address[:], net.ParseIP(cableV6).To16())
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, uintptr(fd), syscall.SIOCSIFADDR, uintptr(unsafe.Pointer(&req)))
	if errno != 0 && errno != syscall.EEXIST {
		return errno
	}
	return nil
}

var errOverlap = errors.New("cable subnet overlaps existing route")

// verifyNetwork refuses a stale TAP and reports errOverlap when another
// interface already routes the cable subnet (the link then runs on IPv6 only).
func verifyNetwork(network *net.IPNet) error {
	if _, err := os.Stat("/sys/class/net/" + tapName); err == nil || !os.IsNotExist(err) {
		return fmt.Errorf("TAP exists or cannot be checked")
	}
	routes, err := os.ReadFile("/proc/net/route")
	if err != nil {
		return err
	}
	target := binary.LittleEndian.Uint32(network.IP.To4())
	for _, row := range strings.Split(string(routes), "\n") {
		cols := strings.Fields(row)
		if len(cols) == 0 || cols[0] == "Iface" {
			continue
		}
		if len(cols) < 8 {
			return fmt.Errorf("malformed route")
		}
		dest, e1 := strconv.ParseUint(cols[1], 16, 32)
		mask, e2 := strconv.ParseUint(cols[7], 16, 32)
		if e1 != nil || e2 != nil {
			return fmt.Errorf("invalid route")
		}
		if mask == 0 {
			continue // Default traffic continues on its existing link.
		}
		// The cable network is a /24: compare its three network bytes under the route's mask.
		if (target & uint32(mask) & 0x00ffffff) == (uint32(dest) & uint32(mask) & 0x00ffffff) {
			return fmt.Errorf("%w: %s on %s", errOverlap, network, cols[0])
		}
	}
	return nil
}

func validUnicastMAC(mac net.HardwareAddr) bool {
	return len(mac) == 6 && mac[0]&1 == 0 && mac.String() != "00:00:00:00:00:00"
}
