#!/bin/bash
#
# start-librespot.sh - Librespot startup script
# This script handles startup of librespot with the system's pretty hostname
# and auto-configures audio parameters based on the detected sound card
#
# Version: 1.1.3
# Changelog:
# - v1.1.3: Added SYSTEM_CACHE environment knob and pass --system-cache so
#           librespot persists its credentials. Without it the reusable
#           credentials received over zeroconf only ever live in memory, so a
#           restarted player cannot reconnect on its own. Per-user
#           (~/.librespot) or /var/lib/librespot, the same split raat and
#           squeezelite use. The directory is forced to 0700 on every start,
#           and persistence is skipped when it cannot be created or secured.
#           Cached credentials that Spotify explicitly rejects are renamed to
#           credentials.json.rejected, so the next start falls back to
#           discovery instead of failing on them again.
# - v1.1.2: Added VOLUME_CTRL environment knob to select librespot's volume curve
#           (linear|log|cubic|fixed). Default remains "linear" (unchanged behaviour);
#           integrators can override via a systemd drop-in (Environment=VOLUME_CTRL=cubic).
# - v1.1.1: Fixed parameter name from --mdns-backend to --zeroconf-backend for compatibility
#           Updated variable names to match librespot's actual command line options
# - v1.1.0: Added Avahi daemon availability check when using Avahi as MDNS backend
#           Waits up to 30 seconds for Avahi to become responsive
#           Added explicit --mdns-backend parameter to librespot options
#

# User validation check
# Allow running as root, or as the user specified in /etc/hifiberry.user
CURRENT_USER=$(whoami)
if [ "$CURRENT_USER" != "root" ]; then
    if [ -f "/etc/hifiberry.user" ]; then
        AUTHORIZED_USER=$(cat /etc/hifiberry.user 2>/dev/null | tr -d '\n\r ')
        if [ "$CURRENT_USER" != "$AUTHORIZED_USER" ]; then
            echo "Error: not starting librespot, this should run as user $AUTHORIZED_USER"
            exit 0
        fi
    else
        echo "Error: not starting librespot, /etc/hifiberry.user not found and not running as root"
        exit 0
    fi
fi

# Sound card detection check
echo "Checking for sound card..."
if ! /usr/bin/config-soundcard --detect >/dev/null 2>&1; then
    echo "No sound card detected, not starting librespot"
    exit 0
fi
echo "Sound card detected successfully."

# Set default values for librespot
BITRATE=320
BACKEND="rodio"

# Volume control curve: linear|log|cubic|fixed.
# Default "linear" keeps the existing behaviour. Integrators can override it
# without forking this wrapper via a systemd drop-in, e.g.:
#   [Service]
#   Environment=VOLUME_CTRL=cubic
VOLUME_CTRL="${VOLUME_CTRL:-linear}"

# Directory where librespot persists credentials and volume.
# This is not the audio cache: --disable-audio-cache stays on below, and
# --system-cache never stores audio, only credentials.json and volume, a few
# hundred bytes in total.
#
# Per-user (~/.librespot) for the user service, system directory otherwise:
# the same split start-raat and start-squeezelite use. /var/lib/librespot is
# also where spotify-event.sh already looks.
#
# Integrators can point it elsewhere, or disable persistence with an empty
# value, via a systemd drop-in:
#   [Service]
#   Environment=SYSTEM_CACHE=/var/lib/hifiberry/librespot
SYSTEM_CACHE_DEFAULT="/var/lib/librespot"
if [ -n "${XDG_RUNTIME_DIR:-}" ] || [ -n "${XDG_SESSION_ID:-}" ]; then
  # Likely running as a user service/session
  SYSTEM_CACHE_DEFAULT="$HOME/.librespot"
fi
SYSTEM_CACHE="${SYSTEM_CACHE-$SYSTEM_CACHE_DEFAULT}"

# MDNS backend
ZEROCONF_BACKEND="avahi"

# Check if Avahi daemon is running when ZEROCONF_BACKEND is set to avahi
# This ensures Librespot has functioning mDNS capabilities before starting
# We check both that the process exists and that it's actually responding to queries
if [ "$ZEROCONF_BACKEND" = "avahi" ]; then
  echo "Checking if Avahi daemon is running..."
  ATTEMPTS=0
  MAX_ATTEMPTS=6  # 6 attempts x 5 seconds = 30 seconds max wait time
  
  while [ $ATTEMPTS -lt $MAX_ATTEMPTS ]; do
    # Check if avahi-daemon is running and listening
    if pgrep avahi-daemon >/dev/null && avahi-browse -a -t >/dev/null 2>&1; then
      echo "Avahi daemon is running and responding."
      break
    else
      ATTEMPTS=$((ATTEMPTS + 1))
      if [ $ATTEMPTS -lt $MAX_ATTEMPTS ]; then
        echo "Avahi daemon is not ready. Waiting 5 seconds... (Attempt $ATTEMPTS/$MAX_ATTEMPTS)"
        sleep 5
      else
        echo "Warning: Avahi daemon is not running or not responding after 30 seconds."
        echo "Librespot may have limited zeroconf/mDNS functionality."
      fi
    fi
  done
fi

# Get the pretty hostname first, then try normal hostname, and finally use HiFiBerry as fallback
PRETTY_HOSTNAME=$(hostnamectl hostname --pretty 2>/dev/null)
if [ $? -ne 0 ] || [ -z "$PRETTY_HOSTNAME" ]; then
  # Try to get normal hostname
  PRETTY_HOSTNAME=$(hostname 2>/dev/null)
  if [ $? -ne 0 ] || [ -z "$PRETTY_HOSTNAME" ]; then
    PRETTY_HOSTNAME="HiFiBerry"
  fi
