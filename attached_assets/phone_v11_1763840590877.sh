#!/bin/bash
# phone_v12.sh - Full phone pull, generate v4-style PDF, snapshot archive, encrypt everything (PDF included) with single key
# Author: Kennedy (merged & final)
# Version: v12
set -euo pipefail

# ---------- CONFIG ----------
EVIDENCE_DIR="${EVIDENCE_DIR:-/home/kennedy/evidence}"
VENV_DIR="${VENV_DIR:-$HOME/forensics_venv_v12}"
TIMESTAMP=$(date +"%Y-%m-%d_%H%M%S")
mkdir -p "$EVIDENCE_DIR"

log(){ echo "$(date +"%F %T") - $*"; }
err(){ echo "ERROR: $*" >&2; exit 1; }

# ---------- REQUIREMENTS ----------
for cmd in adb openssl tar rsync python3 gpg; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd. Install it and re-run."
    exit 1
  fi
done

# ---------- Python venv & deps for PDF ----------
if [ ! -d "$VENV_DIR" ]; then
  log "Creating Python venv at $VENV_DIR"
  python3 -m venv "$VENV_DIR"
fi
# shellcheck source=/dev/null
source "$VENV_DIR/bin/activate"
pip install --upgrade pip >/dev/null
pip install reportlab Pillow PyPDF2 >/dev/null

# ---------- USER INPUT ----------
read -p "Enter Case ID: " CASE_ID
read -p "Enter Investigator Name: " INVESTIGATOR_NAME
read -p "Enter Investigator ID: " INVESTIGATOR_ID
read -p "Enter Job ID: " JOB_ID
read -p "Resume last acquisition? (y/N): " RESUME_ANS

