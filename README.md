# 🏰 Hlidskjalf: Automated System and Docker Maintenance Script

Hlidskjalf.sh is a resilient and self-logging Bash script designed for automated, comprehensive system maintenance on Linux hosts (VMs, Servers, Home Labs, etc.).

Named after Odin's high seat in Norse mythology, from which he can see all realms, Hlidskjalf meticulously sweeps and cleans every corner of the system to reclaim disk space and ensure administrative hygiene.

## ✨ Features

Hlidskjalf.sh provides an automated, "set-it-and-forget-it" solution for common Linux resource bottlenecks, offering the following capabilities:

Comprehensive Docker Prune: Executes a series of commands to clean up all unused Docker artefacts, including:

- Dangling and unused images (docker image prune -a).

- Unused volumes (docker volume prune).

- Unused networks (docker network prune).

- Forgotten build cache (docker builder prune).

System Log Vacuum: Uses journalctl --vacuum to prune old system logs based on configurable limits for size and time (e.g., keeping logs for only the last 7 days or under 50MB).

Package Cache Cleanup: Automatically runs apt autoremove and apt clean to remove unneeded dependencies and stale package files.

Dry-Run Mode: Includes a crucial --dry-run flag to simulate the entire maintenance run without making any changes, ensuring safety during testing.

Self-Logging & Audit Trail: Logs all command output, errors, and status updates directly to a dedicated file (/var/log/hlidskjalf.log) for clear auditability.

## 🛠️ Prerequisites

Hlidskjalf.sh is a native Bash script with minimal requirements, relying on tools already present on most modern Debian/Ubuntu-based distributions.

    Operating System: Any Linux distribution with Bash (v4.x+) and systemd (for journalctl).

    Privileges: The script requires sudo access to perform log vacuuming and APT cache cleanup.

    Docker: Docker must be installed and running if you intend to use the Docker cleanup features.

## 🚀 Installation and Setup

1. Download the Script

Clone the repository or download the script directly:
```
git clone https://github.com/sli3/Hlidskjalf.git
cd Hlidskjalf
```
2. Set Permissions

You must make the script executable before running it:
```
chmod +x hlidskjalf.sh
```
3. Usage (Manual Run)

You can run the script manually to see the output:
```
# Full execution (performs cleanup actions)
sudo ./hlidskjalf.sh

# Safety Check: Run in Dry-Run Mode (recommended first step!)
sudo ./hlidskjalf.sh --dry-run
```

## 🗓️ Automation (Cron Job Setup)

The intended use for Hlidskjalf.sh is via a scheduled cron job. This ensures regular, automatic maintenance.

Open the Cron Editor:
```
sudo crontab -e
```

Add the Job: Add the following line to the end of the file to run the maintenance script every Sunday at 2:00 AM. (Adjust the path and time as needed).

```
# Run Hlidskjalf maintenance every Sunday at 02:00
0 2 * * 0 /path/to/your/hlidskjalf.sh
```
Ensure you use the full, absolute path to the script.

## 📄 Output and Logging

All script activity is logged to /var/log/hlidskjalf.log.

Example Snippet from Log:

```
Thu 26 Oct 2025 02:00:01 AM ACDT
--- Starting Hlidskjalf Maintenance Run ---
--------------------------------------------------------
1. Cleaning up unused Docker resources...
 -> Output for [docker image prune -a -f]:
Total reclaimed space: 1.5GB
...
--------------------------------------------------------
2. Cleaning up old Ubuntu system logs and APT cache...
Running Journalctl vacuum...
Vacuuming done, freed 100M of archived logs on disk.
...
✅ Maintenance complete.
```

## 🚧 Roadmap and Improvements

This script is a living project. Future improvements will focus on enhancing the system administration workflow:

- [ ] Adding options for dynamic exclusion of specific Docker images/volumes.

- [ ] Implementing pre- and post-run disk space reporting.

- [ ] Integrating cleanup for other common sources of clutter (e.g., temporary user files).

## 📜 Disclaimer

This script is provided "as is" for system maintenance and automation. Always test with the --dry-run flag first. The user assumes all responsibility for its execution.

## 🤝 Contributing

Contributions are welcome! If you have suggestions for improvements, bug fixes, or new features, please feel free to open an Issue or a Pull Request.

## ⚖️ Licence

This project is licensed under the MIT Licence - see the LICENCE file for details.
