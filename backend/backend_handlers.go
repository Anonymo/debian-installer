package main

import (
	"bytes"
	"log/slog"
	"net/http"
	"os"
	"strconv"
	"strings"
)

func (c *BackendContext) Login(w http.ResponseWriter, _ *http.Request) {
	type login struct {
		Hostname         string            `json:"hostname"`
		HasEfi           bool              `json:"has_efi"`
		HasNvidia        bool              `json:"has_nvidia"`
		HasAMDGPU        bool              `json:"has_amd_gpu"`
		WiFiChipset      string            `json:"wifi_chipset"`
		StorageType      string            `json:"storage_type"`
		TPMVersion       string            `json:"tpm_version"`
		Running          bool              `json:"running"`
		Environ          map[string]string `json:"environ"`
		RamGB            int               `json:"ram_gb"`
		SuggestedSwapGB  int               `json:"suggested_swap_gb"`
	}
	data := login{}
	var err error
	data.Hostname, err = os.Hostname()
	if err != nil {
		slog.Error("failed to detect hostname", "error", err)
		http.Error(w, "failed to detect hostname", http.StatusInternalServerError)
		return
	}
	_, err = os.Stat("/sys/firmware/efi")
	if err == nil {
		data.HasEfi = true
	} else if os.IsNotExist(err) {
		data.HasEfi = false
	} else {
		slog.Error("failed to detect efi", "error", err)
		http.Error(w, "failed to detect efi", http.StatusInternalServerError)
		return
	}
	data.HasNvidia = detectNvidia()
	data.HasAMDGPU = detectAMDGPU()
	data.WiFiChipset = detectWiFiChipset()
	data.StorageType = detectStorageType()
	data.TPMVersion = detectTPMVersion()
	data.Running = c.runningCmd != nil && c.runningCmd.Process != nil
	data.Environ = c.runningParameters
	data.RamGB = detectRAM()
	data.SuggestedSwapGB = calculateSwapSize(data.RamGB)
	err = writeJson(w, data)
	if err != nil {
		slog.Error("failed to write data", "error", err)
		http.Error(w, "failed to write data", http.StatusInternalServerError)
		return
	}
}

func detectNvidia() bool {
	out, err := runAndGiveStdout("nvidia-detect")
	if err != nil {
		slog.Warn("failed to run nvidia-detect, assuming no nvidia", "error", err)
		return false
	}
	outString := string(out)
	if strings.Contains(outString, "No NVIDIA GPU detected") {
		return false
	}
	if strings.Contains(outString, "nvidia-driver") {
		return true
	}
	return false
}

func detectAMDGPU() bool {
	out, err := runAndGiveStdout("lspci")
	if err != nil {
		slog.Warn("failed to run lspci, assuming no AMD GPU", "error", err)
		return false
	}
	outString := string(out)
	return strings.Contains(outString, "AMD") && (strings.Contains(outString, "VGA") || strings.Contains(outString, "Display"))
}

func detectWiFiChipset() string {
	out, err := runAndGiveStdout("lspci")
	if err != nil {
		slog.Warn("failed to run lspci for WiFi detection", "error", err)
		return ""
	}
	outString := string(out)
	
	// Common WiFi chipsets that need firmware
	if strings.Contains(outString, "Broadcom") && strings.Contains(outString, "Wireless") {
		return "broadcom"
	}
	if strings.Contains(outString, "Intel") && strings.Contains(outString, "Wireless") {
		return "intel"
	}
	if strings.Contains(outString, "Realtek") && strings.Contains(outString, "Wireless") {
		return "realtek"
	}
	if strings.Contains(outString, "Atheros") && strings.Contains(outString, "Wireless") {
		return "atheros"
	}
	
	return ""
}

func detectStorageType() string {
	// Check if we have NVMe drives
	if _, err := os.Stat("/dev/nvme0n1"); err == nil {
		return "nvme"
	}
	
	// Check for typical SSD indicators
	out, err := runAndGiveStdout("lsblk", "-d", "-o", "name,rota")
	if err == nil && strings.Contains(string(out), "0") {
		return "ssd"
	}
	
	return "hdd"
}

func detectTPMVersion() string {
	// Check for TPM 2.0
	if _, err := os.Stat("/dev/tpmrm0"); err == nil {
		return "2.0"
	}
	
	// Check for TPM 1.2
	if _, err := os.Stat("/dev/tpm0"); err == nil {
		return "1.2"
	}
	
	return "none"
}

