. /lib/partman/lib/auto-lvm.sh

# This is a copy of auto_lvm_prepare() with auto_init_disks() disabled
auto_multiboot_prepare() {
	local devs main_device extra_devices method size free_size normalscheme
	local pvscheme lvmscheme target dev devdir main_pv physdev
	devs="$1"
	method=$2

	size=0
	for dev in $devs; do
		[ -f $dev/size ] || return 1
		size=$(($size + $(cat $dev/size)))
	done

	set -- $devs
	main_device=$1
	shift
	extra_devices="$*"

	# Be sure the modules are loaded
	modprobe dm-mod >/dev/null 2>&1 || true
	modprobe lvm-mod >/dev/null 2>&1 || true

	if type update-dev >/dev/null 2>&1; then
		log-output -t update-dev update-dev --settle
	fi

	if [ "$extra_devices" ]; then
		for dev in $devs; do
			physdev=$(cat $dev/device)
			target="${target:+$target, }${physdev#/dev/}"
		done
		db_metaget partman-auto-lvm/text/multiple_disks description
		target=$(printf "$RET" "$target")
	else
		target="$(humandev $(cat $main_device/device)) - $(cat $main_device/model)"
	fi
	target="$target: $(longint2human $size)"
	free_size=$(convert_to_megabytes $size)

	choose_recipe lvm "$target" "$free_size" || return $?

	# Don't re-initialize disks
	#auto_init_disks $devs || return $?
	for dev in $devs; do
		get_last_free_partition_infos $dev

		# Check if partition is usable; use existing partman-auto
		# template as we depend on it
		if [ "$free_type" = unusable ]; then
			db_input critical partman-auto/unusable_space || true
			db_go || true
			return 1
		fi
	done

	# Change to any one of the devices - we arbitrarily pick the first -
	# to ensure that partman-auto can detect its label.  Of course this
	# only works if all the labels match, but that should be the case
	# since we just initialised them all following the same rules.
	cd "${devs%% *}"
	decode_recipe $recipe lvm
	cd -

	# Make sure the recipe contains lvmok tags
	if ! echo "$scheme" | grep -q lvmok; then
		bail_out unusable_recipe
	fi

	# Make sure a boot partition isn't marked as lvmok, unless the user
	# has told us it is ok for /boot to reside on a logical volume
	if echo "$scheme" | grep lvmok | grep -q "[[:space:]]/boot[[:space:]]"; then
		db_input critical partman-auto-lvm/no_boot || true
		db_go || return 255
		db_get partman-auto-lvm/no_boot || true
		[ "$RET" = true ] || bail_out unusable_recipe
	fi

	# This variable will be used to store the partitions that will be LVM
	# by create_partitions; zero it to be sure it's not cluttered.
	# It will be used later to provide real paths to partitions to LVM.
	# (still one atm)
	pv_devices=''

	### Situation
	### We have a recipe foo from arch bar. we don't know anything other than what
	### partitions can go on lvm ($lvmok{ } tag).
	### As output we need to have 2 recipes:
	### - recipe 1 (normalscheme) that will contain all non-lvm partitions including /boot.
	###            The /boot partition should already be defined in the schema.
	### - recipe 2 everything that can go on lvm and it's calculated in perform_recipe_by_lvm.

	# Get the scheme of partitions that must be created outside LVM
	normalscheme=$(echo "$scheme" | grep -v lvmok)
	lvmscheme=$(echo "$scheme" | grep lvmok)

	# Check if the scheme contains a boot partition; if not warn the user
	# Except for powerpc/prep as that has the kernel in the prep partition
	if type archdetect >/dev/null 2>&1; then
		archdetect=$(archdetect)
	else
		archdetect=unknown/generic
	fi

	case $archdetect in
	    powerpc/prep)
		: ;;
	    *)
		# TODO: make check more explicit, mountpoint{ / }?
		if ! echo "$normalscheme" | grep -q "[[:space:]]/[[:space:]]" && \
		   ! echo "$normalscheme" | grep -q "[[:space:]]/boot[[:space:]]"; then
			db_input critical partman-auto-lvm/no_boot || true
			db_go || return 255
			db_get partman-auto-lvm/no_boot || true
			[ "$RET" = true ] || return 255
		fi
		;;
	esac

	main_pv=$(cat $main_device/device)

	# Partitions with method $method will hold Physical Volumes
	pvscheme=$(echo "$normalscheme" | grep "method{ $method }")

	# Start with partitions that are outside LVM and not PVs
	scheme="$(echo "$normalscheme" | grep -v "method{ $method }")"
	# Add partitions declared to hold PVs on the main device
	scheme="$scheme$NL$(echo "$pvscheme" | grep "device{ $main_pv[[:digit:]]* }")"
	# Add partitions declared to hold PVs without specifying a device
	scheme="$scheme$NL$(echo "$pvscheme" | grep -v 'device{')"
	# If we still don't have a partition to hold PV, add it
	if ! echo "$scheme" | grep -q "method{ $method }"; then
		scheme="$(add_envelope "$scheme")"
	fi
	auto_lvm_create_partitions $main_device

	# Create partitions for PVs on extra devices
	for dev in $extra_devices; do
		physdev=$(cat $dev/device)
		scheme="$(echo "$pvscheme" | grep "device{ $physdev[[:digit:]]* }")"
		if [ -z "$scheme" ]; then
			scheme="$(add_envelope "")"
		fi
		auto_lvm_create_partitions $dev
	done

	# Extract the mapping of which VG goes onto which PV
	auto_lvm_create_vg_map

	if ! confirm_changes partman-lvm; then
		return 255
	fi

	disable_swap
	# Write the partition tables
	for dev in $devs; do
		cd $dev
		open_dialog COMMIT
		close_dialog
		device_cleanup_partitions
	done
	update_all
}
