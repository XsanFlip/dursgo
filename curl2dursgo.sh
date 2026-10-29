#!/usr/bin/env bash
# ============================================================================
#  curl2dursgo.sh — tempel satu perintah cURL, config.yaml langsung terisi
#
#  Script ini membaca perintah cURL dari stdin (atau file), lalu mengekstrak:
#     - target (origin URL) dan seed_urls (URL lengkap yang di-paste)
#     - cookie sesi        -> authentication.cookie
#     - header auth/custom -> authentication.headers
#     - User-Agent         -> user_agent (top-level)
#     - basic auth (-u)    -> Authorization: Basic ...
#     - id user numerik (JWT / cookie) -> authentication.scan_idor
#  lalu menulis ulang HANYA key tersebut di config.yaml. Bagian lain
#  (ai.api_key, scanners_to_run, output, dll) tidak disentuh.
#
#  PEMAKAIAN
#     ./curl2dursgo.sh                 # tempel cURL, lalu Ctrl-D
#     ./curl2dursgo.sh req.txt         # baca dari file
#     xclip -o -selection clipboard | ./curl2dursgo.sh
#     ./curl2dursgo.sh --print         # tampilkan hasil, tidak menulis file
#     ./curl2dursgo.sh --run           # tulis config lalu jalankan ./dursgo
#
#  OPSI
#     -c, --config PATH    file config (default: ./config.yaml di direktori ini)
#     --target-mode MODE   origin (default) | url | host
#     --scan-idor N        paksa nilai scan_idor
#     --output FILE        set output.output_file
#     --minimal-headers    simpan hanya header yang berbau auth
#     --all-headers        simpan semua header non-noise (default)
#     --keep-form-login    pertahankan login_url/login_data lama di config
#     --no-verify          lewati pengecekan HTTP ke target
#     --no-backup          jangan buat config.yaml.bak
#     --print, --dry-run   jangan tulis config
#     --run                jalankan ./dursgo setelah config ditulis
#     -h, --help
#
#  Catatan: dursgo selalu membaca "config.yaml" dari direktori kerja saat
#  binary dijalankan, jadi jalankan script ini di folder yang sama dengan
#  binary dursgo (atau pakai -c untuk menunjuk file lain).
# ============================================================================
set -u
shopt -s extglob nocasematch

CONFIG_FILE="${PWD}/config.yaml"
DO_WRITE=1
DO_VERIFY=1
DO_RUN=0
DO_BACKUP=1
TARGET_MODE="origin"
MINIMAL_HEADERS=0
KEEP_FORM_LOGIN=0
FORCE_IDOR=""
OUTPUT_FILE=""
INPUT_FILE=""
INPUT_TEXT=""

die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
warn() { printf 'WARN : %s\n' "$*" >&2; }
info() { printf '%s\n' "$*"; }

usage() { sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; }

# ---------------------------------------------------------------- argumen ---
while (( $# )); do
  case $1 in
    -c|--config)       CONFIG_FILE=${2:-}; shift 2 2>/dev/null || shift;;
    --target-mode)     TARGET_MODE=${2:-}; shift 2 2>/dev/null || shift;;
    --scan-idor)       FORCE_IDOR=${2:-}; shift 2 2>/dev/null || shift;;
    --output)          OUTPUT_FILE=${2:-}; shift 2 2>/dev/null || shift;;
    --minimal-headers) MINIMAL_HEADERS=1; shift;;
    --all-headers)     MINIMAL_HEADERS=0; shift;;
    --keep-form-login) KEEP_FORM_LOGIN=1; shift;;
    --no-verify)       DO_VERIFY=0; shift;;
    --no-backup)       DO_BACKUP=0; shift;;
    --print|--dry-run) DO_WRITE=0; shift;;
    --run)             DO_RUN=1; shift;;
    -h|--help)         usage; exit 0;;
    --)                shift; break;;
    -*)                die "opsi tidak dikenal: $1 (lihat --help)";;
    *)                 INPUT_FILE=$1; shift;;
  esac
done

case $TARGET_MODE in
  origin|url|host) ;;
  *) die "--target-mode harus: origin | url | host";;
esac

# -------------------------------------------------------------- ambil input --
if [[ -n $INPUT_FILE ]]; then
  [[ -f $INPUT_FILE ]] || die "file tidak ditemukan: $INPUT_FILE"
  INPUT_TEXT=$(cat -- "$INPUT_FILE")
