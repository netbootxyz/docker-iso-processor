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
    i=2
    while [[ -f "/buildin/${DEST}.part${i}" ]]; do
      mv /buildin/${DEST}.part${i} /buildout/
      i=$((i+1))
    done
  done <<< "${CONTENTS}"
  # compress initrd folder into bootable file
  cd /buildin/initrd_files
  if [[ "${INITRD_TYPE}" == "xz" ]] || [[ "${INITRD_TYPE}" == "lz4" ]] ;then
    find . 2>/dev/null | cpio -o -H newc | xz --check=crc32 > /buildout/${INITRD_NAME}
  elif [[ "${INITRD_TYPE}" == "zstd" ]];then
    find . 2>/dev/null | cpio -o -H newc | zstd > /buildout/${INITRD_NAME}
  elif [[ "${INITRD_TYPE}" == "gz" ]];then
    find . | cpio -o -H newc | gzip -9 > /buildout/${INITRD_NAME}
  elif [[ "${INITRD_TYPE}" == "uncomp" ]];then
    find . | cpio -o -H newc > /buildout/${INITRD_NAME}
  elif [[ "${INITRD_TYPE}" == "arch-xz" ]];then
    find . -mindepth 1 -printf '%P\0' | sort -z | LANG=C bsdtar --null -cnf - -T - | LANG=C bsdtar --uid 0 --gid 0 --null -cf - --format=newc @- | xz --check=crc32 > /buildout/${INITRD_NAME}
  fi
  chmod 777 /buildout/*
  exit 0
fi

# return URL that is getting retrieved
echo "Retrieving media from ${URL}."

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
find . -name "*.iso" -exec 7z x {} -y \;
# move files needed to build output
while read -r MOVE; do
  SRC="${MOVE%|*}"
  DEST="${MOVE#*|}"
  # split this file if over 2 gigabytes
  filesize=$(du -b ${SRC} | awk '{print $1}')
  if [[ ${filesize} -gt 2097152000 ]]; then
    split -b 2097151999 ${SRC}
    i=0
    for chunk in $(ls x?? 2>/dev/null | sort); do
      i=$((i+1))
      if [[ ${i} -eq 1 ]]; then
        mv "${chunk}" /buildout/"${DEST}"
      else
        mv "${chunk}" /buildout/"${DEST}".part${i}
      fi
    done
  else
    mv ${SRC} /buildout/"${DEST}"
  fi
done <<< "${CONTENTS}"
chmod 777 /buildout/*

# clean up ISOs once extracted
rm *.iso

echo "Extracting initrd..."

# initrd extraction
if [[ "${EXTRACT_INITRD}" == "true" ]];then
  INITRD_ORG=${INITRD_NAME}
  cd /buildout
  
  # Try using unmkinitramfs first (handles multi-layer initrds properly)
  # Modern distros (Ubuntu, Debian, Clonezilla, etc.) use multi-layer initrds with:
  # - early: microcode
  # - early2: kernel modules/drivers
  # - main: actual initramfs
  if command -v unmkinitramfs >/dev/null 2>&1; then
    echo "Using unmkinitramfs for proper multi-layer extraction..."
    mkdir -p initrd_extracted
    if unmkinitramfs ${INITRD_NAME} initrd_extracted/ 2>/dev/null; then
      mkdir -p initrd_files
      # unmkinitramfs has two output shapes:
      #   - multi-layer initrd: extracts to early/, early2/, ..., main/
      #   - single-layer initrd: extracts the cpio contents directly into the target,
      #     so top-level entries are filesystem roots like bin/, etc/, sbin/.
      # Detect by presence of main/, which is unmkinitramfs's signal for multi-layer mode.
      if [ -d initrd_extracted/main ]; then
        # Multi-layer: merge ordered layers, preserving microcode + drivers + main fs
        for layer in initrd_extracted/early*/ initrd_extracted/main/; do
          [ -d "$layer" ] || continue
          echo "Merging layer: $(basename $layer)"
          rsync -a "$layer" initrd_files/
        done
        echo "Successfully extracted multi-layer initrd"
      else
        # Single-layer: extracted contents are already the initrd root
        echo "Single-layer initrd, copying extracted contents"
        rsync -a initrd_extracted/ initrd_files/
        echo "Successfully extracted single-layer initrd"
      fi
      rm -rf initrd_extracted
    else
      echo "unmkinitramfs failed, falling back to manual extraction"
      EXTRACT_MANUALLY=true
    fi
  else
    echo "unmkinitramfs not available, using manual extraction"
    EXTRACT_MANUALLY=true
  fi
  
  # Fallback: manual extraction for simple single-layer initrds or when unmkinitramfs fails
  if [[ "${EXTRACT_MANUALLY}" == "true" ]]; then
    if [[ "${INITRD_TYPE}" != "lz4" ]]; then
      COUNTER=1
      while :
      do
        # strip microcode from initrd if it has it
        LAYERCOUNT=$(cat ${INITRD_NAME} | cpio -tdmv 2>&1 >/dev/null | wc -c)
        if [[ ${LAYERCOUNT} -lt 5000 ]] && [[ "${INITRD_TYPE}" != "uncomp" ]];then
          # This is a microcode cpio wrapper
          BLOCKCOUNT=$(cat ${INITRD_NAME} | cpio -tdmv 2>&1 >/dev/null | awk 'END{print $1}')
          dd if=${INITRD_NAME} of=${INITRD_NAME}${COUNTER} bs=512 skip=${BLOCKCOUNT} 2>/dev/null
          INITRD_NAME=${INITRD_NAME}${COUNTER}
        else
          # this is a compressed archive
          mkdir -p initrd_files
          cd initrd_files
          # display file type
          file ../${INITRD_NAME}
          if [[ "${INITRD_TYPE}" == "xz" ]] || [[ "${INITRD_TYPE}" == "arch-xz" ]] ;then
            cat ../${INITRD_NAME} | xz -d | cpio -i -d
          elif [[ "${INITRD_TYPE}" == "zstd" ]];then
            cat ../${INITRD_NAME} | zstd -d | cpio -i -d
          elif [[ "${INITRD_TYPE}" == "gz" ]];then
            zcat ../${INITRD_NAME} | cpio -i -d
          elif [[ "${INITRD_TYPE}" == "uncomp" ]];then
            cat ../${INITRD_NAME} | cpio -i -d
          fi
          break
        fi
        COUNTER=$((COUNTER+1))
      done
    elif [[ "${INITRD_TYPE}" == "lz4" ]]; then
      if [[ "${LZ4_SINGLE}" == "true" ]];then
        BLOCKCOUNT=$(cat ${INITRD_NAME} | cpio -tdmv 2>&1 >/dev/null | awk 'END{print $1}')
        dd if=${INITRD_NAME} of=${INITRD_NAME}1 bs=512 skip=${BLOCKCOUNT} 2>/dev/null
        INITRD_NAME=${INITRD_NAME}1
      else
        # lz4 extraction detection is a clusterfuck here we just assume we drill twice for gold
        for COUNTER in 1 2;do
          BLOCKCOUNT=$(cat ${INITRD_NAME} | cpio -tdmv 2>&1 >/dev/null | awk 'END{print $1}')
          dd if=${INITRD_NAME} of=${INITRD_NAME}${COUNTER} bs=512 skip=${BLOCKCOUNT} 2>/dev/null
          INITRD_NAME=${INITRD_NAME}${COUNTER}
        done
      fi
      mkdir -p initrd_files
      cd initrd_files
      cat ../${INITRD_NAME} | lz4 -d - | cpio -i -d
    fi
  fi
fi

exit 0
