#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
helper="$repo_dir/scripts/sp11-support-tree-manifest.py"
temporary_parent="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
temporary_root=""

cleanup() {
  [ -n "$temporary_root" ] || return 0
  case "$temporary_root" in
    "$temporary_parent"/sp11-support-binding.*) rm -rf -- "$temporary_root" ;;
    *) echo "warning: refusing to remove unexpected support-binding fixture: $temporary_root" >&2 ;;
  esac
}
trap cleanup EXIT HUP INT TERM

for tool in cmp git grep mktemp python3 shasum tar; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "missing fixture tool: $tool" >&2
    exit 1
  }
done

temporary_root="$(mktemp -d "$temporary_parent/sp11-support-binding.XXXXXX")"
temporary_root="$(cd "$temporary_root" && pwd -P)"
fixture_repo="$temporary_root/repo"
mkdir -p \
  "$fixture_repo/docs" \
  "$fixture_repo/patches" \
  "$fixture_repo/scripts" \
  "$fixture_repo/tools"
printf 'fixture readme\n' > "$fixture_repo/README.md"
printf 'fixture docs\n' > "$fixture_repo/docs/guide.md"
printf 'fixture patch\n' > "$fixture_repo/patches/fix.patch"
printf '#!/usr/bin/env bash\nprintf "fixture\\n"\n' > "$fixture_repo/scripts/install.sh"
printf 'fixture tool\n' > "$fixture_repo/tools/helper.txt"
chmod 755 "$fixture_repo/scripts/install.sh"
git -C "$fixture_repo" init --quiet --initial-branch=fixture
git -C "$fixture_repo" config user.name 'SP11 support fixture'
git -C "$fixture_repo" config user.email 'sp11-support@example.invalid'
git -C "$fixture_repo" add .
git -C "$fixture_repo" commit --quiet -m 'Create support fixture'
original_commit="$(git -C "$fixture_repo" rev-parse 'HEAD^{commit}')"

manifest="$temporary_root/.sp11-support-tree-v1"
identities="$temporary_root/identities"
python3 "$helper" \
  --repo-dir "$fixture_repo" \
  --commit "$original_commit" \
  --output "$manifest" \
  --output-identities "$identities" >/dev/null
python3 "$helper" \
  --repo-dir "$fixture_repo" \
  --commit "$original_commit" \
  --verify-manifest "$manifest" \
  --actual-identities "$identities" >/dev/null
grep -Fq '100755 ' "$manifest"
grep -Fq ' scripts/install.sh' "$manifest"

expect_failure() {
  local label="$1" actual_manifest="$2" actual_identities="$3" expected="$4"
  if python3 "$helper" \
      --repo-dir "$fixture_repo" \
      --commit "$original_commit" \
      --verify-manifest "$actual_manifest" \
      --actual-identities "$actual_identities" \
      > "$temporary_root/$label.log" 2>&1; then
    echo "support-tree validator accepted $label" >&2
    exit 1
  fi
  grep -Fq "$expected" "$temporary_root/$label.log"
}

wrong_hash="$temporary_root/wrong-hash"
awk 'BEGIN { changed = 0 }
     $1 == "f" && changed == 0 {
       $4 = "0000000000000000000000000000000000000000000000000000000000000000"
       changed = 1
     }
     { print }' "$identities" > "$wrong_hash"
expect_failure byte-tamper "$manifest" "$wrong_hash" 'embedded support identity differs'

missing="$temporary_root/missing"
sed -n '2,$p' "$identities" > "$missing"
expect_failure missing "$manifest" "$missing" 'embedded support tree is missing'

extra="$temporary_root/extra"
cp "$identities" "$extra"
printf 'f 100644 5 %064d docs/unexpected.md\n' 0 >> "$extra"
expect_failure extra "$manifest" "$extra" 'embedded support tree contains an unexpected path'

mode_flip="$temporary_root/mode-flip"
awk 'BEGIN { changed = 0 }
     $1 == "f" && $2 == "100755" && changed == 0 {
       $2 = "100644"
       changed = 1
     }
     { print }
     END { if (changed == 0) exit 1 }' "$identities" > "$mode_flip"
expect_failure mode-flip "$manifest" "$mode_flip" 'embedded support identity differs'

staged="$temporary_root/staged"
mkdir "$staged"
(
  umask 022
  git -C "$fixture_repo" archive --format=tar "$original_commit" -- \
    README.md docs patches scripts tools | tar -x -C "$staged"
)
cp "$manifest" "$staged/.sp11-support-tree-v1"
chmod 644 "$staged/.sp11-support-tree-v1"
chmod 664 "$staged/docs/guide.md"
python3 "$helper" \
  --repo-dir "$fixture_repo" \
  --commit "$original_commit" \
  --normalize-directory "$staged" >/dev/null
python3 "$helper" \
  --repo-dir "$fixture_repo" \
  --commit "$original_commit" \
  --verify-directory "$staged" >/dev/null
chmod 755 "$staged/.sp11-support-tree-v1"
if python3 "$helper" \
    --repo-dir "$fixture_repo" \
    --commit "$original_commit" \
    --verify-directory "$staged" > "$temporary_root/manifest-mode.log" 2>&1; then
  echo 'support-tree validator accepted an executable generated manifest' >&2
  exit 1
fi
grep -Fq 'support manifest must have mode 0644' "$temporary_root/manifest-mode.log"
chmod 644 "$staged/.sp11-support-tree-v1"

expect_directory_failure() {
  local label="$1" expected="$2"
  if python3 "$helper" \
      --repo-dir "$fixture_repo" \
      --commit "$original_commit" \
      --verify-directory "$staged" > "$temporary_root/$label-directory.log" 2>&1; then
    echo "support-tree validator accepted staged $label" >&2
    exit 1
  fi
  grep -Fq "$expected" "$temporary_root/$label-directory.log"
}

chmod 600 "$staged/docs/guide.md"
expect_directory_failure file-mode 'wrong mode'
chmod 644 "$staged/docs/guide.md"

printf 'unexpected staged bytes\n' > "$staged/docs/unexpected.md"
expect_directory_failure extra-file 'unexpected path'
rm "$staged/docs/unexpected.md"

ln -s guide.md "$staged/docs/link.md"
expect_directory_failure symlink 'symlink or special entry'
rm "$staged/docs/link.md"

ln "$staged/docs/guide.md" "$staged/docs/hardlink.md"
expect_directory_failure hardlink 'reuses an inode'
rm "$staged/docs/hardlink.md"

printf 'replacement patch bytes\n' > "$fixture_repo/patches/fix.patch"
git -C "$fixture_repo" add patches/fix.patch
git -C "$fixture_repo" commit --quiet -m 'Create replacement commit'
replacement_commit="$(git -C "$fixture_repo" rev-parse 'HEAD^{commit}')"
git -C "$fixture_repo" replace "$original_commit" "$replacement_commit"
replacement_manifest="$temporary_root/replacement-manifest"
python3 "$helper" \
  --repo-dir "$fixture_repo" \
  --commit "$original_commit" \
  --output "$replacement_manifest" >/dev/null
cmp "$manifest" "$replacement_manifest"

if python3 "$helper" \
    --repo-dir "$fixture_repo" \
    --commit "$replacement_commit" \
    --verify-manifest "$manifest" \
    --actual-identities "$identities" > "$temporary_root/old-commit.log" 2>&1; then
  echo 'support-tree validator accepted an old-commit manifest for a new commit' >&2
  exit 1
fi
grep -Fq 'does not exactly match the committed support tree' "$temporary_root/old-commit.log"

echo 'Committed support-tree binding fixtures passed.'
