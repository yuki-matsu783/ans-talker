#!/usr/bin/env bash
#
# findings に「正解のコード片・正解にしか存在しない識別子」が混入していないかを機械的に検査し、
# 混入した finding を投稿対象から落とす（issue #1）。
#
# 使い方:
#   answer-talker-spoiler-check.sh --findings <findings.json> --reference-root <正解ルート> \
#       --diff <diff.json> --out <検査後findings.json> [--submission-root <受講者ルート>]
#     → {"kept":N,"dropped":M,"materialScope":"full"|"diff","forbiddenCount":K,
#        "subtractedBySubmission":S,"drops":[{"title":"…","words":["…"]}]}
#
# `--submission-root` を渡すと、差し引く材料が「受講者diffに現れる語」から
# 「受講者ソース全体に現れる語」へ広がる（issue #6）。**これは任意の改善ではなく必須の追随**で、
# 渡さないままサブエージェントへ受講者ソースを見せると、hunkに現れない受講者ファイルに基づく
# 指摘だけが選択的に drop される（詳細は main 内のコメント）。どちらで動いたかは
# `materialScope` で返す。
#
# 設計上の要点（issue #1。正史は .claude/docs/spec/answer-talker.md）:
#
#   禁止語 = (正解ファイルの識別子) − (受講者diffに現れる語) − (除外語) − (3文字以下)
#   混入   = findings本文に、禁止語のいずれかが**単語境界**で現れる
#
#   - **誤検知の側へ倒す**（flow-id 3-4で合意）。正当な指摘を落としてでも、転記の見逃しを避ける。
#     演習でのネタバレは一度起きたら取り消せない一方、指摘を1件落としても他の指摘は残るため。
#   - ただし**識別子は分割しない**（`snake_case` をバラすと `user` のような一般語が禁止語に入り、
#     ほぼすべての指摘が落ちて実用にならない）。ここは意図的に厳しくしない。
#   - **受講者diffに現れる語を引く**のが誤検知を減らす主な働き。受講者が自分で書いている語は、
#     指摘本文に出てもネタバレではない。
#   - 落とすのは該当 finding のみ（全体中止にしない）。**落とした件数と反応した語を必ず返す**。
#     この方針は「指摘が落ちすぎて実質何も出なくなる」壊れ方をするため、可視化が無いと気づけない。
#
# 規約: .claude/rules/shell-script-style.md（set -euo pipefail / jq前提 / ループ内で外部コマンドを
# 呼ばない）
set -euo pipefail

# 禁止語から除外する語（言語のキーワード＋ごく一般的な英単語）。
# **スクリプト内の定数として持つ。** 除外語は演習課題ごとに変わらないため、外部ファイルにすると
# 「利用者がファイルを用意しないと動かない」という失敗経路が増えるだけになる。
# 言語ごとに分けない（`func` がGoでもJavaScriptでも予約語であることに違いはない）。
# 足りなければ足す方針で、最初から網羅しようとしない。
readonly -a ATR_STOPWORDS=(
  # 制御構造・宣言
  func function def class struct interface enum type var let const static public private protected
  return yield await async import export from package module namespace using include require
  if else elif then fi for while do done switch case default break continue goto
  try catch finally throw throws raise except with defer panic recover
  new delete this self super base null nil none true false void nan
  # 型・組み込み
  int int8 int16 int32 int64 uint uint8 uint16 uint32 uint64 float float32 float64 double
  bool boolean byte char string str bytes list dict map set array slice tuple object any
  error err errors exception result option some ok none
  # よく使う語
  main init start stop run exec call get set add remove update delete create read write
  open close load save parse format print printf println log logger debug info warn warning fatal
  test tests spec mock stub fake sample example fixture
  name names value values key keys item items data input output result results
  file files path paths dir directory root base src source target dest destination
  config configuration setting settings option options args argv params param
  handler handlers service services repository repositories controller model view
  client server request response req res ctx context cancel timeout retry
  user users id ids index idx count total length size len num number
  echo printf export local readonly shift unset eval trap exit
)

# 文字列から識別子だけを取り出し、1行1語で標準出力へ返す。
# 呼び出し側でまとめて1回だけ使うこと（ファイルごとに呼ばない）。
extract_identifiers() {
  grep -ohE '[A-Za-z_][A-Za-z0-9_]*' || true
}

# 禁止語の集合を組み立て、連想配列 `ATR_FORBIDDEN` へ入れる。
#   $1 = 正解側の語（改行区切り）
#   $2 = 受講者側の語（改行区切り）
# 外部コマンドを呼ばない（差集合はbashの連想配列で取る）。
build_forbidden_set() {
  local reference_words="$1" submission_words="$2"
  local -A submission=() stop=()
  local word

  ATR_FORBIDDEN=()
  while IFS= read -r word; do
    [ -n "$word" ] || continue
    submission["$word"]=1
  done <<<"$submission_words"
  for word in "${ATR_STOPWORDS[@]}"; do
    stop["$word"]=1
  done

  while IFS= read -r word; do
    [ -n "$word" ] || continue
    # 3文字以下は落とす（`id` `db` `err` のような略語が入ると、ほぼすべての指摘が落ちるため）。
    [ "${#word}" -gt 3 ] || continue
    [ -z "${submission["$word"]:-}" ] || continue
    # 除外語の判定は小文字化して行う（`Return` `RETURN` も除外したい）。
    [ -z "${stop["${word,,}"]:-}" ] || continue
    ATR_FORBIDDEN["$word"]=1
  done <<<"$reference_words"
}

