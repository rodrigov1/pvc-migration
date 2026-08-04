#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

scripts=(
	"$ROOT_DIR/pvc-migration.sh"
	"$ROOT_DIR"/commands/*.sh
	"$ROOT_DIR"/lib/*.sh
	"$ROOT_DIR"/ui/*.sh
	"$ROOT_DIR"/tests/*.sh
	"$ROOT_DIR"/vm-pvc/*.sh
)

for script in "${scripts[@]}"; do
	bash -n "$script"
done

bash "$ROOT_DIR/tests/args.sh"
bash "$ROOT_DIR/tests/smoke_dispatcher.sh"
bash "$ROOT_DIR/tests/reclaim_policy.sh"
bash "$ROOT_DIR/tests/copy_result.sh"
bash "$ROOT_DIR/tests/verification_manifest.sh"
bash "$ROOT_DIR/tests/backup_baseline.sh"
bash "$ROOT_DIR/tests/remote_session.sh"

if command -v shellcheck &>/dev/null; then
	shellcheck --shell=bash \
		"$ROOT_DIR/pvc-migration.sh" \
		"$ROOT_DIR"/commands/*.sh \
		"$ROOT_DIR"/lib/*.sh \
		"$ROOT_DIR"/ui/*.sh
else
	printf 'ShellCheck not installed; static analysis skipped.\n'
fi

printf 'All available checks passed.\n'
