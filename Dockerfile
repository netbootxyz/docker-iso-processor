FROM ubuntu:bionic

# environment settings
ARG DEBIAN_FRONTEND="noninteractive"

RUN \
 echo "**** install deps ****" && \
 apt-get update && \
 apt-get install -y \
	curl \
	p7zip-full \
	psmisc \
	transmission-cli && \
 echo "**** directories ****" && \
 mkdir -p \
	/buildout \
	/root/Downloads && \
 echo "**** clean up ****" && \
 rm -rf \
	/tmp/* \
	/var/lib/apt/lists/* \
	/var/tmp/*

# add local files
COPY /root /

ENTRYPOINT [ "/build.sh" ]
