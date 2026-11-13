//go:build linux && arm

package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

const (
	tapName    = "sgncm0"
	cablePort  = "5556"
	cableV4    = "192.168.2.249/24"
	cableV6    = "fe80::c7ad:b"
	usbDevices = "/sys/bus/usb/devices"
	// The NCM function of a Mac: control interface 0, data interface 1,
	// bulk IN 0x81 and bulk OUT 0x01. openUSB verifies this in the descriptors.
	ncmControl = 0
	ncmBulkIn  = 0x81
	ncmBulkOut = 0x01
)

var (
	errServiceStopped = errors.New("service stopped")
	usbDeviceName     = regexp.MustCompile(`^[0-9]+-[0-9]+(\.[0-9]+)*$`)
)

// findMac returns the sysfs directory of the first attached Mac, on any port.
func findMac() (string, bool) {
	entries, err := os.ReadDir(usbDevices)
	if err != nil {
		return "", false
	}
	var names []string
	for _, entry := range entries {
		if usbDeviceName.MatchString(entry.Name()) {
			names = append(names, entry.Name())
		}
	}
	sort.Strings(names)
	for _, name := range names {
		dir := filepath.Join(usbDevices, name)
		if _, err := usbPath(dir); err == nil {
			return dir, true
		}
	}
	return "", false
}

// usbPath maps a sysfs device directory to its usbfs node, only for the Mac's IDs.
func usbPath(dir string) (string, error) {
	if filepath.Dir(dir) != usbDevices || !usbDeviceName.MatchString(filepath.Base(dir)) {
		return "", fmt.Errorf("invalid USB sysfs device path")
	}
	read := func(name string) (string, error) {
		b, e := os.ReadFile(filepath.Join(dir, name))
		return strings.TrimSpace(string(b)), e
	}
	for _, id := range []struct {
		key   string
		value uint16
	}{{"idVendor", appleVendor}, {"idProduct", appleProduct}} {
		v, e := read(id.key)
		if e != nil {
			return "", e
		}
		if n, e := strconv.ParseUint(v, 16, 16); e != nil || uint16(n) != id.value {
			return "", fmt.Errorf("%s is %s, not a Mac", id.key, v)
		}
	}
	var nums [2]int
	for i, name := range []string{"busnum", "devnum"} {
		v, e := read(name)
		if e != nil {
			return "", e
		}
		n, e := strconv.Atoi(v)
		if e != nil || n < 1 || n > 255 {
			return "", fmt.Errorf("invalid %s", name)
		}
		nums[i] = n
	}
	return fmt.Sprintf("/dev/bus/usb/%03d/%03d", nums[0], nums[1]), nil
}

func verifyPrivileges() error {
	b, err := os.ReadFile(fmt.Sprintf("/proc/%d/status", os.Getpid()))
	if err != nil {
		return err
	}
	uidOK, capOK := false, false
	for _, line := range strings.Split(string(b), "\n") {
		f := strings.Fields(line)
		if len(f) == 5 && f[0] == "Uid:" {
			uidOK = f[1] == "0" && f[2] == "0" && f[3] == "0" && f[4] == "0"
		}
		if len(f) == 2 && f[0] == "CapEff:" {
			caps, err := strconv.ParseUint(f[1], 16, 64)
			capOK = err == nil && caps&(1<<12) != 0
		}
	}
	if !uidOK || !capOK {
		return fmt.Errorf("requires four zero process UIDs and effective CAP_NET_ADMIN")
	}
	return nil
}

type cableADB struct {
	cmd    *exec.Cmd
	exited chan error
}

func (a *cableADB) stop() {
	// cmd.Wait may already have returned. Kill never targets a recycled PID
	// while os.Process is still representing a running child.
	_ = a.cmd.Process.Kill()
	<-a.exited
}

// runnable copies the packaged adbd into the working directory (the module's
// private state directory) with execute permission: the package extractor
// writes payload files without it. The copy is refreshed only when it differs.
func runnable(payload string) (string, error) {
	want, err := os.ReadFile(payload)
	if err != nil {
		return "", err
	}
	dir, err := os.Getwd()
	if err != nil {
		return "", err
	}
	target := filepath.Join(dir, "cable-adbd.run")
	if have, err := os.ReadFile(target); err == nil && bytes.Equal(have, want) {
		if err := os.Chmod(target, 0o700); err != nil {
			return "", err
		}
		return target, nil
	}
	temp := target + ".new"
	if err := os.WriteFile(temp, want, 0o700); err != nil {
		return "", err
	}
	if err := os.Chmod(temp, 0o700); err != nil {
		return "", err
	}
	if err := os.Rename(temp, target); err != nil {
		return "", err
	}
	return target, nil
}

// startCableADB opens the only ADB listener, bound to the TAP, and hands it to
// the cable adbd as file descriptor 3. The adbd starts as root, reads the key
// file once, then always becomes the shell user before it accepts a connection.
func startCableADB(ipv6 bool, adbd, keys string) (*cableADB, error) {
	program, err := runnable(adbd)
	if err != nil {
		return nil, fmt.Errorf("prepare adbd: %w", err)
	}
	cfg := net.ListenConfig{Control: func(network, address string, raw syscall.RawConn) error {
		var bindErr error
		if err := raw.Control(func(fd uintptr) {
			bindErr = syscall.SetsockoptString(int(fd), syscall.SOL_SOCKET, syscall.SO_BINDTODEVICE, tapName)
		}); err != nil {
			return err
		}
		return bindErr
	}}
	v4, _, _ := net.ParseCIDR(cableV4)
	family, addr := "tcp4", v4.String()+":"+cablePort
	if ipv6 {
		family, addr = "tcp", "[::]:"+cablePort
	}
	listener, err := cfg.Listen(context.Background(), family, addr)
	if err != nil {
		return nil, err
	}
	defer listener.Close()
	sock, err := listener.(*net.TCPListener).File()
	if err != nil {
		return nil, err
	}
	defer sock.Close()
	if err := syscall.SetNonblock(int(sock.Fd()), false); err != nil {
		return nil, err
	}
	cmd := exec.Command(program, keys)
	cmd.ExtraFiles = []*os.File{sock}
	cmd.Stdout, cmd.Stderr = os.Stdout, os.Stderr
	cmd.Dir = "/"
	cmd.SysProcAttr = &syscall.SysProcAttr{Pdeathsig: syscall.SIGKILL}
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	a := &cableADB{cmd: cmd, exited: make(chan error, 1)}
	go func() { a.exited <- cmd.Wait(); close(a.exited) }()
	return a, nil
}

