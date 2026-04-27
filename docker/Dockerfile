FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

# Buildroot host deps per https://buildroot.org/downloads/manual/manual.html#requirement
# plus PanicOS additions.
RUN apt-get update && apt-get install -y --no-install-recommends \
        bash \
        bc \
        binutils \
        build-essential \
        bzip2 \
        ca-certificates \
        cpio \
        dosfstools \
        file \
        git \
        gzip \
        libncurses-dev \
        locales \
        make \
        mtools \
        patch \
        perl \
        python3 \
        rsync \
        sed \
        squashfs-tools \
        tar \
        unzip \
        wget \
        whiptail \
        xz-utils \
    && rm -rf /var/lib/apt/lists/*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

# Build user mirrors host UID/GID at runtime via --user; default to root for now.
WORKDIR /work
