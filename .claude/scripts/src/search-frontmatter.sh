#!/usr/bin/env bash
#
# リポジトリ内のmarkdownドキュメントを、frontmatterのindex.jsonlを使って横断検索する（issue #38）。
#
# `.claude/scripts/src/extract-frontmatter.sh` が **ディレクトリごとに** 出力している
# index.jsonl には、結合された単一のインデックスも検索の入口も無かった。そのため
# 「type: ddr のドキュメントを一覧したい」「tags に workflow を持つものを探したい」といった
# 探索が、そのつど grep / find による全文探索になっていた。このスクリプトは
#
#   1. index.jsonl の最新化（extract-frontmatter.sh の呼び出し）
#   2. リポジトリ内の全 index.jsonl の列挙・結合
#   3. jq による絞り込み・並び替え・出力形式の切り替え
#
# を1コマンドで行う。呼び出し側（AIエージェント）向けの手順・jqレシピは
# `.claude/skills/doc-search/SKILL.md`、仕様は `.claude/docs/spec/search-frontmatter.md`。
#
# 使い方:
#   search-frontmatter.sh [オプション]
#
# 出力: 検索結果をstdoutへ。件数サマリ（matched=N total=N）はstderrへ。
#
# 終了コード: 0=検索できた（0件でも0）／1=引数不正・検索不能。
#   「該当0件」を非0にしないのは、`set -e` 配下の呼び出し側が0件で止まらないようにするため
#   （check-base-conflicts.sh が「コンフリクトの有無」を終了コードで表さないのと同じ方針）。
#
# 規約: .claude/rules/shell-script-style.md
#   （set -euo pipefail / jq前提 / ループ内で外部コマンドを呼ばない / jq出力はtr -d '\r' を通す）
set -euo pipefail

# 探索から外すディレクトリ名。パスの構成要素がこのいずれかに一致したら、その index.jsonl は使わない。
#
# `.gemini` を外すのは、その配下（docs/hooks/rules/scripts/skills）が `.claude` 配下への
# ローカルリンク（シンボリックリンク、Windowsでは NTFS ジャンクション）であるため
# （.claude/docs/ddr/0017-gemini配下はGit管理下に置かずセットアップスクリプトで生成する.md）。
# ジャンクションは find からは通常のディレクトリに見えるため、外さないと同じドキュメントが
# `.claude/...` と `.gemini/...` の2通りの concept_id で二重にヒットする。
readonly SF_EXCLUDED_DIRS='.git node_modules build .gemini'

# 並び替えキー・出力形式として受け付ける値（jqプログラム側の分岐と対応させる）。
readonly SF_SORT_KEYS='path mtime type title'
readonly SF_FORMATS='table path json jsonl detail count'

usage() {
  cat >&2 <<'USAGE'
usage: search-frontmatter.sh [オプション]

  リポジトリ内のmarkdownを frontmatter の index.jsonl 経由で横断検索する。

絞り込み（同じオプションを繰り返すと OR、異なるオプション同士は AND）:
  --type <値>       frontmatter の type が一致（大文字小文字を無視した完全一致）
  --tag <値>        tags に含まれる（同上）
  --keyword <値>    keywords に含まれる（同上）
  --path <部分文字列>  concept_id（リポジトリルート基準の拡張子なしパス）に含まれる
  --text <部分文字列>  レコード全体（title/description/tags/keywords/パス等）に含まれる
  --since <ISO8601> mtime がこれ以上（例: 2026-08-01）
  --until <ISO8601> mtime がこれ以下（日付のみなら当日の 23:59:59 まで）

並び替え・件数:
  --sort <キー>     path（既定） | mtime | type | title
  --reverse, -r     並び順を逆にする（例: --sort mtime -r で更新が新しい順）
  --limit <N>       先頭N件だけ出力する（0以下・未指定なら全件）

出力・動作:
  --format <形式>   table（既定） | path | json | jsonl | detail | count
  --dir <パス>      このディレクトリ配下だけを対象にする（既定: リポジトリルート）。
                    **相対パスはカレントではなくリポジトリルート基準**で解決する
  --no-refresh      extract-frontmatter.sh による index.jsonl の最新化を行わない
  --quiet, -q       件数サマリ（stderr）を出さない
  -h, --help        この使い方を表示する

例:
  search-frontmatter.sh --type ddr --sort mtime -r
  search-frontmatter.sh --tag workflow --tag conflict --format path
  search-frontmatter.sh --text コンフリクト --format detail
USAGE
}