elif [[ ! -t 0 ]]; then
  INPUT_TEXT=$(cat)
elif (( $# )); then
  INPUT_TEXT="$*"
else
  cat <<'EOF'
Tempel perintah cURL Anda di bawah ini, lalu tekan Enter dan Ctrl-D:

EOF
  INPUT_TEXT=$(cat)
fi

[[ -n ${INPUT_TEXT//[[:space:]]/} ]] || die "tidak ada input (cURL kosong)"

# --------------------------------------------------------------- normalisasi -
# Gabungkan baris yang diakhiri "\" (copy as cURL), buang \r, buang prompt "$ ".
normalize_input() {
  local raw=$1 line buf="" bs='\'
  while IFS= read -r line; do
    line=${line%$'\r'}
    while [[ $line == '$ '* || $line == '> '* || $line == '% '* ]]; do line=${line:2}; done
    [[ -z $buf && ! $line =~ [^[:space:]] ]] && continue
    line=${line%%+([[:space:]])}
    if [[ ${line: -1} == "$bs" ]]; then
      buf+="${line:0:${#line}-1} "
      continue
    fi
    buf+="$line"
    break
  done <<< "$raw"
  printf '%s' "$buf"
}

# ------------------------------------------------------------------ tokenizer -
# Pisahkan perintah jadi token, menghormati kutip tunggal/ganda dan backslash.
TOKENS=()
tokenize() {
  local s=$1
  local i=0 n=${#s} c cur="" started=0 inq=""
  TOKENS=()
  while (( i < n )); do
    c=${s:i:1}
    if [[ $inq == "'" ]]; then
      if [[ $c == "'" ]]; then inq=""; else cur+=$c; fi
    elif [[ $inq == '"' ]]; then
      if [[ $c == '"' ]]; then inq=""
      elif [[ $c == '\' ]]; then i=$((i+1)); cur+=${s:i:1}
      else cur+=$c; fi
    else
      case $c in
        ' '|$'\t'|$'\n')
          if (( started )); then TOKENS+=("$cur"); cur=""; started=0; fi ;;
        "'"|'"') inq=$c; started=1 ;;
        '\') i=$((i+1)); cur+=${s:i:1}; started=1 ;;
        *) cur+=$c; started=1 ;;
      esac
    fi
    i=$((i+1))
  done
  (( started )) && TOKENS+=("$cur")
  return 0
}

# ------------------------------------------------------------------ ekstraksi -
url=""
method="GET"
data=""
ua=""
cookie=""
referer=""
credentials=""
declare -A headers=()
declare -a dropped=()

trim() {
  local v=$1
  v=${v#"${v%%[![:space:]]*}"}
  v=${v%"${v##*[![:space:]]}"}
  printf '%s' "$v"
}
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

add_cookie_arg() {
  local v=$1
  if [[ $v == @* || -f $v ]]; then
    local f=${v#@}
    if [[ -f $f ]]; then
      local l f1 f6 f7 out=""
      while IFS=$'\t' read -r f1 _ _ _ _ f6 f7 _; do
        [[ -z ${f1:-} || $f1 == '#'* ]] && continue
        if [[ -n ${f7:-} ]]; then out+="${f6}=${f7}; "; else out+="$f1; "; fi
      done < "$f"
      cookie+="${out%'; '}; "
      return
    fi
  fi
  cookie+="${v%; }; "
}

# header yang jelas milik browser, bukan sesi -> dibuang
is_noise_header() {
  case $(lower "$1") in
    accept|accept-charset|accept-encoding|accept-language|cache-control|connection) return 0;;
    content-length|content-type|content-encoding|content-disposition|dnt|expect)   return 0;;
    host|origin|pragma|priority|referer|te|trailer|upgrade-insecure-requests)       return 0;;
    if-none-match|if-modified-since|if-range|range|x-requested-with|authority)      return 0;;
    sec-fetch-*|sec-ch-ua*|sec-gpc|sec-websocket-*)                                 return 0;;
    ':authority'|':method'|':path'|':scheme'|'*')                                   return 0;;
  esac
  return 1
}

parse_header() {
  local raw=$1 k v lk
  [[ $raw == *:* ]] || return 0
  k=$(trim "${raw%%:*}")
  v=$(trim "${raw#*:}")
  [[ -z $k ]] && return 0
  lk=$(lower "$k")
  case $lk in
    cookie)     add_cookie_arg "$v"; return 0;;
    user-agent) ua=$v; return 0;;
  esac
  if is_noise_header "$k"; then dropped+=("$k"); return 0; fi
  if (( MINIMAL_HEADERS )); then
    case $lk in
      *auth*|*token*|*key*|*session*|*csrf*|*sid*|*api*) ;;
      *) dropped+=("$k"); return 0;;
    esac
  fi
  headers["$k"]=$v
}