# 1件の finding の本文から、禁止語（`ATR_FORBIDDEN`）に一致する語を空白区切りで REPLY へ返す。
# **単語境界で判定する**（禁止語 `repo` が本文中の `repository` に含まれても混入としない）。
# 英数字とアンダースコア以外をすべて区切りへ置き換えることで、日本語に隣接する場合も正しく切れる。
# 外部コマンドを呼ばない。
find_leaked_words() {
  local text="${1:-}"
  local -a hits=()
  local -A seen=()
  local token
  # bashのパターン置換で「識別子を構成しない文字」を空白へ落とす。
  local normalized="${text//[^A-Za-z0-9_]/ }"
  for token in $normalized; do
    [ -n "${ATR_FORBIDDEN["$token"]:-}" ] || continue
    [ -z "${seen["$token"]:-}" ] || continue
    seen["$token"]=1
    hits+=("$token")
  done
  REPLY="${hits[*]}"
  [ "${#hits[@]}" -gt 0 ]
}

usage() {
  printf 'usage: answer-talker-spoiler-check.sh --findings <findings.json> \\\n' >&2
  printf '         --reference-root <正解ルート> --diff <diff.json> --out <検査後findings.json> \\\n' >&2
  printf '         [--submission-root <受講者ルート>]\n' >&2
}