# ---------------------------------------------------------------------------
# 純粋関数（外部コマンドを呼ばない。.claude/scripts/test/test_search_frontmatter.sh の対象）
# ---------------------------------------------------------------------------

# 空白区切りの候補リスト $2 に値 $1 が含まれるかを返す。case のパターンマッチのみでforkしない。
sf_is_one_of() {
  local value="$1" candidates="$2"
  [ -n "$value" ] || return 1
  case " $candidates " in
    *" $value "*) return 0 ;;
  esac
  return 1
}

# index.jsonl のパス $1 が探索対象外かを返す（0=対象外）。
# 構成要素の完全一致で判定するため、前後を `/` で挟んでからグロブで照合する
# （`build` を外す際に `rebuild/` のようなディレクトリまで巻き込まないようにするため）。
sf_is_excluded_path() {
  local path="$1" dir
  [ -n "$path" ] || return 0
  # 先頭の "./" を落としてから前後に "/" を補う
  path="${path#./}"
  for dir in $SF_EXCLUDED_DIRS; do
    case "/$path/" in
      *"/$dir/"*) return 0 ;;
    esac
  done
  return 1
}

# 改行区切りのパス一覧を stdin から読み、対象外・空行を除いたものを stdout へ出す。
# 呼び出し側の `while read` ループから外部コマンドを追い出すための集約点。
sf_filter_index_paths() {
  local path
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    sf_is_excluded_path "$path" && continue
    printf '%s\n' "$path"
  done
}

# 配列を改行区切りの1つの文字列へ畳んで REPLY へ返す（jq へ --arg で渡すための形）。
# 要素が0個なら空文字列。jq 側は split("\n") 後に length > 0 で絞るため、空文字列は「指定なし」になる。
sf_join_lines_to_reply() {
  local IFS=$'\n'
  REPLY="$*"
}

