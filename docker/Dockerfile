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
        gettext-base \
        git \
        gzip \
        libncurses-dev \
        libssl-dev \
        locales \
        make \
        mtools \
        patch \
        perl \
        python3 \
        python3-dev \
        rsync \
        sed \
        squashfs-tools \
        swig \
        tar \
        u-boot-tools \
        unzip \
        wget \
        whiptail \
        xz-utils \
    && rm -rf /var/lib/apt/lists/*

# Build genimage from source (not packaged in Debian Bookworm)
RUN apt-get update && apt-get install -y --no-install-recommends \
        autoconf automake libtool pkg-config libconfuse-dev \
    && rm -rf /var/lib/apt/lists/* \
    && git clone --depth 1 --branch v19 https://github.com/pengutronix/genimage /tmp/genimage \
    && cd /tmp/genimage \
    && ./autogen.sh && ./configure && make -j"$(nproc)" && make install \
    && rm -rf /tmp/genimage

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

# Build user mirrors host UID/GID at runtime via --user; default to root for now.
WORKDIR /work
