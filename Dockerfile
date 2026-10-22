# A "bare-metal" node: systemd, sshd, python for Ansible. Everything else is
# installed by the playbook, pinned in group_vars/all.yml.
FROM ubuntu:24.04@sha256:68ee22004a9109b44973313b02ff7b1de250f1de0f5ecb628d73f579aaff33ac
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update -q \
    && apt-get install -y -q --no-install-recommends \
         systemd systemd-sysv openssh-server python3 sudo iproute2 ca-certificates \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Lab-only bootstrap credential; the playbook's first play replaces it with a key.
RUN echo 'root:root' | chpasswd \
    && sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config \
    && (systemctl disable ssh.socket || true) && systemctl enable ssh.service

EXPOSE 22
CMD ["/lib/systemd/systemd"]
