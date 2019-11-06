#! /bin/bash

# collect variables from settings file
if [ ! -f /buildout/settings.sh ]; then
  echo "settings not found will not continue"
  exit 1
fi
source /buildout/settings.sh
rm -f /buildout/settings.sh

# download based on type
if [[ "${TYPE}" == "file" ]]; then
  curl -o \
  /root/Downloads/temp.iso -L \
  "${URL}"
elif [[ "${TYPE}" == "torrent" ]]; then
  tmpfile=$(mktemp)
  chmod a+x $tmpfile
  echo "killall transmission-cli" > $tmpfile
  transmission-cli -f $tmpfile ${URL}
fi

# extract contents
cd /root/Downloads
7z x *.iso
# move files needed to build output
while read -r MOVE; do
  SRC="${MOVE%|*}"
  DEST="${MOVE#*|}"
  mv "${SRC}" /buildout/"${DEST}"
done <<< "${CONTENTS}"
chmod 777 /buildout/*

exit 0
