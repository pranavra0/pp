package main

import (
	"crypto/rand"
	"fmt"
	"net"
	"os"
	"os/exec"
	"syscall"
	"time"
)

func child() {
	fmt.Println("child-ok")
}

func report() {
	_, filesystem := os.ReadFile("/etc/passwd")
	fmt.Printf("filesystem-denied=%t\n", filesystem != nil)
	fmt.Printf("environment-cleared=%t\n",
		os.Getenv("HOME") == "" && os.Getenv("PATH") == "")
	fmt.Printf("environment-explicit=%s\n", os.Getenv("EXPLICIT"))

	connection, network := net.DialTimeout("tcp", "1.1.1.1:53", time.Second)
	if connection != nil {
		connection.Close()
	}
	fmt.Printf("network-denied=%t\n", network != nil)

	command := exec.Command("/tool", "child")
	command.Stdin = os.Stdin
	command.Stdout = os.Stdout
	command.Stderr = os.Stderr
	fmt.Printf("subprocess-confined=%t\n", command.Run() == nil)

	script := "/out/script"
	_ = os.WriteFile(script, []byte("#!/bin/sh\nexit 0\n"), 0700)
	loader := exec.Command(script)
	loader.Stdin = os.Stdin
	loader.Stdout = os.Stdout
	loader.Stderr = os.Stderr
	fmt.Printf("loader-denied=%t\n", loader.Run() != nil)

	var random [8]byte
	_, randomError := rand.Read(random[:])
	fmt.Printf("randomness-available=%t\n", randomError == nil)
	fmt.Printf("clock-available=%t\n", time.Now().UnixNano() != 0)
	_ = os.WriteFile("/out/result", []byte("closed\n"), 0600)
}

func escape() {
	_ = os.Symlink("/in/input", "/out/escape")
}

func copyInput() {
	content, err := os.ReadFile("/in/input")
	if err != nil {
		os.Exit(2)
	}
	if os.WriteFile("/out/result", content, 0640) != nil {
		os.Exit(3)
	}
}

func main() {
	switch os.Args[1] {
	case "child":
		child()
	case "report":
		report()
	case "escape":
		escape()
	case "copy":
		copyInput()
	case "signal":
		_ = syscall.Kill(syscall.Getpid(), syscall.SIGTERM)
	}
}
