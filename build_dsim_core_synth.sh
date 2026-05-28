#!/usr/bin/env bash
# Parse/elaborate the ASIC core RTL view with DSim.
#
# This is a boundary check, not a simulator platform build. It compiles
# rv64gc_core_top with SYNTHESIS defined and deliberately excludes testbenches,
# platform devices, and src/rtl/sim helpers.
set -euo pipefail

cd "$(dirname "$0")"

: "${DSIM_HOME:=$HOME/AltairDSim/2026}"

if [[ ! -f "$DSIM_HOME/shell_activate.bash" ]]; then
    echo "ERROR: DSim not found at $DSIM_HOME"
    exit 1
fi

set +u
# shellcheck disable=SC1091
source "$DSIM_HOME/shell_activate.bash" >/dev/null
set -u

if [[ -z "${DSIM_LICENSE:-}" ]]; then
    if [[ -f "$HOME/metrics-ca/dsim-license.json" ]]; then
        export DSIM_LICENSE="$HOME/metrics-ca/dsim-license.json"
    elif [[ -f "$HOME/.metrics-ca/dsim-license.json" ]]; then
        export DSIM_LICENSE="$HOME/.metrics-ca/dsim-license.json"
    fi
fi

mapfile -t SV_FILES < <(
    awk '
        {
            for (idx = 1; idx <= NF; idx++) {
                gsub(/\\$/, "", $idx);
                if ($idx ~ /\.sv$/ &&
                    $idx !~ /^src\/rtl\/sim\// &&
                    $idx !~ /^src\/tb\// &&
                    $idx !~ /^src\/rtl\/platform\// &&
                    $idx != "src/rtl/sim/mem_if_pkg.sv") {
                    print $idx;
                }
            }
        }
    ' build_dsim_linux.sh
)

if [[ ${#SV_FILES[@]} -eq 0 ]]; then
    echo "ERROR: no SystemVerilog files found in build_dsim_linux.sh"
    exit 1
fi

rm -rf dsim_core_synth_work

dsim -sv +define+SYNTHESIS -no-sva \
     +incdir+external/cvfpu-src/src/common_cells/include \
     -work dsim_core_synth_work \
     -top rv64gc_core_top \
     -genimage rv64gc_core_synth_image \
     -l dsim_core_synth_build.log \
     "${SV_FILES[@]}"

echo
echo "DSim core synthesis-view parse OK. Image at dsim_core_synth_work/rv64gc_core_synth_image.so"