main() {
  local findings_file="" root="" submission_root="" diff_file="" out_file=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --findings) findings_file="${2:-}"; shift 2 ;;
      --reference-root) root="${2:-}"; shift 2 ;;
      --submission-root) submission_root="${2:-}"; shift 2 ;;
      --diff) diff_file="${2:-}"; shift 2 ;;
      --out) out_file="${2:-}"; shift 2 ;;
      -h|--help) usage; return 2 ;;
      *) printf 'answer-talker-spoiler-check: 不明な引数: %s\n' "$1" >&2; usage; return 2 ;;
    esac
  done

  if [ -z "$findings_file" ] || [ ! -f "$findings_file" ]; then
    printf 'answer-talker-spoiler-check: --findings に既存のファイルを指定してください\n' >&2
    return 2
  fi
  if [ -z "$out_file" ]; then
    printf 'answer-talker-spoiler-check: --out は必須です\n' >&2
    return 2
  fi
  if [ -z "$root" ] || [ ! -d "$root" ]; then
    printf 'answer-talker-spoiler-check: --reference-root に既存のディレクトリを指定してください\n' >&2
    return 2
  fi
  # **存在しないパスを黙って無視しない。** 無視すると `materialScope` が `diff` へ戻り、
  # issue #6 で問題にした「新しく見えるようになったものについての指摘だけが選択的に落ちる」
  # 状態へ、呼び出し側が気づかないまま逆戻りする。
  if [ -n "$submission_root" ] && [ ! -d "$submission_root" ]; then
    printf 'answer-talker-spoiler-check: --submission-root に既存のディレクトリを指定してください\n' >&2
    return 2
  fi

  local reference_words submission_words
  # 正解側の識別子。ファイル数に比例して外部コマンドを起動しないよう、`grep -r` へ1回だけ通す。
  reference_words="$(grep -rohE --binary-files=without-match --exclude-dir=.git \
    '[A-Za-z_][A-Za-z0-9_]*' "$root" 2>/dev/null | sort -u || true)"
  # 受講者側の語。差分本文とパスの両方から取る（パスにも識別子が現れるため）。
  if [ -n "$diff_file" ] && [ -f "$diff_file" ]; then
    submission_words="$(jq -r '.files[] | .patch, .path, .oldPath' "$diff_file" \
      | extract_identifiers | sort -u || true)"
  else
    submission_words=""
  fi

  # **受講者ソース全体を差し引き集合へ加える（issue #6）。**
  #
  # これは任意の改善ではなく、**本変更に伴う必須の追随**である。差し引く材料が差分だけだと、
  # issue #6 の目的である「hunkに現れない受講者ファイルに基づく指摘」は、その識別子が
  # diffに現れないため差し引かれず、正解側に同名の識別子があれば**必ず禁止語に一致して
  # drop される**（実測で確認済み）。つまり受講者ソースを渡した瞬間、**新しく見えるように
  # なったものについての指摘だけが選択的に落ちる**。
  #
  # 見逃しは増えない。差し引かれるのは「受講者が自分のリポジトリに実際に書いている語」であり、
  # それが指摘本文に現れることは正解からの転記ではないため（DDR 0061 の「誤検知の側へ倒す」
  # という方針とは矛盾しない）。**ただしそれは、生成物・第三者コードを除外してあることが前提**
  # である（`answer-talker-submission.sh` が展開直後にツリーから削除している）。除外を怠ると、
  # 正解にしか無い識別子がたまたま依存ライブラリに含まれていればネタバレ検査を素通りする。
  local material_scope='diff' submission_source_words=""
  declare -gA ATR_FORBIDDEN=()

  # **禁止語の語数を可視化する。** このスクリプトは元々「指摘が落ちすぎて実質何も出なくなる」
  # 壊れ方に備えて drop 件数を返しているが、材料を広げたことで**逆方向の壊れ方**（差し引き
  # すぎて禁止語が消え、検査が実質無効になる）が生まれる。語数が無いと、`dropped: 0` が
  # 「転記が無かった」のか「禁止語が空だった」のかを区別できない。
  #
  # `subtractedBySubmission` は**受講者ソースを加えたことで禁止語から消えた語数**である。
  # `forbiddenCount` だけだと「元から少なかった」のか「広げた結果ここまで減った」のかが
  # 区別できず、材料の広げすぎに気づけない。差分だけの集合を一度組んでから広げて差を取る
  # （`build_forbidden_set` は外部コマンドを呼ばない純粋な処理なので、2回組んでもforkは増えない）。
  local forbidden_count subtracted_by_submission=0
  build_forbidden_set "$reference_words" "$submission_words"
  forbidden_count="${#ATR_FORBIDDEN[@]}"

  if [ -n "$submission_root" ] && [ -d "$submission_root" ]; then
    material_scope='full'
    submission_source_words="$(grep -rohE --binary-files=without-match --exclude-dir=.git \
      '[A-Za-z_][A-Za-z0-9_]*' "$submission_root" 2>/dev/null | sort -u || true)"
    if [ -n "$submission_words" ]; then
      submission_words="$(printf '%s\n%s\n' "$submission_words" "$submission_source_words" | sort -u)"
    else
      submission_words="$submission_source_words"
    fi
    build_forbidden_set "$reference_words" "$submission_words"
    subtracted_by_submission=$(( forbidden_count - ${#ATR_FORBIDDEN[@]} ))
    forbidden_count="${#ATR_FORBIDDEN[@]}"
  fi

  # findings を「連番<TAB>タイトル<TAB>本文（改行は空白へ）」の1行1件で受ける（jqの起動は1回）。
  local -a drop_index=() drop_title=() drop_words=()
  local line idx title body
  while IFS=$'\t' read -r idx title body; do
    [ -n "$idx" ] || continue
    if find_leaked_words "$title $body"; then
      drop_index+=("$idx")
      drop_title+=("$title")
      drop_words+=("$REPLY")
    fi
  done < <(jq -r '
      (.findings // []) | to_entries[]
      | [(.key | tostring), (.value.title // ""), ((.value.body // "") | gsub("[\n\t]"; " "))]
      | @tsv
    ' "$findings_file" | tr -d '\r')

  # 落とす対象の連番をまとめてjqへ渡し、残った findings を書き出す。
  # `--args` の直後に `--` を置く（値がハイフンで始まってもオプションと解釈させないため。
  # .claude/rules/shell-script-style.md「JSON操作」）。
  local drops_json='[]'
  if [ "${#drop_index[@]}" -gt 0 ]; then
    drops_json="$(jq -nc --args '[$ARGS.positional[] | tonumber]' -- "${drop_index[@]}" | tr -d '\r')"
  fi
  jq -c --argjson drop "$drops_json" \
    '{findings: [(.findings // []) | to_entries[] | select((.key | IN($drop[])) | not) | .value]}' \
    "$findings_file" | tr -d '\r' > "$out_file"

  # 報告用のサマリ。落とした件数と、反応した語を必ず返す。
  local -a report=()
  local i
  for i in "${!drop_index[@]}"; do
    report+=("${drop_title[$i]}" "${drop_words[$i]}")
  done
  local kept
  kept="$(jq -r '(.findings // []) | length' "$out_file" | tr -d '\r')"
  local summary_filter='
      {
        kept: $kept,
        dropped: $dropped,
        materialScope: $materialScope,
        forbiddenCount: $forbiddenCount,
        subtractedBySubmission: $subtractedBySubmission,
        drops: [
          range(0; ($ARGS.positional | length) / 2)
          | { title: $ARGS.positional[. * 2], words: ($ARGS.positional[. * 2 + 1] | split(" ")) }
        ]
      }
    '
  if [ "${#report[@]}" -gt 0 ]; then
    jq -nc --arg materialScope "$material_scope" \
      --argjson forbiddenCount "$forbidden_count" \
      --argjson subtractedBySubmission "$subtracted_by_submission" \
      --argjson kept "$kept" --argjson dropped "${#drop_index[@]}" \
      --args "$summary_filter" -- "${report[@]}" | tr -d '\r'
  else
    jq -nc --arg materialScope "$material_scope" \
      --argjson forbiddenCount "$forbidden_count" \
      --argjson subtractedBySubmission "$subtracted_by_submission" \
      --argjson kept "$kept" --argjson dropped 0 \
      --args "$summary_filter" -- | tr -d '\r'
  fi
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
