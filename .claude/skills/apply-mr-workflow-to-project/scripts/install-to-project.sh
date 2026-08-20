#!/usr/bin/env bash
set -euo pipefail

# ロケールを UTF-8 に固定（日本語などのマルチバイトファイル名文字化け防止）
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

# Determine script and skill directories
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ASSETS_DIR="${SKILL_DIR}/assets"

# Output usage instruction
show_usage() {
  echo "Usage: $0 [-f|--force] [destination-directory]"
  echo "Applies the mr-driven-develop workflow assets to the specified repository."
  echo "Options:"
  echo "  -f, --force    Forcefully overwrite existing files without warnings or backups."
}

FORCE=false
DEST_DIR=""
HAS_WARNED=false

while [ $# -gt 0 ]; do
  case "$1" in
    -f|--force)
      FORCE=true
      shift
      ;;
    -h|--help)
      show_usage
      exit 0
      ;;
    -*)
      echo "❌ Error: Unknown option $1"
      show_usage
      exit 1
      ;;
    *)
      if [ -z "${DEST_DIR}" ]; then
        DEST_DIR="$1"
      else
        echo "❌ Error: Multiple destination directories specified."
        show_usage
        exit 1
      fi
      shift
      ;;
  esac
done

if [ -z "${DEST_DIR}" ]; then
  DEST_DIR="."
fi
DEST_DIR="$(cd "${DEST_DIR}" && pwd)"

echo "=== Applying mr-driven-develop Workflow to Project ==="
echo "Target directory: ${DEST_DIR}"
if [ "${FORCE}" = true ]; then
  echo "Force overwrite mode: Enabled"
fi

# 比較およびバックアップ付きコピー
# ファイル比較・バックアップ付きコピー関数: safe_copy_file <コピー元> <コピー先>
safe_copy_file() {
  local src="$1"
  local dest="$2"

  if [ ! -f "${src}" ]; then
    return 0
  fi

  # コピー先の親ディレクトリが確実に存在するように作成
  mkdir -p "$(dirname "${dest}")"

  if [ -f "${dest}" ]; then
    if cmp -s "${src}" "${dest}"; then
      # 内容が完全に同一の場合は何もしない
      return 0
    fi

    # 内容が異なる場合
    if [ "${FORCE}" = true ]; then
      echo "🔄  Overwriting ${dest} (force option enabled)..."
      cp -f "${src}" "${dest}"
    else
      local backup="${dest}.bak"
      echo "⚠️  WARNING: ${dest} already exists and differs from the template."
      echo "   Saving existing file to ${backup}"
      cp -f "${dest}" "${backup}"

      echo "✅  Applying template to ${dest} (existing customization preserved in ${backup})."
      cp -f "${src}" "${dest}"
      HAS_WARNED=true
    fi
  else
    # 新規ファイル作成
    cp -f "${src}" "${dest}"
  fi
}

# ディレクトリ配下のファイルを安全に一括コピーする関数: safe_copy_dir <コピー元ディレクトリ> <コピー先ディレクトリ>
safe_copy_dir() {
  local src_dir="$1"
  local dest_dir="$2"

  if [ ! -d "${src_dir}" ]; then
    return 0
  fi

  # コピー元ディレクトリ配下のすべてのファイルを検索して安全にコピー（ヌル区切りで文字化けやスペース割れを完全防止）
  find "${src_dir}" -type f -print0 | while IFS= read -r -d '' src_file; do
    local rel_path="${src_file#${src_dir}/}"
    local dest_file="${dest_dir}/${rel_path}"
    safe_copy_file "${src_file}" "${dest_file}"
  done
}

# 1. Validation
if [ ! -d "${DEST_DIR}/.git" ]; then
  echo "❌ Error: Target directory is not a Git repository (.git directory not found)."
  echo "Git repository is required to use the Issue/MR driven workflow."
  exit 1
fi

# Detect configurations for specific environments
IS_GO_PROJECT=false
if [ -f "${DEST_DIR}/go.mod" ]; then
  echo "🔍  Go project configuration (go.mod) detected."
  IS_GO_PROJECT=true
fi

# 2. Copy core workflow assets from skill's assets
echo "Installing core configuration files..."

