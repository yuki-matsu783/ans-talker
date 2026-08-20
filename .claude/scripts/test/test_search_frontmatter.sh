#!/usr/bin/env bash
# .claude/scripts/src/search-frontmatter.sh の単体テスト（issue #38）。
#
# 対象は次の2つ。
#   1. 外部コマンドを呼ばない純粋関数（sf_is_one_of / sf_is_excluded_path /
#      sf_filter_index_paths / sf_join_lines_to_reply / sf_validate_sort / sf_validate_format）
#   2. 絞り込み・並び替え・整形を担う jq プログラム（SF_JQ_PROGRAM）。
#      mktemp -d のフィクスチャ index.jsonl に対して直接 jq を回す
#      （test_extract_frontmatter.sh / test_usage_tracking.sh と同じやり方。実リポジトリは汚さない）。
#   3. main の結合テスト。mktemp -d + git init の使い捨てリポジトリに index.jsonl を置き、
#      スクリプトを**実プロセスとして起動**して stdout / stderr / 終了コードを見る（末尾の節）。
#      引数解析・find の除外・件数サマリは main にしか無く、合成フィクスチャだけでは検出できない
#      （.claude/rules/shell-script-style.md「テスト」の「合成フィクスチャのテストだけで完了と
#      しない」）。実際、この層に3件の不具合があった（値省略時の無言終了・値位置のフラグ食い・
#      --limit の件数サマリへの波及）。
# 規約: passed=N failures=N を標準出力へ出し、失敗があれば終了コード1
#       （.claude/rules/shell-script-style.md「テスト」）。
# 実行: bash .claude/scripts/test/test_search_frontmatter.sh
set -euo pipefail

script_dir="${BASH_SOURCE[0]%/*}"
[[ "$script_dir" == "${BASH_SOURCE[0]}" ]] && script_dir="."
repo_root="$(cd "$script_dir/../../.." && pwd)"

# shellcheck source=../../../.claude/scripts/src/search-frontmatter.sh
source "$repo_root/.claude/scripts/src/search-frontmatter.sh"

passed=0
failures=0

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    passed=$((passed + 1))
  else
    failures=$((failures + 1))
    echo "FAIL: $name"
    echo "  expected: $expected"
    echo "  actual  : $actual"
  fi
}

# --- sf_is_one_of --------------------------------------------------------

# 終了コードは `if` の条件式で受ける（`"$(func; echo $?)"` は set -e 配下で空文字列になりうる。
# .claude/rules/shell-script-style.md「テスト」）。
status_of() {
  if "$@"; then echo 0; else echo 1; fi
}

assert_eq "sf_is_one_of: 含まれる" "0" "$(status_of sf_is_one_of 'mtime' 'path mtime type title')"
assert_eq "sf_is_one_of: 先頭の要素" "0" "$(status_of sf_is_one_of 'path' 'path mtime type title')"
assert_eq "sf_is_one_of: 末尾の要素" "0" "$(status_of sf_is_one_of 'title' 'path mtime type title')"
assert_eq "sf_is_one_of: 含まれない" "1" "$(status_of sf_is_one_of 'bogus' 'path mtime type title')"
assert_eq "sf_is_one_of: 空文字列は含まれない" "1" "$(status_of sf_is_one_of '' 'path mtime')"
# 部分一致で誤って通さないこと（`case` のグロブを前後の空白で挟んでいる理由）
assert_eq "sf_is_one_of: 部分文字列は一致しない" "1" "$(status_of sf_is_one_of 'tim' 'path mtime type title')"

# --- sf_is_excluded_path -------------------------------------------------

assert_eq "sf_is_excluded_path: 通常のパスは対象" "1" \
  "$(status_of sf_is_excluded_path '.claude/docs/ddr/index.jsonl')"
assert_eq "sf_is_excluded_path: 先頭の ./ が付いていても対象" "1" \
  "$(status_of sf_is_excluded_path './.claude/rules/index.jsonl')"
