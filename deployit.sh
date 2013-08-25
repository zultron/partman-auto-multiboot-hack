#!/bin/sh
#
# Deploy the partman-auto-multiboot hack
#

DESTHOST=foo
DESTDIR=/v/distro/provisioning/debian-multiboot-hack
URL=http://web0.zultron.com/provisioning/debian-multiboot-hack

if test -d /var/lib/anna-install; then
    # in the debian installer miniroot

    # ensure our directories exist
    mkdir -p /lib/partman/lib

    # fetch things
    fetch-url $URL/autopartition-multiboot /bin/autopartition-multiboot
    fetch-url $URL/initial_auto_multiboot \
	/lib/partman/display.d/05initial_auto_multiboot
    fetch-url $URL/auto-multiboot.sh /lib/partman/lib/auto-multiboot.sh
    fetch-url $URL/perform_recipe_by_multiboot /bin/perform_recipe_by_multiboot

    # make them executable
    chmod +x \
	/bin/autopartition-multiboot \
	/bin/perform_recipe_by_multiboot \
	/lib/partman/display.d/05initial_auto_multiboot
else
    # in the dev environment
    cd $(dirname $0)

    # prepare a distribution
    rm -rf deploy
    mkdir -p deploy
    cp autopartition-multiboot perform_recipe_by_multiboot \
	lib/auto-multiboot.sh \
	display.d/initial_auto_multiboot $0 \
	deploy

    # deploy a tarball
    ssh $DESTHOST mkdir -p $DESTDIR
    tar czfC - deploy . | ssh $DESTHOST tar xzfC - $DESTDIR

    # clean up
    rm -rf deploy
fi