# Ensure target directories exist
mkdir -p "${DEST_DIR}/.claude"
mkdir -p "${DEST_DIR}/.gemini"
mkdir -p "${DEST_DIR}/plans"
mkdir -p "${DEST_DIR}/worklog"

# Copy configuration and rules safely
safe_copy_dir "${ASSETS_DIR}/.claude" "${DEST_DIR}/.claude"
safe_copy_dir "${ASSETS_DIR}/.gemini" "${DEST_DIR}/.gemini"
safe_copy_file "${ASSETS_DIR}/.mrworkflow.json" "${DEST_DIR}/.mrworkflow.json"
safe_copy_file "${ASSETS_DIR}/AGENTS.md" "${DEST_DIR}/AGENTS.md"
safe_copy_file "${ASSETS_DIR}/GEMINI.md" "${DEST_DIR}/GEMINI.md"
safe_copy_file "${ASSETS_DIR}/CLAUDE.md" "${DEST_DIR}/CLAUDE.md"
safe_copy_file "${ASSETS_DIR}/HANDOFF.md" "${DEST_DIR}/HANDOFF.md"
safe_copy_file "${ASSETS_DIR}/index.md" "${DEST_DIR}/index.md"

# Copy git provider templates if they exist in assets safely
if [ -d "${ASSETS_DIR}/.github" ]; then
  echo "Setting up GitHub issue templates..."
  safe_copy_dir "${ASSETS_DIR}/.github" "${DEST_DIR}/.github"
fi

if [ -d "${ASSETS_DIR}/.gitlab" ]; then
  echo "Setting up GitLab issue templates..."
  safe_copy_dir "${ASSETS_DIR}/.gitlab" "${DEST_DIR}/.gitlab"
fi

# Create placeholders for plan and worklog if they do not exist
touch "${DEST_DIR}/plans/.gitkeep"
touch "${DEST_DIR}/worklog/.gitkeep"

# 3. Inject Language-specific rules if detected
if [ "${IS_GO_PROJECT}" = true ]; then
  echo "Injecting Go-specific rules..."
  # If AGENTS.md exists, append reference to go-applications.md
  if ! grep -q "go-applications.md" "${DEST_DIR}/AGENTS.md"; then
    echo -e "\n- Goアプリケーションの開発規約については、 [.claude/rules/go-applications.md](.claude/rules/go-applications.md) を参照し、それに従うこと " >> "${DEST_DIR}/AGENTS.md"
  fi
else
  # Clean up Go-specific files on non-Go projects
  rm -f "${DEST_DIR}/.claude/rules/go-applications.md" \
        "${DEST_DIR}/.gemini/rules/go-applications.md" || true
fi

# 4. Update destination .gitignore
echo "Updating .gitignore..."
GITIGNORE="${DEST_DIR}/.gitignore"
touch "${GITIGNORE}"

declare -a ignore_rules=(
  ""
  "# mr-driven-develop workflow ignores"
  "/.claude/usage-state/"
  "/.claude/session-logs/"
  "/.gemini/usage-state/"
  "/.gemini/session-logs/"
)

for rule in "${ignore_rules[@]}"; do
  if [ -z "${rule}" ]; then
    echo "" >> "${GITIGNORE}"
  elif ! grep -Fq "${rule}" "${GITIGNORE}"; then
    echo "${rule}" >> "${GITIGNORE}"
  fi
done

echo "=== Setup Completed Successfully! ==="
echo "The mr-driven-develop workflow assets have been applied to your repository."
echo ""

if [ "${HAS_WARNED}" = true ]; then
  echo "⚠️  ATTENTION: Some existing files differed from the template."
  echo "   Their previous contents have been saved with a '.bak' extension."
  echo "   Please review the differences and consult with your AI assistant to import"
  echo "   or merge your prior customizations."
  echo ""
fi

echo "Next Steps:"
echo "1. Check and customize '.mrworkflow.json' if needed."
if [ "${IS_GO_PROJECT}" = true ]; then
  echo "2. Verify that '.claude/rules/go-applications.md' exists in your project."
  echo "3. Run your tests with 'go test ./...' and linter with 'golangci-lint run' to make sure your local environment is set up."
  echo "4. Create an issue, then run '/issue-mr-flow start <issue-number>' to begin!"
else
  echo "2. Create an issue, then run '/issue-mr-flow start <issue-number>' to begin!"
fi