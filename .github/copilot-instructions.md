# Proxmox-Hetzner Installer AI Instructions

## Project Overview
This repository contains `install-proxmox.sh`, a monolithic Bash script designed to automate the installation of Proxmox VE on dedicated servers (primarily Hetzner and OVH) running in a Linux Rescue system. It utilizes QEMU to boot the Proxmox ISO and performs post-installation configuration via a plugin system.

## Architectural Patterns

### 1. Monolithic Script Structure
*   **Central logic:** All major logic resides in `install-proxmox.sh`.
*   **Global State:** rely on global variables for configuration (e.g., `pve_fqdn`, `skip_installer`) and runtime discovery (e.g., `WAN_IFACE`).
*   **Entry Point:** The script executes sequentially: Option Parsing -> Pre-checks -> QEMU/Install -> Plugin Execution.

### 2. Plugin System
Functionality is modularized into "plugins". To add a new feature:

1.  **Define the function:** Create a bash function (e.g., `my_new_feature()`).
2.  **Register Description:** Add a case to `describe_plugin()`:
    ```bash
    "my_new_feature")
        echo "[Optional]" # or [Default]
        echo "Description of what it does"
        echo "    --my-arg VALUE    Description of required arg"
        ;;
    ```
3.  **Register Execution:** Add a case to `run_plugin()` calls your function.
4.  **Add to List:** Add the name to `plugin_list` variable (if default) or rely on `--disable`/logic to manage it.

### 3. External Dependencies
*   **Templates:** The script downloads auxiliary files (like network templates) directly from the GitHub `main` branch using `curl`.
    *   *Warning:* Local changes to `files/` are ignored by the script unless the `curl` command in `install-proxmox.sh` is modified to point to a local path or a different URL.

## Developer Workflows

*   **Testing:** Code is typically tested on live Hetzner Rescue Systems or local VMs simulating that environment.
*   **Debugging:** use `--verbose` flag to enable verbose logging (`verbose=true`).
*   **Argument Parsing:** Manual `while` loop with `case` statements handles arguments. When adding flags, ensure you `shift` correctly for values.

## Coding Conventions

*   **Shell:** Bash.
*   **Output:** Use defined color variables (`${CLR_RED}`, `${CLR_GREEN}`, etc.) for user feedback.
*   **Naming:** Snake_case for functions and variables (e.g., `setup_private_subnet`).
*   **Error Handling:** Check for command success, especially network/SSH operations.
*   **Compatibility:** Ensure commands are compatible with minimal Debian/Rescue environments.

## Integration Points
*   **Hetzner Network:** Specific logic handles Hetzner's bridge setup and single public IP requirements.
*   **QEMU:** Wraps the Proxmox installation ISO. Logic handles VNC tunneling and automated unattended installs (Proxmox 9+).
