FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive

RUN apt update && apt install -y openssh-server python3 sudo iproute2 systemd systemd-sysv

RUN echo 'root:root' | chpasswd
RUN sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config

RUN systemctl enable ssh

EXPOSE 22

CMD ["/lib/systemd/systemd"]