NORM=$(normalize_input "$INPUT_TEXT")
tokenize "$NORM"
ARGS=("${TOKENS[@]}")

i=0
while (( i < ${#ARGS[@]} )); do
  a=${ARGS[i]}
  case $a in
    -X|--request)      method=${ARGS[i+1]:-GET};              i=$((i+2));;
    -H|--header)       parse_header "${ARGS[i+1]:-}";         i=$((i+2));;
    -b|--cookie)       add_cookie_arg "${ARGS[i+1]:-}";       i=$((i+2));;
    -A|--user-agent)   ua=${ARGS[i+1]:-};                     i=$((i+2));;
    -e|--referer|--referrer) referer=${ARGS[i+1]:-};          i=$((i+2));;
    -u|--user)         credentials=${ARGS[i+1]:-};            i=$((i+2));;
    -d|--data|--data-raw|--data-binary|--data-ascii|--data-urlencode)
                       data+="${data:+&}${ARGS[i+1]:-}";      i=$((i+2));;
    --url)             url=${ARGS[i+1]:-};                    i=$((i+2));;
    -F|--form|--form-string|-T|--upload-file|-o|--output|-w|--write-out) i=$((i+2));;
    -x|--proxy|--proxy-user|--resolve|-c|--cookie-jar|--connect-timeout) i=$((i+2));;
    -m|--max-time|--retry|--retry-delay|--limit-rate|--cert|--key)       i=$((i+2));;
    curl)              i=$((i+1));;
    -*)                i=$((i+1));;
    *)                 [[ -z $url ]] && url=$a; i=$((i+1));;
  esac
done

# -u user:pass -> Authorization: Basic
if [[ -n $credentials ]]; then
  BASIC=$(printf '%s' "$credentials" | base64 | tr -d '\n')
  headers["Authorization"]="Basic ${BASIC}"
fi

[[ -n $url ]] || die "URL tidak ditemukan di perintah cURL"
[[ $url =~ ^https?:// ]] || die "URL bukan http/https: $url"

cookie=${cookie%; }
[[ -n $referer ]] && info "referer terdeteksi (tidak dimasukkan ke config): $referer"

# --------------------------------------------------------------- target URL --
case $TARGET_MODE in
  url)    target=$url;;
  host)   target=${url#*://}; target=${target%%/*};;
  *)      target=${url%%\?*};;   # origin dihitung di bawah
