#!/bin/bash
# botcheck.sh - botlist に追加すべき bot を探して検証する
#
#   ./botcheck.sh npub1... [npub2...]     指定したアカウントを判定
#   ./botcheck.sh -d nostrmag.com         ドメインの .well-known から列挙して判定
#   ./botcheck.sh -a                      botlist 収録 bot の全ドメインを巡回
#   ./botcheck.sh -a --add                「追加」判定を botlist.txt に追記し update.sh を実行
#
# 判定は次の順:
#   追加 = (kind 0 の bot フラグ | 指標が全閾値を下回る) かつ 直近 N 日に投稿あり
#   除外 = bot の証拠はあるが休眠 / 証拠なし
#   保留 = 活動中だが証拠が決定的でない (bot 運用者本人がここに来やすい)

set -uo pipefail

export PATH=$HOME/bin:$HOME/go/bin:$PATH
cd "$(dirname "$0")" || exit 1

RELAYS=${RELAYS:-"wss://yabu.me wss://relay-jp.nostr.wirednet.jp wss://nos.lol wss://relay.damus.io"}
UA='Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36'

DAYS=30          # これより古い最終投稿は休眠
TH_PREFIX=25     # テンプレ率 (%) の上限
TH_REPLY=5       # 返信率 (%) の上限
TH_N=20          # 指標で判定するのに必要な最低投稿数
LIMIT=50         # 取得する投稿数
JOBS=6           # 並列数

# well-known が巨大なブリッジ等、列挙対象から外すドメイン
EXCLUDE_DOMAINS=${EXCLUDE_DOMAINS:-"fedibird-com.mostr.pub"}

AUTO=0 ADD=0 SHOW_ALL=0 JSON=0
DOMAINS=() INPUTS=()

die() { echo "botcheck: $*" >&2; exit 1; }
usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [ $# -gt 0 ]; do
  case "$1" in
    -d|--domain)  DOMAINS+=("$2"); shift 2 ;;
    -a|--auto)    AUTO=1; shift ;;
    --add)        ADD=1; shift ;;
    --all)        SHOW_ALL=1; shift ;;
    --json)       JSON=1; shift ;;
    --days)       DAYS=$2; shift 2 ;;
    --prefix)     TH_PREFIX=$2; shift 2 ;;
    --reply)      TH_REPLY=$2; shift 2 ;;
    --min)        TH_N=$2; shift 2 ;;
    --limit)      LIMIT=$2; shift 2 ;;
    -j|--jobs)    JOBS=$2; shift 2 ;;
    -h|--help)    usage ;;
    -*)           die "不明なオプション: $1" ;;
    *)            INPUTS+=("$1"); shift ;;
  esac
done

for c in nak jq curl; do
  command -v "$c" >/dev/null 2>&1 || die "$c が必要です"
done
[ -f botlist.txt ] || die "botlist.txt が見つかりません"

TMP=$(mktemp -d) || die "作業ディレクトリを作れません"
trap 'rm -rf "$TMP"' EXIT

# ---- 既登録の pubkey ----
while read -r line; do
  [ -n "$line" ] || continue
  nak decode "$line" 2>/dev/null | tr -d '\n'; echo
done < botlist.txt | grep -E '^[0-9a-f]{64}$' | sort -u > "$TMP/known.txt"

# ---- 対象の収集 ----
: > "$TMP/targets.txt"

for in in ${INPUTS+"${INPUTS[@]}"}; do
  case "$in" in
    *@*) host=${in#*@}; name=${in%@*}; [ -n "$name" ] || name=_
         pk=$(curl -sS --max-time 15 -A "$UA" "https://$host/.well-known/nostr.json?name=$name" 2>/dev/null \
              | jq -r --arg n "$name" '.names[$n] // empty' 2>/dev/null) ;;
    *)   pk=$(nak decode "$in" 2>/dev/null | tr -d '\n') ;;
  esac
  if printf '%s' "$pk" | grep -qE '^[0-9a-f]{64}$'; then
    echo "$pk" >> "$TMP/targets.txt"
  else
    echo "解釈できない入力を無視: $in" >&2
  fi
