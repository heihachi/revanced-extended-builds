#!/usr/bin/env bash

set -euo pipefail

source utils.sh
trap "rm -rf temp/tmp.*" INT

: >build.md
mkdir -p "$BUILD_DIR" "$TEMP_DIR"

toml_prep "$(cat 2>/dev/null "${1:-config.toml}")" || abort "could not find config file '${1}'"
main_config_t=$(toml_get_table "")
COMPRESSION_LEVEL=$(toml_get "$main_config_t" compression-level) || abort "ERROR: compression-level is missing"
ENABLE_MAGISK_UPDATE=$(toml_get "$main_config_t" enable-magisk-update) || abort "ERROR: enable-magisk-update is missing"
PARALLEL_JOBS=$(toml_get "$main_config_t" parallel-jobs) || abort "ERROR: parallel-jobs is missing"
UPDATE_PREBUILTS=$(toml_get "$main_config_t" update-prebuilts) || abort "ERROR: update-prebuilts is missing"
BUILD_MINDETACH_MODULE=$(toml_get "$main_config_t" build-mindetach-module) || abort "ERROR: build-mindetach-module is missing"
LOGGING_F=$(toml_get "$main_config_t" logging-to-file) || LOGGING_F=false

if ((COMPRESSION_LEVEL > 9)) || ((COMPRESSION_LEVEL < 0)); then abort "compression-level must be from 0 to 9"; fi
if [ "$UPDATE_PREBUILTS" = true ]; then get_prebuilts; else set_prebuilts; fi
if [ "$BUILD_MINDETACH_MODULE" = true ]; then : >$PKGS_LIST; fi
if [ "$LOGGING_F" = true ]; then mkdir -p logs; fi
jq --version >/dev/null || abort "\`jq\` is not installed. install it with 'apt install jq' or equivalent"
get_cmpr

isoneof() {
	local i=$1 v
	shift
	for v; do [ "$v" = "$i" ] && return 0; done
	return 1
}

log "**App Versions:**"
idx=0
for table_name in $(toml_get_table_names); do
	if [ -z "$table_name" ]; then continue; fi
	t=$(toml_get_table "$table_name")
	enabled=$(toml_get "$t" enabled) || enabled=true
	if [ "$enabled" = false ]; then continue; fi

	if ((idx >= PARALLEL_JOBS)); then wait -n; else idx=$((idx + 1)); fi
	declare -A app_args
	excluded_patches=$(toml_get "$t" excluded-patches) || excluded_patches=""
	included_patches=$(toml_get "$t" included-patches) || included_patches=""
	exclusive_patches=$(toml_get "$t" exclusive-patches) || exclusive_patches=false
	app_args[version]=$(toml_get "$t" version) || app_args[version]="auto"
	app_args[app_name]=$(toml_get "$t" app-name) || app_args[app_name]=$table_name
	app_args[allow_alpha_version]=$(toml_get "$t" allow-alpha-version) || app_args[allow_alpha_version]=false
	app_args[build_mode]=$(toml_get "$t" build-mode) && {
		if ! isoneof "${app_args[build_mode]}" both apk module; then
			abort "ERROR: undefined build mode '${app_args[build_mode]}' for '${table_name}': only 'both', 'apk' or 'module' are allowed"
		fi
	} || app_args[build_mode]=apk
	app_args[microg_patch]=$(toml_get "$t" microg-patch) || app_args[microg_patch]=""
	app_args[uptodown_dlurl]=$(toml_get "$t" uptodown-dlurl) && {
		app_args[uptodown_dlurl]=${app_args[uptodown_dlurl]%/}
		app_args[uptodown_dlurl]=${app_args[uptodown_dlurl]%download}
		app_args[uptodown_dlurl]=${app_args[uptodown_dlurl]%/}
		app_args[dl_from]=UpToDown
	} || app_args[uptodown_dlurl]=""
	app_args[apkmirror_dlurl]=$(toml_get "$t" apkmirror-dlurl) && {
		app_args[apkmirror_dlurl]=${app_args[apkmirror_dlurl]%/}
		app_args[dl_from]=APKMirror
	} || app_args[apkmirror_dlurl]=""
	if [ -z "${app_args[dl_from]:-}" ]; then
		abort "ERROR: neither 'apkmirror_dlurl' nor 'uptodown_dlurl' were not set for '$table_name'."
	fi
	app_args[arch]=$(toml_get "$t" arch) && {
		if ! isoneof "${app_args[arch]}" all arm64-v8a arm-v7a; then
			abort "ERROR: ${app_args[arch]} is not a valid option for '$table_name': only 'all', 'arm64-v8a', 'arm-v7a' are allowed"
		fi
	} || app_args[arch]="all"
	app_args[module_prop_name]=$(toml_get "$t" module-prop-name) || {
		app_name_l=${app_args[app_name],,}
		if [ "${app_args[arch]}" = "all" ]; then
			app_args[module_prop_name]="${app_name_l}-rv-E85-magisk"
		else
			app_args[module_prop_name]="${app_name_l}-${app_args[arch]}-rv-E85-magisk"
		fi
	}
	app_args[patcher_args]="$(join_args "${excluded_patches}" -e) $(join_args "${included_patches}" -i)"
	[ "$exclusive_patches" = true ] && app_args[patcher_args]+=" --exclusive"
	if [ "${app_args[microg_patch]}" ] && [[ "${app_args[patcher_args]}" = *"${app_args[microg_patch]}"* ]]; then
		abort "ERROR: Do not include microg in included or excluded patches list"
	fi
	if [ "$LOGGING_F" = true ]; then
		logf=logs/"${table_name,,}.log"
		: >"$logf"
		(build_rv 2>&1 app_args | tee "$logf") &
	else
		build_rv app_args &
	fi
done
wait

rm -rf temp/tmp.*

if [ "$BUILD_MINDETACH_MODULE" = true ]; then
	echo "Building mindetach module"
	cp -f $PKGS_LIST mindetach-magisk/mindetach/detach.txt
	pushd mindetach-magisk/mindetach/
	zip -r ../../build/mindetach-"$(grep version= module.prop | cut -d= -f2)".zip .
	popd
fi

youtube_mode=$(toml_get "$(toml_get_table "YouTube")" "build-mode") || youtube_mode="module"
music_arm_mode=$(toml_get "$(toml_get_table "Music-arm")" "build-mode") || music_arm_mode="module"
music_arm64_mode=$(toml_get "$(toml_get_table "Music-arm64")" "build-mode") || music_arm64_mode="module"
if [ "$youtube_mode" != module ] || [ "$music_arm_mode" != module ] || [ "$music_arm64_mode" != module ]; then
	log "\nInstall [Vanced Microg](https://github.com/inotia00/VancedMicroG/releases) to be able to use non-root YouTube or Music"
fi
log "\n[revanced-extended-builds](https://github.com/E85Addict/revanced-extended-builds)"

echo "Done"
