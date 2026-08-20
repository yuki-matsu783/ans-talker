#!/usr/bin/env bash
# 指定ディレクトリ配下を再帰的に走査し、YAML frontmatterのみを抽出する。
# markdownファイルが直下に存在するディレクトリ毎に、そのディレクトリ自身へ1行1JSONの
# index.jsonl を出力する（1回の実行で複数ファイルになりうる）。
# concept_id/directoryは、実行時に指定したディレクトリではなく常にgitリポジトリのルートからの
# 相対パスを基準にする（例: リポジトリルートで実行しても .claude/docs/ を指定して実行しても、
# .claude/docs/spec/shell-scripts.md のconcept_idは常に ".claude/docs/spec/shell-scripts"）。
# 使い方: extract-frontmatter.sh [--force] <directory>（リポジトリルートで "." を指定すると、
# markdownを含む全ディレクトリのindex.jsonlを一括生成できる）。
# YAML→JSON変換は、PATH上に`yq`（https://github.com/mikefarah/yq）があれば優先的に使い、
# 無ければ本リポジトリのfrontmatterスキーマに絞った自前の軽量パーサーへフォールバックする
# （yqを新規の必須外部依存にはしない）。
#
# 性能・中断耐性（issue #11）:
#   - git bash（MSYS）は外部プロセス起動が約95ms/回と重いため、jqの呼び出しを
#     「1ファイルあたり1回」に集約している。frontmatterの解析結果は中間表現（3要素組）として
#     シェル配列へ溜め、jqへ一度だけ渡す。ループ内でjqを呼び出す実装へ戻さないこと。
#   - mtimeが変わっていないファイルは既存のindex.jsonlの行をそのまま再利用する（--forceで無効化）。
#   - 出力は全走査完了後に一時ファイルへ書き、mvで差し替える（中断しても既存を壊さない）。
#
# 削除済みファイルの扱い（issue #117）:
#   列挙に使う `git ls-files --cached` は、削除したがまだステージしていない追跡ファイルも返す。
#   ワーキングツリーに実体が無いパスは走査対象から外す（インデックスからも消える）。
#   スキップ件数はサマリ行の skipped= に出る。
#
# 仕様: .claude/docs/spec/extract-frontmatter.md
set -euo pipefail