assert_eq "sf_is_excluded_path: リポジトリ直下も対象" "1" "$(status_of sf_is_excluded_path 'index.jsonl')"
assert_eq "sf_is_excluded_path: .git 配下は除外" "0" "$(status_of sf_is_excluded_path '.git/foo/index.jsonl')"
assert_eq "sf_is_excluded_path: node_modules 配下は除外" "0" \
  "$(status_of sf_is_excluded_path 'app/node_modules/pkg/index.jsonl')"
assert_eq "sf_is_excluded_path: build 配下は除外" "0" "$(status_of sf_is_excluded_path 'build/index.jsonl')"
# .gemini/ は .claude/ へのリンク（ジャンクション）のため、除外しないと同じドキュメントが二重に出る
assert_eq "sf_is_excluded_path: .gemini 配下は除外" "0" \
  "$(status_of sf_is_excluded_path '.gemini/docs/ddr/index.jsonl')"
assert_eq "sf_is_excluded_path: 空文字列は除外" "0" "$(status_of sf_is_excluded_path '')"
# 構成要素の完全一致で判定していること（部分一致だと巻き込む名前）
assert_eq "sf_is_excluded_path: rebuild/ は build ではない" "1" \
  "$(status_of sf_is_excluded_path 'rebuild/index.jsonl')"
assert_eq "sf_is_excluded_path: builder/ は build ではない" "1" \
  "$(status_of sf_is_excluded_path 'src/builder/index.jsonl')"
assert_eq "sf_is_excluded_path: .github は .git ではない" "1" \
  "$(status_of sf_is_excluded_path '.github/ISSUE_TEMPLATE/index.jsonl')"

# --- sf_filter_index_paths -----------------------------------------------

filtered="$(sf_filter_index_paths <<'EOF'
.claude/docs/ddr/index.jsonl

.git/modules/index.jsonl
.gemini/rules/index.jsonl
.github/ISSUE_TEMPLATE/index.jsonl
EOF
)"
assert_eq "sf_filter_index_paths: 除外対象と空行だけを落とす" \
  "$(printf '%s\n' '.claude/docs/ddr/index.jsonl' '.github/ISSUE_TEMPLATE/index.jsonl')" "$filtered"

assert_eq "sf_filter_index_paths: すべて除外なら空" "" "$(sf_filter_index_paths <<'EOF'
.git/a/index.jsonl
.gemini/b/index.jsonl
EOF
)"

# --- sf_join_lines_to_reply ----------------------------------------------

REPLY='dirty'
sf_join_lines_to_reply
assert_eq "sf_join_lines_to_reply: 要素0個なら空文字列" "" "$REPLY"

sf_join_lines_to_reply 'ddr'
assert_eq "sf_join_lines_to_reply: 要素1個" "ddr" "$REPLY"

sf_join_lines_to_reply 'ddr' 'spec' 'rule'
assert_eq "sf_join_lines_to_reply: 改行で連結する" "$(printf 'ddr\nspec\nrule')" "$REPLY"

# 呼び出し元の IFS を壊さないこと（local IFS で閉じ込めている）
IFS_before="$IFS"
sf_join_lines_to_reply 'a' 'b'
assert_eq "sf_join_lines_to_reply: 呼び出し元のIFSを変えない" "$IFS_before" "$IFS"

# 値に空白を含んでいても分割されないこと
sf_join_lines_to_reply 'git add' '-A'
assert_eq "sf_join_lines_to_reply: 空白・ハイフン始まりの値をそのまま保つ" \
  "$(printf 'git add\n-A')" "$REPLY"

# --- sf_validate_sort / sf_validate_format -------------------------------

assert_eq "sf_validate_sort: path" "0" "$(status_of sf_validate_sort 'path' 2>/dev/null)"
assert_eq "sf_validate_sort: mtime" "0" "$(status_of sf_validate_sort 'mtime' 2>/dev/null)"
assert_eq "sf_validate_sort: 未知の値は1" "1" "$(status_of sf_validate_sort 'bogus' 2>/dev/null)"
assert_eq "sf_validate_format: table" "0" "$(status_of sf_validate_format 'table' 2>/dev/null)"
assert_eq "sf_validate_format: count" "0" "$(status_of sf_validate_format 'count' 2>/dev/null)"
assert_eq "sf_validate_format: 未知の値は1" "1" "$(status_of sf_validate_format 'bogus' 2>/dev/null)"

