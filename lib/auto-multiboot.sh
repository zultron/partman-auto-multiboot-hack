. /lib/partman/lib/auto-lvm.sh
. /lib/partman/lib/lvm-remove.sh

# Create $pv_devices list
# Partial copy of auto-shared.sh:create_primary_partitions()
check_primary_partitions() {
    logger "in check_primary_partitions"
    logger "free_type $free_type"

    local partid ondev num id size type fs path name

    # copy the first few lines of create_primary_partitions

    cd $dev

    while echo $scheme | grep -q '\$primary{'; do
	pull_primary
	logger "primary $primary"
	logger "scheme_rest $scheme_rest"
	set -- $primary

	# skip creating/deleting partitions

	# collect list of pv_devices from our scheme
	shift; shift; shift; shift
	if echo "$*" | grep -q "vg_name{"; then
	    vgname="$(echo $* | sed -n 's/.*vg_name{ \([^}]*\) }.*/\1/p')"
	    logger "found vg_name{ $vgname }"
	    for pv in $(pv_list); do
		logger "found pv $pv"
		vg=$(pv_get_vg $pv)
		logger "found vg $vg"
		if [ "$vg" = "$vgname" ]; then
		    logger "matched needed vg"
		    pv_devices="$pv_devices $pv"
		fi
	    done
	fi
	logger "pv_devices $pv_devices"

	# if method is multiboot and ondev{ } is set,
	# try to match with an existing partition
	if echo "$*" | grep -q "method{ multiboot }" && \
	    echo "$*" | grep -q '\$ondev{'; then

	    ondev="$(echo $* | sed -n 's/.*ondev{ \([^}]*\) }.*/\1/p')"

	    logger "Found primary partition with method multiboot, ondev = $ondev"

	    open_dialog PARTITIONS
	    while { read_line num id size type fs path name; [ "$id" ]; }; do
		[ "$fs" == free ] && continue
		[ "$type" == primary ] || continue
		if test "$path" = "$ondev"; then
		    partid="$id"
		fi
	    done
	    close_dialog

	    if test -z "$partid"; then
		logger "No existing partition found for $ondev"
		return 1
	    fi

	    logger "found matching existing partition $id"

	    logger "calling setup_partition $id $*"
	    setup_partition $partid $*

	fi

	# copy last bit of create_primary_functions

	primary=''
	scheme="$scheme_rest"
	free_space=$new_free_space
	free_type="$new_free_type"
    done
}


# Analogous to auto_lvm_create_partitions()
# Called from auto_multiboot_prepare() (the equiv of auto_lvm_prepare())
#
# Create the partitions needed by a recipe to hold all PVs
# (need $scheme and $pv_devices in scope)
auto_multiboot_create_partitions() {
    local dev free_size
    dev=$1
    logger "dev $dev"

    logger "entering get_last_free_partition_infos"
    get_last_free_partition_infos $dev
    free_size=$(convert_to_megabytes $free_size)

    logger "entering expand_scheme"
    expand_scheme
    logger "scheme:  $scheme"
    

    logger "entering ensure_primary"
    ensure_primary

    logger "free_type: $free_type"
    logger "entering check_primary_partitions"
    check_primary_partitions
    logger "NOT entering create_partitions"
    # create_partitions tells parted server to create primary &
    # logical partitions and set flags, as appropriate
    # multiboot isn't interested in this
    #
    #create_partitions
}


