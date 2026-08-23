#!/usr/bin/env bash
#
# answer-talker スキルの「受講者ソース」を用意し、後始末する（issue #6）。
#
# 使い方:
#   answer-talker-submission.sh resolve --mr <番号> [--repo <URL|owner/repo>]
#                                       [--max-size-kb N] [--max-fetch-files N]
#                                       [--max-list-files N] [--timeout-sec N]
#     → {"stage":1|2|3,"root":"…"|null,"tmpdir":"…"|null,"fileCount":N,
#        "files":["…"],"truncated":bool,"degraded":bool,"reason":"…"}
#   answer-talker-submission.sh cleanup --tmpdir <パス>
#     → {"removed":true|false,"reason":"…"}
#
# 設計上の要点（issue #6。正史は .claude/docs/spec/answer-talker.md — フェーズ4で反映する）:
#
#   - **3段の縮退**。段1=アーカイブ1回、段2=tree列挙+ファイル単位、段3=hunkのみ。
#     `git clone` は採らない（`.git` の除去と資格情報供給という2つの追加作業が要るため）。
#   - **段3は「失敗」ではない。** `stage:3, degraded:true, root:null` を**終了コード0**で返す
#     （呼び出し側が `set -e` で落ちないように）。取得できないこと自体は想定内であり、
#     hunkだけで続行して報告する。
#   - **段2の対象パスをdiffから作らない。** `get_repo_tree` を使う。diffから作ると受講者が
#     今回変更していないファイルが入らず、issue #6 が目的未達として却下した案と同じ状態へ
#     静かに落ちる（しかも `degraded:false` で返るため報告上は正常に見える）。
#   - **`tmpdir` を必ず返す。** `cleanup --tmpdir` へ渡す値が返り値に無いと、後始末の呼び先が
#     無くなり残骸が実行のたびに増える。
#   - **展開先は `$tmpdir/source`、マーカーは `$tmpdir` 直下。** `root == tmpdir` にすると、
#     マーカーが受講者のファイル一覧・`mapping.submissionOnly`・禁止語の材料へ混入する。
#   - **除外（バイナリ・生成物）は展開直後に一度だけ行う。** 一覧・読み取り・`mapping`・
#     禁止語のすべてが同じツリーを見る。限定すると、第三者コードの識別子が禁止語から
#     差し引かれ、正解の識別子が依存ライブラリに含まれていればネタバレ検査を素通りする
#     （DDR 0061「誤検知の側へ倒す」の方針を無言で反転させる）。
#   - **サイズが取得できない場合は段1を試す。** 「超過扱い」にすると、権限の弱い環境で
#     上限とは無関係の理由で機能が縮退する。大きすぎた場合はタイムアウトが受け止める。
#
# 規約: .claude/rules/shell-script-style.md（set -euo pipefail / jq前提 / BOM無しUTF-8・LF）
set -euo pipefail

# `resolve` が一時ディレクトリの直下へ置くマーカー。`cleanup` はこれがある場合しか削除しない
# （`answer-talker-reference.sh` と同じ方式）。
readonly ATR_SUBMISSION_MARKER='.answer-talker-submission'

# 既定値。設計で決めた値だが、**実運用のデータが無いまま決めた値**である
# （「演習用リポジトリの想定規模を大きく超える」以上の根拠は無い）。
readonly ATR_DEFAULT_MAX_SIZE_KB=102400   # 100MB相当
readonly ATR_DEFAULT_MAX_FETCH_FILES=50   # 段2の取得件数（50 × 約672ms ≒ 34秒）
readonly ATR_DEFAULT_MAX_LIST_FILES=500   # サブエージェントへ渡す一覧の件数
readonly ATR_DEFAULT_TIMEOUT_SEC=60

# 一覧・読み取り・mapping・禁止語のすべてから除外するディレクトリ（生成物・第三者コード）。
readonly -a ATR_EXCLUDE_DIRS=(
  node_modules dist build target vendor __pycache__ .venv .git
)