# --- SF_JQ_PROGRAM（フィクスチャ index.jsonl に対する絞り込み・並び替え・整形） -----

fixture_dir="$(mktemp -d)"
trap 'rm -rf "$fixture_dir"' EXIT
fixture="$fixture_dir/index.jsonl"

# 末尾に #1 と同じ concept_id の行を置き、unique_by による重複排除も併せて検証する
# （.gemini/ のリンクを辿ってしまった場合に同じドキュメントが二重に出るのを防ぐ仕掛け）。
cat > "$fixture" <<'EOF'
{"concept_id":".claude/docs/ddr/0001-alpha","directory":".claude/docs/ddr","frontmatter":{"title":"0001. Alphaの決定","type":"ddr","description":"最初の決定","tags":["workflow","conflict"],"keywords":["merge","DDR番号"]},"mtime":"2026-08-01T00:00:00"}
{"concept_id":".claude/docs/spec/beta","directory":".claude/docs/spec","frontmatter":{"title":"Beta仕様","type":"spec","description":"betaの仕様","tags":["spec"],"keywords":["frontmatter","JSONL"]},"mtime":"2026-08-10T12:00:00"}
{"concept_id":".claude/rules/gamma","directory":".claude/rules","frontmatter":{"title":"Gammaルール","type":"rule","description":"gammaの規約","tags":["Workflow"],"keywords":["bash","git add"]},"mtime":"2026-08-20T09:00:00"}
{"concept_id":"worklog/delta","directory":"worklog","frontmatter":{"title":"delta","type":"log"},"mtime":"2026-07-01T00:00:00"}
{"concept_id":"考えたこと","directory":".","frontmatter":null,"mtime":"2026-08-05T00:00:00"}
{"concept_id":".claude/docs/ddr/0001-alpha","directory":".claude/docs/ddr","frontmatter":{"title":"0001. Alphaの決定","type":"ddr","description":"最初の決定","tags":["workflow","conflict"],"keywords":["merge","DDR番号"]},"mtime":"2026-08-01T00:00:00"}
EOF

Q_TYPES='' Q_TAGS='' Q_KEYWORDS='' Q_PATHS='' Q_TEXTS=''
Q_SINCE='' Q_UNTIL='' Q_SORT='path' Q_REVERSE='0' Q_LIMIT='0' Q_FORMAT='path'

qreset() {
  Q_TYPES='' Q_TAGS='' Q_KEYWORDS='' Q_PATHS='' Q_TEXTS=''
  Q_SINCE='' Q_UNTIL='' Q_SORT='path' Q_REVERSE='0' Q_LIMIT='0' Q_FORMAT='path'
}

# jq出力の行末CR（Windowsネイティブjq）は本体と同じく落とす
q() {
  jq -n -r \
    --arg types "$Q_TYPES" --arg tags "$Q_TAGS" --arg keywords "$Q_KEYWORDS" \
    --arg paths "$Q_PATHS" --arg texts "$Q_TEXTS" \
    --arg since "$Q_SINCE" --arg until "$Q_UNTIL" \
    --arg sort "$Q_SORT" --arg reverse "$Q_REVERSE" --arg limit "$Q_LIMIT" --arg format "$Q_FORMAT" \
    "$SF_JQ_PROGRAM" "$fixture" | tr -d '\r'
}

qreset
assert_eq "jq: 条件なしなら全件（重複排除後5件）を concept_id 順で返す" \
  "$(printf '%s\n' '.claude/docs/ddr/0001-alpha' '.claude/docs/spec/beta' '.claude/rules/gamma' 'worklog/delta' '考えたこと')" \
  "$(q)"

qreset
Q_FORMAT='count'
assert_eq "jq: 同じ concept_id の行は1件に畳む（total も畳んだ後の件数）" "matched=5 total=5" "$(q)"