func (c *BackendContext) GetBlockDevices(w http.ResponseWriter, _ *http.Request) {
	out, err := runAndGiveStdout("lsblk", "-OJ")
	if err != nil {
		slog.Error("failed to execute lsblk", "error", err)
		http.Error(w, "failed to execute lsblk", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_, err = w.Write(out)
	if err != nil {
		slog.Error("failed to send output", "error", err)
		return
	}
}

func (c *BackendContext) Install(w http.ResponseWriter, r *http.Request) {
	if c.runningCmd != nil {
		slog.Error("already running")
		http.Error(w, "already running", http.StatusConflict)
		return
	}
	var err error
	contentType := r.Header.Get("Content-Type")
	switch {
	case strings.HasPrefix(contentType, "application/x-www-form-urlencoded"):
		err = r.ParseForm()
	case strings.HasPrefix(contentType, "multipart/form-data"):
		err = r.ParseMultipartForm(1024 * 1024)
	default:
		slog.Error("unknown content type", "content_type", r.Header.Get("Content-Type"))
		http.Error(w, "failed to parse form", http.StatusBadRequest)
		return
	}
	if err != nil {
		slog.Error("failed to parse form", "error", err)
		http.Error(w, "failed to parse form", http.StatusBadRequest)
		return
	}
	slog.Debug("Install button pressed")
	for k, v := range r.Form {
		slog.Debug(" form value", "key", k, "value", v[0])
		c.runningParameters[k] = v[0]
	}
	c.doRunInstall()
}

func (c *BackendContext) ProcessStatus(w http.ResponseWriter, _ *http.Request) {
	type status struct {
		Status     string `json:"status"`
		Output     string `json:"output"`
		ReturnCode int    `json:"return_code"`
		Command    string `json:"command"`
	}
	s := status{
		Status:     "RUNNING",
		Output:     c.cmdOutput.String(),
		ReturnCode: -1,
		Command:    "",
	}
	if c.runningCmd == nil || c.runningCmd.Process == nil {
		http.Error(w, "no running process", http.StatusNotFound)
		return
	}
	if c.runningCmd.ProcessState != nil {
		s.Status = "FINISHED"
		s.ReturnCode = c.runningCmd.ProcessState.ExitCode()
		s.Command = strings.Join(c.runningCmd.Args, " ")
	}

	err := writeJson(w, s)
	if err != nil {
		slog.Error("failed to write data", "error", err)
		http.Error(w, "failed to write data", http.StatusInternalServerError)
		return
	}
}

func (c *BackendContext) DownloadLog(w http.ResponseWriter, _ *http.Request) {
	w.Header().Add("Content-Type", "text/plain;charset=UTF-8")
	w.Header().Add("Content-Disposition", "attachment;filename=installer.log")
	_, err := w.Write(c.cmdOutput.Bytes())
	if err != nil {
		slog.Error("failed to write data", "error", err)
		return
	}
}

func (c *BackendContext) Clear(w http.ResponseWriter, _ *http.Request) {
	if c.runningCmd == nil || c.runningCmd.Process == nil {
		return
	}
	if c.runningCmd.ProcessState != nil {
		// already finished, clear
		c.runningCmd = nil
		c.cmdOutput = bytes.Buffer{}
		return
	}
	err := c.runningCmd.Cancel()
	if err != nil {
		slog.Error("failed to stop the process", "error", err)
		http.Error(w, "failed to stop the process", http.StatusInternalServerError)
	}
}

func detectRAM() int {
	// Read /proc/meminfo to get total memory
	out, err := runAndGiveStdout("grep", "MemTotal", "/proc/meminfo")
	if err != nil {
		slog.Warn("failed to detect RAM, using default", "error", err)
		return 8 // Default to 8GB if detection fails
	}
	
	// Parse output like: "MemTotal:       16384000 kB"
	fields := strings.Fields(string(out))
	if len(fields) < 2 {
		slog.Warn("unexpected meminfo format")
		return 8
	}
	
	memKB, err := strconv.Atoi(fields[1])
	if err != nil {
		slog.Warn("failed to parse memory value", "error", err)
		return 8
	}
	
	// Convert KB to GB (rounded)
	memGB := (memKB + 512*1024) / (1024 * 1024) // Add 512MB for rounding
	return memGB
}

func calculateSwapSize(ramGB int) int {
	// Standard Linux swap recommendations:
	// RAM <= 2GB: swap = 2 * RAM
	// 2GB < RAM <= 8GB: swap = RAM
	// 8GB < RAM <= 64GB: swap = RAM/2, minimum 4GB
	// RAM > 64GB: swap = 4GB (for hibernation support)
	
	switch {
	case ramGB <= 2:
		return ramGB * 2
	case ramGB <= 8:
		return ramGB
	case ramGB <= 64:
		suggested := ramGB / 2
		if suggested < 4 {
			return 4
		}
		return suggested
	default:
		return 4
	}
}
