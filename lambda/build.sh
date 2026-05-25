#!/usr/bin/env bash
# Build the Lambda deployment package
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
echo "Building lambda/failover.zip..."
zip -j failover.zip lambda_function.py
echo "Done: $(du -h failover.zip | cut -f1) failover.zip"