qreset
Q_TYPES='ddr'
assert_eq "jq: --type で絞り込む" ".claude/docs/ddr/0001-alpha" "$(q)"

qreset
Q_TYPES='DDR'
assert_eq "jq: --type は大文字小文字を無視する" ".claude/docs/ddr/0001-alpha" "$(q)"

qreset
Q_TYPES="$(printf 'ddr\nspec')"
assert_eq "jq: 同じ条件を複数指定するとORになる" \
  "$(printf '%s\n' '.claude/docs/ddr/0001-alpha' '.claude/docs/spec/beta')" "$(q)"

qreset
Q_TAGS='workflow'
assert_eq "jq: --tag は配列の要素と完全一致（大文字小文字は無視）" \
  "$(printf '%s\n' '.claude/docs/ddr/0001-alpha' '.claude/rules/gamma')" "$(q)"

qreset
Q_TAGS='work'
assert_eq "jq: --tag は部分一致では当たらない" "" "$(q)"

qreset
Q_TYPES='ddr' Q_TAGS='spec'
assert_eq "jq: 異なる条件同士はANDになる" "" "$(q)"

qreset
Q_KEYWORDS='frontmatter'
assert_eq "jq: --keyword で絞り込む" ".claude/docs/spec/beta" "$(q)"

qreset
Q_KEYWORDS='git add'
assert_eq "jq: --keyword は空白を含む値も扱える" ".claude/rules/gamma" "$(q)"

# match_sub の回帰テスト。以前 `$h | contains(.)` と書いていたため `.` が $h へ差し替わり、
# 部分一致条件が常に真（＝全件ヒット）になっていた。
qreset
Q_PATHS='docs/'
assert_eq "jq: --path は concept_id の部分一致で絞り込む（全件ヒットしない）" \
  "$(printf '%s\n' '.claude/docs/ddr/0001-alpha' '.claude/docs/spec/beta')" "$(q)"

qreset
Q_PATHS='DOCS/SPEC'
assert_eq "jq: --path は大文字小文字を無視する" ".claude/docs/spec/beta" "$(q)"

qreset
Q_PATHS='存在しないパス'
assert_eq "jq: --path が当たらなければ0件" "" "$(q)"

qreset
Q_TEXTS='最初の決定'
assert_eq "jq: --text は description まで含めて部分一致する" ".claude/docs/ddr/0001-alpha" "$(q)"

qreset
Q_TEXTS='DDR番号'
assert_eq "jq: --text は keywords も対象にする" ".claude/docs/ddr/0001-alpha" "$(q)"

qreset
Q_TEXTS='どこにも無い文字列'
assert_eq "jq: --text が当たらなければ0件" "" "$(q)"

qreset
Q_SINCE='2026-08-05'
assert_eq "jq: --since は mtime がその値以上のものだけ残す" \
  "$(printf '%s\n' '.claude/docs/spec/beta' '.claude/rules/gamma' '考えたこと')" "$(q)"

# 日付だけの --until は当日の終わりまでを含むよう正規化される（main が通す前処理）。
# 正規化しないと "2026-08-05T00:00:00" > "2026-08-05" となり、当日更新分が丸ごと落ちる。
sf_normalize_until_to_reply '2026-08-05'
assert_eq "sf_normalize_until_to_reply: 日付のみなら当日の終わりまで補う" "2026-08-05T23:59:59" "$REPLY"
sf_normalize_until_to_reply '2026-08-05T12:00:00'
assert_eq "sf_normalize_until_to_reply: 時刻付きはそのまま" "2026-08-05T12:00:00" "$REPLY"
sf_normalize_until_to_reply ''
assert_eq "sf_normalize_until_to_reply: 空はそのまま（指定なし）" "" "$REPLY"

qreset
sf_normalize_until_to_reply '2026-08-05'
Q_UNTIL="$REPLY"
assert_eq "jq: --until は mtime がその値以下のものだけ残す（当日更新分を含む）" \
  "$(printf '%s\n' '.claude/docs/ddr/0001-alpha' 'worklog/delta' '考えたこと')" "$(q)"

