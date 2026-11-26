#!/bin/bash
#~~~~~~~~~~
# Builds the pinned phpredis release (the PHP redis extension, redis.so) from PECL's tarball on this
# build server for the release's PHP (8.5 on resolute), packages it as php8.5-redis in place of
# Ubuntu's (same files, same maintainer scripts, a higher version) and publishes it there. Built per
# release (PHP's API number follows the release), so deploy.sh runs it with --per-server:
# build-resolute only for now (publish-apt.sh's module_releases).
#
# Why: Ubuntu resolute ships 6.2.0, whose cluster_update_slot() dereferences a NULL slaves list after a
# failover's MOVED and kills the php-fpm worker (rediscluster sessions); 6.3.0 has the fix (phpredis PR 2552).
#
# Run this in the directory deploy.sh synced it to (/var/www/build/sc-phpredis).

set -euo pipefail

version=$(tr -d ' \t\n' < VERSION.txt)
checksum=$(tr -d ' \t\n' < SHA256.txt)
ubuntu_codename=$(lsb_release -sc)
php=8.5
package="php${php}-redis"
# The packaging revision: 6.3.0-0sc1 sorts above Ubuntu's 6.2.0-1ubuntu1 and below a later Ubuntu 6.3.0-1ubuntu1.
revision=$( [ -f REVISION.txt ] && tr -d ' \t\n' < REVISION.txt || true)
package_version="${version}${revision:+-$revision}~${ubuntu_codename}"
deb_file="${package}_${package_version}_amd64.deb"

# Build dependencies (also listed for the build servers' template in 1webman's design). igbinary's
# headers come with php8.5-igbinary.
DEBIAN_FRONTEND=noninteractive apt-get -y -q install build-essential dpkg-dev "php${php}-dev" "php${php}-igbinary" liblz4-dev libzstd-dev >/dev/null

rm -rf pkg work
mkdir -p work pkg/DEBIAN

tarball="work/redis-$version.tgz"
echo "Downloading phpredis $version from PECL"
curl -fsSL -o "$tarball" "https://pecl.php.net/get/redis-$version.tgz"
# The release as published, or nothing: SHA256.txt is the checksum of the tarball that was checked
# (against the GitHub tag's sources) when VERSION.txt was set.
if [ "$(sha256sum "$tarball" | cut -d' ' -f1)" != "$checksum" ]; then
    echo "$tarball doesn't match SHA256.txt: not packaged" >&2
    exit 1
fi
tar --no-same-owner -xzf "$tarball" -C work # the build folder is on NFS (root squashed): no chown
src="work/redis-$version"

# As Ubuntu builds it: igbinary, lz4 and zstd (the php, json and igbinary serializers; zstd and lz4 compression).
(
    cd "$src"
    "phpize$php" >/dev/null
    ./configure -q --with-php-config="php-config$php" --enable-redis-igbinary --enable-redis-lz4 --with-liblz4 \
        --enable-redis-zstd --with-libzstd >/dev/null
    make -s -j"$(nproc)" >/dev/null
)
api=$("php-config$php" --phpapi)
extension_dir=$("php-config$php" --extension-dir)

install -D -m 644 "$src/modules/redis.so" "pkg$extension_dir/redis.so"
strip --strip-unneeded "pkg$extension_dir/redis.so"
install -d "pkg/etc/php/$php/mods-available"
printf '; priority=25\nextension=redis.so\n' > "pkg/etc/php/$php/mods-available/redis.ini"
echo "/etc/php/$php/mods-available/redis.ini" > pkg/DEBIAN/conffiles
# Ubuntu's own maintainer scripts (dh_php's: the module enabled for every SAPI, its links cleaned up),
# unchanged. Enabling it fires php-fpm's trigger: dpkg restarts php8.5-fpm on install and upgrade.
install -m 755 debian/preinst debian/postinst debian/prerm debian/postrm pkg/DEBIAN/

# It loads, with igbinary, and says its version.
loaded=$("php$php" -n -d extension=igbinary -d "extension=$(pwd)/pkg$extension_dir/redis.so" -r 'echo phpversion("redis");')
[ "$loaded" = "$version" ] || { echo "redis.so says $loaded, not $version" >&2; exit 1; }
"php$php" -n -d extension=igbinary -d "extension=$(pwd)/pkg$extension_dir/redis.so" --ri redis | grep -q 'Available serializers => .*igbinary' ||
    { echo "redis.so has no igbinary serializer" >&2; exit 1; }

# Depends: what redis.so links, on this release.
mkdir -p work/shlibs/debian
printf 'Source: php-redis\n\nPackage: %s\nArchitecture: amd64\n' "$package" > work/shlibs/debian/control
libraries=$(cd work/shlibs && dpkg-shlibdeps -O "../../pkg$extension_dir/redis.so" 2>/dev/null | sed -n 's/^shlibs:Depends=//p')
[ -n "$libraries" ] || { echo "dpkg-shlibdeps found no Depends" >&2; exit 1; }

cat > pkg/DEBIAN/control <<CONTROL
Package: $package
Source: php-redis
Version: $package_version
Architecture: amd64
Maintainer: Roelof Rossouw
Pre-Depends: php-common (>= 2:69~)
Depends: php${php}-common, php${php}-igbinary, phpapi-$api, $libraries
Suggests: redis-server
Breaks: php-redis (<< 6.2.0~)
Replaces: php-redis (<< 6.2.0~)
Provides: php-redis
Section: php
Priority: optional
Homepage: https://pecl.php.net/package/redis
Description: PHP extension for interfacing with Redis (phpredis $version)
 phpredis $version, built from PECL's release for PHP $php on Ubuntu $ubuntu_codename with the
 igbinary serializer and lz4/zstd compression, as Ubuntu's php${php}-redis is. Packaged in its
 place for the fix to Redis Cluster's slot update after a failover (phpredis PR 2552), which
 crashes 6.2.0's php-fpm workers that keep sessions in a cluster.
CONTROL

install -d "pkg/usr/share/doc/$package"
{
    echo "$package packages phpredis $version (https://github.com/phpredis/phpredis), built from PECL's"
    echo "release unmodified. The packaging scripts (https://github.com/roelofrossouw/simply-cpp-phpredis) are"
    echo "Apache-2.0; the maintainer scripts are Debian's (dh_php). phpredis is under the PHP License 3.01:"
    echo
    cat "$src/LICENSE"
} > "pkg/usr/share/doc/$package/copyright"
(cd pkg && find . -type f ! -path './DEBIAN/*' -printf '%P\0' | sort -z | xargs -0 md5sum > DEBIAN/md5sums)

dpkg-deb --build --root-owner-group pkg "$deb_file"

pushd /var/www/build/repo >/dev/null
export GNUPGHOME=/var/www/build/signing
if reprepro list "$ubuntu_codename" | grep -q "$package .*$package_version"; then
    echo "$ubuntu_codename: $package $package_version already published"
else
    echo "$ubuntu_codename: publishing $package $package_version"
    reprepro remove "$ubuntu_codename" "$package" || true
    reprepro includedeb "$ubuntu_codename" "/var/www/build/sc-phpredis/$deb_file"
fi
popd >/dev/null

echo "Done."
