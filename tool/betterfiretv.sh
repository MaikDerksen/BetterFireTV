#!/usr/bin/env bash
# BetterFireTV. Die ganze Logik steht in betterfiretv-core.sh. Sie wird hier komplett eingelesen,
# bevor etwas passiert: so kann ein Update der Dateien einen laufenden Durchgang nicht stören.
# Aufrufe: siehe Kopf von betterfiretv-core.sh (einrichten, rueckgaengig, backup, status,
# startbildschirm, hintergrund, screenshot).
source "$(dirname "${BASH_SOURCE[0]}")/betterfiretv-core.sh" && bftv_main "$@"
exit $?
