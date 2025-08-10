# Smart-Chkdsk

**Smart-Chkdsk** is a PowerShell script for intelligent, automated disk error detection and repair scheduling on Windows systems.

## Features

- Scans all local fixed drives for errors.
- Schedules repairs based on drive type:
  - **System and pagefile drives:** Repair scheduled at next restart (with notification).
  - **Data drives:** Repair scheduled during system idle time using self-removing scheduled tasks.
- Minimizes user intervention with non-interactive operation.
- Provides a clear summary and guidance after execution.

## Requirements

- Windows OS
- PowerShell
- Administrator privileges

## Usage

Run `Smart-Chkdsk.ps1` as Administrator / Schedualed Task

## Notes

- Idle-time repairs require the system to be idle for at least 10 minutes.
- All actions and results are displayed in the terminal and via notifications.
- Not for mission critical environments where dismounting could cause data loss.

---

Intelligent automated disk error detection and repair scheduling.
