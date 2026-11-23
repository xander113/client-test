package main

import (
	"bufio"
	"fmt"
	"os"
	"syscall"
	"unsafe"
)

func main() {
	pause := hasPrivateConsole()
	exitCode := runLogged(os.Args[1:], os.Stdout, os.Stderr)
	if pause {
		fmt.Fprint(os.Stderr, "\nPress Enter to close TESTEX...")
		_, _ = bufio.NewReader(os.Stdin).ReadString('\n')
	}
	os.Exit(exitCode)
}

// Explorer gives a console app its own console. An existing shell is also
// counted when TESTEX starts from that shell, so only pause in a private console.
func hasPrivateConsole() bool {
	var mode uint32
	if err := syscall.GetConsoleMode(syscall.Handle(os.Stdin.Fd()), &mode); err != nil {
		return false
	}
	getConsoleProcessList := syscall.NewLazyDLL("kernel32.dll").NewProc("GetConsoleProcessList")
	var processID uint32
	count, _, _ := getConsoleProcessList.Call(uintptr(unsafe.Pointer(&processID)), 1)
	return count == 1
}
