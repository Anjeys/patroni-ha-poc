# Берем стабильную Ubuntu
FROM ubuntu:22.04

# Отключаем интерактивные запросы при установке
ENV DEBIAN_FRONTEND=noninteractive

# Ставим ssh, питон для ansible, sudo и утилиты сети
RUN apt update && apt install -y openssh-server python3 sudo iproute2

# Директория, нужная для работы ssh-сервера
RUN mkdir /var/run/sshd

# Задаем пароль root (для тестов, ansible будет ходить под ним)
RUN echo 'root:root' | chpasswd

# Разрешаем вход root по ssh
RUN sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config

# Открываем 22 порт наружу
EXPOSE 22

# Запускаем ssh-сервер демоном на переднем плане
CMD ["/usr/sbin/sshd", "-D"]