done

if [ "$AUTO" = 1 ]; then
  ls npub1*.json >/dev/null 2>&1 || die "--auto にはプロフィール JSON が必要です (先に ./update.sh)"
  find . -maxdepth 1 -name 'npub1*.json' -size +0 -print0 \
    | xargs -0 jq -sr '.[]|select(type=="object")|.nip05//empty' 2>/dev/null \
    | sed 's/.*@//' | tr 'A-Z' 'a-z' | grep -v '^$' | sort -u > "$TMP/domains.txt"
  for d in $EXCLUDE_DOMAINS; do
    grep -vx "$d" "$TMP/domains.txt" > "$TMP/d2" && mv "$TMP/d2" "$TMP/domains.txt"
  done
  echo "巡回するドメイン: $(wc -l < "$TMP/domains.txt") 件" >&2
else
  : > "$TMP/domains.txt"
fi
for d in ${DOMAINS+"${DOMAINS[@]}"}; do echo "$d" | tr 'A-Z' 'a-z' >> "$TMP/domains.txt"; done
sort -u -o "$TMP/domains.txt" "$TMP/domains.txt"

while read -r d; do
  [ -n "$d" ] || continue
  body=$(curl -sS --max-time 20 -A "$UA" -H 'Accept: application/json' "https://$d/.well-known/nostr.json" 2>/dev/null)
  cnt=$(printf '%s' "$body" | jq -r '(.names//{})|length' 2>/dev/null)
  if [ -z "$cnt" ] || [ "$cnt" = "null" ]; then
    echo "well-known 取得失敗: $d" >&2
    continue
  fi
  echo "  $d: $cnt 件" >&2
  printf '%s' "$body" | jq -r '(.names//{})|.[]|select(test("^[0-9a-f]{64}$"))' 2>/dev/null \
    | tr 'A-Z' 'a-z' >> "$TMP/targets.txt"
done < "$TMP/domains.txt"

sort -u -o "$TMP/targets.txt" "$TMP/targets.txt"
[ -s "$TMP/targets.txt" ] || die "対象がありません"

if [ "$SHOW_ALL" = 1 ]; then
  cp "$TMP/targets.txt" "$TMP/cand.txt"
else
  comm -23 "$TMP/targets.txt" "$TMP/known.txt" > "$TMP/cand.txt"
fi
TOTAL=$(wc -l < "$TMP/cand.txt")
echo "判定対象: $TOTAL 件 (well-known/入力 $(wc -l < "$TMP/targets.txt") 件 - 登録済み)" >&2
[ "$TOTAL" -gt 0 ] || { echo "追加すべきアカウントはありません。" >&2; exit 0; }

# ---- 1件分の判定 ----
cat > "$TMP/one.sh" <<'ONE'
#!/bin/bash
export PATH=$HOME/bin:$HOME/go/bin:$PATH
pk=$1
prof=$(cat /dev/null | timeout 40 nak req -k 0 -a "$pk" $RELAYS 2>/dev/null \
       | jq -sc 'map(select(.content!=null))|sort_by(.created_at)|last // {}')
