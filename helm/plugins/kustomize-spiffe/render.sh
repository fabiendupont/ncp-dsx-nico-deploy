#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 Red Hat, Inc. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Helm post-renderer plugin for Kustomize-based SPIFFE patching.
# Usage: helm install ... --post-renderer kustomize-spiffe --post-renderer-args <kustomize-dir>

set -euo pipefail

KUSTOMIZE_DIR="${1:?Usage: --post-renderer-args <path-to-kustomize-dir>}"

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

cat > "$TMPDIR/all.yaml"
cp -r "$KUSTOMIZE_DIR/"* "$TMPDIR/"

cd "$TMPDIR"
kustomize build .
