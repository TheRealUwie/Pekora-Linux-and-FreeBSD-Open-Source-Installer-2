#!/bin/bash
# BSD 3-Clause License
#
# Copyright (c) 2026, Uwie
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
# 1. Redistributions of source code must retain the above copyright notice, this
#    list of conditions and the following disclaimer.
#
# 2. Redistributions in binary form must reproduce the above copyright notice,
#    this list of conditions and the following disclaimer in the documentation
#    and/or other materials provided with the distribution.
#
# 3. Neither the name of the copyright holder nor the names of its
#    contributors may be used to endorse or promote products derived from
#    this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
# SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
# CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
# OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
# OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.


set -e

INSTALLER_URL="https://setup.pekora.zip/ProjectXPlayerLauncher.exe"
APP_NAME="Pekora Player"
APP_COMMENT="https://pekora.zip/"
APP_ID="pekora-player"
APP_INSTALLER_EXE="PekoraPlayerLauncher.exe"
APP_INSTALL_SEARCH_DIR="AppData/Local/Pekora/Versions"
MIN_WINE_VERSION_MAJOR=8

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: This installer must be run as root (sudo)."
  exit 1
fi

echo "Detecting non-root users..."
USER_DIRS=(/home/* /usr/home/*)
declare -A found_users
for dir in "${USER_DIRS[@]}"; do
  if [[ -d "$dir" ]] && [[ ! -L "$dir" ]]; then
    user=$(basename "$dir")
    if [[ "$user" != "root" ]] && id "$user" >/dev/null 2>&1; then
        uid=$(id -u "$user")
        if [[ "$uid" -ge 1000 ]]; then
           found_users["$user"]=1
        fi
    fi
  fi
done
USER_LIST=("${!found_users[@]}")

if [[ ${#USER_LIST[@]} -eq 0 ]]; then
  echo "ERROR: No suitable user directories found in /home or /usr/home."
  echo "Please ensure a regular user exists with a home directory."
  exit 1
elif [[ ${#USER_LIST[@]} -eq 1 ]]; then
  REAL_USER="${USER_LIST[0]}"
  echo "Found single user: $REAL_USER"
else
  echo "Multiple users found. Please choose the user to install $APP_NAME for:"
  mapfile -t sorted_users < <(printf "%s\n" "${USER_LIST[@]}" | sort)
  select chosen_user in "${sorted_users[@]}"; do
    if [[ -n "$chosen_user" ]]; then
      REAL_USER="$chosen_user"
      echo "Selected user: $REAL_USER"
      break
    else
      echo "Invalid selection. Try again."
    fi
  done
fi

    
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
if [[ ! -d "$REAL_HOME" ]]; then
    echo "ERROR: Cannot determine home directory for user '$REAL_USER'."
    exit 1
fi
REAL_UID=$(id -u "$REAL_USER")
REAL_GID=$(id -g "$REAL_USER")
WINEPREFIX="$REAL_HOME/.Korone"

WINE_EXE=$(command -v wine || true)
NEEDS_WINE_INSTALL_OR_UPGRADE=false
CURRENT_WINE_VERSION_MAJOR=0

if [[ -n "$WINE_EXE" ]]; then
    echo "Wine found at $WINE_EXE. Checking version..."
    WINE_VERSION_STRING=$(wine --version 2>/dev/null || echo "wine-0.0")
    CURRENT_WINE_VERSION_MAJOR=$(echo "$WINE_VERSION_STRING" | grep -oE '^[^-]+-[0-9]+' | grep -oE '[0-9]+$' || echo 0)

    if [[ "$CURRENT_WINE_VERSION_MAJOR" -lt "$MIN_WINE_VERSION_MAJOR" ]]; then
        echo "Installed Wine version ($WINE_VERSION_STRING -> Major $CURRENT_WINE_VERSION_MAJOR) is older than required ($MIN_WINE_VERSION_MAJOR). Will attempt upgrade."
        NEEDS_WINE_INSTALL_OR_UPGRADE=true
    else
        echo "Installed Wine version ($WINE_VERSION_STRING -> Major $CURRENT_WINE_VERSION_MAJOR) is sufficient."
    fi
else
    echo "Wine not found. Will attempt installation."
    NEEDS_WINE_INSTALL_OR_UPGRADE=true
fi

if [[ "$NEEDS_WINE_INSTALL_OR_UPGRADE" == "true" ]]; then
    echo "Detecting package manager for Wine installation/upgrade..."
    PM=""
    command -v apt >/dev/null 2>&1 && PM="apt"
    command -v dnf >/dev/null 2>&1 && PM="dnf"
    command -v pacman >/dev/null 2>&1 && PM="pacman"
    command -v pkg >/dev/null 2>&1 && PM="pkg"
    command -v yum >/dev/null 2>&1 && [[ -z "$PM" ]] && PM="yum"

    if [[ -z "$PM" ]]; then
        echo "ERROR: No supported package manager (apt, dnf, pacman, pkg, yum) detected."
        echo "Please install or upgrade Wine manually (version $MIN_WINE_VERSION_MAJOR.0 or newer required) and re-run this script."
        exit 1
    fi
    echo "Detected package manager: $PM"

    if [[ -n "$WINE_EXE" ]]; then
        echo "Attempting to upgrade Wine using $PM..."
    else
        echo "Attempting to install Wine using $PM..."
    fi

    case "$PM" in
        apt)
          dpkg --add-architecture i386
          mkdir -pm755 /etc/apt/keyrings
          echo "Downloading WineHQ repository key..."
          if ! wget -O /etc/apt/keyrings/winehq-archive.key https://dl.winehq.org/wine-builds/winehq.key; then
            echo "ERROR: Failed to download WineHQ key." && exit 1
          fi
          
          OS_ID=$(grep '^ID=' /etc/os-release 2>/dev/null | cut -d'=' -f2 || echo "ubuntu")
          OS_VERSION_CODENAME=$(grep '^VERSION_CODENAME=' /etc/os-release 2>/dev/null | cut -d'=' -f2 || lsb_release -cs)
          
          if [[ -z "$OS_VERSION_CODENAME" ]]; then
              read -p "Could not detect distribution codename. Please enter it (e.g., jammy, bookworm): " OS_VERSION_CODENAME
              if [[ -z "$OS_VERSION_CODENAME" ]]; then echo "Aborting." && exit 1; fi
          fi

          echo "Adding WineHQ repository for $OS_ID/$OS_VERSION_CODENAME..."
          SOURCES_URL_UBUNTU="https://dl.winehq.org/wine-builds/${OS_ID}/dists/${OS_VERSION_CODENAME}/winehq-${OS_VERSION_CODENAME}.sources"
          SOURCES_URL_DEBIAN="https://dl.winehq.org/wine-builds/debian/dists/${OS_VERSION_CODENAME}/winehq-${OS_VERSION_CODENAME}.sources"
          
          if ! wget -NP /etc/apt/sources.list.d/ "$SOURCES_URL_UBUNTU" 2>/dev/null && ! wget -NP /etc/apt/sources.list.d/ "$SOURCES_URL_DEBIAN" 2>/dev/null; then
             echo "ERROR: Failed to download WineHQ sources list for '$OS_VERSION_CODENAME'."
             rm -f /etc/apt/sources.list.d/winehq-${OS_VERSION_CODENAME}.sources
             echo "Please check https://wiki.winehq.org/Download for manual instructions."
             exit 1
          fi

          apt update
          if ! apt install --install-recommends winehq-stable -y; then
              echo "ERROR: Failed to install/upgrade winehq-stable." && exit 1
          fi
          apt install wine-binfmt -y || echo "Info: wine-binfmt not available or failed to install (non-critical)."
          ;;
        pacman)
          if ! grep -q "^\s*\[multilib\]" /etc/pacman.conf; then
            echo "ERROR: The [multilib] repository is not enabled in /etc/pacman.conf."
            echo "Please uncomment it, run 'sudo pacman -Syu', then re-run this script."
            exit 1
          fi
          if ! pacman -Sy --noconfirm wine wine-mono wine-gecko; then
               echo "ERROR: Failed to install/upgrade wine using pacman." && exit 1
          fi
          ;;
        dnf)
          if ! dnf install wine -y; then
              echo "ERROR: Failed to install/upgrade wine using dnf." && exit 1
          fi
          ;;
        yum)
          if ! yum install wine -y; then
              echo "ERROR: Failed to install/upgrade wine using yum." && exit 1
          fi
          ;;
        pkg)
          pkg update
          if ! pkg install -y wine wine-mono wine-gecko; then
              echo "ERROR: Failed to install/upgrade wine using pkg." && exit 1
          fi
          ;;
        *)
          echo "Internal ERROR: Unsupported package manager '$PM'." && exit 1
          ;;
    esac

    if ! command -v wine >/dev/null 2>&1; then
        echo "ERROR: Wine command still not found after installation attempt."
        exit 1
    fi
    echo "Current Wine version: $(wine --version)"
fi

TEMP_DIR="$REAL_HOME/.$APP_ID-temp"
INSTALLER_PATH="$TEMP_DIR/$APP_INSTALLER_EXE"
echo "Creating temporary directory: $TEMP_DIR"
mkdir -p "$TEMP_DIR"
chown "$REAL_UID:$REAL_GID" "$TEMP_DIR"

echo "Downloading $APP_NAME installer from $INSTALLER_URL..."
if ! sudo -u "$REAL_USER" HOME="$REAL_HOME" curl -L --fail -o "$INSTALLER_PATH" "$INSTALLER_URL"; then
    echo "ERROR: Failed to download installer from $INSTALLER_URL"
    rm -rf "$TEMP_DIR"
    exit 1
fi
chown "$REAL_UID:$REAL_GID" "$INSTALLER_PATH"
chmod +x "$INSTALLER_PATH"

echo
echo "Attempting to launch the $APP_NAME installer GUI as user '$REAL_USER'."
echo "If it fails, you may need to run it manually: wine \"$INSTALLER_PATH\""
read -p "Press Enter to attempt launching the installer automatically..."

if ! sudo -u "$REAL_USER" \
     env HOME="$REAL_HOME" WINEPREFIX="$WINEPREFIX" \
     DISPLAY="$DISPLAY" XAUTHORITY="${XAUTHORITY:-$REAL_HOME/.Xauthority}" \
     DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/$REAL_UID/bus}" \
     wine "$INSTALLER_PATH"; then
    echo "WARNING: The Wine installer process exited with an error."
    read -p "Please check if $APP_NAME seems installed. Press Enter to continue..."
fi

echo "Searching for installed application..."
WINE_USER_PATH="$WINEPREFIX/drive_c/users/$REAL_USER"
SEARCH_ROOT="$WINE_USER_PATH/$APP_INSTALL_SEARCH_DIR"

LAUNCHER_CANDIDATES=()
while IFS= read -r -d $'\0'; do
    LAUNCHER_CANDIDATES+=("$REPLY")
done < <(find "$SEARCH_ROOT" -path '*/'"$APP_INSTALLER_EXE" -type f -print0 2>/dev/null)

if [[ ${#LAUNCHER_CANDIDATES[@]} -eq 0 ]]; then
  echo "ERROR: Could not find installed $APP_INSTALLER_EXE"
  echo "Searched in: $SEARCH_ROOT"
  exit 1
elif [[ ${#LAUNCHER_CANDIDATES[@]} -gt 1 ]]; then
  echo "WARNING: Found multiple possible launchers, using the first one."
  LAUNCHER_PATH="${LAUNCHER_CANDIDATES[0]}"
else
   LAUNCHER_PATH="${LAUNCHER_CANDIDATES[0]}"
fi
echo "Found launcher: $LAUNCHER_PATH"

DESKTOP_FILE_NAME="$APP_ID.desktop"
if [[ "$(uname)" == "FreeBSD" ]]; then
    DESKTOP_DIR="/usr/local/share/applications"
else
    DESKTOP_DIR="/usr/share/applications"
fi
mkdir -p "$DESKTOP_DIR"
DESKTOP_PATH="$DESKTOP_DIR/$DESKTOP_FILE_NAME"
echo "Creating desktop entry: $DESKTOP_PATH"

cat <<EOF > "$DESKTOP_PATH"
[Desktop Entry]
Name=Pekora Player
Comment=https://pekora.zip/
Type=Application
Exec=env WINEPREFIX="$WINEPREFIX" wine "$LAUNCHER_PATH" %u
MimeType=x-scheme-handler/pekora-player
Categories=Game
EOF

chmod 644 "$DESKTOP_PATH"

echo "Updating desktop application database..."
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$DESKTOP_DIR"
elif command -v kbuildsycoca5 >/dev/null 2>&1; then
    kbuildsycoca5
else
  echo "WARNING: Could not find 'update-desktop-database' or 'kbuildsycoca5'."
fi

echo "Cleaning up temporary files..."
rm -rf "$TEMP_DIR"

echo
echo "$APP_NAME installation script finished for user: $REAL_USER"
exit 0
