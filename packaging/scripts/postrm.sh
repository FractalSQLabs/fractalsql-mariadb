#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#
# fpm --before-remove hook, shared by the .deb and the .rpm. Stops and
# disables fractalsqld. Runs on both an upgrade's remove-old step and a true
# removal; safe either way, since a new version's postinst re-enables and
# restarts it, and the key, config, and fractalsql user are never deleted
# here (so a reinstall does not need to regenerate the shared HMAC key).
set -e

systemctl stop fractalsqld.service >/dev/null 2>&1 || true
systemctl disable fractalsqld.service >/dev/null 2>&1 || true
