#!/bin/bash
# push_homebrew.sh — Update a Homebrew cask in a tap and optionally open a PR.
# Requires [homebrew] section in catapult.toml and a cask.rb template in the app
# repo root (or pointed to via homebrew.cask_template).
#
# Usage: push_homebrew.sh [--pull-request] [version]

PULL_REQUEST=false
ARGS=()
for arg in "$@"; do
    case "$arg" in
        -h|--help)
            sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        --pull-request) PULL_REQUEST=true ;;
        *) ARGS+=("$arg") ;;
    esac
done

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

if [ -z "${CATAPULT_HAS_HOMEBREW:-}" ]; then
    echo "❌ [homebrew] section missing from catapult.toml"
    exit 1
fi

cd "$CATAPULT_APP_ROOT"

export GH_TOKEN="${GITHUB_PERSONAL_ACCESS_TOKEN:-${GH_TOKEN:-}}"

RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; NC='\033[0m'

APP_NAME="$CATAPULT_APP_NAME"
SLUG="$CATAPULT_APP_SLUG"
TARGET="$CATAPULT_BUILD_TARGET_TRIPLE"
DIST_DIR="$CATAPULT_DIST_DIR"

BREW_NAME="${CATAPULT_HOMEBREW_CASK_NAME:-$SLUG}"
CASK_TEMPLATE="${CATAPULT_HOMEBREW_CASK_TEMPLATE:-${CATAPULT_APP_ROOT}/cask.rb}"
if [ ! -f "$CASK_TEMPLATE" ]; then
    echo "❌ Cask template not found: $CASK_TEMPLATE"
    exit 1
fi

HOMEBREW_TAP_URL="${HOMEBREW_TAP_URL:-https://github.com/Homebrew/homebrew-cask.git}"
HOMEBREW_REPO=$(echo "$HOMEBREW_TAP_URL" | sed 's|https://github.com/||' | sed 's|\.git$||')
HOMEBREW_DIR=$(basename "$HOMEBREW_TAP_URL" .git)
TAP_NAME=$(echo "$HOMEBREW_REPO" | sed 's|/homebrew-|/|')
CASK_FILE="Casks/${BREW_NAME:0:1}/${BREW_NAME}.rb"

VERSION="${ARGS[0]:-$(git describe --tags --abbrev=0 2>/dev/null || echo "")}"
if [ -z "$VERSION" ]; then
    echo -e "${RED}❌ Version required${NC}"
    exit 1
fi

DMG_FILE="${SLUG}-${VERSION}-${TARGET}.dmg"
SHA_FILE="${DMG_FILE}.sha256"

if [ ! -f "${DIST_DIR}/${SHA_FILE}" ]; then
    echo -e "${RED}❌ ${DIST_DIR}/${SHA_FILE} not found — run build.sh ${VERSION} first${NC}"
    exit 1
fi

SHA256=$(awk '{print $1}' "${DIST_DIR}/${SHA_FILE}")

echo -e "${BLUE}🍺 Updating Homebrew cask for ${APP_NAME} v${VERSION}${NC}"
echo ""

# Clone/update tap in sibling dir
APP_DIR_NAME=$(basename "$CATAPULT_APP_ROOT")
cd ..
if [ -d "$HOMEBREW_DIR" ]; then
    cd "$HOMEBREW_DIR"
else
    git clone "$HOMEBREW_TAP_URL" "$HOMEBREW_DIR"
    cd "$HOMEBREW_DIR"
fi

if ! git remote get-url upstream >/dev/null 2>&1; then
    git remote add upstream "$HOMEBREW_TAP_URL"
fi

git fetch upstream
# Park HEAD on main before resetting so a parallel run's in-progress
# bump branch can't be silently moved out from under it.
git checkout main 2>/dev/null || git checkout -B main upstream/main
git reset --hard upstream/main
echo ""