qreset
Q_UNTIL='2026-08-05'
assert_eq "jq: 正規化前の日付をそのまま渡すと当日分は落ちる（正規化が必要な理由）" \
  "$(printf '%s\n' '.claude/docs/ddr/0001-alpha' 'worklog/delta')" "$(q)"

qreset
Q_SORT='mtime'
assert_eq "jq: --sort mtime は古い順" \
  "$(printf '%s\n' 'worklog/delta' '.claude/docs/ddr/0001-alpha' '考えたこと' '.claude/docs/spec/beta' '.claude/rules/gamma')" \
  "$(q)"

qreset
Q_SORT='mtime' Q_REVERSE='1'
assert_eq "jq: --sort mtime --reverse は新しい順" \
  "$(printf '%s\n' '.claude/rules/gamma' '.claude/docs/spec/beta' '考えたこと' '.claude/docs/ddr/0001-alpha' 'worklog/delta')" \
  "$(q)"

qreset
Q_SORT='mtime' Q_REVERSE='1' Q_LIMIT='2'
assert_eq "jq: --limit は並び替えの後に効く" \
  "$(printf '%s\n' '.claude/rules/gamma' '.claude/docs/spec/beta')" "$(q)"

qreset
Q_LIMIT='0'
assert_eq "jq: --limit 0 は全件（5件）" "5" "$(q | grep -c .)"

qreset
Q_SORT='type'
assert_eq "jq: --sort type は type 順（frontmatter 無しは空文字列で先頭）" \
  "$(printf '%s\n' '考えたこと' '.claude/docs/ddr/0001-alpha' 'worklog/delta' '.claude/rules/gamma' '.claude/docs/spec/beta')" \
  "$(q)"

qreset
Q_FORMAT='jsonl' Q_PATHS='worklog/delta'
assert_eq "jq: --format jsonl は1行1JSONで返す" \
  '{"concept_id":"worklog/delta","directory":"worklog","frontmatter":{"title":"delta","type":"log"},"mtime":"2026-07-01T00:00:00"}' \
  "$(q)"

qreset
Q_FORMAT='json' Q_PATHS='worklog/delta'
assert_eq "jq: --format json は配列を返す" "1" "$(q | jq 'length')"

qreset
Q_FORMAT='detail' Q_PATHS='worklog/delta'
assert_eq "jq: --format detail の1行目は concept_id" "- worklog/delta" "$(q | head -1)"
qreset
Q_FORMAT='detail' Q_PATHS='worklog/delta'
assert_eq "jq: --format detail は tags が無くても落ちない" "  tags       : " "$(q | sed -n '5p')"

qreset
Q_FORMAT='table' Q_TYPES='ddr'
assert_eq "jq: --format table は type / concept_id / title を並べる" \
  "ddr  .claude/docs/ddr/0001-alpha  0001. Alphaの決定" "$(q)"

# 全角を含む行と含まない行が同じ桁で揃うこと（jq の length はコードポイント数のため dwidth で補正）
qreset
Q_FORMAT='table' Q_PATHS="$(printf 'gamma\n考えたこと')"
gamma_col="$(q | grep gamma | awk -F'  +' '{print length($1"  "$2)}')"
kangae_col="$(q | grep 考えた | awk -F'  +' '{print length($1"  "$2)}')"
assert_eq "jq: table の桁揃えは全角を幅2として数える（コードポイント数では一致しない）" \
  "0" "$([ "$gamma_col" = "$kangae_col" ] && echo 1 || echo 0)"

qreset
Q_FORMAT='count' Q_TYPES='ddr'
assert_eq "jq: --format count は matched と total を返す" "matched=1 total=5" "$(q)"

# --limit は「絞り込みがどれだけ効いたか」を汚さない。打ち切りが起きたときだけ shown= が付く。
qreset
Q_FORMAT='count' Q_TYPES="$(printf 'ddr\nspec')" Q_LIMIT='1'
assert_eq "jq: --format count は --limit の打ち切り前の件数を matched とする" \
  "matched=2 shown=1 total=5" "$(q)"
