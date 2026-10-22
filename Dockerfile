# A "bare-metal" node: systemd, sshd, python for Ansible. Everything else is
# installed by the playbook, pinned in group_vars/all.yml. Access is by the
# control node's public key only; there is no password.
FROM ubuntu:24.04@sha256:68ee22004a9109b44973313b02ff7b1de250f1de0f5ecb628d73f579aaff33ac
ENV DEBIAN_FRONTEND=noninteractive
ARG SSH_PUBKEY

RUN apt-get update -q \
    && apt-get install -y -q --no-install-recommends \
         systemd systemd-sysv openssh-server python3 sudo iproute2 ca-certificates cron \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN test -n "$SSH_PUBKEY" \
    && mkdir -p /root/.ssh && chmod 0700 /root/.ssh \
    && printf '%s\n' "$SSH_PUBKEY" > /root/.ssh/authorized_keys && chmod 0600 /root/.ssh/authorized_keys \
    && sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config \
    && sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config \
    && (systemctl disable ssh.socket || true) && systemctl enable ssh.service

EXPOSE 22
CMD ["/lib/systemd/systemd"]
