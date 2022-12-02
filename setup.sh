#!/bin/bash

check_command() {
	command -v "$1" >/dev/null 2>&1
}

if ! check_command jq; then
	echo "jq not found, please install it, https://stedolan.github.io/jq/download/"
	exit 1
fi

OS_NAME=$(echo "$RUNNER_OS" | awk '{print tolower($0)}')
MANIFEST_BASE_URL="https://storage.googleapis.com/flutter_infra_release/releases"
MANIFEST_URL="$MANIFEST_BASE_URL/releases_$OS_NAME.json"
MANIFEST_TEST_FIXTURE="$(dirname -- "${BASH_SOURCE[0]}")/test/releases_$OS_NAME.json"

legacy_wildcard_version() {
	if [[ $1 == any ]]; then
		jq --arg version "$2" '.releases | map(select(.version | startswith($version) )) | first'
	else
		jq --arg channel "$1" --arg version "$2" '.releases | map(select(.channel==$channel) | select(.version | startswith($version) )) | first'
	fi
}

wildcard_version() {
	if [[ $1 == any ]]; then
		jq --arg version "$2" --arg arch "$3" '.releases | map(select(.version | startswith($version)) | select(.dart_sdk_arch == null or .dart_sdk_arch == $arch)) | first'
	else
		jq --arg channel "$1" --arg version "$2" --arg arch "$3" '.releases | map(select(.channel==$channel) | select(.version | startswith($version) ) | select(.dart_sdk_arch == null or .dart_sdk_arch == $arch)) | first'
	fi
}

get_version() {
	if [[ "$1" == any && "$2" == any ]]; then # latest_version
		jq --arg arch "$3" '.releases | map(select(.dart_sdk_arch == null or .dart_sdk_arch == $arch)) | first'
	elif [[ "$2" == any ]]; then # latest channel version
		jq --arg channel "$1" --arg arch "$3" '.releases | map(select(.channel==$channel) | select(.dart_sdk_arch == null or .dart_sdk_arch == $arch)) | first'
	else
		wildcard_version "$1" "$2" "$3"
	fi
}

normalize_version() {
	if [[ "$1" == *.x ]]; then
		echo "${1/.x/}"
	else
		echo "$1"
	fi
}

not_found_error() {
	echo "Unable to determine Flutter version for channel: $1 version: $2 architecture: $3"
}

transform_path() {
	if [[ "$OS_NAME" == windows ]]; then
		echo "$1" | sed -e 's/^\///' -e 's/\//\\/g'
	else
		echo "$1"
	fi
}

download_archive() {
	archive_url="$MANIFEST_BASE_URL/$1"
	archive_name=$(basename "$1")
	archive_local="$RUNNER_TEMP/$archive_name"

	curl --connect-timeout 15 --retry 5 "$archive_url" >"$archive_local"

	mkdir -p "$2"

	if [[ "$archive_name" == *zip ]]; then
		unzip -q -o "$archive_local" -d "$RUNNER_TEMP"
		# Remove the folder again so that the move command can do a simple rename
		# instead of moving the content into the target folder.
		# This is a little bit of a hack since the "mv --no-target-directory"
		# linux option is not available here
		rm -r "$2"
		mv "$RUNNER_TEMP"/flutter "$2"
	else
		tar xf "$archive_local" -C "$2" --strip-components=1
	fi

	rm "$archive_local"
}

CACHE_PATH=""
CACHE_KEY=""
PRINT_MODE=""
USE_TEST_FIXTURE=false
ARCH=""
VERSION=""

while getopts 'tc:k:pa:n:' flag; do
	case "$flag" in
	c) CACHE_PATH="$OPTARG" ;;
	k) CACHE_KEY="$OPTARG" ;;
	p) PRINT_MODE=true ;;
	t) USE_TEST_FIXTURE=true ;;
	a) ARCH="$(echo "$OPTARG" | awk '{print tolower($0)}')" ;;
	n) VERSION="$OPTARG" ;;
	?) exit 2 ;;
	esac
done

ARR_CHANNEL=("${@:$OPTIND:1}")
CHANNEL="${ARR_CHANNEL[0]}"

[[ -z $CHANNEL ]] && CHANNEL=stable
[[ -z $VERSION ]] && VERSION=any
[[ -z $ARCH ]] && ARCH=x64
[[ -z $CACHE_PATH ]] && CACHE_PATH="$RUNNER_TEMP/flutter/:channel:-:version:-:arch:"
[[ -z $CACHE_KEY ]] && CACHE_KEY="flutter-:os:-:channel:-:version:-:arch:-:hash:"

RELEASE_MANIFEST=""
VERSION_MANIFEST=""

get_version_manifest() {
	version_normalized=$(normalize_version "$VERSION")
	echo "Loading manifest --- normalized: $version_normalized"
	version_manifest=$(echo "$RELEASE_MANIFEST" | get_version "$CHANNEL" "$version_normalized" "$ARCH")

	echo "Loading manifest --- version: $version_manifest"
	if [[ "$version_manifest" == null ]]; then
		version_manifest=$(echo "$RELEASE_MANIFEST" | legacy_wildcard_version "$CHANNEL" "v$version_normalized")
	fi

	version_arch=$(echo "$version_manifest" | jq -r '.dart_sdk_arch')
	echo "Loading manifest --- prefinal version arch: $version_arch"

	if [[ "$version_arch" == null ]]; then
		if [[ "$ARCH" == x64 ]]; then
			echo "$version_manifest" | jq --arg dart_sdk_arch x64 '.+={dart_sdk_arch:$dart_sdk_arch}'
		else
			echo ""
		fi
	else
		echo "$version_manifest"
	fi

	echo "Loading manifest --- final ref: version_manifest: $version_manifest, version_arch: $version_arch"
}

