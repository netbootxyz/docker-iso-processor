FROM ubuntu:bionic

# environment settings
ARG DEBIAN_FRONTEND="noninteractive"

RUN \
 echo "**** install deps ****" && \
 apt-get update && \
 apt-get install -y \
	bsdtar \
	cpio \
	curl \
	jq \
	liblz4-tool \
	p7zip-full \
	psmisc \
	transmission-cli \
	xz-utils && \
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