cat /dev/null | timeout 60 nak req -k 1 -a "$pk" -l "$LIMIT" $RELAYS 2>/dev/null \
  | jq -s --arg pk "$pk" --argjson prof "${prof:-{\}}" \
       --argjson now "$(date +%s)" --argjson days "$DAYS" \
       --argjson thp "$TH_PREFIX" --argjson thr "$TH_REPLY" --argjson thn "$TH_N" '
  ($prof.content // "{}" | fromjson? // {}) as $p |
  (map(select(.content != null and .content != "")) | unique_by(.id)) as $e |
  ($e | length) as $n |
  (if $n > 0 then ($e | map(.created_at) | max) else null end) as $last |
  {
    pubkey: $pk,
    name: ($p.display_name // $p.name // ""),
    nip05: ($p.nip05 // ""),
    botflag: (($p.bot == true) or ($p.bot == "true")),
    n: $n,
    prefix: (if $n > 0 then (($e|map(.content[0:30])|unique|length) / $n * 100 | round) else null end),
    sec:    (if $n > 0 then (($e|map(.created_at % 60)|unique|length) / $n * 100 | round) else null end),
    reply:  (if $n > 0 then (($e|map(select(.tags|any(.[0]=="e")))|length) / $n * 100 | round) else null end),
    clients: ($e | map(.tags[]? | select(.[0]=="client") | .[1]) | unique),
    days: (if $last then (($now - $last) / 86400 | floor) else null end)
  }
  | . + { active: (.days != null and .days <= $days),
          strong: (.n >= $thn and .prefix != null and .prefix <= $thp
                   and .reply != null and .reply <= $thr) }
  | . + { verdict:
      (if   (.botflag and .active)  then "追加"
       elif (.strong  and .active)  then "追加"
       elif ((.botflag or .strong) and (.active|not)) then "除外"
       elif .active                 then "保留"
       else                              "除外" end),
      why:
      (if   (.botflag and .active)  then "bot フラグ自己申告 + 活動中"
       elif (.strong  and .active)  then "指標が全閾値を下回る + 活動中"
       elif ((.botflag or .strong) and (.active|not))
            then "bot の証拠はあるが休眠(" + (if .days == null then "投稿なし" else (.days|tostring) + "日前" end) + ")"
       elif .active                 then "活動中だが証拠が決定的でない"
       else "休眠かつ証拠なし" end) }' -c
ONE
chmod +x "$TMP/one.sh"

export RELAYS LIMIT DAYS TH_PREFIX TH_REPLY TH_N
xargs -a "$TMP/cand.txt" -P "$JOBS" -I{} "$TMP/one.sh" {} 2>/dev/null > "$TMP/result.ndjson"

# ---- 出力 ----
if [ "$JSON" = 1 ]; then
  jq -s 'sort_by(.verdict, -.n)' "$TMP/result.ndjson"
else
  {
    printf '判定\tname\tnip05\t投稿\t最終\tテンプレ\t秒\t返信\tフラグ\tclient\t理由\n'
    jq -sr 'sort_by((if .verdict=="追加" then 0 elif .verdict=="保留" then 1 else 2 end), -.n)[]
      | [ .verdict,
          (if .name == "" then "-" else .name end),
          (if .nip05 == "" then "-" else .nip05 end),
          (.n|tostring),
          (if .days == null then "-" else (.days|tostring) + "d" end),
          (if .prefix == null then "-" else (.prefix|tostring) + "%" end),
          (if .sec == null then "-" else (.sec|tostring) + "%" end),
          (if .reply == null then "-" else (.reply|tostring) + "%" end),
          (if .botflag then "bot" else "-" end),
          (if (.clients|length) == 0 then "-" else (.clients|join(",")) end),
          .why ] | @tsv' "$TMP/result.ndjson"
  } | column -t -s$'\t'
fi

jq -r 'select(.verdict=="追加")|.pubkey' "$TMP/result.ndjson" > "$TMP/add_pk.txt"
NADD=$(wc -l < "$TMP/add_pk.txt")
echo >&2
jq -sr 'group_by(.verdict)[] | "\(.[0].verdict): \(length) 件"' "$TMP/result.ndjson" >&2

[ "$NADD" -gt 0 ] || exit 0
: > "$TMP/add_npub.txt"
while read -r pk; do nak encode npub "$pk" | tr -d '\n'; echo; done < "$TMP/add_pk.txt" >> "$TMP/add_npub.txt"

if [ "$ADD" = 1 ]; then
  cat "$TMP/add_npub.txt" >> botlist.txt
  sort -o botlist.txt botlist.txt
  echo >&2; echo "botlist.txt に $NADD 件追記しました。update.sh を実行します。" >&2
  ./update.sh
  echo "完了。git diff を確認してください。" >&2
else
  echo >&2; echo "--- 追加候補の npub ($NADD 件) --- (--add で botlist.txt に追記)" >&2
  cat "$TMP/add_npub.txt"
fi
