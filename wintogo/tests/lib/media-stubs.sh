#!/usr/bin/env bash
#
# media-stubs.sh - a simulated media toolchain for build-media.sh's self-test.
#
# build-media.sh cannot run for real without xorriso, wimlib, mtools, dosfstools
# and gdisk. This dispatcher stands in for them so the script's own logic - ISO
# walking, staging, wim patching calls, splitting, FAT population, verification,
# manifest writing and the single-USB layout - is executed for real and can be
# asserted on.
#
# It is deliberately not a full emulator. Each stub does the minimum that lets the
# next step of build-media.sh proceed, and records enough state that the test can
# check what the script asked for:
#
#   $STUB_STATE/calls.log                    every invocation, one line each
#   $STUB_STATE/fat/<image>.d/<path>         the "filesystem" of each FAT image
#   $STUB_STATE/fat/<image>.formatted
#   $STUB_STATE/wim/<image>.entries          files added to each WIM
#   $STUB_STATE/sgdisk/<image>.args
#
# Invoked as: media-stubs.sh <tool-name> [args...]

set -uo pipefail

tool="${1:?tool name required}"
shift

state="${STUB_STATE:?STUB_STATE must be set}"
fake_iso="${FAKE_ISO:?FAKE_ISO must be set}"

mkdir -p "$state/fat" "$state/wim" "$state/sgdisk" "$state/sfdisk"
printf '%s|%s\n' "$tool" "$*" >> "$state/calls.log"

fat_root() {
    local image="$1"
    printf '%s/fat/%s.d' "$state" "$(basename "$image")"
}

case "$tool" in

# ---------------------------------------------------------------------------
xorriso)
    # Query mode: -indev <iso> -find / -name <name> -exec echo
    if printf '%s\n' "$*" | grep -q -- ' -find '; then
        wanted=""
        previous=""
        start_path="/"
        for argument in "$@"; do
            [ "$previous" = "-find" ] && start_path="$argument"
            [ "$previous" = "-name" ] && wanted="$argument"
            previous="$argument"
        done
        [ -n "$wanted" ] || exit 0
        # Directories match too (the fonts directory is fetched this way).
        start_path="${start_path%/}"
        hit="$(cd "$fake_iso" && find ".$start_path" -name "$wanted" 2>/dev/null | head -n1 | sed 's|^\.||')"
        [ -n "$hit" ] && printf '%s\n' "$hit"
        exit 0
    fi

    # Extraction mode: -osirrox on -indev <iso> -extract <path> <dest>
    if printf '%s\n' "$*" | grep -q -- ' -extract '; then
        source_path=""
        destination=""
        while [ $# -gt 0 ]; do
            if [ "$1" = "-extract" ]; then
                source_path="$2"
                destination="$3"
                break
            fi
            shift
        done
        [ -n "$source_path" ] || { echo 'stub xorriso: -extract without a path' >&2; exit 2; }
        [ -e "$fake_iso$source_path" ] || { echo "stub xorriso: not in ISO: $source_path" >&2; exit 2; }
        cp -R "$fake_iso$source_path" "$destination"
        exit $?
    fi

    # mkisofs mode: ... -o <output> ...
    output=""
    while [ $# -gt 0 ]; do
        [ "$1" = "-o" ] && output="$2"
        shift
    done
    if [ -n "$output" ]; then
        printf 'STUB-ISO-CONTAINER\n' > "$output"
    fi
    exit 0
    ;;

# ---------------------------------------------------------------------------
wimlib-imagex)
    subcommand="${1:-}"
    case "$subcommand" in
        info)
            printf 'Image index: 1\nArchitecture: x86_64\n'
            exit 0
            ;;
        dir)
            image="$2"
            cat "$state/wim/$(basename "$image").entries" 2>/dev/null
            exit 0
            ;;
        update)
            image="$2"
            entries="$state/wim/$(basename "$image").entries"
            touch "$entries"
            shift 2
            for argument in "$@"; do
                case "$argument" in
                    --command=*)
                        command_text="${argument#--command=}"
                        # Expected forms: add '<src>' '<dest>'
                        action="${command_text%% *}"
                        [ "$action" = "add" ] || continue
                        remainder="${command_text#add }"
                        remainder="$(printf '%s' "$remainder" | tr -d "'\"")"
                        source_item="${remainder%% *}"
                        destination_item="${remainder#* }"
                        if [ -d "$source_item" ]; then
                            ( cd "$source_item" && find . -type f | sed 's|^\./||' ) | while read -r relative; do
                                printf '%s/%s\n' "${destination_item%/}" "$relative" >> "$entries"
                            done
                        elif [ -f "$source_item" ]; then
                            printf '%s\n' "$destination_item" >> "$entries"
                        else
                            echo "stub wimlib: no such source: $source_item" >&2
                            exit 2
                        fi
                        ;;
                esac
            done
            exit 0
            ;;
        split)
            source_image="$2"
            destination_image="$3"
            size_mb="${4:-3800}"
            [ -f "$source_image" ] || { echo "stub wimlib: no image: $source_image" >&2; exit 2; }
            cp "$source_image" "$destination_image"
            # A second part, named the way wimlib names them.
            printf 'STUB-SWM-PART-2\n' > "$(printf '%s' "${destination_image%.swm}"2.swm)"
            exit 0
            ;;
        export)
            source_image="$2"
            destination_image="$4"
            cp "$source_image" "$destination_image"
            exit 0
            ;;
        *)
            echo "stub wimlib-imagex: unsupported subcommand: $subcommand" >&2
            exit 2
            ;;
    esac
    ;;