qreset
Q_FORMAT='count' Q_LIMIT='99'
assert_eq "jq: --limit が実際に効いていなければ shown= は付かない" "matched=5 total=5" "$(q)"

# --- --text がJSONのキー名に当たらないこと（回帰テスト） -----------------
# 以前は match_sub の haystack がレコードの `tostring`（キー名・区切り記号を含むJSONテキスト
# 全体）だったため、`--text description` のような普通に打つ語で実質全件がヒットしていた。
qreset
Q_TEXTS='description'
assert_eq "jq: --text はJSONのキー名に当たらない（description）" "" "$(q)"
qreset
Q_TEXTS='keywords'
assert_eq "jq: --text はJSONのキー名に当たらない（keywords）" "" "$(q)"
qreset
Q_TEXTS='concept_id'
assert_eq "jq: --text はJSONのキー名に当たらない（concept_id）" "" "$(q)"
qreset
Q_TEXTS='directory'
assert_eq "jq: --text はJSONのキー名に当たらない（directory）" "" "$(q)"
# 逆に、キー名と同じ綴りでも**値として**存在すれば当たる（キー名を消しただけで値は消していない）
qreset
Q_TEXTS='frontmatter'
assert_eq "jq: キー名と同綴りでも keywords の値なら当たる" ".claude/docs/spec/beta" "$(q)"
# 値の側は従来どおり当たる
qreset
Q_TEXTS='betaの仕様'
assert_eq "jq: --text は description の値には当たる" ".claude/docs/spec/beta" "$(q)"
qreset
Q_TEXTS='JSONL'
assert_eq "jq: --text は keywords の値には当たる" ".claude/docs/spec/beta" "$(q)"
qreset
Q_TEXTS='2026-08-20'
assert_eq "jq: --text は mtime の値には当たる" ".claude/rules/gamma" "$(q)"

# frontmatter が null のレコードでも各条件が例外なく評価できること
qreset
Q_TYPES='rule' 
assert_eq "jq: frontmatter が null の行があっても --type は動く" ".claude/rules/gamma" "$(q)"
qreset
Q_TEXTS='考えたこと'
assert_eq "jq: frontmatter が null の行も --text で拾える" "考えたこと" "$(q)"

# --- 規約違反レコード（tags/keywords がスカラー）でも落ちないこと --------
# frontmatter が `tags: workflow` のようにリストで書かれていない場合、extract-frontmatter.sh は
# それを文字列のまま index へ入れる。本スキルは「frontmatter規約違反の洗い出し」も用途に
# 掲げているため、**規約違反のレコードが混ざった状態で使われるのが想定内**であり、そこで
# jq ごと落ちてはいけない（以前は detail 形式が `Cannot iterate over string` で exit 5 になった）。
scalar_fixture="$fixture_dir/scalar.jsonl"
cat > "$scalar_fixture" <<'EOF'
{"concept_id":"ok","directory":".","frontmatter":{"title":"OK","type":"spec","tags":["x"],"keywords":["k"]},"mtime":"2026-08-01T00:00:00"}
{"concept_id":"scalar","directory":".","frontmatter":{"title":"Scalar","type":"spec","tags":"workflow","keywords":"single"},"mtime":"2026-08-02T00:00:00"}
{"concept_id":"nofm","directory":".","frontmatter":null,"mtime":"2026-08-03T00:00:00"}
EOF

q_scalar() { # $1=format
  jq -n -r \
    --arg types '' --arg tags '' --arg keywords '' --arg paths '' --arg texts '' \
    --arg since '' --arg until '' --arg sort path --arg reverse 0 --arg limit 0 --arg format "$1" \
    "$SF_JQ_PROGRAM" "$scalar_fixture" 2>/dev/null | tr -d '\r'
}

for fmt in table path json jsonl detail count; do
  if q_scalar "$fmt" >/dev/null 2>&1; then
    scalar_status=0
  else
    scalar_status=1
  fi
  assert_eq "jq: tags/keywords がスカラーでも --format $fmt が落ちない" "0" "$scalar_status"