expand_key() {
	version_channel=$(echo "$VERSION_MANIFEST" | jq -r '.channel')
	version_version=$(echo "$VERSION_MANIFEST" | jq -r '.version')
	version_arch=$(echo "$VERSION_MANIFEST" | jq -r '.dart_sdk_arch')
	version_hash=$(echo "$VERSION_MANIFEST" | jq -r '.hash')
	version_sha_256=$(echo "$VERSION_MANIFEST" | jq -r '.sha256')

	expanded_key="${1/:channel:/$version_channel}"
	expanded_key="${expanded_key/:version:/$version_version}"
	expanded_key="${expanded_key/:arch:/$version_arch}"
	expanded_key="${expanded_key/:hash:/$version_hash}"
	expanded_key="${expanded_key/:sha256:/$version_sha_256}"
	expanded_key="${expanded_key/:os:/$OS_NAME}"

	echo "$expanded_key"
}

if [[ "$PRINT_MODE" == true ]]; then
	if [[ "$USE_TEST_FIXTURE" == true ]]; then
		RELEASE_MANIFEST=$(cat "$MANIFEST_TEST_FIXTURE")
	else
		RELEASE_MANIFEST=$(curl --connect-timeout 15 --retry 5 "$MANIFEST_URL")
	fi
  echo "DD: Loading manifest success"

	if [[ "$CHANNEL" == master ]]; then
		VERSION_MANIFEST="{\"channel\":\"$CHANNEL\",\"version\":\"$CHANNEL\",\"dart_sdk_arch\":\"$ARCH\",\"hash\":\"$CHANNEL\",\"sha256\":\"$CHANNEL\"}"
	else
		VERSION_MANIFEST=$(get_version_manifest)
	fi
  echo "DD: Loading channel $VERSION_MANIFEST"

	if [[ -z "$VERSION_MANIFEST" ]]; then
		not_found_error "$CHANNEL" "$VERSION" "$ARCH"
		exit 1
	fi

	version_info=$(echo "$VERSION_MANIFEST" | jq -j '.channel,":",.version,":",.dart_sdk_arch')
  echo "DD: Loading vinfo $version_info"

	if [[ "$version_info" == *null* ]]; then
		not_found_error "$CHANNEL" "$VERSION" "$ARCH"
		exit 1
	fi
	
	echo "DD: Load manifest success $VERSION_MANIFEST"
	
	info_channel=$(echo "$version_info" | awk -F ':' '{print $1}')
	info_version=$(echo "$version_info" | awk -F ':' '{print $2}')
	info_architecture=$(echo "$version_info" | awk -F ':' '{print $3}')
	expanded_key=$(expand_key "$CACHE_KEY")
	cache_path=$(transform_path "$CACHE_PATH")
	expanded_path=$(expand_key "$cache_path")

	if [[ "$USE_TEST_FIXTURE" == true ]]; then
		echo "CHANNEL=$info_channel"
		echo "VERSION=$info_version"
		echo "ARCHITECTURE=$info_architecture"
		echo "CACHE-KEY=$expanded_key"
		echo "CACHE-PATH=$expanded_path"
		exit 0
	fi

	{
		echo "CHANNEL=$info_channel"
		echo "VERSION=$info_version"
		echo "ARCHITECTURE=$info_architecture"
		echo "CACHE-KEY=$expanded_key"
		echo "CACHE-PATH=$expanded_path"
	} >> "$GITHUB_OUTPUT"

	exit 0
fi

CACHE_PATH=$(transform_path "$CACHE_PATH")
SDK_CACHE=$(expand_key "$CACHE_PATH")
PUB_CACHE=$(expand_key "$SDK_CACHE/.pub-cache")

if [[ ! -x "$SDK_CACHE/bin/flutter" ]]; then
  	echo "DD: Load bin/flutter with channel: $CHANNEL"
	if [[ $CHANNEL == master ]]; then
		git clone -b master https://github.com/flutter/flutter.git "$SDK_CACHE"
	else
		RELEASE_MANIFEST=$(curl --connect-timeout 15 --retry 5 "$MANIFEST_URL")
		VERSION_MANIFEST=$(get_version_manifest)

		if [[ -z "$VERSION_MANIFEST" ]]; then
			not_found_error "$CHANNEL" "$VERSION" "$ARCH"
			exit 1
		fi

		ARCHIVE_PATH=$(echo "$VERSION_MANIFEST" | jq -r '.archive')
		download_archive "$ARCHIVE_PATH" "$SDK_CACHE"
	fi
	  echo "DD: Loaded bin/flutter with channel: $CHANNEL"
fi

{
	echo "FLUTTER_ROOT=$SDK_CACHE"
	echo "PUB_CACHE=$PUB_CACHE"
} >>"$GITHUB_ENV"

{
	echo "$SDK_CACHE/bin"
	echo "$SDK_CACHE/bin/cache/dart-sdk/bin"
	echo "$PUB_CACHE/bin"
} >>"$GITHUB_PATH"
