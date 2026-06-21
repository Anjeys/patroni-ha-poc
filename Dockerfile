FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive

# Добавляем systemd в установку
RUN apt update && apt install -y openssh-server python3 sudo iproute2 systemd systemd-sysv

RUN echo 'root:root' | chpasswd
RUN sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config

# Включаем SSH в автозагрузку systemd
RUN systemctl enable ssh

EXPOSE 22

# Теперь PID 1 — это systemd. Он сам запустит ssh и все наши будущие сервисы
CMD ["/lib/systemd/systemd"]