// serveLink bridges one attached Mac to the TAP until the cable is removed,
// the adbd exits or the service is stopped.
func serveLink(sysfs string, ip net.IP, network *net.IPNet, adbd, keys string, stop <-chan os.Signal) error {
	path, err := usbPath(sysfs)
	if err != nil {
		return err
	}
	tap, err := openTap()
	if err != nil {
		return err
	}
	defer tap.Close()
	usb, err := openUSB(path, ncmControl, ncmBulkIn, ncmBulkOut)
	if err != nil {
		return err
	}
	defer usb.Close()
	mac := usb.descriptorMAC
	if !validUnicastMAC(mac) {
		mac = net.HardwareAddr{0x02, 0x48, 0x53, 0x47, 0x00, 0x02}
	}
	if err := configureTap(ip, network.Mask, mac); err != nil {
		return err
	}
	v6err := addCableIPv6()
	if v6err != nil && ip == nil {
		return v6err
	}
	// Linux ties the child death signal to its creating thread.
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	child, err := startCableADB(v6err == nil, adbd, keys)
	if err != nil {
		return err
	}
	defer child.stop()
	fmt.Printf("READY %s %v\n", tapName, ip)
	done := make(chan error, 2)
	var toUSB, fromUSB atomic.Uint64
	tapFD := int(tap.Fd())
	if err := syscall.SetNonblock(tapFD, true); err != nil {
		return err
	}
	var stopping atomic.Bool
	var workers sync.WaitGroup
	workers.Add(2)
	defer func() {
		stopping.Store(true)
		// TAP syscalls are nonblocking and USB requests time out in 600 ms.
		// Leave both descriptors open until all workers have stopped.
		workers.Wait()
		fmt.Printf("STOP tx_frames=%d rx_frames=%d\n", toUSB.Load(), fromUSB.Load())
	}()
	go func() {
		defer workers.Done()
		buf := make([]byte, 65536)
		for !stopping.Load() {
			n, err := syscall.Read(tapFD, buf)
			if errors.Is(err, syscall.EAGAIN) || errors.Is(err, syscall.EINTR) {
				time.Sleep(5 * time.Millisecond)
				continue
			}
			if err != nil {
				done <- fmt.Errorf("TAP read: %w", err)
				return
			}
			if err := usb.WriteFrame(buf[:n]); err != nil {
				done <- fmt.Errorf("USB write: %w", err)
				return
			}
			toUSB.Add(1)
		}
	}()
	go func() {
		defer workers.Done()
		for !stopping.Load() {
			b, err := usb.ReadFrame()
			if err != nil {
				if errors.Is(err, syscall.ETIMEDOUT) || errors.Is(err, syscall.EAGAIN) || errors.Is(err, syscall.EINTR) {
					continue
				}
				done <- fmt.Errorf("USB read: %w", err)
				return
			}
			if len(b) == 0 {
				continue
			}
			n, err := syscall.Write(tapFD, b)
			if err != nil || n != len(b) {
				if err == nil {
					err = io.ErrShortWrite
				}
				done <- fmt.Errorf("TAP write: %w", err)
				return
			}
			fromUSB.Add(1)
		}
	}()
	// USB removal terminates the bulk read. Poll only to catch a controller
	// that continues returning ETIMEDOUT after unplug.
	tick := time.NewTicker(3 * time.Second)
	defer tick.Stop()
	for {
		select {
		case err := <-done:
			return err
		case <-stop:
			return errServiceStopped
		case err := <-child.exited:
			return fmt.Errorf("cable adbd exited: %v", err)
		case <-tick.C:
			current, err := usbPath(sysfs)
			if err != nil || current != path {
				return fmt.Errorf("USB detached")
			}
		}
	}
}

// runService waits for a key and a Mac, serves the link, and starts over when
// it closes. It prints a line only when the state changes.
func runService(adbd, keys string) error {
	if err := verifyPrivileges(); err != nil {
		return err
	}
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGTERM, syscall.SIGINT, syscall.SIGHUP)
	defer signal.Stop(stop)
	ip, network, err := net.ParseCIDR(cableV4)
	if err != nil {
		return err
	}
	last := ""
	for {
		state := "waiting for a Mac"
		if n, err := countKeys(keys); err != nil || n == 0 {
			state = "waiting for an ADB key"
		} else if sysfs, found := findMac(); found {
			localIP := ip
			err = verifyNetwork(network)
			if errors.Is(err, errOverlap) {
				localIP = nil
				err = nil
			}
			if err == nil {
				err = serveLink(sysfs, localIP, network, adbd, keys, stop)
			}
			if errors.Is(err, errServiceStopped) {
				return nil
			}
			state = fmt.Sprintf("link closed: %v", err)
		}
		if state != last {
			fmt.Println(state)
			last = state
		}
		select {
		case <-stop:
			return nil
		case <-time.After(2 * time.Second):
		}
	}
}
