FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# ------------------------------------------------------------------ base apt
RUN apt-get update && apt-get install -y --no-install-recommends \
      git git-lfs ca-certificates curl wget gnupg lsb-release \
      build-essential ccache g++ gawk make cmake pkg-config \
      python3 python3-dev python3-pip python3-venv python3-setuptools \
      screen tmux xterm rsync unzip \
      gdb ripgrep jq sudo \
    && rm -rf /var/lib/apt/lists/*

# ------------------------------------------------------------ gazebo harmonic
# OSRF stable repo (noble suite) — Harmonic LTS, matches docs/ENVIRONMENT_SETUP.md §4
RUN curl -sSL https://packages.osrfoundation.org/gazebo.gpg \
      -o /usr/share/keyrings/pkgs-osrf-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/pkgs-osrf-archive-keyring.gpg] http://packages.osrfoundation.org/gazebo/ubuntu-stable noble main" \
      > /etc/apt/sources.list.d/gazebo-stable.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends gz-harmonic \
    && rm -rf /var/lib/apt/lists/*

# --------------------------------------------------- ardupilot_gazebo plugin deps
RUN apt-get update && apt-get install -y --no-install-recommends \
    libgz-sim8-dev rapidjson-dev cppzmq-dev \
      libopencv-dev libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
      gstreamer1.0-plugins-bad gstreamer1.0-libav gstreamer1.0-gl \
    && rm -rf /var/lib/apt/lists/*

# ------------------------------------------------------------ user (match host)
# ubuntu:24.04 ships a default 'ubuntu' user at uid/gid 1000 — remove it so
# our user matches the host's uid/gid for clean bind-mount ownership.
RUN userdel -r ubuntu 2>/dev/null || true \
    && groupdel ubuntu 2>/dev/null || true \
    && groupadd -g 1000 rusik \
    && useradd -m -u 1000 -g 1000 -s /bin/bash rusik \
    && echo 'rusik ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/rusik \
    && chmod 0440 /etc/sudoers.d/rusik

USER rusik
WORKDIR /home/rusik
ENV HOME=/home/rusik

# ------------------------------------- ardupilot official prereq script (apt side)
# The host already has a full ardupilot clone; copying the official prereq
# script in avoids a redundant multi-GB clone during image build (this
# router's DNS chokes on 8 parallel submodule fetches). The script derives
# ARDUPILOT_ROOT from its own path, so it lives at the canonical location.
# It refuses to run as root and invokes sudo itself → run as rusik.
# SKIP_AP_GIT_CHECK=1: submodules come from the host bind-mount at runtime.
# The venv it creates in the image is discarded — first-run.sh recreates it
# inside the bind-mounted ~/ardupilot so it persists on the host
# (docs/ENVIRONMENT_SETUP.md §3).
COPY install-prereqs-ubuntu.sh /tmp/ardupilot/Tools/environment_install/install-prereqs-ubuntu.sh
COPY Tools/completion/completion.bash /tmp/ardupilot/Tools/completion/completion.bash
USER rusik
RUN USER=rusik SKIP_AP_GIT_CHECK=1 SKIP_AP_GRAPHIC_ENV=1 SKIP_AP_COMPLETION_ENV=1 SKIP_AP_STM_ENV=1 bash /tmp/ardupilot/Tools/environment_install/install-prereqs-ubuntu.sh -y \
    && (sed -i '/\/tmp\/ardupilot\/Tools\/completion\/completion.bash/d; /\/tmp\/ardupilot\/Tools\/autotest/d' /home/rusik/.profile /home/rusik/.bashrc 2>/dev/null || true) \
    && sudo rm -rf /tmp/ardupilot

# ------------------------------------------------------------------ gui extras
# Deliberately a late layer, not folded into the base apt block: the prereq
# script above is a ~10-minute layer and this router's apt DNS is flaky
# (PROJECT.md §7), so adding packages here keeps every expensive layer cached.
#   ffmpeg     — record the demo flight
#   mesa-utils — glxinfo, to tell working GL from a silent software fallback
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
      ffmpeg mesa-utils \
    && rm -rf /var/lib/apt/lists/*
USER rusik

COPY --chmod=0755 first-run.sh /usr/local/bin/first-run.sh

CMD ["sleep", "infinity"]