# パスが除外対象のディレクトリ配下かを判定する（純粋関数）。
# 先頭・途中のどちらに現れても除外する（`a/node_modules/b` も `node_modules/b` も対象）。
is_excluded_path() {
  local path="$1" dir
  for dir in "${ATR_EXCLUDE_DIRS[@]}"; do
    case "/$path/" in
      */"$dir"/*) return 0 ;;
    esac
  done
  return 1
}

# 展開後のツリーから、除外対象（生成物ディレクトリ・バイナリ）を**実際に削除する**。
#
# **一覧から省くだけでは足りない。** `answer-talker-map.sh` と
# `answer-talker-spoiler-check.sh` は `--submission-root` を受けてツリーを自分で走査するため、
# ツリーに残っていれば見えてしまう。設計の「除外は展開直後に一度だけ行い、以降のコンポーネントは
# すべて同じツリーを見る」を成立させるには、ここで消しておく必要がある。
#
# 消し忘れると、第三者コードの識別子が禁止語から差し引かれ、**正解にしか無い識別子がたまたま
# 依存ライブラリに含まれていればネタバレ検査を素通りする**（DDR 0061 の方針が無言で反転する）。
prune_submission_tree() {
  local root="$1" dir
  for dir in "${ATR_EXCLUDE_DIRS[@]}"; do
    find "$root" -type d -name "$dir" -prune -exec rm -rf {} + 2>/dev/null || true
  done
  # バイナリを消す。`grep -rlI` がテキストファイルを列挙するので、その補集合を消す
  # （ファイルごとに判定コマンドを起動しない）。
  #
  # **空ファイルを補集合に入れないこと**（issue #6）。grepは行単位でマッチするので、行が1つも
  # 無いファイルはどのパターンにも一致せず列挙されない。**`-I` によるバイナリ判定とは無関係で、
  # `-I` を外しても同じである**（実機確認）。つまり素朴に補集合を取ると、バイナリと判定された
  # わけでもない **0バイトのファイルが、バイナリの巻き添えで削除される**。
  # `__init__.py` `.gitkeep` 空の設定ファイル等は演習リポジトリに普通に存在する。消すと
  # `mapping.referenceOnly` に正解側の同名ファイルが残り、**実在するファイルについて
  # 「作られていない」という指摘が出る**。`! -empty` で走査対象から外す。
  local text_list all_list
  text_list="$(grep -rlI -- '' "$root" 2>/dev/null | sort)"
  all_list="$(find "$root" -type f ! -empty | sort)"
  comm -13 <(printf '%s\n' "$text_list") <(printf '%s\n' "$all_list") \
    | while IFS= read -r f; do
        [ -n "$f" ] && rm -f -- "$f"
      done
  return 0
}

# ツリー配下のテキストファイルを、除外を適用したうえでルートからの相対パスで列挙する
# （改行区切りでstdoutへ。`.git` 配下は ATR_EXCLUDE_DIRS に含めてある）。
#
# **バイナリ判定は `grep -I` に任せて1回のforkで済ませる。** ファイルごとに判定すると
# ファイル数に比例して外部コマンドを起動することになる
# （.claude/rules/shell-script-style.md「外部プロセス起動のコスト」: git bashでは約95ms/回）。
# **拡張子では判定しない**（網羅は破綻する）。`grep -I` はNULバイトの有無で判断する。
#
# **空ファイルは `grep` にマッチしないため `find ... -empty` で足す**（issue #6。行が1つも
# 無いためであって `-I` によるバイナリ判定とは無関係。
# `.claude/rules/shell-script-style.md`「テキスト/バイナリ判定」）。
# `prune_submission_tree` と判定を揃えておかないと、ツリーには残っているのに一覧に載らない
# ファイルが生まれる。エージェント定義は「一覧に無いものを探しに行かない」と指示しているため、
# 一覧から落ちたファイルは確認そのものが行われない。
list_submission_files() {
  local root="$1" rel
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    rel="${file#"$root"/}"
    is_excluded_path "$rel" && continue
    printf '%s\n' "$rel"
  done < <({ grep -rlI -- '' "$root" 2>/dev/null; find "$root" -type f -empty; } | sort -u)
}

# 段1: アーカイブ1回で取得して展開する。成功したら 0、失敗したら 1。
#
# **タイムアウトは `timeout` で bash関数を包むのではなく、Provider側の `gh`/`glab` 呼び出しへ
# 掛ける**（`timeout` は外部コマンドであり、bash関数は子プロセスへ継承されないため包めない）。
# 値は環境変数 `ATR_HTTP_TIMEOUT_SEC` で渡す。
fetch_stage1() {
  local ref="$1" tmpdir="$2" archive="$2/archive.tar.gz"

  if ! fetch_repo_archive "$ref" "$archive" 2>/dev/null; then
    return 1
  fi
  [ -s "$archive" ] || return 1

  mkdir -p "$tmpdir/source"
  # `--strip-components=1` でアーカイブ内のprefix（<owner>-<repo>-<sha7>/）を剥がす。
  # `--force-local` が無いと、Windows版tarがドライブレターをホスト名と解釈して失敗する。
  if ! tar xzf "$archive" -C "$tmpdir/source" --strip-components=1 --force-local 2>/dev/null; then
    # **途中まで展開されたツリーを残さない**（issue #6）。段2は同じ `$tmpdir/source` へ
    # 書き足すため、残すと「段2が取得していない、途中まで書かれたファイル」が混ざったまま
    # `stage:2, degraded:false` で返る。段2は必ず空のディレクトリから始める。
    rm -rf "$tmpdir/source"
    rm -f "$archive"
    return 1
  fi
  rm -f "$archive"
  return 0
}

# 段2: tree列挙 → ファイルごとに取得。成功したら 0、失敗・件数超過なら 1。
fetch_stage2() {
  local ref="$1" tmpdir="$2" max_fetch="$3"
  local tree count path dest

  tree="$(get_repo_tree "$ref" 2>/dev/null)" || return 1
  [ -n "$tree" ] || return 1

  # **一覧が全件でないなら段2を成功させない**（issue #6）。欠けたツリーのまま成功すると
  # `degraded:false` で「受講者リポジトリの全ファイル」として渡り、**実在するファイルについて
  # 「無い」という指摘が出る**。段3（hunkのみ）へ縮退したほうが、報告上も正直になる。
  [ "$(printf '%s' "$tree" | jq -r '.truncated' | tr -d '\r')" = 'false' ] || return 1

  # 除外を先に適用してから件数を数える（生成物で件数上限を食い潰さない）
  local -a paths=()
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    is_excluded_path "$path" && continue
    paths+=("$path")
    # **`tr -d '\r'` を外さないこと。** WindowsネイティブのjqはCRLFで出力するため、複数行を
    # `jq -r` で受けると各行の末尾にCRが残る。パスにCRが付いたままAPIへ渡すと、そのファイルだけ
    # 404になり、段2が「1件目は成功したのに2件目で失敗する」という形で壊れる（実機で発生）。
  done < <(printf '%s' "$tree" | jq -r '.files[].path' | tr -d '\r')

  count="${#paths[@]}"
  [ "$count" -gt 0 ] || return 1
  [ "$count" -le "$max_fetch" ] || return 1

  mkdir -p "$tmpdir/source"
  for path in "${paths[@]}"; do
    dest="$tmpdir/source/$path"
    mkdir -p "${dest%/*}"
    get_repo_file "$ref" "$path" > "$dest" 2>/dev/null || return 1
  done
  return 0
}

# 取得できなかった場合の戻り値（段3）。**終了コード0で返す。**
emit_degraded() {
  local reason="$1" tmpdir="${2:-}"
  jq -nc --arg reason "$reason" --arg tmpdir "$tmpdir" \
    '{stage: 3, root: null, tmpdir: (if $tmpdir == "" then null else $tmpdir end),
      fileCount: 0, files: [], truncated: false, degraded: true, reason: $reason}'
}

resolve_main() {
  local mr_number="" target_repo="" max_size_kb="$ATR_DEFAULT_MAX_SIZE_KB"
  local max_fetch="$ATR_DEFAULT_MAX_FETCH_FILES"
  local max_list="$ATR_DEFAULT_MAX_LIST_FILES"
  local timeout_sec="$ATR_DEFAULT_TIMEOUT_SEC"

  while [ $# -gt 0 ]; do
    case "$1" in
      --mr) mr_number="$2"; shift 2 ;;
      --repo) target_repo="$2"; shift 2 ;;
      --max-size-kb) max_size_kb="$2"; shift 2 ;;
      --max-fetch-files) max_fetch="$2"; shift 2 ;;
      --max-list-files) max_list="$2"; shift 2 ;;
      --timeout-sec) timeout_sec="$2"; shift 2 ;;
      *) printf 'resolve: 不明な引数: %s\n' "$1" >&2; return 1 ;;
    esac
  done
  if [ -z "$mr_number" ]; then
    printf 'resolve: --mr は必須です\n' >&2
    return 1
  fi

  # **対象リポジトリはこのプロセスの中で切り替える。** `use_target_repo` が設定する
  # `_PROVIDER_CACHE` はシェル変数であり、**別プロセスへは継承されない**（`GH_REPO` 等の
  # 環境変数だけが渡り、`get_provider` は cwd のremoteから判定してしまう）。呼び出し側が
  # 先に `use_target_repo` を呼んでいても、このスクリプトを `bash …` で起動した時点で
  # プロバイダの判定が cwd 基準へ戻るため、ここで受け直す。
  if [ -n "$target_repo" ]; then
    use_target_repo "$target_repo" >/dev/null || return 1
  fi

  # タイムアウトはProvider側の `gh`/`glab` 呼び出しが参照する（段1・段2の両方に効く）
  export ATR_HTTP_TIMEOUT_SEC="$timeout_sec"

  local head_sha size_kb tmpdir stage=0
  head_sha="$(get_mr_changed_files "$mr_number" | jq -r '.headSha // ""')" || head_sha=""
  if [ -z "$head_sha" ]; then
    emit_degraded 'head-sha-unavailable'
    return 0
  fi

  tmpdir="$(mktemp -d)"
  printf 'answer-talker submission\n' > "$tmpdir/$ATR_SUBMISSION_MARKER"

  # サイズは「不明なら段1を試す」（設計の決定）。理由は reason へ残す。
  local size_reason=""
  size_kb="$(with_mr_head_repo "$mr_number" get_repo_size_kb 2>/dev/null)" || size_kb=""
  if [ -z "$size_kb" ]; then
    size_reason='size-unknown'
  elif [ "$size_kb" -gt "$max_size_kb" ]; then
    size_reason='size-over-limit'
  fi

  if [ "$size_reason" != 'size-over-limit' ]; then
    if with_mr_head_repo "$mr_number" fetch_stage1 "$head_sha" "$tmpdir"; then
      stage=1
    fi
  fi

  if [ "$stage" -eq 0 ]; then
    if with_mr_head_repo "$mr_number" fetch_stage2 "$head_sha" "$tmpdir" "$max_fetch"; then
      stage=2
    fi
  fi

  if [ "$stage" -eq 0 ]; then
    rm -rf "$tmpdir"
    # **縮退の直接原因を主にする**（issue #6）。`size_reason` をそのまま返すと、段1・段2の
    # 両方が失敗しても `reason: "size-unknown"` になり、SKILL.md 手順11がそのまま人間へ
    # 報告する文字列が「サイズ不明」になって調査が別方向を向く。`size-unknown` は縮退の理由
    # ではなく段1を試した経緯にすぎない。成功経路の `stage-2/size-over-limit` と同じ併記形式に揃える。
    local fail_reason='fetch-failed'
    [ -n "$size_reason" ] && fail_reason="${fail_reason}/${size_reason}"
    emit_degraded "$fail_reason"
    return 0
  fi

  # 除外を**ツリーから実際に削除**する（ここで一度だけ。以降は全コンポーネントが同じツリーを見る）
  prune_submission_tree "$tmpdir/source"

  local -a files=()
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    files+=("$rel")
  done < <(list_submission_files "$tmpdir/source")

  local total="${#files[@]}" truncated='false'
  if [ "$total" -gt "$max_list" ]; then
    truncated='true'
    files=("${files[@]:0:$max_list}")
  fi

  local reason="stage-${stage}"
  [ -n "$size_reason" ] && reason="${reason}/${size_reason}"

  # **一覧を `--args` の位置引数で渡さない**（issue #6）。件数（最大 `--max-list-files`＝既定500）
  # × パス長に比例してコマンドライン長が伸び、Windowsの上限（約32KB）に達すると
  # `Argument list too long` で**jqの起動自体が失敗する**（実測: 500件・平均パス長64文字で到達。
  # `src/main/java/...` のような構成では珍しくない）。`.claude/rules/shell-script-style.md`
  # 「JSON操作」が禁じている形そのものである。
  #
  # **壊れ方が悪い。** 失敗するのは展開が終わった後なので、`set -e` で落ちて **stdoutへ何も
  # 出ない**。呼び出し側は `tmpdir` を受け取れず `cleanup --tmpdir` へ渡す値を失い、
  # 「残骸が実行のたびに増える」——このファイル冒頭が避けると宣言している状態になる。
  # 一時ファイルへ書き出し `--rawfile` で読ませることで、件数に依存しない形にする。
  local list_file="$tmpdir/filelist.txt"
  printf '%s\n' "${files[@]}" > "$list_file"
  jq -nc --arg root "$tmpdir/source" --arg tmpdir "$tmpdir" --argjson stage "$stage" \
    --argjson total "$total" --argjson truncated "$truncated" --arg reason "$reason" \
    --rawfile listRaw "$list_file" \
    '{stage: $stage, root: $root, tmpdir: $tmpdir, fileCount: $total,
      files: ($listRaw | rtrimstr("\n") | if . == "" then [] else split("\n") end),
      truncated: $truncated, degraded: false, reason: $reason}'
  rm -f "$list_file"
}

cleanup_main() {
  local tmpdir=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --tmpdir) tmpdir="$2"; shift 2 ;;
      *) printf 'cleanup: 不明な引数: %s\n' "$1" >&2; return 1 ;;
    esac
  done

  if [ -z "$tmpdir" ] || [ ! -d "$tmpdir" ]; then
    jq -nc '{removed: false, reason: "not-found"}'
    return 0
  fi
  if [ ! -f "$tmpdir/$ATR_SUBMISSION_MARKER" ]; then
    jq -nc '{removed: false, reason: "no-marker"}'
    return 0
  fi
  rm -rf "$tmpdir"
  jq -nc '{removed: true, reason: "removed"}'
}

main() {
  local sub="${1:-}"
  [ $# -gt 0 ] && shift
  case "$sub" in
    resolve)
      # shellcheck source=/dev/null
      . "$(dirname "${BASH_SOURCE[0]}")/vcs/Provider.sh"
      resolve_main "$@"
      ;;
    cleanup) cleanup_main "$@" ;;
    *)
      printf 'usage: answer-talker-submission.sh resolve --mr <番号> [options]\n' >&2
      printf '       answer-talker-submission.sh cleanup --tmpdir <パス>\n' >&2
      return 1
      ;;
  esac
}

# `source` されたときは関数定義だけを読み込む（単体テストのため。
# .claude/rules/shell-script-style.md「テスト」）
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