# `--until` の値を REPLY へ正規化する。
# mtime は "2026-08-05T00:00:00" 形式で、比較は文字列の辞書順で行っている。そのため
# `--until 2026-08-05` をそのまま使うと "2026-08-05T00:00:00" > "2026-08-05" となり、
# **指定した当日に更新されたファイルが1件も残らない**（直感に反する）。日付だけが与えられた
# 場合は、その日の終わりまでを含む形へ補う。`--since` は日付だけでもその日の 00:00:00 以上に
# なるため補正不要。
sf_normalize_until_to_reply() {
  local value="$1"
  if [[ "$value" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    REPLY="${value}T23:59:59"
  else
    REPLY="$value"
  fi
}

# 値を取るオプションの引数を検証する。$2 には検証時点の `$#`、$3 には値（`${2-}`）を渡す。
#
# これが無いと2通りの形で無言の誤動作になる。
#   (1) 値の省略（`--type` で終端）… `shift 2` が失敗し `set -e` でシェルごと終了するため、
#       バリデーションにも `usage` にも到達せず、**何も出力しないまま exit 1** になる。
#   (2) 値の位置に別のオプション（`--type --quiet`）… `--quiet` が値として食われ、
#       `matched=0` の**正常終了**になる。タイプミスが「該当なし」と区別できない。
#
# 弾くのは `--` で始まる値だけにする。`--text -A` のように**ハイフン1つで始まる値**は
# 実在する検索語（`keywords: [git add, -A, pathspec]` 等）のため通す。
sf_validate_option_value() {
  local opt="$1" argc="$2" value="${3-}"
  if [ "$argc" -lt 2 ]; then
    echo "error: $opt には値が必要です" >&2
    return 1
  fi
  case "$value" in
    --*)
      echo "error: $opt の値がオプションのように見えます: $value（値を省略していませんか）" >&2
      return 1
      ;;
  esac
  return 0
}

# 並び替えキーの検証。不正なら使用可能な値を stderr へ出して 1 を返す。
sf_validate_sort() {
  if sf_is_one_of "$1" "$SF_SORT_KEYS"; then
    return 0
  fi
  echo "error: unknown --sort key: $1 (使える値: $SF_SORT_KEYS)" >&2
  return 1
}

# 出力形式の検証。
sf_validate_format() {
  if sf_is_one_of "$1" "$SF_FORMATS"; then
    return 0
  fi
  echo "error: unknown --format: $1 (使える値: $SF_FORMATS)" >&2
  return 1
}

# ---------------------------------------------------------------------------
# jqプログラム
# ---------------------------------------------------------------------------
#
# 絞り込み条件はすべて `--arg`（改行区切りの文字列）で渡し、jqプログラム自体は固定文字列にする。
# 利用者の入力でjqプログラムを組み立てると、`--text '"'` のような値でフィルタが壊れるため。
# `--arg` は値を必ず次の引数として読むので、`-A` のようにハイフンで始まる値も安全に渡せる
# （位置引数 `--args` の場合に必要な `--` の問題を避けられる。
#  .claude/rules/shell-script-style.md「JSON操作」）。
read -r -d '' SF_JQ_PROGRAM <<'JQ_EOF' || true
def vals($s): $s | split("\n") | map(select(length > 0) | ascii_downcase);
# 表形式の桁揃え用の「見た目の幅」。jqの length は Unicode のコードポイント数を返すため、
# 日本語（全角）を含む title / concept_id をそのまま使うと列がずれる。CJK・全角記号・ハングルの
# 範囲にある文字を幅2として数え直す（jqの文字列リテラル中の \uXXXX は実文字へ展開されるため、
# そのまま文字クラスの範囲指定として使える）。
def dwidth: length + ([scan("[\u1100-\u115f\u2e80-\ua4cf\uac00-\ud7a3\uf900-\ufaff\ufe30-\ufe6f\uff00-\uff60\uffe0-\uffe6]")] | length);
def pad($w): . + (($w - dwidth) as $n | if $n > 0 then " " * $n else "" end);

def fm: .frontmatter // {};
# 配列キーへのアクセサ。frontmatterは `tags: workflow` のようにリストで書かれていないことが
# ありえ（extract-frontmatter.sh はそれを文字列のままindexへ入れる）、本スクリプトは
# 「frontmatter規約違反の洗い出し」も用途に掲げているため、**規約違反のレコードが混ざった状態で
# 使われることが想定内**である。スカラーを配列へ包んで、どの出力形式でも落ちないようにする。
def arr_raw($k): (fm[$k] // []) | if type == "array" then map(tostring) else [tostring] end;
def arr($k): arr_raw($k) | map(ascii_downcase);
def str($k): (fm[$k] // "") | tostring;

def match_exact($needles; $haystack): ($needles | length) == 0 or any($needles[]; . as $n | $haystack | index($n) != null);
def match_sub($needles; $hay): ($needles | length) == 0 or (($hay | ascii_downcase) as $h | any($needles[]; . as $n | $h | contains($n)));

# `--text` の検索対象。レコードを `tostring` した**JSONテキスト全体**を対象にすると、値ではなく
# **キー名**に当たってしまい、`--text description` や `--text mtime` のような普通に打ちうる語で
# 実質全件がヒットする（しかも「それらしい件数」が返るため誤りに気づけない）。
# concept_id・mtime と、frontmatter配下の**値**だけを連結して対象にする（`..` はキーではなく
# 値をたどるため、ネストした配列の要素も拾える）。
def searchable_text:
  [(.concept_id // ""), (.mtime // "")]
  + [fm | .. | scalars | select(. != null) | tostring]
  | join(" ");

[inputs]
| unique_by(.concept_id)
| . as $all
| map(
    select(
      match_exact(vals($types);    [str("type") | ascii_downcase])
      and match_exact(vals($tags);     arr("tags"))
      and match_exact(vals($keywords); arr("keywords"))
      and match_sub(vals($paths); (.concept_id // ""))
      and match_sub(vals($texts); searchable_text)
      and ($since == "" or ((.mtime // "") >= $since))
      and ($until == "" or ((.mtime // "") <= $until))
    )
  )
| sort_by(
    if   $sort == "mtime" then [(.mtime // ""), (.concept_id // "")]
    elif $sort == "type"  then [(str("type")), (.concept_id // "")]
    elif $sort == "title" then [(str("title")), (.concept_id // "")]
    else [(.concept_id // "")] end
  )
| (if $reverse == "1" then reverse else . end)
# 絞り込みが「どれだけ効いたか」は --limit の打ち切り前の件数で数える。打ち切り後を matched と
# して報告すると、--limit 10 を付けた瞬間に常に matched=10 になり、まだ他に候補があるのか
# （もっと絞るべきか）を呼び出し側が判断できなくなる。
| . as $matched
| (if ($limit | tonumber) > 0 then .[0:($limit | tonumber)] else . end)
| . as $hits
| ($all | length) as $total
| ($matched | length) as $nmatched
| if $format == "count" then
    "matched=\($nmatched)"
    + (if ($hits | length) != $nmatched then " shown=\($hits | length)" else "" end)
    + " total=\($total)"
  elif $format == "path" then
    $hits[] | .concept_id
  elif $format == "jsonl" then
    $hits[] | tojson
  elif $format == "json" then
    $hits
  elif $format == "detail" then
    $hits[]
    | "- \(.concept_id)\n"
      + "  type       : \(str("type"))\n"
      + "  title      : \(str("title"))\n"
      + "  description: \(str("description"))\n"
      + "  tags       : \(arr_raw("tags") | join(", "))\n"
      + "  keywords   : \(arr_raw("keywords") | join(", "))\n"
      + "  mtime      : \(.mtime // "")"
  else
    ($hits | map(str("type") | dwidth) | max // 0) as $tw
    | ($hits | map(.concept_id // "" | dwidth) | max // 0) as $cw
    | $hits[]
    | "\(str("type") | pad($tw))  \(.concept_id // "" | pad($cw))  \(str("title"))"
  end
JQ_EOF

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

main() {
  local -a types=() tags=() keywords=() paths=() texts=() index_files=()
  local since_ts='' until_ts='' sort_key='path' format='table' target_dir='.'
  local reverse='0' limit='0' refresh=1 quiet=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      # 値を取るオプションは、検証を1箇所へ寄せるため入れ子の case で振り分ける
      --type | --tag | --keyword | --path | --text | --since | --until | --sort | --limit | \
        --format | --dir)
        sf_validate_option_value "$1" "$#" "${2-}" || return 1
        case "$1" in
          --type) types+=("$2") ;;
          --tag) tags+=("$2") ;;
          --keyword) keywords+=("$2") ;;
          --path) paths+=("$2") ;;
          --text) texts+=("$2") ;;
          --since) since_ts="$2" ;;
          --until) until_ts="$2" ;;
          --sort) sort_key="$2" ;;
          --limit) limit="$2" ;;
          --format) format="$2" ;;
          --dir) target_dir="$2" ;;
        esac
        shift 2
        ;;
      -r | --reverse) reverse='1'; shift ;;
      --no-refresh) refresh=0; shift ;;
      -q | --quiet) quiet=1; shift ;;
      -h | --help) usage; return 0 ;;
      *)
        echo "error: unknown option: $1" >&2
        usage
        return 1
        ;;
    esac
  done

  sf_validate_sort "$sort_key" || return 1
  sf_validate_format "$format" || return 1
  if [[ ! "$limit" =~ ^-?[0-9]+$ ]]; then
    echo "error: --limit は整数で指定する: $limit" >&2
    return 1
  fi

  # 以降はリポジトリルート基準の相対パスだけを扱う（realpath を使わずに済ませるため
  # 先に cd しておく。.claude/rules/shell-script-style.md「外部プロセス起動のコスト」）。
  local repo_root
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -z "$repo_root" ]; then
    echo "error: gitリポジトリの中で実行すること" >&2
    return 1
  fi
  cd "$repo_root"

  sf_normalize_until_to_reply "$until_ts"
  until_ts="$REPLY"

  target_dir="${target_dir%/}"
  [ -n "$target_dir" ] || target_dir='.'
  if [ ! -d "$target_dir" ]; then
    echo "error: ディレクトリが見つかりません: $target_dir" >&2
    echo "       （--dir はカレントではなくリポジトリルート $repo_root からの相対パスで解決します）" >&2
    return 1
  fi

  # 1. index.jsonl を最新化する。extract-frontmatter.sh は「1件でも行の生成に失敗したら非0」
  #    という規約のため、失敗しても検索自体は続行する（古いインデックスでも無いよりはよい）。
  if [ "$refresh" -eq 1 ]; then
    if ! bash .claude/scripts/src/extract-frontmatter.sh "$target_dir" >/dev/null 2>&1; then
      echo "warning: extract-frontmatter.sh が失敗した。既存の index.jsonl で検索を続行する" >&2
    fi
  fi

  # 2. index.jsonl を列挙する。`find` はGit管理の有無を見ないため、index.jsonl が
  #    Git管理下にある場合（issue #36以前）と .gitignore 対象の生成物である場合の双方で動く
  #    （`git ls-files` を使うと後者で1件も拾えない）。
  #
  #    受け口はコマンド置換ではなくプロセス置換にする。`$(...)` はNULを保持できず警告だけ出して
  #    捨てるため、この種の列挙をコマンド置換で受けてはいけない
  #    （.claude/rules/shell-script-style.md「コマンド置換とNULバイト」）。
  #    ここでは `-print0` ではなく `-print`（改行区切り）を使う。`git ls-files` と違い `find` は
  #    パスをクォート・8進エスケープしないため `-print0` の利点は「改行を含むパスを区別できる」
  #    ことだけだが、その区別は結局 `read -r` の行単位受けで失われる（`-print0 | tr '\0' '\n'`
  #    と書いても同じで、NUL指定が打ち消されるうえ `tr` の分だけforkが増える）。
  #    **ディレクトリ名に改行を含むリポジトリは対象外**という前提を明示して単純な形を採る
  #    （その場合はjqが開けないパスとして失敗するため、無言で誤った結果にはならない）。
  # prune 条件は SF_EXCLUDED_DIRS から組み立てる。走査打ち切り（find）と除外判定
  # （sf_filter_index_paths）でリストが二重管理になっていると、片方にだけ追記したときに
  # 「除外は効くが走査は続く」「specに書いていないディレクトリが黙って外れる」のどちらかになる。
  local dir
  local -a prune_args=()
  for dir in $SF_EXCLUDED_DIRS; do
    [ "${#prune_args[@]}" -eq 0 ] || prune_args+=(-o)
    prune_args+=(-name "$dir")
  done

  local path
  while IFS= read -r path; do
    index_files+=("$path")
  done < <(
    find "$target_dir" \( "${prune_args[@]}" \) -prune -o -name index.jsonl -print |
      sf_filter_index_paths
  )

  if [[ ${#index_files[@]} -eq 0 ]]; then
    echo "warning: index.jsonl が1件も見つからない（--no-refresh を外すか extract-frontmatter.sh を実行する）" >&2
    [ "$quiet" -eq 1 ] || echo "matched=0 total=0" >&2
    return 0
  fi

  # 3. 絞り込み・並び替え・整形。jq の起動は検索1回につき（サマリ用と合わせて）2回まで。
  local types_arg tags_arg keywords_arg paths_arg texts_arg
  sf_join_lines_to_reply ${types[@]+"${types[@]}"};    types_arg="$REPLY"
  sf_join_lines_to_reply ${tags[@]+"${tags[@]}"};      tags_arg="$REPLY"
  sf_join_lines_to_reply ${keywords[@]+"${keywords[@]}"}; keywords_arg="$REPLY"
  sf_join_lines_to_reply ${paths[@]+"${paths[@]}"};    paths_arg="$REPLY"
  sf_join_lines_to_reply ${texts[@]+"${texts[@]}"};    texts_arg="$REPLY"

  # Windowsネイティブのjqは出力行末へCRを付けることがあるため必ず落とす
  # （.claude/rules/shell-script-style.md「文字コード」）。
  jq -n -r \
    --arg types "$types_arg" \
    --arg tags "$tags_arg" \
    --arg keywords "$keywords_arg" \
    --arg paths "$paths_arg" \
    --arg texts "$texts_arg" \
    --arg since "$since_ts" \
    --arg until "$until_ts" \
    --arg sort "$sort_key" \
    --arg reverse "$reverse" \
    --arg limit "$limit" \
    --arg format "$format" \
    "$SF_JQ_PROGRAM" "${index_files[@]}" | tr -d '\r'

  # 件数サマリ。--format count と同じプログラムを使い回すため、集計ロジックは1箇所しかない。
  if [ "$quiet" -eq 0 ]; then
    local summary
    summary="$(jq -n -r \
      --arg types "$types_arg" --arg tags "$tags_arg" --arg keywords "$keywords_arg" \
      --arg paths "$paths_arg" --arg texts "$texts_arg" --arg since "$since_ts" --arg until "$until_ts" \
      --arg sort "$sort_key" --arg reverse "$reverse" --arg limit "$limit" --arg format count \
      "$SF_JQ_PROGRAM" "${index_files[@]}" | tr -d '\r')"
    echo "${summary:-matched=? total=?} indexes=${#index_files[@]}" >&2
  fi
}

# 単体テスト（.claude/scripts/test/test_search_frontmatter.sh）から source して純粋関数だけを
# 再利用できるよう、直接実行された場合のみ main を呼ぶ
# （.claude/rules/shell-script-style.md「テスト」）。
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