esac
if [[ $TARGET_MODE == origin ]]; then
  if [[ $url =~ ^(https?://[^/?#]+) ]]; then target=${BASH_REMATCH[1]}; else target=$url; fi
fi

# ------------------------------------------------------- deteksi id user -----
b64d() {
  local p=$1 pad
  pad=$(( (4 - ${#p} % 4) % 4 ))
  if (( pad )); then p+=$(printf '=%.0s' $(seq 1 $pad)); fi
  printf '%s' "$p" | tr '_-' '/+' | base64 -d 2>/dev/null
}

detect_idor() {
  local blob id
  # 1) cookie numerik: user_id=123, uid=5, id=42 ...
  if [[ $cookie =~ (^|;\ *)((user|usr|customer|member)?[_-]?id|uid|userid|user_id)[[:space:]]*=[[:space:]]*([0-9]{1,10})([[:space:]]*;|$) ]]; then
    id=${BASH_REMATCH[4]}; [[ $id != 0 ]] && { printf '%s' "$id"; return 0; }
  fi
  # 2) JWT payload (cookie atau header) yang memuat klaim id numerik
  blob="$cookie"
  for k in "${!headers[@]}"; do blob+=" ${headers[$k]}"; done
  if [[ $blob =~ (eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.) ]]; then
    local tok=${BASH_REMATCH[1]} payload dec
    payload=${tok#*.}; payload=${payload%%.*}
    dec=$(b64d "$payload")
    if [[ $dec =~ \"(sub|id|uid|userid|user_id|userId|customer_id)\"[[:space:]]*:[[:space:]]*\"?([0-9]{1,10}) ]]; then
      id=${BASH_REMATCH[2]}; [[ $id != 0 ]] && { printf '%s' "$id"; return 0; }
    fi
  fi
  return 1
}

if [[ -n $FORCE_IDOR ]]; then
  scan_idor=$FORCE_IDOR
elif scan_idor=$(detect_idor); then
  :
else
  scan_idor=""
fi

# ------------------------------------------------------------ bantu YAML -----
yaml_escape() {
  local v=$1
  v=${v//\\/\\\\}
  v=${v//\"/\\\"}
  printf '%s' "$v"
}
yaml_key() { [[ $1 =~ ^[A-Za-z0-9_.-]+$ ]] && printf '%s' "$1" || printf '"%s"' "$1"; }

HKEYS=()
if (( ${#headers[@]} )); then
  mapfile -t HKEYS < <(printf '%s\n' "${!headers[@]}" | LC_ALL=C sort)
fi

emit_seed_block() {
  printf 'seed_urls:\n  - "%s"\n' "$(yaml_escape "$url")"
}

emit_auth_block() {
  printf '# [curl2dursgo] dibuat %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
  printf 'authentication:\n'
  printf '  enabled: true\n'
  [[ -n $scan_idor ]] && printf '  scan_idor: %s\n' "$scan_idor"
  if [[ -n $cookie ]]; then
    printf '\n'
    printf '  cookie: "%s"\n' "$(yaml_escape "$cookie")"
  fi
  if (( ${#headers[@]} )); then
    printf '\n'
    printf '  headers:\n'
    local k
    for k in "${HKEYS[@]}"; do
      printf '    %s: "%s"\n' "$(yaml_key "$k")" "$(yaml_escape "${headers[$k]}")"
    done
  fi
  if (( KEEP_FORM_LOGIN )) && [[ -n $data ]]; then
    printf '\n'
    printf '  login_url: "%s"\n' "$(yaml_escape "$url")"
    printf '  login_method: "%s"\n' "${method:-POST}"
    printf '  login_data: "%s"\n' "$(yaml_escape "$data")"
  fi
}

# --------------------------------------------------------- tulis ulang file --
# ------------------------------- baca nilai lama yang perlu dipertahankan ----
OLD_IDOR=""
OLD_UA=""
IDOR_NOTE=""
KEPT=()
COMMENTS=()

prescan_auth() {
  local f=$1 line in_auth=0 seen=" " v
  OLD_IDOR=""; OLD_UA=""; KEPT=(); COMMENTS=()
  [[ -f $f ]] || return 0
  while IFS= read -r line || [[ -n $line ]]; do
    if (( ! in_auth )); then
      if [[ $line == user_agent:* && -z $OLD_UA ]]; then
        v=${line#user_agent:}; v=$(trim "$v"); v=${v#\"}; v=${v%\"}
        OLD_UA=$v
      fi
      [[ $line == authentication:* ]] && in_auth=1
      continue
    fi
    [[ $line =~ ^[A-Za-z0-9_]+: ]] && break
    if [[ $line =~ ^[[:space:]]+scan_idor[[:space:]]*:[[:space:]]*([0-9]+) ]]; then
      OLD_IDOR=${BASH_REMATCH[1]}
    elif [[ $line =~ ^[[:space:]]+(login_url|login_method|login_data|login_check_keyword)[[:space:]]*: ]]; then
      KEPT+=("$line")
    elif [[ $line =~ ^[[:space:]]*# ]]; then
      [[ $line == *'[curl2dursgo]'* ]] && continue
      [[ $seen == *"|$line|"* ]] && continue
      seen+="|$line|"
      COMMENTS+=("$line")
    fi
  done < "$f"
}

# ------------------------------------------------ tulis ulang file config ----
rewrite_config() {
  local src=$1 line
  local wrote_auth=0 wrote_target=0 wrote_ua=0 wrote_seed=0
  local skip_auth=0 skip_seed=0

  while IFS= read -r line || [[ -n $line ]]; do
    # --- penanda buatan script sendiri dibuang dulu (biar tidak menumpuk)
    [[ $line == *'[curl2dursgo]'* ]] && continue
    # --- sedang melewati blok seed_urls lama
    if (( skip_seed )); then
      if [[ $line =~ ^[[:space:]]+- ]]; then continue; else skip_seed=0; fi
    fi
    # --- sedang melewati blok authentication lama (dibuang, diganti baru)
    if (( skip_auth )); then
      if [[ $line =~ ^[A-Za-z0-9_]+: ]]; then
        skip_auth=0
      else
        continue
      fi
    fi

    # --- key yang dikelola script
    if [[ $line == seed_urls:* ]]; then
      if (( ! wrote_seed )); then wrote_seed=1; emit_seed_block; fi
      skip_seed=1
      continue
    fi
    if [[ $line == target:* ]]; then
      if (( ! wrote_target )); then
        wrote_target=1
        printf 'target: "%s"\n' "$(yaml_escape "$target")"
        if (( ! wrote_seed )); then wrote_seed=1; emit_seed_block; fi
      fi
      continue
    fi
    if [[ $line == user_agent:* ]]; then
      if (( ! wrote_ua )); then
        wrote_ua=1
        [[ -n $ua ]] && printf 'user_agent: "%s"\n' "$(yaml_escape "$ua")"
      fi
      continue
    fi
    if [[ $line == authentication:* ]]; then
      if (( ! wrote_auth )); then
        wrote_auth=1
        skip_auth=1
        emit_auth_block
        local k2
        if (( KEEP_FORM_LOGIN )) && (( ${#KEPT[@]} )); then
          for k2 in "${KEPT[@]}"; do printf '%s\n' "$k2"; done
        elif (( ${#KEPT[@]} )); then
          warn "login_* lama dibuang dari config (pakai --keep-form-login bila ingin dipertahankan)"
        fi
        if (( ${#COMMENTS[@]} )); then
          printf '\n'
          for k2 in "${COMMENTS[@]}"; do printf '%s\n' "$k2"; done
        fi
      fi
      continue
    fi

    printf '%s\n' "$line"
  done < "$src"

  (( wrote_target )) || printf 'target: "%s"\n' "$(yaml_escape "$target")"
  (( wrote_seed ))   || emit_seed_block
  if (( ! wrote_ua )) && [[ -n $ua ]]; then printf 'user_agent: "%s"\n' "$(yaml_escape "$ua")"; fi
  if (( ! wrote_auth )); then
    printf '\n'
    emit_auth_block
    local k3
    if (( KEEP_FORM_LOGIN )) && (( ${#KEPT[@]} )); then
      for k3 in "${KEPT[@]}"; do printf '%s\n' "$k3"; done
    fi
  fi
}

# ------------------------------------------------------------------ ringkasan -
cookie_names() {
  local c=$1 out="" part
  local -a parts
  IFS=';' read -ra parts <<< "$c"
  for part in "${parts[@]}"; do
    part=$(trim "$part")
    [[ -z $part ]] && continue
    out+="${part%%=*}, "
  done
  printf '%s' "${out%, }"
}

prescan_auth "$CONFIG_FILE"
if [[ -z $scan_idor && -n $OLD_IDOR ]]; then
  scan_idor=$OLD_IDOR
  IDOR_NOTE="dipertahankan dari config lama"
fi
UA_NOTE=""
if [[ -z $ua && -n $OLD_UA ]]; then
  ua=$OLD_UA
  UA_NOTE="dipertahankan dari config lama"
fi

printf '\n'
printf '  Target        : %s\n' "$target"
printf '  Seed URL      : %s\n' "$url"
printf '  Method        : %s%s\n' "$method" "$([[ -n $data ]] && printf ' (body %d byte)' "${#data}")"
if [[ -n $cookie ]]; then
  printf '  Cookie        : %d byte (%s)\n' "${#cookie}" "$(cookie_names "$cookie")"
else
  printf '  Cookie        : <tidak ada>\n'
fi
(( ${#headers[@]} )) && printf '  Auth header   : %s\n' "${HKEYS[*]}"
printf '  User-Agent    : %s%s\n' "${ua:-<tidak ada>}" "${UA_NOTE:+ ($UA_NOTE)}"
printf '  scan_idor     : %s%s\n' "${scan_idor:-<tidak terdeteksi>}" "${IDOR_NOTE:+ ($IDOR_NOTE)}"
(( ${#dropped[@]} )) && printf '  Header dibuang: %s\n' "${dropped[*]}"
printf '\n'

# --------------------------------------------------------------------- tulis --
tmp=$(mktemp "${CONFIG_FILE}.XXXXXX") || die "gagal membuat file sementara"
if [[ -f $CONFIG_FILE ]]; then
  rewrite_config "$CONFIG_FILE" > "$tmp" || die "gagal menulis config"
else
  stub=$(mktemp "${CONFIG_FILE}.stub.XXXXXX")
  printf '%s\n' \
    '# config.yaml dibuat oleh curl2dursgo.sh' \
    '# Panduan opsi autentikasi: lihat README-CONFIG.md' \
    'concurrency: 10' \
    'max_depth: 5' \
    "scanners_to_run: \"xss,sqli,lfi,openredirect,ssrf,exposed,idor,csrf,cmdinjection,ssti,securityheaders,cors,fileupload,bola,massassignment,graphql,blindssrf,domxss\"" \
    'oast: false' \
    'render_js: false' > "$stub"
  rewrite_config "$stub" > "$tmp" || die "gagal menulis config"
  rm -f "$stub"
fi

if (( ! DO_WRITE )); then
  printf '%s\n' '--- hasil (--print, file tidak diubah) -------------------------'
  cat "$tmp"
  rm -f "$tmp"
  exit 0
fi

if (( DO_BACKUP )) && [[ -f $CONFIG_FILE ]]; then
  cp -p "$CONFIG_FILE" "${CONFIG_FILE}.bak"
  info "backup  : ${CONFIG_FILE}.bak"
fi

mv -f "$tmp" "$CONFIG_FILE"
info "config  : $CONFIG_FILE  (diperbarui)"

if [[ -n $OUTPUT_FILE ]]; then
  sed -i "s|^\(  *\)output_file:.*|\1output_file: \"$(yaml_escape "$OUTPUT_FILE")\"|" "$CONFIG_FILE" 2>/dev/null \
    || warn "gagal set output_file, edit manual"
  info "output  : $OUTPUT_FILE"
fi

# ------------------------------------------------------------------- verifikasi
if (( DO_VERIFY )); then
  command -v curl >/dev/null || { warn "curl tidak ada, verifikasi dilewati"; exit 0; }
  probe() {  # $1 = 1 -> pakai auth, 0 -> anon
    local -a a=( -sS -o /dev/null --max-time 20 -w '%{http_code}|%{size_download}|%{redirect_url}' )
    (( $1 )) && [[ -n $cookie ]] && a+=( -H "Cookie: $cookie" )
    if (( $1 )); then
      if (( ${#HKEYS[@]} )); then
        local k; for k in "${HKEYS[@]}"; do a+=( -H "$k: ${headers[$k]}" ); done
      fi
      [[ -n $ua ]] && a+=( -A "$ua" )
      [[ -n $data && $method != GET ]] && a+=( -X "$method" --data-raw "$data" )
    fi
    curl "${a[@]}" "$url" 2>/dev/null || printf '000||'
  }
  IFS='|' read -r c_ok s_ok r_ok <<< "$(probe 1)"
  IFS='|' read -r c_an s_an r_an <<< "$(probe 0)"
  printf '  cek auth : HTTP %s (%s byte)%s\n' "$c_ok" "$s_ok" "${r_ok:+ -> $r_ok}"
  printf '  cek anon : HTTP %s (%s byte)%s\n' "$c_an" "$s_an" "${r_an:+ -> $r_an}"
  case $c_ok in
    2??|3??)
      if [[ $c_ok =~ ^3 && $r_ok =~ (login|signin|auth) ]]; then
        warn "sesi tampak kedaluwarsa: diarahkan ke halaman login ($r_ok)"
      elif [[ $c_ok == "$c_an" && $s_ok == "$s_an" ]]; then
        warn "respons auth == anon; cookie/header mungkin tidak berpengaruh pada endpoint ini"
      else
        info "sesi terlihat valid"
      fi;;
    401|403|419|440)
      warn "target menolak sesi (HTTP $c_ok) — ambil ulang cookie dari browser";;
    000) warn "tidak bisa menghubungi target (DNS/TLS/timeout)";;
    *)   warn "respons tak terduga: HTTP $c_ok";;
  esac
fi

if (( DO_RUN )); then
  if [[ -x ./dursgo ]]; then
    printf '\n'
    info "menjalankan: ./dursgo  (memakai $CONFIG_FILE)"
    exec ./dursgo
  else
    warn "binary ./dursgo tidak ada di direktori ini; jalankan manual"
  fi
fi
