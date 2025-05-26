#! /bin/bash
set -e

# collect variables from settings file
if [ ! -f /buildout/settings.sh ]; then
  echo "settings not found will not continue"
  exit 1
fi
source /buildout/settings.sh
rm -f /buildout/settings.sh


# --- Multilayer initrd helpers ---

is_multilayer_initrd() {
  grep -aob 'TRAILER!!!' "$1" | head -n1 | grep -q .
}

extract_multilayer_initrd() {
  IMG="$1"
  OUTDIR="$2"
  # Find TRAILER!!! marker
  TRAILER_OFFSET=$(grep -aob 'TRAILER!!!' "$IMG" | head -n1 | cut -d: -f1)
  if [ -z "$TRAILER_OFFSET" ]; then
    echo "Could not find TRAILER!!! marker in $IMG"
    exit 1
  fi
  SEARCH_START=$((TRAILER_OFFSET + 10))
  MAGIC=""
  ARCHIVE_OFFSET=""
  for ((i=0; i<1048576; i++)); do
    offset=$((SEARCH_START + i))
    magic=$(dd if="$IMG" bs=1 skip="$offset" count=6 2>/dev/null | xxd -p)
    case "$magic" in
      fd377a585a00)
        MAGIC="xz"
        ARCHIVE_OFFSET="$offset"
        break
        ;;
      1f8b0800*)
        MAGIC="gz"
        ARCHIVE_OFFSET="$offset"
        break
        ;;
      28b52ffd*)
        MAGIC="zst"
        ARCHIVE_OFFSET="$offset"
        break
        ;;
      5d000080*)
        MAGIC="lzma"
        ARCHIVE_OFFSET="$offset"
        break
        ;;
    esac
  done
  if [ -z "$ARCHIVE_OFFSET" ]; then
    echo "Could not find known compressed archive after TRAILER!!! marker."
    exit 2
  fi
  # Save outer part and embedded archive
  head -c "$ARCHIVE_OFFSET" "$IMG" > "$OUTDIR/outer_part.bin"
  dd if="$IMG" bs=1 skip="$ARCHIVE_OFFSET" of="$OUTDIR/embedded_archive.$MAGIC" status=none
  # Decompress embedded archive
  case "$MAGIC" in
    xz)   xz -dc "$OUTDIR/embedded_archive.xz"   > "$OUTDIR/embedded_archive.cpio" ;;
    gz)   gzip -dc "$OUTDIR/embedded_archive.gz" > "$OUTDIR/embedded_archive.cpio" ;;
    zst)  zstd -dc "$OUTDIR/embedded_archive.zst" > "$OUTDIR/embedded_archive.cpio" ;;
    lzma) lzma -dc "$OUTDIR/embedded_archive.lzma" > "$OUTDIR/embedded_archive.cpio" ;;
  esac
  mkdir -p "$OUTDIR/initrd_files"
  (cd "$OUTDIR/initrd_files" && cpio -id < ../embedded_archive.cpio)
  echo "$ARCHIVE_OFFSET" > "$OUTDIR/.embedded_offset"
  echo "$MAGIC" > "$OUTDIR/.embedded_magic"
}

rebuild_multilayer_initrd() {
  OUTDIR="$1"
  NEW_INITRD_DIR="$2"
  OUTPUT="$3"
  ARCHIVE_OFFSET=$(cat "$OUTDIR/.embedded_offset")
  MAGIC=$(cat "$OUTDIR/.embedded_magic")
  TMP_CPIO=$(mktemp --suffix=.cpio)
  TMP_COMPRESSED=$(mktemp --suffix=.$MAGIC)
  (cd "$NEW_INITRD_DIR" && find . | cpio -o -H newc > "$TMP_CPIO")
  case "$MAGIC" in
    xz)   xz -c "$TMP_CPIO"   > "$TMP_COMPRESSED" ;;
    gz)   gzip -c "$TMP_CPIO" > "$TMP_COMPRESSED" ;;
    zst)  zstd -19 -c "$TMP_CPIO" > "$TMP_COMPRESSED" ;;
    lzma) lzma -c "$TMP_CPIO" > "$TMP_COMPRESSED" ;;
  esac
  cat "$OUTDIR/outer_part.bin" > "$OUTPUT"
  cat "$TMP_COMPRESSED" >> "$OUTPUT"
  rm -f "$TMP_CPIO" "$TMP_COMPRESSED"
}

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
  # --- multilayer rebuild ---
  if [[ "${INITRD_TYPE}" == "multilayer" ]] || [[ -f /buildin/.multilayer_outer/.embedded_offset ]]; then
    rebuild_multilayer_initrd "/buildin/.multilayer_outer" "." "/buildout/${INITRD_NAME}"
    chmod 777 /buildout/*
    exit 0
  fi
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

# clean up ISOs once extracted
rm *.iso

echo "Extracting initrd..."

# initrd extraction
if [[ "${EXTRACT_INITRD}" == "true" ]] && [[ "${INITRD_TYPE}" != "lz4" ]];then
  INITRD_ORG=${INITRD_NAME}
  COUNTER=1
  cd /buildout
  # --- multilayer extraction ---
  if [[ "${INITRD_TYPE}" == "multilayer" ]] || is_multilayer_initrd "${INITRD_NAME}"; then
    mkdir -p .multilayer_outer
    extract_multilayer_initrd "${INITRD_NAME}" ".multilayer_outer"
    cp -r .multilayer_outer/initrd_files .
    INITRD_NAME="initrd_files"
  else
    while :
    do
      # strip microcode from initrd if it has it
      LAYERCOUNT=$(cat ${INITRD_NAME} | cpio -tdmv 2>&1 >/dev/null | wc -c)
      if [[ ${LAYERCOUNT} -lt 5000 ]] && [[ "${INITRD_TYPE}" != "uncomp" ]];then
        # This is a microcode cpio wrapper
        BLOCKCOUNT=$(cat ${INITRD_NAME} | cpio -tdmv 2>&1 >/dev/null | awk 'END{print $1}')
        dd if=${INITRD_NAME} of=${INITRD_NAME}${COUNTER} bs=512 skip=${BLOCKCOUNT}
        INITRD_NAME=${INITRD_NAME}${COUNTER}
      else
        # this is a compressed archive
        mkdir initrd_files
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
  fi
elif [[ "${EXTRACT_INITRD}" == "true" ]] && [[ "${INITRD_TYPE}" == "lz4" ]];then
  INITRD_ORG=${INITRD_NAME}
  cd /buildout
  if [[ "${LZ4_SINGLE}" == "true" ]];then
    BLOCKCOUNT=$(cat ${INITRD_NAME} | cpio -tdmv 2>&1 >/dev/null | awk 'END{print $1}')
    dd if=${INITRD_NAME} of=${INITRD_NAME}1 bs=512 skip=${BLOCKCOUNT}
    INITRD_NAME=${INITRD_NAME}1
  else
    # lz4 extraction detection is a clusterfuck here we just assume we drill twice for gold
    for COUNTER in 1 2;do
      BLOCKCOUNT=$(cat ${INITRD_NAME} | cpio -tdmv 2>&1 >/dev/null | awk 'END{print $1}')
      dd if=${INITRD_NAME} of=${INITRD_NAME}${COUNTER} bs=512 skip=${BLOCKCOUNT}
      INITRD_NAME=${INITRD_NAME}${COUNTER} 
    done
  fi
  mkdir initrd_files
  cd initrd_files
  cat ../${INITRD_NAME} | lz4 -d - | cpio -i -d
fi

exit 0
