# Image Linux jetable pour tester les scripts du homelab depuis le Mac
# (le script de backup utilise stat -c, setpriv, etc. : GNU/Linux uniquement).
FROM debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
      bats shellcheck sqlite3 openssh-server systemd util-linux python3 sudo ca-certificates \
    && rm -rf /var/lib/apt/lists/*