# this is a copy of recipes.sh:update_all
#
# this isn't needed; just for logging/debugging
update_all_multiboot () {
    local dev num id size type fs path name partitions
    logger "in update_all_multiboot"
    for dev in $DEVICES/*; do
	logger "dev $dev $(test -d $dev || echo not a dir)"
	[ -d "$dev" ] || continue
	cd $dev
	partitions=''
	open_dialog PARTITIONS
	while { read_line num id size type fs path name; [ "$id" ]; }; do
	    partitions="$partitions $id"
	done
	logger "    partitions $partitions"
	close_dialog
	for id in $partitions; do
	    logger "calling update_partition $dev $id"
	    update_partition $dev $id
	done
    done
}


# This copies parts of lvm-remove.sh:device_remove_lvm() that remove lvs.
#
# It doesn't blindly remove everything, though, so it checks for
# conflicts between existing LVs and LVs defined in $lvmscheme.
device_remove_conflicting_lvs() {
    local dev realdev vgs vg lv
    dev="$1"
    cd $dev

    logger "in device_remove_conflicting_lvs $*"

    # This first part copies the first part of device_remove_lvm()

    # Check if the device already contains any physical volumes
    realdev=$(mapdevfs "$(cat $dev/device)")
    if ! pv_on_device "$realdev"; then
	logger "pv not on device $realdev; leaving device_remove_conflicting_lvs"
	return 0
    fi

    vgs="$(remove_lvm_find_vgs $realdev)" || {
	logger "remove_lvm_find_vgs failed; leaving device_remove_conflicting_lvs"
	return 1
    }
    [ "$vgs" ] || {
	logger "no vgs found to remove; leaving device_remove_conflicting_lvs"
	return 0
    }

    # Skip parts about asking permission to erase LVM volumes

    # Copy the part where LVs are removed; however, only remove those
    # in $lvmscheme

    # We need devicemapper support here
    modprobe dm-mod >/dev/null 2>&1

    for vg in $vgs; do
	logger "checking vg $vg"
	# Remove LVs from the VG
	for lv in $(vg_list_lvs $vg); do
	    logger "checking lv $lv"
	    # check for and remove conflicting LVs
	    echo "$lvmscheme" | \
		grep -e "in_vg{ $vg }.*lv_name{ $lv }" \
		-e "lv_name{ $lv }.*in_vg{ $vg }" && \
		{ logger "calling lv_delete $vg $lv"; lv_delete $vg $lv; }
	done
    done

    # Skip removing PVs

    # And copy the code that checks if partman needs a restart

    # Make sure that parted has no stale LVM info
    restart=""
    for tmpdev in $DEVICES/*; do
	[ -d "$tmpdev" ] || continue

	realdev=$(cat $tmpdev/device)

	if [ -b "$realdev" ] || \
	    ! $(echo "$realdev" | grep -q "/dev/mapper/"); then
	    continue
	fi

	rm -rf $tmpdev
	restart=1
    done

    if [ "$restart" ]; then
	return 99
    fi
    return 0
}


# This is a copy of auto_lvm_prepare() with auto_init_disks() disabled
auto_multiboot_prepare() {
    local devs main_device extra_devices method size free_size normalscheme
    local pvscheme lvmscheme target dev devdir main_pv physdev restart

    logger "in auto_multiboot_prepare $*"

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
    
    logger "main_device $main_device"
    logger "extra_devices $extra_devices"
    logger "size $size"

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

    logger "entering choose_recipe lvm $target $free_size"

    choose_recipe lvm "$target" "$free_size" || return $?

    logger "scheme:"
    IFS="$NL"
    for l in $scheme; do
	logger "        $l"
    done
    restore_ifs

    logger "NOT calling auto_init_disks $devs"
    # auto-shared.sh:auto_init_disks() wipes out every trace of LVM on
    # the disk and wipes the disk label.  We don't want this.
    # However, we do need to remove LVMs that conflict with our
    # scheme; see device_remove_conflicting_lvs() below.
    #
    #auto_init_disks $devs || return $?

    for dev in $devs; do
	logger "looking at dev $dev"
	get_last_free_partition_infos $dev
	logger "free_space $free_space; free_size $free_size; free_type $free_type"

	# Check if partition is usable; use existing partman-auto
	# template as we depend on it
	if [ "$free_type" = unusable ]; then
	    logger "found free_type = unusable"
	    db_input critical partman-auto/unusable_space || true
	    db_go || true
	    return 1
	fi
    done

    # Change to any one of the devices - we arbitrarily pick the first -
    # to ensure that partman-auto can detect its label.  Of course this
    # only works if all the labels match, but that should be the case
    # since we just initialised them all following the same rules.
    logger "entering decode_recipe"
    cd "${devs%% *}"
    decode_recipe $recipe lvm
    cd -
    logger "exiting decode_recipe"

    logger "checking for lvmok tags"
	# Make sure the recipe contains lvmok tags
    if ! echo "$scheme" | grep -q lvmok; then
	bail_out unusable_recipe
    fi

    logger "checking boot partition is not on LVM"
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
    logger "normalscheme:"
    IFS="$NL"
    for l in $normalscheme; do
	logger "        $l"
    done
    restore_ifs

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
	    logger "make sure /boot is in normalscheme"
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
    logger "main_pv $main_pv"

    # Partitions with method $method will hold Physical Volumes
    pvscheme=$(echo "$normalscheme" | grep "method{ $method }")
    logger "pvscheme $pvscheme"

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
    logger "scheme $scheme"

    # Now that we have the schemes worked out, remove any existing LVs
    # that conflict.
    #
    # auto-shared.sh:auto_init_disks() calls
    # disk-label.sh:prepare_new_labels(); parts of that are below.
    #
    # In turn, that calls lvm-remove.sh:device_remove_lvm(); parts of
    # that are above in device_remove_conflicting_lvs().
    logger "Calling device_remove_conflicting_lvs() instead"
    restart=
    for dev in $devs; do
	device_remove_conflicting_lvs $dev || {
	    case $? in
		99) restart=1 ;;
		*)
		    logger "device_remove_conflicting_lvs failed"
		    logger "exiting auto_multiboot_prepare"
		    return 1
		    ;;
	    esac
	}
    done
    if [ "$restart" ]; then
	logger "restarting partman server"
	stop_parted_server
	restart_partman || return 1
    fi


    logger "entering auto_multiboot_create_partitions"
    auto_multiboot_create_partitions $main_device
    logger "exited auto_multiboot_create_partitions"

    # Create partitions for PVs on extra devices
    for dev in $extra_devices; do
	logger "creating part for extra device dev $dev"
	physdev=$(cat $dev/device)
	scheme="$(echo "$pvscheme" | grep "device{ $physdev[[:digit:]]* }")"
	if [ -z "$scheme" ]; then
	    scheme="$(add_envelope "")"
	fi
	auto_multiboot_create_partitions $dev
    done

    logger "entering auto_lvm_create_vg_map"
    logger "   with lvmscheme:"
    IFS="$NL"
    for l in $lvmscheme; do
	logger "        $l"
    done
    logger "   with pvscheme:"
    for l in $pvscheme; do
	logger "        $l"
    done
    restore_ifs
    logger "    with pv_devices $pv_devices"
    # Extract the mapping of which VG goes onto which PV
    auto_lvm_create_vg_map

    logger "entering confirm_changes"
    if ! confirm_changes partman-lvm; then
	return 255
    fi

    logger "entering disable_swap"
    disable_swap
    logger "NOT writing partition tables"
    # Write the partition tables
    # for dev in $devs; do
    # 	cd $dev
    # 	open_dialog COMMIT
    # 	close_dialog
    # 	device_cleanup_partitions
    # done
    logger "entering update_all_multiboot"
    update_all_multiboot
    logger "exiting auto_multiboot_prepare"
}
