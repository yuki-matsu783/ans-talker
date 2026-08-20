#!/usr/bin/env bash
set -euo pipefail

# ロケールを UTF-8 に固定（日本語などのマルチバイトファイル名文字化け防止）
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

# 各種パスの定義
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_ROOT="$(cd "${SKILL_DIR}/../../.." && pwd)"
ASSETS_DIR="${SKILL_DIR}/assets"

echo "Syncing assets from project root [${PROJECT_ROOT}] to skill assets [${ASSETS_DIR}]..."

# クリーンなアセット用ディレクトリ構造を再作成
rm -rf "${ASSETS_DIR}"
mkdir -p "${ASSETS_DIR}"

# 1. .claude ディレクトリの同期（このスキル自体や機密性の高い一時設定などを除く）
echo "Syncing .claude files..."
mkdir -p "${ASSETS_DIR}/.claude"
for item in "${PROJECT_ROOT}/.claude/"*; do
  [ -e "${item}" ] || continue
  name=$(basename "${item}")
  if [ "${name}" = "skills" ]; then
    mkdir -p "${ASSETS_DIR}/.claude/skills"
    for skill_item in "${PROJECT_ROOT}/.claude/skills/"*; do
      [ -e "${skill_item}" ] || continue
      skill_name=$(basename "${skill_item}")
      if [ "${skill_name}" != "apply-mr-workflow-to-project" ]; then
        echo " -> Copying .claude skill: ${skill_name}"
        cp -R "${skill_item}" "${ASSETS_DIR}/.claude/skills/"
      fi
    done
  else
    echo " -> Copying .claude item: ${name}"
    cp -R "${item}" "${ASSETS_DIR}/.claude/"
  fi
done

# 2. .gemini ディレクトリの同期（無限ループや再帰処理を避けるため、このスキル自体を除く）
echo "Syncing .gemini files..."
mkdir -p "${ASSETS_DIR}/.gemini"
for item in "${PROJECT_ROOT}/.gemini/"*; do
  [ -e "${item}" ] || continue
  name=$(basename "${item}")
  if [ "${name}" = "skills" ]; then
    mkdir -p "${ASSETS_DIR}/.gemini/skills"
    for skill_item in "${PROJECT_ROOT}/.gemini/skills/"*; do
      [ -e "${skill_item}" ] || continue
      skill_name=$(basename "${skill_item}")
      if [ "${skill_name}" != "apply-mr-workflow-to-project" ]; then
        echo " -> Copying .gemini skill: ${skill_name}"
        cp -R "${skill_item}" "${ASSETS_DIR}/.gemini/skills/"
      fi
    done
  else
    echo " -> Copying .gemini item: ${name}"
    cp -R "${item}" "${ASSETS_DIR}/.gemini/"
  fi
done

# 3. .github テンプレートの同期
if [ -d "${PROJECT_ROOT}/.github" ]; then
  echo "Syncing .github templates..."
  mkdir -p "${ASSETS_DIR}/.github"
  cp -R "${PROJECT_ROOT}/.github/"* "${ASSETS_DIR}/.github/"
fi

# 4. .gitlab テンプレートの同期
if [ -d "${PROJECT_ROOT}/.gitlab" ]; then
  echo "Syncing .gitlab templates..."
  mkdir -p "${ASSETS_DIR}/.gitlab"
  cp -R "${PROJECT_ROOT}/.gitlab/"* "${ASSETS_DIR}/.gitlab/"
fi

# 5. プロジェクト設定および共通ルール、運用ドキュメントの同期
echo "Syncing root configurations and guides..."
cp -f "${PROJECT_ROOT}/.mrworkflow.json" "${ASSETS_DIR}/.mrworkflow.json" || true
cp -f "${PROJECT_ROOT}/AGENTS.md" "${ASSETS_DIR}/AGENTS.md" || true
cp -f "${PROJECT_ROOT}/GEMINI.md" "${ASSETS_DIR}/GEMINI.md" || true
cp -f "${PROJECT_ROOT}/CLAUDE.md" "${ASSETS_DIR}/CLAUDE.md" || true
cp -f "${PROJECT_ROOT}/HANDOFF.md" "${ASSETS_DIR}/HANDOFF.md" || true
cp -f "${PROJECT_ROOT}/index.md" "${ASSETS_DIR}/index.md" || true

# 6. スキル初期化時に生成された一時的なプレースホルダーファイルの削除
rm -rf "${SKILL_DIR}/references/example_reference.md" \
       "${SKILL_DIR}/scripts/example_script.cjs" \
       "${ASSETS_DIR}/example_asset.txt" || true

echo "✅  Asset synchronization complete."