fi

# Path to the event handler script
EVENT_HANDLER="/usr/bin/spotify-event"

# check if /usr/bin/audiocontrol_notify_librespot exists and is executable and use this as the event handler
if [ -x /usr/bin/audiocontrol_notify_librespot ]; then
  EVENT_HANDLER="/usr/bin/audiocontrol_notify_librespot"
fi


# Build basic librespot command with options
LIBRESPOT_CMD="/usr/bin/librespot"
LIBRESPOT_OPTS=("--name" "$PRETTY_HOSTNAME" 
                "--backend" "$BACKEND" 
                "--bitrate" "$BITRATE"
                "--disable-audio-cache"
                "--onevent" "$EVENT_HANDLER"
                "--volume-ctrl" "$VOLUME_CTRL"
                "--zeroconf-backend" "$ZEROCONF_BACKEND")  # Explicitly set the zeroconf backend

# Persist credentials, so a restart does not depend on a client pushing them
# back over zeroconf. The directory is what keeps the credentials off other
# local accounts, since librespot writes credentials.json without a mode of
# its own, so its mode is set on every start rather than only at creation:
# mkdir -m applies to a directory it creates and says nothing about one that
# already exists. /var/lib/librespot does exist on a device upgraded from
# 0.7.1.1 or earlier, where the postinst created it 0775 librespot:audio for
# the event pipe.
# Persistence is skipped rather than fatal when the directory cannot be
# created or secured: a player that starts without persistence is better than
# one that does not start, and credentials do not belong in a directory whose
# mode could not be set -- on that upgraded device the mode belongs to a
# system user this service no longer runs as.
CACHED_CREDENTIALS=""
if [ -n "$SYSTEM_CACHE" ]; then
  if mkdir -p "$SYSTEM_CACHE" 2>/dev/null && chmod 700 "$SYSTEM_CACHE" 2>/dev/null; then
    LIBRESPOT_OPTS+=("--system-cache" "$SYSTEM_CACHE")
    CACHED_CREDENTIALS="$SYSTEM_CACHE/credentials.json"
  else
    echo "Warning: could not create or secure $SYSTEM_CACHE (needs to be a directory owned by $(id -un), mode 0700), starting without credential persistence."
  fi
fi

# Check if we can get an access token from audiocontrol
TOKEN=`curl -f http://localhost:1080/api/spotify/access_token`
if [ $? == 0 ]; then
  echo "Successfully obtained access token from audiocontrol, using it"
  LIBRESPOT_OPTS+=("--access-token" "$TOKEN")
  # The token takes precedence: librespot does not log in with the cache.
  CACHED_CREDENTIALS=""
else
  echo "No access token available on audiocontrol"
fi

# Try to get both mixer name and hardware index from configurator
if command -v config-soundcard >/dev/null 2>&1; then
  MIXER_NAME=$(config-soundcard --no-eeprom --volume-control-softvol 2>/dev/null)
  HW_INDEX=$(config-soundcard --no-eeprom --hw 2>/dev/null)
  
  # Only use all three audio options together if both mixer and hw index are available
  if [ $? -eq 0 ] && [ -n "$MIXER_NAME" ] && [ -n "$HW_INDEX" ]; then
    echo "Using mixer control: $MIXER_NAME and hardware device: hw:$HW_INDEX"
    LIBRESPOT_OPTS+=("--mixer" "alsa")
    LIBRESPOT_OPTS+=("--alsa-mixer-control" "$MIXER_NAME")
    LIBRESPOT_OPTS+=("--alsa-mixer-device" "hw:$HW_INDEX")
  fi
fi

# Set aside cached credentials that Spotify explicitly rejects.
# librespot logs in with them at startup, and when the account refuses them it
# exits 1 without touching the cache, so every restart would read the same
# file and fail again before discovery could receive replacement credentials.
# Only the login reasons that condemn the credentials themselves count here: a
# network or audio failure, or any other nonzero exit, leaves them alone. The
# file is renamed rather than deleted, so it can still be inspected.
# librespot's stderr runs through this filter, which forwards every line
# unchanged. It ignores SIGTERM so that systemd reaping the unit once librespot
# has exited cannot cut it off before it has read the final error; it still
# ends on its own, at end of input, when librespot exits.
watch_rejected_credentials() {
  local credentials="$1" line
  trap '' TERM INT
  while IFS= read -r line || [ -n "$line" ]; do
    printf '%s\n' "$line"
    case "$line" in
      *"Login failed with reason: Bad credentials"* | \
      *"Login failed with reason: Could not validate credentials"* | \
      *"Login failed with reason: Premium account required"*)
        if [ -f "$credentials" ] && mv -f "$credentials" "$credentials.rejected"; then
          echo "Spotify rejected the cached credentials, moved them to $credentials.rejected. Select this player from a Spotify client to authenticate again."
        fi
        ;;
    esac
  done
}

if [ -n "$CACHED_CREDENTIALS" ]; then
  exec 3>&2
  exec 2> >(watch_rejected_credentials "$CACHED_CREDENTIALS" >&3 2>&3)
  exec 3>&-
fi

# Debug: print the command to be executed
echo "Starting Librespot with device name: $PRETTY_HOSTNAME"
echo "Command: $LIBRESPOT_CMD ${LIBRESPOT_OPTS[@]}"

# Run librespot with the configured options
exec $LIBRESPOT_CMD "${LIBRESPOT_OPTS[@]}"