if [[ "$RESUME_ANS" =~ ^[Yy]$ ]]; then
  CASE_FOLDER=$(ls -td "$EVIDENCE_DIR"/* 2>/dev/null | head -n1)
  [ -n "$CASE_FOLDER" ] || err "No previous case folder found to resume."
  log "Resuming into: $CASE_FOLDER"
else
  DEVICE_ID=$(adb devices | sed '1d' | awk '{print $1}' | head -n1)
  [ -n "$DEVICE_ID" ] || err "No ADB device detected. Enable USB debugging and reconnect."
  DEVICE_MODEL=$(adb -s "$DEVICE_ID" shell getprop ro.product.model | tr -d '\r' || echo "unknown")
  CASE_FOLDER="${EVIDENCE_DIR}/${DEVICE_ID}_${TIMESTAMP}"
  mkdir -p "$CASE_FOLDER"
fi

LOG_FILE="${CASE_FOLDER}/acquisition.log"
# route stdout/stderr to log file as well
exec > >(tee -a "$LOG_FILE") 2>&1

log "Starting acquisition for device: ${DEVICE_ID} (${DEVICE_MODEL})"
log "Evidence folder: ${CASE_FOLDER}"

# ---------- DEVICE PROFILE ----------
log "Collecting device metadata..."
adb -s "$DEVICE_ID" shell getprop > "${CASE_FOLDER}/device_properties.txt" 2>/dev/null || true
adb -s "$DEVICE_ID" shell date > "${CASE_FOLDER}/device_date.txt" 2>/dev/null || true
adb -s "$DEVICE_ID" shell dumpsys battery > "${CASE_FOLDER}/battery_status.txt" 2>/dev/null || true
adb -s "$DEVICE_ID" shell wm size > "${CASE_FOLDER}/screen_info.txt" 2>/dev/null || true
adb -s "$DEVICE_ID" shell ip addr show > "${CASE_FOLDER}/network_info.txt" 2>/dev/null || true
adb -s "$DEVICE_ID" shell pm list packages -f > "${CASE_FOLDER}/installed_packages.txt" 2>/dev/null || true
adb -s "$DEVICE_ID" shell df -h > "${CASE_FOLDER}/storage_info.txt" 2>/dev/null || true

# ---------- FULL LOGICAL PULL ----------
log "Pulling entire /sdcard (user storage) to ${CASE_FOLDER}/sdcard (may be large)..."
mkdir -p "${CASE_FOLDER}/sdcard"
adb -s "$DEVICE_ID" pull /sdcard "${CASE_FOLDER}/sdcard" || log "Warning: /sdcard pull had errors or incomplete."

# best-effort pulls of system areas (may be permission-limited)
log "Attempting to pull /system, /vendor, /etc (best-effort)..."
for p in /system /vendor /etc; do
  mkdir -p "${CASE_FOLDER}${p}"
  adb -s "$DEVICE_ID" pull "$p" "${CASE_FOLDER}${p}" 2>/dev/null || log "Could not pull $p (permission or not present)."
done

# ---------- APP PRIVATE DATA (best-effort) ----------
log "Attempting run-as backups for debuggable apps..."
mkdir -p "${CASE_FOLDER}/app_private"
PKGS=$(adb -s "$DEVICE_ID" shell pm list packages -3 | sed 's/package://g' | tr -d '\r' || true)
for p in $PKGS; do
  if adb -s "$DEVICE_ID" shell "run-as $p ls /data/data/$p 2>/dev/null" >/dev/null 2>&1; then
    log "run-as available for $p: archiving data..."
    adb -s "$DEVICE_ID" shell "run-as $p tar -C /data/data/$p -czf /data/local/tmp/${p}_data.tar.gz . 2>/dev/null" || true
    adb -s "$DEVICE_ID" pull "/data/local/tmp/${p}_data.tar.gz" "${CASE_FOLDER}/app_private/${p}_data.tar.gz" 2>/dev/null || true
    adb -s "$DEVICE_ID" shell "rm /data/local/tmp/${p}_data.tar.gz" 2>/dev/null || true
  fi
done

# attempt adb backup as fallback (may require device confirmation)
log "Attempting adb backup (may require device confirmation)..."
adb -s "$DEVICE_ID" backup -apk -all -f "${CASE_FOLDER}/adb_full_backup.ab" 2>/dev/null || log "adb backup failed or was declined by device."

# ---------- PHYSICAL IMAGING (requires root or TWRP) ----------
acquire_physical() {
  RAW_DIR="${CASE_FOLDER}/raw_images"
  mkdir -p "$RAW_DIR"
  if adb -s "$DEVICE_ID" shell id 2>/dev/null | grep -q "uid=0"; then
    log "Device is rooted — attempting userdata imaging."
    USERNODE=$(adb -s "$DEVICE_ID" shell "ls -l /dev/block/by-name 2>/dev/null | awk '/userdata/ {print \$NF; exit}'" | tr -d '\r' || true)
    if [ -n "$USERNODE" ]; then
      USERPATH=$(adb -s "$DEVICE_ID" shell "readlink -f ${USERNODE} || echo ${USERNODE}" | tr -d '\r')
      OUTIMG="${RAW_DIR}/${DEVICE_ID}_userdata_${TIMESTAMP}.img"
      log "Imaging ${USERPATH} -> ${OUTIMG} (may be large)..."
      adb -s "$DEVICE_ID" exec-out "su -c 'dd if=${USERPATH} bs=4096 2>/dev/null'" > "${OUTIMG}" || log "dd failed"
      if [ -f "${OUTIMG}" ]; then
        gzip -f "${OUTIMG}"
        sha256sum "${OUTIMG}.gz" > "${RAW_DIR}/userdata_img.sha256"
        log "Userdata image saved and hashed."
      fi
    else
      log "Could not detect userdata partition automatically. Consider booting TWRP and re-run."
      adb -s "$DEVICE_ID" shell "ls -l /dev/block/" | sed -n '1,200p' >> "${CASE_FOLDER}/block_devices_list.txt" || true
    fi
  else
    log "Device not rooted — skipping physical imaging (requires root or custom recovery)."
  fi
}
acquire_physical

# ---------- CARVING (optional host-side) ----------
CARVE_DIR="${CASE_FOLDER}/carved"
mkdir -p "$CARVE_DIR"
RAW_GZ=$(ls "${CASE_FOLDER}/raw_images"/*.img.gz 2>/dev/null | head -n1 || true)
if [ -n "$RAW_GZ" ]; then
  TMP_IMG="${CASE_FOLDER}/raw_images/decompressed_${TIMESTAMP}.img"
  log "Decompressing ${RAW_GZ} to ${TMP_IMG}"
  gzip -d -c "${RAW_GZ}" > "${TMP_IMG}" || { log "Decompress failed"; TMP_IMG=""; }
  if [ -n "$TMP_IMG" ] && [ -f "$TMP_IMG" ]; then
    if command -v foremost >/dev/null 2>&1; then
      log "Running foremost carve..."
      foremost -i "$TMP_IMG" -o "${CARVE_DIR}/foremost_out" || log "foremost finished with warnings"
    fi
    if command -v photorec >/dev/null 2>&1; then
      log "Running photorec carve (best-effort)..."
      mkdir -p "${CARVE_DIR}/photorec_out"
      photorec /d "${CARVE_DIR}/photorec_out" /cmd "$TMP_IMG" options,search >/dev/null 2>&1 || log "photorec attempted"
    fi
    if command -v scalpel >/dev/null 2>&1; then
      log "Running scalpel carve..."
      scalpel "$TMP_IMG" -o "${CARVE_DIR}/scalpel_out" || log "scalpel attempted"
    fi
    rm -f "$TMP_IMG" || true
  fi
else
  log "No raw image found — skipping carving."
fi

# ---------- HASHING ----------
log "Computing SHA256 hashes for all files (will include carved/raw if present)..."
find "${CASE_FOLDER}" -type f -not -name "*.enc" -not -name "decryption_key_*.txt" -print0 | xargs -0 -I{} sha256sum "{}" > "${CASE_FOLDER}/hashes.txt" || true
HASH_COUNT=$(wc -l < "${CASE_FOLDER}/hashes.txt" 2>/dev/null || echo 0)
log "Total hashed files: ${HASH_COUNT}"

# ---------- METADATA JSON ----------
python3 - <<PYTHON
import json, os
meta = {
  "case_id": "${CASE_ID}",
  "investigator": "${INVESTIGATOR_NAME}",
  "investigator_id": "${INVESTIGATOR_ID}",
  "job_id": "${JOB_ID}",
  "device_id": "${DEVICE_ID}",
  "device_model": "${DEVICE_MODEL}",
  "timestamp": "${TIMESTAMP}",
  "total_hashed_files": ${HASH_COUNT}
}
open(os.path.join("${CASE_FOLDER}", "metadata.json"), "w").write(json.dumps(meta, indent=2))
print("metadata.json written")
PYTHON

# ---------- CHAIN OF CUSTODY PDF (v4 layout, watermark & signature) ----------
log "Generating Chain of Custody PDF (v4 layout) ..."
PDF_PATH="${CASE_FOLDER}/${DEVICE_ID}_chain_of_custody_${TIMESTAMP}.pdf"

python3 - <<PYTHON
import os
from datetime import datetime
from reportlab.platypus import SimpleDocTemplate, Table, TableStyle, Paragraph, Spacer, PageBreak
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.pdfbase import pdfmetrics
from reportlab.lib import colors
from reportlab.lib.utils import ImageReader
from PIL import Image

case_id = "${CASE_ID}"
investigator_name = "${INVESTIGATOR_NAME}"
investigator_id = "${INVESTIGATOR_ID}"
job_id = "${JOB_ID}"
device_serial = "${DEVICE_ID}"
device_model = "${DEVICE_MODEL}"
timestamp = "${TIMESTAMP}"
CASE_FOLDER = "${CASE_FOLDER}"
hash_file = os.path.join(CASE_FOLDER, "hashes.txt")
output_pdf = "${PDF_PATH}"

# Register font if present
try:
    pdfmetrics.registerFont(TTFont('Courier', '/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf'))
    font_name = 'Courier'
except Exception:
    font_name = 'Helvetica'

styles = getSampleStyleSheet()
styles.add(ParagraphStyle(name='Center', alignment=1, fontName=font_name, fontSize=14))
styles.add(ParagraphStyle(name='Body', alignment=0, fontName=font_name, fontSize=10))

story = []
story.append(Paragraph("<b>CHAIN OF CUSTODY REPORT</b>", styles['Center']))
story.append(Spacer(1, 12))

metadata_data = [
    ["Case ID", case_id],
    ["Investigator Name", investigator_name],
    ["Investigator ID", investigator_id],
    ["Job ID", job_id],
    ["Device Serial Number", device_serial],
    ["Model", device_model]
]
metadata_table = Table(metadata_data, colWidths=[150, 250])
metadata_table.setStyle(TableStyle([
    ('ALIGN',(0,0),(0,-1),'RIGHT'),
    ('ALIGN',(1,0),(1,-1),'LEFT'),
    ('FONTNAME',(0,0),(-1,-1), font_name),
    ('FONTSIZE',(0,0),(-1,-1),11),
]))
story.append(metadata_table)
story.append(Spacer(1, 15))

table_data = [['Date/Time','Examiner Name','Action'],
              [datetime.now().strftime("%Y-%m-%d %H:%M:%S"), investigator_name, 'Initial Evidence Acquisition']]
t = Table(table_data, colWidths=[150,200,180])
t.setStyle(TableStyle([
    ('BACKGROUND',(0,0),(-1,0),colors.lightgrey),
    ('GRID',(0,0),(-1,-1),0.5,colors.black),
    ('FONTNAME',(0,0),(-1,-1), font_name)
]))
story.append(t)
story.append(Spacer(1,15))

ack = ("All evidence has been collected in accordance with forensic best practices. "
       "Hashes listed below verify the integrity of the acquired data.")
story.append(Paragraph(ack, styles['Body']))
story.append(Spacer(1,10))

if os.path.exists(hash_file):
    with open(hash_file) as f:
        hashes = f.readlines()
    total_hashes = len(hashes)
    if total_hashes <= 200:
        display_hashes = hashes
        story.append(Paragraph(f"<b>All File Hashes ({total_hashes} total):</b>", styles['Body']))
    else:
        display_hashes = hashes[:10]
        story.append(Paragraph(f"<b>Sample Hashes (10 of {total_hashes}):</b>", styles['Body']))
    story.append(Spacer(1,5))
    for line in display_hashes:
        story.append(Paragraph(line.strip(), styles['Body']))

story.append(PageBreak())
story.append(Paragraph("Signature: ________________________________", styles['Body']))

def watermark(canvas, doc):
    path = "/home/kennedy/Pictures/Wallpapers/kali-2014-orange2-1920x1080.png"
    if os.path.exists(path):
        try:
            img = Image.open(path).convert("RGBA")
            width, height = A4
            img = img.resize((int(width), int(height)))
            # make semi-transparent
            if img.mode == 'RGBA':
                alpha = img.split()[3].point(lambda p: int(p * 0.1))
                img.putalpha(alpha)
            temp = "/tmp/temp_wm.png"
            img.save(temp)
            canvas.drawImage(ImageReader(temp), 0, 0, width=width, height=height, mask='auto')
        except Exception:
            pass

doc = SimpleDocTemplate(output_pdf, pagesize=A4)
doc.build(story, onFirstPage=watermark, onLaterPages=watermark)
print("✅ PDF created:", output_pdf)
PYTHON

# verify pdf created
[ -f "$PDF_PATH" ] || err "PDF generation failed: $PDF_PATH"
log "PDF created: $PDF_PATH"

# ---------- SAFE STAGING for TAR ----------
STAGING="${CASE_FOLDER}/_staging_${TIMESTAMP}"
ARCHIVE="${CASE_FOLDER}/evidence_${TIMESTAMP}.tar.gz"
log "Creating stable staging copy at $STAGING"
mkdir -p "$STAGING"
# exclude previous archives, encrypted files, staging and decryption keys
rsync -a --exclude="*_staging_*" --exclude="*.tar.gz" --exclude="*.enc" --exclude="decryption_key_*.txt" --exclude="acquisition.log" "${CASE_FOLDER}/" "${STAGING}/"

log "Creating archive from staging: $ARCHIVE"
tar -C "$STAGING" -czf "$ARCHIVE" . || { rm -rf "$STAGING"; err "tar failed"; }

# cleanup staging
rm -rf "$STAGING"

# ---------- GENERATE STRONG SYMMETRIC KEY ----------
DECRYPTION_KEY_FILE="${CASE_FOLDER}/decryption_key_${TIMESTAMP}.txt"
log "Generating strong symmetric key and saving to ${DECRYPTION_KEY_FILE} (chmod 600)"
KEY_B64=$(openssl rand -base64 48)
printf "DO NOT LOSE THIS KEY - it decrypts the archive\n%s\n" "$KEY_B64" > "$DECRYPTION_KEY_FILE"
chmod 600 "$DECRYPTION_KEY_FILE"

# ---------- ENCRYPT THE ARCHIVE (OpenSSL AES-256-CBC PBKDF2) ----------
ENC_ARCHIVE="${ARCHIVE}.enc"
log "Encrypting archive with AES-256-CBC (pbkdf2)..."
PASSFILE=$(mktemp)
printf "%s" "$KEY_B64" > "$PASSFILE"
openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt -in "$ARCHIVE" -out "$ENC_ARCHIVE" -pass file:"$PASSFILE" || { shred -u "$PASSFILE" || rm -f "$PASSFILE"; err "encryption failed"; }
shred -u "$PASSFILE" || rm -f "$PASSFILE"
[ -f "$ENC_ARCHIVE" ] || err "Encrypted archive not found"

log "Encrypted archive created: $ENC_ARCHIVE"

# ---------- APPEND ENCRYPTED ARCHIVE HASH ----------
sha256sum "$ENC_ARCHIVE" >> "${CASE_FOLDER}/hashes.txt"
ENCRYPTED_HASH=$(sha256sum "$ENC_ARCHIVE" | awk '{print $1}')
log "Encrypted archive SHA256: $ENCRYPTED_HASH"

# ---------- SECURE CLEANUP: remove plaintext archive and optionally the plaintext evidence ----------
log "Securely removing plaintext archive and raw unencrypted files inside case folder (keeping only the encrypted archive, decryption key, hashes, metadata, and log)."
if command -v shred >/dev/null 2>&1; then
  shred -u "$ARCHIVE" || rm -f "$ARCHIVE"
else
  rm -f "$ARCHIVE"
fi

# Remove everything inside CASE_FOLDER except the encrypted archive, key, hashes, metadata, and log
log "Removing unencrypted files/folders inside case folder..."
shopt -s extglob
cd "${CASE_FOLDER}"
KEEP_LIST="$(basename "$ENC_ARCHIVE") $(basename "$DECRYPTION_KEY_FILE") acquisition.log hashes.txt metadata.json $(basename "$PDF_PATH")"
for f in *; do
  keep=0
  for k in $KEEP_LIST; do
    if [ "$f" = "$k" ]; then keep=1; break; fi
  done
  if [ "$keep" -eq 0 ]; then
    if [ -d "$f" ]; then
      if command -v shred >/dev/null 2>&1; then
        find "$f" -type f -exec shred -u {} \; 2>/dev/null || true
      fi
      rm -rf "$f"
    else
      if command -v shred >/dev/null 2>&1; then shred -u "$f" || rm -f "$f"; else rm -f "$f"; fi
    fi
  fi
done
shopt -u extglob
cd - >/dev/null || true

# NOTE: PDF is included in the encrypted archive already. If you want the readable PDF to be removed also, it already was removed above if not in KEEP_LIST.
# If you prefer the PDF NOT to be left in plaintext, ensure KEEP_LIST includes it. (Currently we keep the PDF file then remove it below to ensure encrypted copy only)
# remove plaintext pdf now so only encrypted archive contains it
if [ -f "$PDF_PATH" ]; then
  if command -v shred >/dev/null 2>&1; then shred -u "$PDF_PATH" || rm -f "$PDF_PATH"; else rm -f "$PDF_PATH"; fi
fi

# ---------- FINAL LISTING ----------
log "Final files remaining in case folder:"
ls -lah "${CASE_FOLDER}" | sed -n '1,200p'

log "Done. Encrypted evidence: ${ENC_ARCHIVE}"
log "Decryption key (base64) saved to: ${DECRYPTION_KEY_FILE} (chmod 600). BACKUP SECURELY."

echo
echo "To decrypt later:"
echo "  openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -in $(basename "$ENC_ARCHIVE") -out evidence_${TIMESTAMP}.tar.gz -pass file:$(basename "$DECRYPTION_KEY_FILE")"
echo "  tar -xzf evidence_${TIMESTAMP}.tar.gz -C /destination"
echo
exit 0