BRANCH="bump-${BREW_NAME}-${VERSION}"
git checkout -B "$BRANCH" upstream/main
echo -e "${GREEN}✅ Created branch $BRANCH${NC}"
echo ""

echo "📝 Updating cask file..."
mkdir -p "$(dirname "$CASK_FILE")"
sed -e "s|{{VERSION}}|${VERSION}|g" \
    -e "s|{{SHA256}}|${SHA256}|g" \
    "$CASK_TEMPLATE" > "$CASK_FILE"
echo ""

git --no-pager diff "$CASK_FILE"
echo ""

git add "$CASK_FILE"
git commit -m "${BREW_NAME} ${VERSION}"
echo ""

TAP_CASK="${TAP_NAME}/${BREW_NAME}"
cleanup() {
    brew uninstall --cask "$TAP_CASK" 2>/dev/null || true
    brew untap --force "$TAP_NAME" 2>/dev/null || true
}
trap cleanup EXIT

echo "🧪 Testing cask..."
rm -f ~/Library/Caches/Homebrew/downloads/*${APP_NAME}*
brew untap --force "$TAP_NAME" 2>/dev/null || true
brew tap "$TAP_NAME" "$(pwd)"

brew style --fix "$CASK_FILE"
if ! git diff --quiet "$CASK_FILE"; then
    echo "📝 Style fixes applied, amending..."
    git add "$CASK_FILE"
    git commit --amend --no-edit
fi

brew audit ${AUDIT_FLAGS:-} "$TAP_CASK"
HOMEBREW_NO_INSTALL_FROM_API=1 brew install --cask "$TAP_CASK"

cleanup
trap - EXIT
echo -e "${GREEN}✅ Tests passed${NC}"
echo ""

echo "🚀 Pushing to GitHub..."
git push --force origin "$BRANCH"
echo ""

if [ "$PULL_REQUEST" = true ]; then
    echo "📬 Creating pull request..."
    REPO_INFO=$(gh repo view "$HOMEBREW_REPO" --json isFork,parent,defaultBranchRef 2>/dev/null)
    IS_FORK=$(echo "$REPO_INFO" | python3 -c "import json,sys; print(json.load(sys.stdin).get('isFork', False))")

    if [ "$IS_FORK" = "True" ]; then
        PARENT_SLUG=$(echo "$REPO_INFO" | python3 -c "import json,sys; print(json.load(sys.stdin)['parent']['nameWithOwner'])")
        PR_BASE=$(gh repo view "$PARENT_SLUG" --json defaultBranchRef -q '.defaultBranchRef.name')
        OWNER=$(echo "$HOMEBREW_REPO" | cut -d/ -f1)
        PR_REPO="$PARENT_SLUG"
        PR_HEAD="${OWNER}:${BRANCH}"
    else
        PR_BASE=$(echo "$REPO_INFO" | python3 -c "import json,sys; print(json.load(sys.stdin)['defaultBranchRef']['name'])")
        PR_REPO="$HOMEBREW_REPO"
        PR_HEAD="$BRANCH"
    fi

    DOWNLOAD_URL_TEMPLATE="${CATAPULT_S3_DOWNLOAD_URL_TEMPLATE:-}"
    if [ -n "$DOWNLOAD_URL_TEMPLATE" ]; then
        DMG_URL="${DOWNLOAD_URL_TEMPLATE//\{version\}/$VERSION}"
        DMG_URL="${DMG_URL//\{target\}/$TARGET}"
    else
        DMG_URL="(see cask)"
    fi

    gh pr create \
        --repo "$PR_REPO" \
        --head "$PR_HEAD" \
        --base "$PR_BASE" \
        --title "${BREW_NAME} ${VERSION}" \
        --body "Updates ${BREW_NAME} to version ${VERSION}.

- URL: ${DMG_URL}
- SHA256: ${SHA256}"
fi

echo -e "${GREEN}🎉 Done!${NC}"
