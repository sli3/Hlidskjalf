# Hlidskjalf
A self-logging, automated Bash script designed to aggressively reclaim disk space and maintain system hygiene on Linux hosts (VMs, Servers, etc.). Named after Odin's high seat, Hlidskjalf meticulously sweeps every corner of your system to eliminate clutter.

Key Features:

🧹 Docker Cleanup: Prunes unused images, volumes, networks, and build cache (docker system prune).

⚙️ System Tidy-up: Vacuums old journalctl logs (by size and time) and cleans the APT package cache.

🔒 Safety: Includes a --dry-run option to simulate cleanup actions before execution.

📄 Auditability: Writes a detailed log of all actions, errors, and status updates to a dedicated file (/var/log/hlidskjalf.log).

⏱️ Automation Ready: Designed to be deployed as a resilient, no-fuss cron job.

Goal: Turn forgotten maintenance into a reliable, automated system administration workflow.