done

# 行番号で位置を決め打ちすると、出力の行数が変わるたびに壊れる。内容そのものを数える。
assert_eq "jq: スカラーの tags は detail でそのまま表示される" "1" \
  "$(q_scalar detail | grep -c '^  tags       : workflow$')"
assert_eq "jq: スカラーの keywords は detail でそのまま表示される" "1" \
  "$(q_scalar detail | grep -c '^  keywords   : single$')"
assert_eq "jq: frontmatter が null でも detail が空欄で出る（nofm の1件だけ）" "1" \
  "$(q_scalar detail | grep -c '^  tags       : $')"

# --- sf_validate_option_value --------------------------------------------

# 値が無い（`--type` で終端）
assert_eq "sf_validate_option_value: 値が無ければ1" "1" \
  "$(status_of sf_validate_option_value '--type' 1 '' 2>/dev/null)"
# 値の位置に別のオプションが来た
assert_eq "sf_validate_option_value: 値が -- で始まれば1" "1" \
  "$(status_of sf_validate_option_value '--type' 2 '--quiet' 2>/dev/null)"
# ハイフン1つで始まる値は通す（`keywords: [git add, -A, pathspec]` のような実在の検索語）
assert_eq "sf_validate_option_value: ハイフン1つで始まる値は通す" "0" \
  "$(status_of sf_validate_option_value '--text' 2 '-A' 2>/dev/null)"
assert_eq "sf_validate_option_value: 通常の値は通す" "0" \
  "$(status_of sf_validate_option_value '--type' 2 'ddr' 2>/dev/null)"
# 空文字列そのものは値として認める（`--text ''` を弾く理由が無い）
assert_eq "sf_validate_option_value: 空文字列は値として通す" "0" \
  "$(status_of sf_validate_option_value '--text' 2 '' 2>/dev/null)"

# --- main の結合テスト（実プロセス起動） ---------------------------------
#
# 引数解析・find の除外・件数サマリは main にしか無く、上の合成フィクスチャでは検出できない
# （.claude/rules/shell-script-style.md「テスト」）。使い捨てのgitリポジトリを作り、
# `--no-refresh` で extract-frontmatter.sh を外して実プロセスとして起動する。

script="$repo_root/.claude/scripts/src/search-frontmatter.sh"
itest="$fixture_dir/repo"
mkdir -p "$itest/docs" "$itest/build/gen" "$itest/.gemini/rules"
git -C "$itest" init -q 2>/dev/null || git -C "$itest" init >/dev/null 2>&1
cat > "$itest/index.jsonl" <<'EOF'
{"concept_id":"README","directory":".","frontmatter":{"title":"読み物","type":"guide","tags":["top"],"keywords":["入口"]},"mtime":"2026-08-01T00:00:00"}
EOF
cat > "$itest/docs/index.jsonl" <<'EOF'
{"concept_id":"docs/alpha","directory":"docs","frontmatter":{"title":"アルファ","type":"spec","tags":["doc"],"keywords":["仕様"]},"mtime":"2026-08-02T00:00:00"}
{"concept_id":"docs/beta","directory":"docs","frontmatter":{"title":"ベータ","type":"ddr","tags":["doc"],"keywords":["決定"]},"mtime":"2026-08-03T00:00:00"}
EOF
# 除外されるべきディレクトリ（build/ は find の prune、.gemini/ は .claude へのリンク相当）
cat > "$itest/build/gen/index.jsonl" <<'EOF'
{"concept_id":"build/gen/生成物","directory":"build/gen","frontmatter":{"title":"生成物","type":"spec"},"mtime":"2026-08-04T00:00:00"}
EOF
cat > "$itest/.gemini/rules/index.jsonl" <<'EOF'
{"concept_id":".gemini/rules/リンク","directory":".gemini/rules","frontmatter":{"title":"リンク","type":"rule"},"mtime":"2026-08-05T00:00:00"}
EOF

