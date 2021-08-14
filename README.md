# docker-iso-processor

The purpose of this container is to download a remote ISO and extract specific contents based on a `settings.sh` file bind mounted into it.

Settings File example:

```
URL="http://your/direct/link/or/torrent"
TYPE=file or torrent
CONTENTS="\
path/in/ISO|OutputFileName
casper/filesystem.squashfs|filesystem.squashfs"
```

Usage Snippet:

```
docker run --rm -it \
  -v $(pwd):/buildout \
  ghcr.io/netbootxyz/iso-processor
```
