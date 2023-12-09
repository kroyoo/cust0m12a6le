FROM ubuntu:22.04


RUN sed -i 's#http://archive.ubuntu.com/ubuntu/#mirror://mirrors.ubuntu.com/mirrors.txt#' /etc/apt/sources.list;

# disable snap
RUN apt-mark hold snapd && apt autoremove --purge snapd || true && rm -rf ~/snap/ && rm -rf /var/cache/snapd/ \
    && echo 'Package: snapd' >> /etc/apt/preferences.d/nosnap.pref \
    && echo 'Pin: release a=*' >> /etc/apt/preferences.d/nosnap.pref \
    && echo 'Pin-Priority: -10' >> /etc/apt/preferences.d/nosnap.pref \
    && echo 'Package: firefox*' >> /etc/apt/preferences.d/firefox-no-snap.pref \
    && echo 'Pin: release o=Ubuntu*' >> /etc/apt/preferences.d/firefox-no-snap.pref \
    && echo 'Pin-Priority: -1' >> /etc/apt/preferences.d/firefox-no-snap.pref

# add software-properties-common
ENV DEBIAN_FRONTEND noninteractive
RUN apt-get update \
    && apt-get install -y software-properties-common \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

RUN apt update && add-apt-repository ppa:mozillateam/ppa && apt update \
    && apt install -y --no-install-recommends \
    sudo net-tools zenity xz-utils dbus-x11 x11-utils alsa-utils libgl1-mesa-dri \
    xvfb x11vnc firefox vim nano git curl wget neofetch feh mesa-utils \
    gtk2-engines-murrine gnome-themes-standard gtk2-engines-pixbuf gtk2-engines-murrine arc-theme \
    xfce4 xfce4-goodies xrdp xorgxrdp xserver-xorg-input-all

RUN sed -i 's/^port=3389/port=30689/g' /etc/xrdp/xrdp.ini && sed -i '/^test -x/i xfce4-session' /etc/xrdp/startwm.sh

RUN mkdir /etc/wireguard
WORKDIR /etc/wireguard
VOLUME /etc/wireguard
COPY wireproxy /usr/local/bin/wireproxy
RUN chmod +x /usr/local/bin/wireproxy
COPY entry.sh /entry.sh
RUN chmod +x /entry.sh

ENTRYPOINT ["/entry.sh"]