# 実プロセスとして起動する。cd はサブシェルへ閉じ込め、テスト側のカレントを動かさない。
run_main() { ( cd "$itest" && bash "$script" --no-refresh "$@" 2>"$fixture_dir/stderr.txt" ); }
run_main_status() { if run_main "$@" >/dev/null; then echo 0; else echo 1; fi; }
last_stderr() { cat "$fixture_dir/stderr.txt"; }

assert_eq "main: 除外ディレクトリを除いた3件を返す" \
  "$(printf '%s\n' 'README' 'docs/alpha' 'docs/beta')" "$(run_main --format path -q)"
assert_eq "main: build/ 配下の index.jsonl は探索しない" "" "$(run_main --path 生成物 --format path -q)"
assert_eq "main: .gemini/ 配下の index.jsonl は探索しない" "" "$(run_main --path リンク --format path -q)"

assert_eq "main: 件数サマリを stderr へ出す（index数を含む）" \
  "matched=3 total=3 indexes=2" "$(run_main --format path >/dev/null; last_stderr)"
assert_eq "main: --quiet で件数サマリを出さない" "" "$(run_main --format path -q >/dev/null; last_stderr)"

assert_eq "main: --dir でリポジトリルート基準に対象を絞る" \
  "$(printf '%s\n' 'docs/alpha' 'docs/beta')" "$(run_main --dir docs --format path -q)"
assert_eq "main: --dir が存在しなければ1" "1" "$(run_main_status --dir 存在しない)"
assert_eq "main: --dir のエラーはリポジトリルート基準であることを示す" "1" \
  "$(run_main --dir 存在しない >/dev/null 2>&1 || true; last_stderr | grep -c 'リポジトリルート')"

# 引数エラーは「無言で終了」しないこと（以前は shift 2 の失敗で何も出さずexit 1になっていた）
assert_eq "main: 未知のオプションは1" "1" "$(run_main_status --bogus)"
assert_eq "main: 値を省略したオプションは1" "1" "$(run_main_status --type)"
assert_eq "main: 値を省略したオプションはエラーを出す（無言で終わらない）" "1" \
  "$(run_main --type >/dev/null 2>&1 || true; last_stderr | grep -c 'error:')"
assert_eq "main: 値の位置にオプションが来たら1" "1" "$(run_main_status --type --quiet)"
assert_eq "main: 値の位置にオプションが来たらエラーを出す" "1" \
  "$(run_main --type --quiet >/dev/null 2>&1 || true; last_stderr | grep -c 'error:')"
assert_eq "main: ハイフン1つで始まる値は受け付ける" "0" "$(run_main_status --text -A --format count)"
assert_eq "main: 不正な --sort は1" "1" "$(run_main_status --sort bogus)"
assert_eq "main: 不正な --format は1" "1" "$(run_main_status --format bogus)"
assert_eq "main: 整数でない --limit は1" "1" "$(run_main_status --limit abc)"

# 該当0件は「正常終了」（set -e 配下の呼び出し側が0件で止まらないようにするため）
assert_eq "main: 該当0件でも終了コードは0" "0" "$(run_main_status --type 存在しない型)"
assert_eq "main: 該当0件の出力は空" "" "$(run_main --type 存在しない型 --format path -q)"

assert_eq "main: --limit は打ち切り前の件数を matched として報告する" \
  "matched=3 shown=1 total=3" "$(run_main --limit 1 --format count -q)"
assert_eq "main: --sort mtime --reverse で新しい順になる" \
  "$(printf '%s\n' 'docs/beta' 'docs/alpha' 'README')" "$(run_main --sort mtime -r --format path -q)"
assert_eq "main: -h は使い方を表示して0で終わる" "0" "$(run_main_status -h)"

# index.jsonl が1件も無いディレクトリ
mkdir -p "$itest/empty"
assert_eq "main: index.jsonl が無くても終了コードは0" "0" "$(run_main_status --dir empty)"
assert_eq "main: index.jsonl が無ければ警告を出す" "1" \
  "$(run_main --dir empty >/dev/null 2>&1 || true; last_stderr | grep -c 'warning:')"

echo "passed=$passed failures=$failures"
[[ "$failures" -eq 0 ]]