# ---------------------------------------------------------------------------
mkfs.vfat)
    image="${!#}"
    [ -f "$image" ] || { echo "stub mkfs.vfat: no image: $image" >&2; exit 2; }
    # A recognisable signature at offset 0, so the test can prove where the
    # filesystem ended up after it is embedded in a disk image.
    printf 'FATSTUB' | dd of="$image" bs=1 seek=0 conv=notrunc status=none
    touch "$state/fat/$(basename "$image").formatted"
    exit 0
    ;;

# ---------------------------------------------------------------------------
mmd|mcopy|mdir)
    image=""
    mpath=""
    while [ $# -gt 0 ]; do
        case "$1" in
            -i)
                image="$2"
                shift 2
                ;;
            ::/*)
                mpath="${1#::}"
                shift
                ;;
            *)
                other="$1"
                shift
                ;;
        esac
    done

    [ -n "$image" ] || { echo "stub $tool: no -i image" >&2; exit 2; }
    root="$(fat_root "$image")"

    case "$tool" in
        mmd)
            mkdir -p "$root$mpath"
            exit 0
            ;;
        mcopy)
            upstream="${other:?mcopy needs a source path}"
            [ -e "$upstream" ] || { echo "stub mcopy: no source: $upstream" >&2; exit 2; }
            mkdir -p "$(dirname "$root$mpath")"
            cp "$upstream" "$root$mpath"
            exit 0
            ;;
        mdir)
            if [ -d "$root$mpath" ]; then
                ls -1 "$root$mpath"
                exit 0
            elif [ -e "$root$mpath" ]; then
                printf '%s\n' "$(basename "$mpath")"
                exit 0
            else
                echo "stub mdir: not found: $mpath" >&2
                exit 1
            fi
            ;;
    esac
    ;;

# ---------------------------------------------------------------------------
ms-sys)
    # Writes Microsoft boot code; the record itself is opaque to the script, which
    # only cares that it was asked for. A marker at offset 0 lets the test prove
    # the volume boot record travelled into the disk image with the FAT volume.
    image="${!#}"
    [ -f "$image" ] || { echo "stub ms-sys: no image: $image" >&2; exit 2; }
    printf 'MS-SYS-CODE' | dd of="$image" bs=1 seek=0 conv=notrunc status=none
    exit 0
    ;;

# ---------------------------------------------------------------------------
sfdisk)
    # Real sfdisk writes the partition table and leaves existing boot code alone.
    # This stub writes the same bytes build-media.sh verifies afterwards.
    image="${!#}"
    [ -f "$image" ] || { echo "stub sfdisk: no image: $image" >&2; exit 2; }
    cat > "$state/sfdisk/$(basename "$image").args"
    printf '\x80' | dd of="$image" bs=1 seek=446 conv=notrunc status=none
    printf '\x0c' | dd of="$image" bs=1 seek=450 conv=notrunc status=none
    printf '\x55\xaa' | dd of="$image" bs=1 seek=510 conv=notrunc status=none
    exit 0
    ;;

# ---------------------------------------------------------------------------
sgdisk)
    # Record the requested layout; the image file itself is created by the script.
    image="${!#}"
    printf '%s\n' "$*" > "$state/sgdisk/$(basename "$image").args"
    exit 0
    ;;

*)
    echo "stub: unknown tool: $tool" >&2
    exit 2
    ;;
esac