# 中間表現（FM_ITEMS）→ JSONオブジェクトへ変換するjqプログラム片。
# frontmatter_items_to_json と build_index_line の両方から参照する。
# 種別: s=スカラー文字列 / b=真偽値 / A=配列キーの初期化（空配列） / a=配列要素の追加
readonly JQ_FM_DEF='
def build_fm($p):
  reduce range(0; ($p | length); 3) as $i ({};
    $p[$i] as $kind
    | $p[$i + 1] as $key
    | $p[$i + 2] as $value
    | if $kind == "s" then .[$key] = $value
      elif $kind == "b" then .[$key] = ($value == "true")
      elif $kind == "A" then .[$key] = (.[$key] // [])
      else .[$key] = ((.[$key] // []) + [$value])
      end);
'

# jqへコマンドライン引数として渡す中間表現の上限バイト数。これを超える場合は一時ファイル経由へ
# フォールバックする（Windowsのコマンドライン長上限で jq: Argument list too long になるのを防ぐ。
# 詳細: .claude/rules/shell-script-style.md「JSON操作」）。
readonly ARGS_BYTES_LIMIT=24576

# 一時ファイルの掃除対象（中断時もtrapで確実に削除する）
TMP_FILES=()

# frontmatter解析結果の中間表現（3要素で1組）。parse_frontmatter_block が設定する。
FM_ITEMS=()

# 前後の空白を取り除く
trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# 前後がダブルクォートで囲まれていれば取り除く
unquote() {
  local s="$1"
  if [[ "$s" == \"*\" && "$s" == *\" && ${#s} -ge 2 ]]; then
    s="${s#\"}"
    s="${s%\"}"
  fi
  printf '%s' "$s"
}

# trim + unquote と同じ処理を行い、結果を標準出力ではなくグローバル変数 REPLY へ返す。
# `$(trim ...)` のようなコマンド置換は**呼び出しのたびにサブシェルをforkする**（git bashでは
# 数十msかかる）ため、1ファイルあたり十数回呼ばれる解析処理では致命的に遅くなる。解析の
# ホットパスからはこちらを使うこと（issue #11。trim/unquoteは公開関数として互換のため残す）。
trim_unquote_to_reply() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  if [[ "$s" == \"*\" && "$s" == *\" && ${#s} -ge 2 ]]; then
    s="${s#\"}"
    s="${s%\"}"
  fi
  REPLY="$s"
}

# unquote と同じ処理を行い、結果を REPLY へ返す（上と同じ理由）。
unquote_to_reply() {
  local s="$1"
  if [[ "$s" == \"*\" && "$s" == *\" && ${#s} -ge 2 ]]; then
    s="${s#\"}"
    s="${s%\"}"
  fi
  REPLY="$s"
}

# frontmatterの中身（区切り行 "---" を含まない）を標準出力へ返す。
# frontmatterが無ければ何も出力せず終了コード1を返す。
extract_frontmatter_block() {
  local file="$1"
  local first_line=""
  IFS= read -r first_line <"$file" || true
  first_line="${first_line%$'\r'}"
  if [[ "$first_line" != "---" ]]; then
    return 1
  fi

  local line_no=0
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    line_no=$((line_no + 1))
    line="${line%$'\r'}"
    if [[ $line_no -eq 1 ]]; then
      continue
    fi
    if [[ "$line" == "---" ]]; then
      return 0
    fi
    printf '%s\n' "$line"
  done <"$file"
  return 0
}

# 保留中のブロック配列をFM_ITEMSへ書き出す（parse_frontmatter_block専用の内部関数）。
_fm_flush_list() {
  if [[ -n "$_fm_list_key" ]]; then
    FM_ITEMS+=("A" "$_fm_list_key" "")
    local item
    for item in "${_fm_list_items[@]:-}"; do
      [[ -z "$item" ]] && continue
      FM_ITEMS+=("a" "$_fm_list_key" "$item")
    done
    _fm_list_key=""
    _fm_list_items=()
  fi
}

# 標準入力からfrontmatterブロック本文（区切り行を含まない）を読み、解析結果をグローバル配列
# FM_ITEMS へ「種別 キー 値」の3要素組で詰める。**外部プロセスを一切起動しない**。
# 単純なスカラー値・フロー配列 [a, b, c]・ブロック配列（改行+ "  - item"）のみに対応した
# 自前の軽量YAMLパーサー。フルYAML文法は非対応（本リポジトリのfrontmatterスキーマ専用。
# 詳細: .claude/rules/shell-script-style.md, .claude/rules/markdown-frontmatter.md）。
# パイプ（`... | parse_frontmatter_block`）で呼ぶとサブシェルになりFM_ITEMSが呼び出し元へ
# 伝わらないため、ヒアストリング（`parse_frontmatter_block <<<"$block"`）で呼ぶこと。
parse_frontmatter_block() {
  FM_ITEMS=()
  _fm_list_key=""
  _fm_list_items=()

  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^([A-Za-z0-9_]+):[[:space:]]*(.*)$ ]]; then
      _fm_flush_list
      local key="${BASH_REMATCH[1]}"
      local val="${BASH_REMATCH[2]}"
      if [[ -z "$val" ]]; then
        # 値が空 = 後続行のブロック配列（"  - item"）を期待する
        _fm_list_key="$key"
        continue
      fi
      if [[ "$val" == \[*\] ]]; then
        local inner="${val#\[}"
        inner="${inner%\]}"
        FM_ITEMS+=("A" "$key" "")
        # trを起動せず、カンマ区切りをbashだけで分解する
        while [[ "$inner" == *,* ]]; do
          trim_unquote_to_reply "${inner%%,*}"
          [[ -n "$REPLY" ]] && FM_ITEMS+=("a" "$key" "$REPLY")
          inner="${inner#*,}"
        done
        trim_unquote_to_reply "$inner"
        [[ -n "$REPLY" ]] && FM_ITEMS+=("a" "$key" "$REPLY")
      elif [[ "$val" == "true" || "$val" == "false" ]]; then
        FM_ITEMS+=("b" "$key" "$val")
      else
        unquote_to_reply "$val"
        FM_ITEMS+=("s" "$key" "$REPLY")
      fi
    elif [[ "$line" =~ ^[[:space:]]+-[[:space:]]*(.*)$ ]]; then
      trim_unquote_to_reply "${BASH_REMATCH[1]}"
      _fm_list_items+=("$REPLY")
    fi
  done
  _fm_flush_list
}

# FM_ITEMS を jq へ渡して、指定フィルタを1回だけ実行する。
# フィルタ内では `items`（中間表現の配列）と `build_fm(...)` を参照できる。
# $1: jqフィルタ。$2以降: jqへ渡す追加オプション（--arg 等）。
# 戻り値: jqの終了コードをそのまま返す（失敗を握りつぶさない。下記「終了コード」参照）。
run_fm_jq() {
  local filter="$1"
  shift

  local total=0 item
  for item in ${FM_ITEMS[@]+"${FM_ITEMS[@]}"}; do
    # 日本語等のマルチバイトを考慮し、文字数×3を上限見積もりに使う（保守的に大きく見る）
    total=$((total + ${#item} * 3 + 1))
  done

  local status=0
  if [[ $total -le $ARGS_BYTES_LIMIT ]]; then
    # フィルタの直後に `--` を置き、それ以降をすべて位置引数として扱わせる。これが無いと、
    # `-A` のようにハイフンで始まる中間表現の要素をjqがオプションとして解釈し
    # `jq: Unknown option -A` で失敗する（issue #69。`keywords: [git add, -A, pathspec]` で発生）。
    jq -nc "$@" --args "def items: \$ARGS.positional; ${JQ_FM_DEF} ${filter}" \
      -- ${FM_ITEMS[@]+"${FM_ITEMS[@]}"} || status=$?
    return "$status"
  fi

  # 引数長上限を超える巨大なfrontmatter向けのフォールバック（通常は通らない経路）。
  # 位置引数を使わないため、上記のハイフン問題の影響を受けない。
  local tmp
  tmp="$(mktemp)"
  TMP_FILES+=("$tmp")
  printf '%s\0' ${FM_ITEMS[@]+"${FM_ITEMS[@]}"} >"$tmp"
  jq -nc "$@" --rawfile fmraw "$tmp" \
    "def items: (\$fmraw | split(\"\\u0000\") | .[0:-1]); ${JQ_FM_DEF} ${filter}" || status=$?
  rm -f "$tmp"
  return "$status"
}

# FM_ITEMS をJSONオブジェクトへ変換する（jq 1回）。
frontmatter_items_to_json() {
  run_fm_jq 'build_fm(items)'
}

# 標準入力からfrontmatterブロック本文を読み、JSONオブジェクトを標準出力へ返す。
# yqが使えない環境向けのフォールバック実装（frontmatter_to_json参照）。
frontmatter_block_to_json() {
  parse_frontmatter_block
  frontmatter_items_to_json
}

# frontmatterをJSONへ変換する（公開関数）。frontmatterが無いファイルは文字列 "null" を返す。
# `yq`（https://github.com/mikefarah/yq）がPATH上にあれば優先的に使い、フルYAML文法への対応力を
# 上げる。無い、または変換に失敗した場合は自前の軽量パーサーへフォールバックする
# （yqを新規の必須外部依存にはしない）。
frontmatter_to_json() {
  local file="$1"
  local block
  if ! block="$(extract_frontmatter_block "$file")"; then
    echo "null"
    return 0
  fi

  if command -v yq >/dev/null 2>&1; then
    local yq_out
    if yq_out="$(printf '%s\n' "$block" | yq -o=json e '.' - 2>/dev/null)" && jq empty <<<"$yq_out" >/dev/null 2>&1; then
      echo "$yq_out"
      return 0
    fi
    # yqでの変換に失敗した場合は自前パーサーへフォールバックする
  fi

  parse_frontmatter_block <<<"$block"
  frontmatter_items_to_json
}

# index.jsonlの1行分（concept_id/directory/frontmatter/mtime）を組み立てて標準出力へ返す。
# jqの起動は1回だけ（frontmatterのJSON化と行の組み立てを同じ呼び出しで行う）。
# 引数: <ファイルパス> <concept_id> <directory> <mtime>
build_index_line() {
  local file="$1" concept_id="$2" directory="$3" mtime="$4"
  local block

  if ! block="$(extract_frontmatter_block "$file")"; then
    jq -nc --arg concept_id "$concept_id" --arg directory "$directory" --arg mtime "$mtime" \
      '{concept_id: $concept_id, directory: $directory, frontmatter: null, mtime: $mtime}'
    return 0
  fi

  if command -v yq >/dev/null 2>&1; then
    local yq_out
    if yq_out="$(printf '%s\n' "$block" | yq -o=json e '.' - 2>/dev/null)" && jq empty <<<"$yq_out" >/dev/null 2>&1; then
      jq -nc --arg concept_id "$concept_id" --arg directory "$directory" \
        --argjson frontmatter "$yq_out" --arg mtime "$mtime" \
        '{concept_id: $concept_id, directory: $directory, frontmatter: $frontmatter, mtime: $mtime}'
      return 0
    fi
  fi

  parse_frontmatter_block <<<"$block"
  run_fm_jq \
    '{concept_id: $concept_id, directory: $directory, frontmatter: build_fm(items), mtime: $mtime}' \
    --arg concept_id "$concept_id" --arg directory "$directory" --arg mtime "$mtime"
}

# gitリポジトリのルートを、MSYS形式（/c/...）に正規化して返す。
# `git rev-parse --show-toplevel`はWindowsドライブレター形式（C:/...）で返るため、
# `cd`してから`pwd`することで一貫したMSYS形式を取得する（実機確認済み）。
resolve_repo_root() {
  local start_dir="$1"
  (cd "$start_dir" && cd "$(git rev-parse --show-toplevel)" && pwd)
}

# 中断時も含め、書きかけの一時ファイルを必ず削除する
cleanup_tmp_files() {
  local f
  for f in ${TMP_FILES[@]+"${TMP_FILES[@]}"}; do
    [[ -n "$f" ]] && rm -f "$f" 2>/dev/null
  done
  return 0
}

usage() {
  cat >&2 <<'USAGE'
usage: extract-frontmatter.sh [--force] <directory>

  --force, -f   mtimeが変わっていないファイルもすべて再生成する（キャッシュを使わない）
USAGE
}

main() {
  trap cleanup_tmp_files EXIT INT TERM

  local force=0
  local target_dir=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -f | --force)
        force=1
        shift
        ;;
      -h | --help)
        usage
        return 0
        ;;
      --)
        shift
        ;;
      -*)
        echo "error: unknown option: $1" >&2
        usage
        return 1
        ;;
      *)
        if [[ -n "$target_dir" ]]; then
          echo "error: too many arguments: $1" >&2
          usage
          return 1
        fi
        target_dir="$1"
        shift
        ;;
    esac
  done

  if [[ -z "$target_dir" ]]; then
    usage
    return 1
  fi
  if [[ ! -d "$target_dir" ]]; then
    echo "error: directory not found: $target_dir" >&2
    return 1
  fi
  target_dir="${target_dir%/}"

  # スクリプト自身のmtime（index.jsonlより新しければキャッシュを自動的に無効化する）
  local script_path="${BASH_SOURCE[0]}"
  local script_dir="${script_path%/*}"
  [[ "$script_dir" == "$script_path" ]] && script_dir="."
  local script_epoch
  script_epoch="$(stat -c %Y "$(cd "$script_dir" && pwd)/${script_path##*/}")"

  local target_abs repo_root
  target_abs="$(cd "$target_dir" && pwd)"
  repo_root="$(resolve_repo_root "$target_dir")"
  # 以降はリポジトリルートを基準に動く。git ls-files の出力がそのままリポジトリルート相対の
  # パスになるため、1ファイルごとの realpath / dirname 起動が不要になる。
  cd "$repo_root"
  local target_rel="."
  if [[ "$target_abs" != "$repo_root" ]]; then
    target_rel="${target_abs#"$repo_root"/}"
  fi

  # 対象markdownの列挙（.gitignore対象は列挙されない。詳細:
  # .claude/docs/ddr/0016-frontmatterスクリプトの走査方式にgit-ls-filesを採用する.md）
  local -a files=()
  local f skipped=0
  while IFS= read -r -d '' f; do
    # `--cached` は「削除したがまだステージしていない」追跡ファイルも列挙する。実体が無いまま
    # 後続の stat へ渡すと `stat: cannot stat ...` で失敗し、xargs一括取得と1件ずつの再取得の
    # 両方が倒れて**走査全体が中断**する（無関係なディレクトリのindex.jsonlまで再生成されない）。
    # 削除済みのファイルはインデックスに載せるべきものでもないため、ここで落とす（issue #117。
    # `cleanup-task.sh` はコミットせずに削除するため、この状態が正常系として必ず発生する）。
    # `[[ -f ]]` はbash組み込みでforkを伴わない（`.claude/rules/shell-script-style.md`
    # 「外部プロセス起動のコスト」）。
    if [[ ! -f "$f" ]]; then
      skipped=$((skipped + 1))
      continue
    fi
    files+=("$f")
  done < <(git ls-files --cached --others --exclude-standard -z -- "$target_rel" | grep -z '\.md$' | sort -z -u)

  if [[ $skipped -gt 0 ]]; then
    echo "skipped $skipped deleted file(s) not present in the working tree" >&2
  fi

  if [[ ${#files[@]} -eq 0 ]]; then
    echo "no markdown files found under: $target_rel" >&2
    return 0
  fi

  # mtimeを一括取得する（1ファイルずつ stat / date を起動しない）
  local -a epochs=()
  local e
  while IFS= read -r e; do
    epochs+=("${e%$'\r'}")
  done < <(printf '%s\0' "${files[@]}" | xargs -0 stat -c '%Y')
  if [[ ${#epochs[@]} -ne ${#files[@]} ]]; then
    # 想定外（xargsの分割等）の場合は1件ずつ取り直す
    epochs=()
    for f in "${files[@]}"; do
      epochs+=("$(stat -c %Y "$f")")
    done
  fi

  # 出力先ごとの既存内容とキャッシュを読み込む
  local -A out_lines=()
  local -A out_existing=()
  local -A out_seen=()
  local -A cache_line=()
  local -A cache_mtime=()
  local -a out_files_existing=()
  local i dir out_file
  for ((i = 0; i < ${#files[@]}; i++)); do
    f="${files[$i]}"
    dir="${f%/*}"
    [[ "$dir" == "$f" ]] && dir="."
    out_file="$dir/index.jsonl"
    if [[ -z "${out_seen[$out_file]:-}" ]]; then
      out_seen[$out_file]=1
      [[ -f "$out_file" ]] && out_files_existing+=("$out_file")
    fi
  done

  local -A out_epoch=()
  if [[ ${#out_files_existing[@]} -gt 0 ]]; then
    local -a out_epochs=()
    while IFS= read -r e; do
      out_epochs+=("${e%$'\r'}")
    done < <(printf '%s\0' "${out_files_existing[@]}" | xargs -0 stat -c '%Y')
    for ((i = 0; i < ${#out_files_existing[@]}; i++)); do
      out_epoch[${out_files_existing[$i]}]="${out_epochs[$i]:-0}"
    done

    local content line cid
    for out_file in "${out_files_existing[@]}"; do
      content="$(<"$out_file")"
      out_existing[$out_file]="$content"
      # --force指定時、またはスクリプト自身の方が新しい場合はキャッシュを使わない
      if [[ $force -eq 1 ]] || [[ "${out_epoch[$out_file]:-0}" -lt "$script_epoch" ]]; then
        continue
      fi
      while IFS= read -r line; do
        [[ "$line" =~ \"concept_id\":\"([^\"]+)\" ]] || continue
        cid="${BASH_REMATCH[1]}"
        [[ "$line" =~ \"mtime\":\"([^\"]+)\" ]] || continue
        cache_line[$cid]="$line"
        cache_mtime[$cid]="${BASH_REMATCH[1]}"
      done <<<"$content"
    done
  fi

  # 1ファイルずつ、キャッシュヒットなら既存行を再利用し、ミスならjqを1回だけ起動して生成する
  local concept_id mtime out
  local reused=0 built=0 failed=0
  for ((i = 0; i < ${#files[@]}; i++)); do
    f="${files[$i]}"
    concept_id="${f%.md}"
    dir="${f%/*}"
    [[ "$dir" == "$f" ]] && dir="."
    out_file="$dir/index.jsonl"
    printf -v mtime '%(%Y-%m-%dT%H:%M:%S)T' "${epochs[$i]}"

    if [[ -n "${cache_line[$concept_id]:-}" && "${cache_mtime[$concept_id]:-}" == "$mtime" ]]; then
      out="${cache_line[$concept_id]}"
      reused=$((reused + 1))
    else
      # 生成に失敗したファイルは空行を書かずスキップし、ファイル名を標準エラーへ出したうえで
      # 最後に非ゼロ終了する（issue #69。以前はjqの失敗が握りつぶされ、index.jsonlへ空行が
      # 1行入るだけで終了コード0のまま完了していたため、欠落に気づけなかった）。
      if ! out="$(build_index_line "$f" "$concept_id" "$dir" "$mtime")"; then
        echo "error: failed to build index line: $f" >&2
        failed=$((failed + 1))
        continue
      fi
      # Windows版native jqバイナリは行末にCRを付与することがあるため取り除く（詳細:
      # .claude/rules/shell-script-style.md「文字コード」）
      out="${out//$'\r'/}"
      built=$((built + 1))
    fi
    out_lines[$out_file]+="$out"$'\n'
  done

  # 全走査が終わってから、一時ファイル経由で原子的に差し替える（中断しても既存を壊さない）
  local tmp
  local -a unchanged_files=()
  for out_file in "${!out_lines[@]}"; do
    if [[ "${out_existing[$out_file]+set}" == "set" && "${out_existing[$out_file]}" == "${out_lines[$out_file]%$'\n'}" ]]; then
      unchanged_files+=("$out_file")
      echo "unchanged: $out_file" >&2
      continue
    fi
    tmp="$out_file.tmp.$$"
    TMP_FILES+=("$tmp")
    printf '%s' "${out_lines[$out_file]}" >"$tmp"
    mv -f "$tmp" "$out_file"
    echo "wrote: $out_file" >&2
  done

  # 内容が変わらなかったindex.jsonlも「今の内容で最新である」ことを記録するためmtimeだけ更新する。
  # これをしないと、スクリプト自身のmtimeによるキャッシュ自動無効化（上記）が毎回成立してしまい、
  # 差分が無くても永久に全ファイル再生成され続ける（実機で確認済み。issue #11）。
  # gitはmtimeを見ないため、この更新でリポジトリに差分は生じない。
  if [[ ${#unchanged_files[@]} -gt 0 ]]; then
    printf '%s\0' "${unchanged_files[@]}" | xargs -0 touch
  fi

  echo "files=${#files[@]} built=$built reused=$reused failed=$failed skipped=$skipped" >&2

  # 1件でも生成に失敗していれば非ゼロで終了する（index.jsonl自体は生成できた分だけ書き出す）
  if [[ $failed -gt 0 ]]; then
    return 1
  fi
}

# 単体テスト（.claude/scripts/test/test_extract_frontmatter.sh）からsourceして関数のみ再利用できるよう、
# 直接実行された場合のみ main を呼ぶ。
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
