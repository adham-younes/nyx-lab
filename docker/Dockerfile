# syntax=docker/dockerfile:1.7
# NYX lab — OpenHands Enterprise custom sandbox image.
# Extends the agent-server base image; the base entrypoint is left untouched.
FROM ghcr.io/openhands/agent-server:1.46.0-python

ARG KALI_MIRROR=http://http.kali.org/kali
ARG WITH_SECLISTS=1
ENV DEBIAN_FRONTEND=noninteractive

USER root

RUN apt-get update \
 && apt-get install -y --no-install-recommends debootstrap ca-certificates curl git jq zstd \
 && rm -rf /var/lib/apt/lists/*

# Kali rolling chroot (merged-usr layout, same as the proven runtime setup)
RUN debootstrap --variant=minbase --include=ca-certificates,gnupg,apt-transport-https \
      kali-rolling /opt/kali "$KALI_MIRROR"

RUN echo "deb $KALI_MIRROR kali-rolling main contrib non-free non-free-firmware" \
      > /opt/kali/etc/apt/sources.list \
 && chroot /opt/kali apt-get update

RUN chroot /opt/kali env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      nmap masscan sqlmap hydra john hashcat nuclei ffuf gobuster dirb nikto whatweb wpscan \
      wafw00f dnsrecon dnsenum amass theharvester enum4linux-ng smbclient smbmap responder \
      netexec impacket-scripts certipy-ad coercer krbrelayx bloodyad mitm6 chisel ligolo-ng \
      yara tor obfs4proxy proxychains4 age gcc g++ make mingw-w64 golang-go python3-pip \
      python3-venv jq zstd git curl exploitdb wordlists havoc donut metasploit-framework \
      sliver villain \
 && chroot /opt/kali apt-get clean \
 && rm -rf /opt/kali/var/lib/apt/lists/* /opt/kali/usr/share/doc/* /opt/kali/usr/share/man/*

RUN if [ "$WITH_SECLISTS" = "1" ]; then \
      chroot /opt/kali env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends seclists; \
      chroot /opt/kali apt-get clean; rm -rf /opt/kali/var/lib/apt/lists/*; \
    fi

RUN chroot /opt/kali env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      volatility3 feroxbuster medusa || true

COPY lab/ /opt/lab/
RUN bash /opt/lab/install-extras.sh

RUN ln -sf /opt/lab/nyx.sh /usr/local/bin/nyx \
 && mkdir -p /home/openhands/.openhands/memory \
 && cat /opt/lab/MEMORY.md >> /home/openhands/.openhands/memory/MEMORY.md \
 && chown -R openhands:openhands /home/openhands/.openhands /opt/lab

USER openhands
WORKDIR /workspace/project
