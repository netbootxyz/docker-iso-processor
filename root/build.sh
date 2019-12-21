#! /bin/bash
set -e

# collect variables from settings file
if [ ! -f /buildout/settings.sh ]; then
  echo "settings not found will not continue"
  exit 1
fi
source /buildout/settings.sh
rm -f /buildout/settings.sh


# initrd package and exit
if [[ "${COMPRESS_INITRD}" == "true" ]];then
  # move files needed to build output
  while read -r MOVE; do
    DEST="${MOVE#*|}"
    mv /buildin/${DEST} /buildout/
    if [[ -f "/buildin/${DEST}.part2" ]]; then
      mv /buildin/${DEST}.part2 /buildout/
    fi
    if [[ -f "/buildin/${DEST}.part3" ]]; then
      mv /buildin/${DEST}.part3 /buildout/
    fi
  done <<< "${CONTENTS}"
  # compress initrd folder into bootable file
  cd /buildin/initrd_files
  if [[ "${INITRD_TYPE}" == "xz" ]] || [[ "${INITRD_TYPE}" == "lz4" ]];then
    find . 2>/dev/null | cpio -o -H newc | xz --check=crc32 > /buildout/${INITRD_NAME}
  elif [[ "${INITRD_TYPE}" == "gz" ]];then
    find . | cpio -o -H newc | gzip -9 > /buildout/${INITRD_NAME}
  fi
  chmod 777 /buildout/*
  exit 0
fi

# download based on type
if [[ "${TYPE}" == "file" ]]; then
  curl -o \
  /root/Downloads/temp.iso -L \
  "${URL}"
elif [[ "${TYPE}" == "torrent" ]]; then
  tmpfile=$(mktemp)
  chmod a+x $tmpfile
  echo "killall transmission-cli" > $tmpfile
  transmission-cli -f $tmpfile ${URL} || :
fi

# extract contents
cd /root/Downloads
find . -name "*.iso" -exec 7z x {} \;
# move files needed to build output
while read -r MOVE; do
  SRC="${MOVE%|*}"
  DEST="${MOVE#*|}"
  # split this file if over 2 gigabytes
  filesize=$(du -b ${SRC} | awk '{print $1}')
  if [[ ${filesize} -gt 2147483648 ]]; then
    split -b 2147483647 ${SRC}
    mv xaa /buildout/"${DEST}"
    mv xab /buildout/"${DEST}".part2
    if [[ -f "xac" ]]; then
      mv xac /buildout/"${DEST}".part3
    fi
  else
    mv ${SRC} /buildout/"${DEST}"
  fi
done <<< "${CONTENTS}"
chmod 777 /buildout/*

# initrd extraction
if [[ "${EXTRACT_INITRD}" == "true" ]] && [[ "${INITRD_TYPE}" != "lz4" ]];then
  INITRD_ORG=${INITRD_NAME}
  COUNTER=1
  cd /buildout
  while :
  do
    # strip microcode from initrd if it has it
    LAYERCOUNT=$(cat ${INITRD_NAME} | cpio -tdmv 2>&1 >/dev/null | wc -c)
    if [[ ${LAYERCOUNT} -lt 5000 ]];then
      # This is a microcode cpio wrapper
      BLOCKCOUNT=$(cat ${INITRD_NAME} | cpio -tdmv 2>&1 >/dev/null | awk 'END{print $1}')
      dd if=${INITRD_NAME} of=${INITRD_NAME}${COUNTER} bs=512 skip=${BLOCKCOUNT}
      INITRD_NAME=${INITRD_NAME}${COUNTER}
    else
      # this is a compressed archive
      mkdir initrd_files
      cd initrd_files
      if [[ "${INITRD_TYPE}" == "xz" ]];then
        cat ../${INITRD_NAME} | xz -d | cpio -i -d
      elif [[ "${INITRD_TYPE}" == "gz" ]];then
        zcat ../${INITRD_NAME} | cpio -i -d
      fi
      break
    fi
    COUNTER=$((COUNTER+1))
  done
elif [[ "${EXTRACT_INITRD}" == "true" ]] && [[ "${INITRD_TYPE}" == "lz4" ]];then
  INITRD_ORG=${INITRD_NAME}
  cd /buildout
  # lz4 extraction detection is a clusterfuck here we just assume we drill twice for gold
  for COUNTER in 1 2;do
    BLOCKCOUNT=$(cat ${INITRD_NAME} | cpio -tdmv 2>&1 >/dev/null | awk 'END{print $1}')
    dd if=${INITRD_NAME} of=${INITRD_NAME}${COUNTER} bs=512 skip=${BLOCKCOUNT}
    INITRD_NAME=${INITRD_NAME}${COUNTER} 
  done
  mkdir initrd_files
  cd initrd_files
  cat ../${INITRD_NAME} | lz4 -d - | cpio -i -d
fi

exit 0
