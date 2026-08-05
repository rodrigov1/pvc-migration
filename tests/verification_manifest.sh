#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/pvc-migration.sh"

ssh() {
	local host="$1" remote_command="$2"
	bash -c "$remote_command"
}

state_get_mounts() {
	MOUNT_COUNT=1
	MOUNTS_LIST=("/data")
	SUBPATHS_LIST=("")
}

STATE_BASE=$(mktemp -d)
source_root=$(mktemp -d)
destination_root=$(mktemp -d)
mkdir -p "$source_root/empty directory" "$destination_root/empty directory"
printf 'baseline data\n' >"$source_root/regular file.txt"
printf 'newline path\n' >"$source_root/$'file\nwith-newline'"
ln -s 'regular file.txt' "$source_root/link with space"
cp -a "$source_root/regular file.txt" "$destination_root/regular file.txt"
cp -a "$source_root/$'file\nwith-newline'" "$destination_root/$'file\nwith-newline'"
ln -s 'regular file.txt' "$destination_root/link with space"
touch -h -r "$source_root/link with space" "$destination_root/link with space"
touch -r "$source_root" "$destination_root"
touch -r "$source_root/empty directory" "$destination_root/empty directory"

verification_capture_side test-context test-namespace test-migration OLD \
	local-host "$source_root"
verification_capture_side test-context test-namespace test-migration NEW \
	local-host "$destination_root"

old_content=$(verification_manifest_path test-context test-namespace test-migration OLD 1 content)
old_metadata=$(verification_manifest_path test-context test-namespace test-migration OLD 1 metadata)
new_content=$(verification_manifest_path test-context test-namespace test-migration NEW 1 content)
new_metadata=$(verification_manifest_path test-context test-namespace test-migration NEW 1 metadata)

if ! cmp -s "$old_content" "$new_content" || ! cmp -s "$old_metadata" "$new_metadata"; then
	printf 'Identical trees with special paths must produce identical manifests\n' >&2
	printf '%s\n' '--- old metadata ---' >&2
	tr '\0' '\n' <"$old_metadata" >&2
	printf '%s\n' '--- new metadata ---' >&2
	tr '\0' '\n' <"$new_metadata" >&2
	exit 1
fi

if verification_compare_sides test-context test-namespace test-migration >/dev/null 2>&1; then
	:
else
	printf 'Identical baseline manifests must compare successfully\n' >&2
	exit 1
fi

printf 'changed data\n' >"$destination_root/regular file.txt"
verification_capture_side test-context test-namespace test-migration NEW \
	local-host "$destination_root"
if verification_compare_sides test-context test-namespace test-migration >/dev/null 2>&1; then
	printf 'Content differences must fail baseline verification\n' >&2
	exit 1
fi
if [[ "$(state_get test-context test-namespace test-migration VERIFY_STATUS)" != failed ]]; then
	printf 'Failed baseline verification must persist failed status\n' >&2
	exit 1
fi

cp -p "$source_root/regular file.txt" "$destination_root/regular file.txt"
chmod 0600 "$destination_root/regular file.txt"
verification_capture_side test-context test-namespace test-migration NEW \
	local-host "$destination_root"
if verification_compare_sides test-context test-namespace test-migration >/dev/null 2>&1; then
	printf 'Permission differences must fail baseline verification\n' >&2
	exit 1
fi

rm -f "$source_root/regular file.txt" "$source_root/$'file\nwith-newline'" \
	"$source_root/link with space" "$destination_root/regular file.txt" \
	"$destination_root/$'file\nwith-newline'" "$destination_root/link with space"
rmdir "$source_root/empty directory" "$source_root" \
	"$destination_root/empty directory" "$destination_root"
rm -rf -- "$STATE_BASE"

printf 'Verification manifest tests passed.\n'
