# SteamShut: Advanced Steam Download Watcher

A PowerShell-based automation tool that monitors Steam download queues and safely shuts down your PC only after both the download and the disk installation are verified complete.

---

## 🚀 Features
 
* **Queue-Aware Logic**: Prevents premature shutdowns between queued games by monitoring the `downloading` directory for new activity.

* **2-Factor Verification (2FA)**:

* **Check 1**: Confirms the Steam `downloading` folder is empty.

* **Check 2**: Queries the Steam Store API to verify the common installation folder has reached at least **80%** of the expected size.

* **Smart Confirmation Window**: Waits for 60 seconds after a queue clears to catch delayed Steam operations before initiating shutdown.

* **Real-time Dashboard**: Displays active Game Name, App ID, download speed, ETA, and visual progress bars.

* **Fail-Safe Abort**: If a new download starts during the shutdown countdown, the script automatically intercepts and cancels the shutdown.

---

## 🛠️ Configuration

Before running, you must set your Steam library path:

1. Open `SteamDownloadWatcher.ps1` in a text editor.


2. Update the `$steamLibrary` variable on **Line 1** to match your actual Steam library location:


```powershell
$steamLibrary = 'C:\'

```
---

## 🖥️ Usage

1. **Download**: Get the latest release from the Releases section.

2. **Extract**: Extract the files to a local directory.

3. **Launch**: Right-click `SteamDownloadWatcher.bat` and select **Run as Administrator** (required for the shutdown command).

4. **Monitor**: Leave the console window open; the script will handle the monitoring and shutdown automatically.

---

## 📦 Files

* **`SteamDownloadWatcher.bat`**: Launcher that handles execution policy bypass and sets the correct working directory.
* **`SteamDownloadWatcher.ps1`**: The core logic engine featuring API integration, state management, and folder size tracking.
---

## 🛡️ License

Distributed under the **GPL-3.0 License**.
